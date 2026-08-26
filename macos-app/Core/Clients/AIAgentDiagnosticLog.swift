// AI Agent 诊断日志层（OpenAICompatibleAgentClient / V2 ModelGateway 共用）。
// 原生于 Core/TrendResearch/AIAgentDiagnosticLog.swift（旧趋势链路），旧链路
// 下线（WF-4）时随消费方迁入 Core/Clients 归位。API Key 等敏感信息永不进入。
import Foundation

/// 一次 AI 分析运行的非敏感元数据。API Key、Cookie 和请求头永不进入该结构。
struct AIAgentDiagnosticRunMetadata: Codable, Hashable, Sendable {
    let runID: UUID
    let agentKind: String
    let scope: String
    let trigger: String
    let providerName: String
    let baseURL: String
    let model: String
    let privacyMode: String
    let startedAt: String
}

struct AIAgentDiagnosticTraceEntry: Codable, Hashable, Sendable {
    let sequence: Int
    let timestamp: String
    let event: String
    let turn: Int?
    let toolName: String?
    let toolCallID: String?
    let payload: AgentJSONValue?
}

struct AIAgentModelRequestTrace: Encodable, Sendable {
    let model: String
    let messages: [AgentChatMessage]
    let tools: [AgentToolDefinition]
    let toolChoice: AgentToolChoice
    let temperature: Double
    let timeoutSeconds: Double
}

struct AIAgentModelResponseTrace: Encodable, Sendable {
    let assistantMessage: AgentChatMessage
    let stopReason: String
    let finishReason: String?
    let durationSeconds: Double

    init(result: AgentCompletionResult, durationSeconds: Double) {
        assistantMessage = result.assistantMessage
        finishReason = result.finishReason
        self.durationSeconds = durationSeconds
        stopReason = switch result.stopReason {
        case .stop: "stop"
        case .toolCalls: "tool_calls"
        case .length: "length"
        case .contentFilter: "content_filter"
        case .other(let value): value
        }
    }
}

/// 单次运行独享的 JSONL 写入器。每一行都是独立 JSON，运行中崩溃时也能保留
/// 已经完成的请求、响应和工具结果，不依赖最终审计产物成功落盘。
actor AIAgentDiagnosticRecorder {
    nonisolated let fileURL: URL

    private var sequence: Int
    private let encoder: JSONEncoder

    init(
        directoryURL: URL,
        metadata: AIAgentDiagnosticRunMetadata,
        maximumFileCount: Int = 20,
        maximumTotalBytes: Int64 = 200 * 1024 * 1024
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let day = String(metadata.startedAt.prefix(10))
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let safeScope = metadata.scope
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        fileURL = directoryURL.appendingPathComponent(
            "\(String(day))-\(String(safeScope))-\(metadata.runID.uuidString).jsonl",
            isDirectory: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        sequence = 1

        let initial = AIAgentDiagnosticTraceEntry(
            sequence: 1,
            timestamp: Self.timestamp(),
            event: "run_started",
            turn: nil,
            toolName: nil,
            toolCallID: nil,
            payload: AIAgentDiagnosticRedactor.payload(metadata)
        )
        let initialData = try Self.lineData(initial, encoder: encoder)
        try initialData.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        try Self.trimLogs(
            in: directoryURL,
            maximumFileCount: max(1, maximumFileCount),
            maximumTotalBytes: max(1, maximumTotalBytes)
        )
    }

    func record(
        event: String,
        turn: Int? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil,
        payload: AgentJSONValue? = nil
    ) throws {
        sequence += 1
        let entry = AIAgentDiagnosticTraceEntry(
            sequence: sequence,
            timestamp: Self.timestamp(),
            event: event,
            turn: turn,
            toolName: toolName,
            toolCallID: toolCallID,
            payload: payload.map(AIAgentDiagnosticRedactor.redacted)
        )
        let data = try Self.lineData(entry, encoder: encoder)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func lineData(
        _ entry: AIAgentDiagnosticTraceEntry,
        encoder: JSONEncoder
    ) throws -> Data {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    private static func trimLogs(
        in directoryURL: URL,
        maximumFileCount: Int,
        maximumTotalBytes: Int64
    ) throws {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        var files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate)
                ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate)
                ?? .distantPast
            return lhs > rhs
        }

        for staleURL in files.dropFirst(maximumFileCount) {
            try FileManager.default.removeItem(at: staleURL)
        }
        files = Array(files.prefix(maximumFileCount))

        var totalBytes = files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: keys).fileSize) ?? 0
            return total + Int64(size)
        }
        // 始终保留最新一份，即使单份日志本身超过总量上限。
        for staleURL in files.dropFirst().reversed() where totalBytes > maximumTotalBytes {
            let size = (try? staleURL.resourceValues(forKeys: keys).fileSize) ?? 0
            try FileManager.default.removeItem(at: staleURL)
            totalBytes -= Int64(size)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: .now)
    }
}

/// TaskLocal 会随 async/await 和结构化子任务传播，因此趋势研究、盘中 V2 子 Agent
/// 以及专项研究都能复用同一份运行日志，不需要把文件路径侵入每个 Agent 协议。
enum AIAgentDiagnosticLog {
    @TaskLocal static var recorder: AIAgentDiagnosticRecorder?

    /// 进程级默认 recorder（十七轮 P2：TaskLocal 只在 withValue 作用域内
    /// 生效——生产 App 无作用域包裹,record 全是 no-op；App 引导时
    /// setDefaultRecorder 挂文件 recorder，TaskLocal 优先于默认）。
    private static let defaultRecorderLock = NSLock()
    private static var _defaultRecorder: AIAgentDiagnosticRecorder?

    static func setDefaultRecorder(_ recorder: AIAgentDiagnosticRecorder) {
        defaultRecorderLock.lock()
        defer { defaultRecorderLock.unlock() }
        _defaultRecorder = recorder
    }

    static var effectiveRecorder: AIAgentDiagnosticRecorder? {
        if let recorder { return recorder }
        defaultRecorderLock.lock()
        defer { defaultRecorderLock.unlock() }
        return _defaultRecorder
    }

    static func record<T: Encodable>(
        _ event: String,
        turn: Int? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil,
        payload: T
    ) async {
        guard let recorder = effectiveRecorder else { return }
        try? await recorder.record(
            event: event,
            turn: turn,
            toolName: toolName,
            toolCallID: toolCallID,
            payload: AIAgentDiagnosticRedactor.payload(payload)
        )
    }

    static func record(
        _ event: String,
        turn: Int? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil,
        message: String
    ) async {
        await record(
            event,
            turn: turn,
            toolName: toolName,
            toolCallID: toolCallID,
            payload: ["message": message]
        )
    }

    static func recordToolResult(
        turn: Int,
        call: AgentToolCall,
        contentJSON: String,
        modelContentJSON: String? = nil,
        isError: Bool
    ) async {
        let arguments = AIAgentDiagnosticRedactor.jsonPayload(call.function.arguments)
        let result = AIAgentDiagnosticRedactor.jsonPayload(contentJSON)
        var fields: [String: AgentJSONValue] = [
            "arguments": arguments,
            "is_error": .bool(isError),
            "result": result,
        ]
        if let modelContentJSON {
            fields["model_message"] = AIAgentDiagnosticRedactor.jsonPayload(modelContentJSON)
        }
        guard let recorder else { return }
        try? await recorder.record(
            event: "tool_result",
            turn: turn,
            toolName: call.function.name,
            toolCallID: call.id,
            payload: .object(fields)
        )
    }
}

enum AIAgentDiagnosticRedactor {
    private static let sensitiveKeys: Set<String> = [
        "apikey", "authorization", "cookie", "setcookie", "token",
        "accesstoken", "refreshtoken", "secret", "clientsecret", "password",
    ]

    static func payload<T: Encodable>(_ value: T) -> AgentJSONValue {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let decoded = try? JSONDecoder().decode(AgentJSONValue.self, from: data) else {
            return .string("[payload-encoding-failed]")
        }
        return redacted(decoded)
    }

    static func jsonPayload(_ value: String) -> AgentJSONValue {
        guard let decoded = try? JSONDecoder().decode(
            AgentJSONValue.self,
            from: Data(value.utf8)
        ) else {
            return .string(redactedText(value))
        }
        return redacted(decoded)
    }

    static func redacted(_ value: AgentJSONValue) -> AgentJSONValue {
        switch value {
        case .null, .bool, .number:
            return value
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
               let nested = try? JSONDecoder().decode(
                   AgentJSONValue.self,
                   from: Data(trimmed.utf8)
               ) {
                let redactedNested = redacted(nested)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(redactedNested),
                   let encoded = String(data: data, encoding: .utf8) {
                    return .string(encoded)
                }
            }
            return .string(redactedText(text))
        case .array(let values):
            return .array(values.map(redacted))
        case .object(let object):
            return .object(
                object.mapValues { key, value in
                    sensitiveKeys.contains(normalizedKey(key))
                        ? .string("[redacted]")
                        : redacted(value)
                }
            )
        }
    }

    static func redactedText(_ value: String) -> String {
        var result = value
        let patterns = [
            #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
            #"\btvly-[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._-]{8,}\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[redacted]"
            )
        }
        if let expression = try? NSRegularExpression(
            pattern: #"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password|authorization|cookie)(\s*[:=]\s*[\"']?)[^&\s\"',}]+"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1$2[redacted]"
            )
        }
        return result
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

private extension Dictionary {
    func mapValues<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { key, value in
            (key, transform(key, value))
        })
    }
}
