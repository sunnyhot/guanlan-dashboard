import Foundation

// 阶段一：OpenAI-compatible chat/completions 传输层。
//
// OpenAICompatibleAgentClient 只负责请求/响应协议：
//   - 发送 messages / tools / tool_choice / temperature
//   - 解析流式 SSE 或普通 JSON assistant 消息及其 tool_calls（content 为 null 也合法）
//   - 把 HTTP 错误、超时、限流映射成用户可读说明
//   - 提供真实工具调用能力探测，决定是否允许启动内嵌 Agent
//
// 不包含趋势分析业务规则；业务规则在 Agent、工具和 Validator 中。

/// 一次工具调用能力探测的结果。
struct TrendProviderCapabilities: Hashable, Sendable {
    /// 模型是否能发起原生 tool_calls。只有为 true 才允许启动内嵌 Agent。
    let supportsToolCalls: Bool
    /// 是否支持指定函数的 tool_choice（部分供应商只支持 auto）。
    let supportsForcedToolChoice: Bool
    /// 探测时所用的 Provider 指纹；与当前配置不符时检测结果视为过期，需重新探测。
    let providerFingerprint: String
    let checkedAt: String
    let detail: String
}

enum OpenAICompatibleAgentClientError: Error, LocalizedError {
    case missingConfiguration
    case invalidBaseURL
    case requestFailed(statusCode: Int?, detail: String?)
    case timedOut(Double)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "尚未配置趋势分析模型。请填写模型地址、模型名称和 API Key。"
        case .invalidBaseURL:
            return "趋势分析模型地址无效。"
        case .requestFailed(let statusCode, let detail):
            let suffix = detail.map { " \($0)" } ?? ""
            if statusCode == 429 {
                return Self.rateLimitDescription(detail: detail)
            }
            if let statusCode {
                return "趋势分析模型请求失败：HTTP \(statusCode)。\(suffix)"
            }
            return "趋势分析模型请求失败。\(suffix)"
        case .timedOut(let seconds):
            return "趋势分析模型请求超时：\(Int(seconds.rounded())) 秒内未完成有效响应。请检查模型服务状态或稍后重试。"
        case .invalidResponse(let detail):
            return "模型接口返回格式不符合 OpenAI-compatible chat/completions：\(detail)"
        }
    }

    /// 能力探测时，哪些错误可以退回 auto 再试一次（只有「供应商不接受指定函数 tool_choice」这类才退回）。
    var isCapabilityProbeRecoverable: Bool {
        switch self {
        case .requestFailed(let statusCode, _) where statusCode == 400 || statusCode == 422:
            return true
        default:
            return false
        }
    }

    private static func rateLimitDescription(detail: String?) -> String {
        let normalized = detail?.lowercased() ?? ""
        let original = detail.map { " 原始信息：\($0)" } ?? ""
        if normalized.contains("余额不足") || normalized.contains("无可用资源包") || normalized.contains("1113") {
            return "趋势分析模型请求失败：HTTP 429。服务商提示余额不足或无可用资源包，请确认 API Key 对应的套餐/资源包。\(original)"
        }
        if normalized.contains("rate limit") || normalized.contains("1302") || normalized.contains("limit reached") {
            return "趋势分析模型请求失败：HTTP 429。服务商提示请求频率或并发超限，请稍后重试或检查该 API Key 的限额。\(original)"
        }
        return "趋势分析模型请求失败：HTTP 429。服务商限流或资源不可用，请稍后重试并检查 API Key 套餐/限额。\(original)"
    }
}

struct OpenAICompatibleAgentClient: Sendable {
    /// finish_reason 后等待 usage 尾包的短空闲窗口（秒）——等不到说明
    /// 该服务不支持 include_usage，交由保守估算兜底。
    static let postFinishUsageGraceSeconds: Double = 5

    let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// 能力探针使用的无副作用工具名。
    static let capabilityProbeToolName = "agent_capability_probe"

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 发起一轮 chat/completions，返回 assistant 消息、工具调用与停止原因。
    ///
    /// 普通文本响应（无 tool_calls）不是错误，由调用方决定如何处理。
    /// `timeout` 非空时覆盖 settings 的请求超时，用于 Agent 运行策略的单次请求上限。
    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice = .auto,
        temperature: Double = 0.2,
        maxOutputTokens: Int? = nil,
        settings: TrendAIProviderSettings,
        timeout: Double? = nil,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)? = nil,
        onContentDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> AgentCompletionResult {
        guard settings.isConfigured else {
            throw OpenAICompatibleAgentClientError.missingConfiguration
        }

        let url = try Self.chatCompletionsURL(baseURL: settings.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let effectiveTimeout = timeout ?? settings.timeoutSeconds
        request.timeoutInterval = effectiveTimeout
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(
            AgentChatCompletionRequest(
                model: settings.model,
                messages: messages,
                tools: tools.isEmpty ? nil : tools,
                toolChoice: tools.isEmpty ? nil : toolChoice,
                temperature: temperature,
                maxTokens: maxOutputTokens,
                stream: true,
                streamOptions: ["include_usage": true]
            )
        )
        let requestStartedAt = Date()
        let hardDeadline = requestStartedAt.addingTimeInterval(effectiveTimeout)
        await AIAgentDiagnosticLog.record(
            "model_request",
            payload: AIAgentModelRequestTrace(
                model: settings.model,
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                temperature: temperature,
                timeoutSeconds: effectiveTimeout
            )
        )

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAICompatibleAgentClientError.requestFailed(statusCode: nil, detail: nil)
            }

            guard (200..<300).contains(http.statusCode) else {
                let data = try await Self.collect(
                    bytes,
                    deadline: hardDeadline,
                    timeoutSeconds: effectiveTimeout
                )
                throw OpenAICompatibleAgentClientError.requestFailed(
                    statusCode: http.statusCode,
                    detail: Self.providerErrorMessage(from: data, decoder: decoder)
                )
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let result: AgentCompletionResult
            if contentType.contains("text/event-stream") {
                result = try await Self.decodeStreamingResponse(
                    bytes,
                    statusCode: http.statusCode,
                    startedAt: requestStartedAt,
                    timeoutSeconds: effectiveTimeout,
                    progressHandler: streamProgress,
                    contentHandler: onContentDelta
                )
            } else {
                // 部分 OpenAI-compatible 服务会忽略 stream=true，仍返回普通 JSON；
                // 也有代理漏写 text/event-stream。完整收集后同时兼容这两类响应。
                let data = try await Self.collect(
                    bytes,
                    deadline: hardDeadline,
                    timeoutSeconds: effectiveTimeout
                )
                if Self.looksLikeEventStream(data) {
                    result = try Self.decodeBufferedEventStream(data, statusCode: http.statusCode)
                } else {
                    result = try Self.decodeCompletion(data, decoder: decoder)
                }
                // 非流式路径没有增量可发，整段正文一次性透出（UI 仍能看到输出）。
                if let text = result.assistantMessage.content, !text.isEmpty {
                    await onContentDelta?(text)
                }
            }
            // usage 缺失（服务不支持 include_usage / JSON 响应未带）时按
            // 保守估算记账——宁可高估不漏记，tokenBudget 不因缺计量而失效
            //（十五轮审查 P1-2）。
            let resultWithUsage = Self.ensureUsage(
                result, messages: messages, tools: tools
            )
            await AIAgentDiagnosticLog.record(
                "model_response",
                payload: AIAgentModelResponseTrace(
                    result: resultWithUsage,
                    durationSeconds: Date().timeIntervalSince(requestStartedAt)
                )
            )
            return resultWithUsage
        } catch let error as URLError where error.code == .timedOut {
            let mapped = OpenAICompatibleAgentClientError.timedOut(effectiveTimeout)
            await AIAgentDiagnosticLog.record(
                "model_error",
                message: mapped.localizedDescription
            )
            throw mapped
        } catch let error as OpenAICompatibleAgentClientError {
            await AIAgentDiagnosticLog.record(
                "model_error",
                message: error.localizedDescription
            )
            throw error
        } catch {
            let mapped = OpenAICompatibleAgentClientError.requestFailed(
                statusCode: nil,
                detail: error.localizedDescription
            )
            await AIAgentDiagnosticLog.record(
                "model_error",
                message: mapped.localizedDescription
            )
            throw mapped
        }
    }

    /// 真实工具调用能力探测。
    ///
    /// 优先用指定函数的 `tool_choice` 探测；供应商不接受（400/422）或仅返回普通文本时
    /// 退回 `auto` 再探一次。只有响应里出现合法 `tool_calls` 才视为支持内嵌 Agent。
    /// 鉴权、限流、5xx、网络和超时等错误不退回，直接抛出交给调用方展示。
    func checkToolCallingCapability(settings: TrendAIProviderSettings) async throws -> TrendProviderCapabilities {
        guard settings.isConfigured else {
            throw OpenAICompatibleAgentClientError.missingConfiguration
        }

        let tool = AgentToolDefinition.function(
            name: Self.capabilityProbeToolName,
            description: "连通性探针。被调用时立即返回 ok=true，无副作用。仅用于检测模型是否支持工具调用。",
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        )
        let messages: [AgentChatMessage] = [
            .init(role: .system, content: "你是工具调用能力探针。必须调用 agent_capability_probe 工具，不要输出普通文本。"),
            .init(role: .user, content: "请立即调用 agent_capability_probe 工具。")
        ]

        // 1) 优先探测指定函数的 tool_choice。
        do {
            let result = try await complete(
                messages: messages,
                tools: [tool],
                toolChoice: .function(name: Self.capabilityProbeToolName),
                temperature: 0,
                settings: settings
            )
            if result.toolCalls.contains(where: { $0.function.name == Self.capabilityProbeToolName }) {
                return TrendProviderCapabilities(
                    supportsToolCalls: true,
                    supportsForcedToolChoice: true,
                    providerFingerprint: settings.fingerprint,
                    checkedAt: Self.nowTimestamp(),
                    detail: "模型支持指定函数的 tool_choice。"
                )
            }
            // 指定函数 tool_choice 下仍只返回普通文本，退回 auto 再探。
        } catch let error as OpenAICompatibleAgentClientError {
            // 400/422 视为供应商不接受指定函数 tool_choice，退回 auto；
            // 鉴权、限流、5xx、超时、协议错误等直接抛出。
            guard error.isCapabilityProbeRecoverable else { throw error }
        }

        // 2) 退回 auto 再探一次。
        let result = try await complete(
            messages: messages,
            tools: [tool],
            toolChoice: .auto,
            temperature: 0,
            settings: settings
        )
        let supports = result.toolCalls.contains(where: { $0.function.name == Self.capabilityProbeToolName })
        return TrendProviderCapabilities(
            supportsToolCalls: supports,
            supportsForcedToolChoice: false,
            providerFingerprint: settings.fingerprint,
            checkedAt: Self.nowTimestamp(),
            detail: supports
                ? "模型在 auto 模式下可发起工具调用。"
                : "模型仅返回普通文本，未发起工具调用，不支持内嵌 Agent。"
        )
    }

    // MARK: - Helpers

    private static func chatCompletionsURL(baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/chat/completions") else {
            throw OpenAICompatibleAgentClientError.invalidBaseURL
        }
        return url
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes,
        deadline: Date,
        timeoutSeconds: Double
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4_096), Date() >= deadline {
                throw OpenAICompatibleAgentClientError.timedOut(timeoutSeconds)
            }
            data.append(byte)
        }
        if Date() >= deadline {
            throw OpenAICompatibleAgentClientError.timedOut(timeoutSeconds)
        }
        return data
    }

    private static func decodeCompletion(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> AgentCompletionResult {
        let completion: AgentChatCompletionResponse
        do {
            completion = try decoder.decode(AgentChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAICompatibleAgentClientError.invalidResponse(decodingSummary(error, data: data))
        }

        guard let choice = completion.choices.first else {
            throw OpenAICompatibleAgentClientError.invalidResponse("响应缺少 choices")
        }

        let message = choice.message
        let toolCalls = message.toolCalls ?? []
        return AgentCompletionResult(
            assistantMessage: message,
            toolCalls: toolCalls,
            stopReason: AgentStopReason(finishReason: choice.finishReason),
            finishReason: choice.finishReason,
            usage: completion.usage
        )
    }

    /// usage 缺失时的保守估算：输入（messages + tools 声明）与输出（正文 +
    /// 工具参数）按字符数 / 2 折算 token（中英混合偏高估——保守方向），
    /// 标注 estimated=true 供台账 / 审计区分真实计量与估算。
    private static func ensureUsage(
        _ result: AgentCompletionResult,
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition]
    ) -> AgentCompletionResult {
        if result.usage != nil { return result }
        var promptChars = 0
        for message in messages {
            promptChars += message.content?.utf16.count ?? 0
            for call in message.toolCalls ?? [] {
                promptChars += call.function.name.utf16.count
                promptChars += call.function.arguments.utf16.count
            }
        }
        for tool in tools {
            promptChars += tool.function.name.utf16.count
            promptChars += tool.function.description.utf16.count
        }
        var completionChars = result.assistantMessage.content?.utf16.count ?? 0
        for call in result.toolCalls {
            completionChars += call.function.name.utf16.count
            completionChars += call.function.arguments.utf16.count
        }
        let promptTokens = max((promptChars + 1) / 2, 1)
        let completionTokens = max((completionChars + 1) / 2, 1)
        return AgentCompletionResult(
            assistantMessage: result.assistantMessage,
            toolCalls: result.toolCalls,
            stopReason: result.stopReason,
            finishReason: result.finishReason,
            usage: AgentTokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens,
                estimated: true
            )
        )
    }

    private static func decodeStreamingResponse(
        _ bytes: URLSession.AsyncBytes,
        statusCode: Int,
        startedAt: Date,
        timeoutSeconds: Double,
        progressHandler: (@Sendable (AgentStreamProgress) async -> Void)?,
        contentHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> AgentCompletionResult {
        var accumulator = AgentStreamingResponseAccumulator()
        var eventDataLines: [String] = []
        var lineBuffer = Data()
        var reachedDone = false
        var lastReportedChunkCount = 0
        var lastProgressReportedAt = startedAt
        var lastActivityAt = startedAt
        var lastEmittedContentLength = 0

        // 正文增量透出：content 只增不减，按已发长度切出本次增量。
        func emitPendingContentDelta() async {
            guard let contentHandler, accumulator.content.count > lastEmittedContentLength else { return }
            let delta = String(accumulator.content.dropFirst(lastEmittedContentLength))
            lastEmittedContentLength = accumulator.content.count
            await contentHandler(delta)
        }

        // 不使用 AsyncBytes.lines：它会忽略 SSE 事件之间的空行，进而把相邻
        // `data: {...}\n\ndata: {...}` 错误拼成同一个 JSON。这里直接按原始字节
        // 分行，保留空行作为事件边界。
        for try await byte in bytes {
            guard byte == 0x0A else {
                lineBuffer.append(byte)
                continue
            }
            // 流式超时改为“分片间空闲”：收到字节即续期，超过空闲上限无新数据才收工。
            // 这样推理模型(GLM 等)的长流式响应只要持续吐片就能完成；彻底无字节的卡死由
            // URLSession 的 timeoutInterval 兜底，整体上限由 Agent 整次运行总预算保证。
            // finish_reason 已到但 usage 未到时，只等一个短窗口（尾包紧跟语义
            // 终包，等不到说明该服务不发 usage——保守估算兜底，不耗满全超时）。
            let idleLimit = accumulator.isFinished
                ? min(timeoutSeconds, Self.postFinishUsageGraceSeconds)
                : timeoutSeconds
            let now = Date()
            if now.timeIntervalSince(lastActivityAt) >= idleLimit {
                if accumulator.isFinished {
                    break
                }
                throw OpenAICompatibleAgentClientError.timedOut(timeoutSeconds)
            }
            lastActivityAt = now

            let rawLine = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            reachedDone = try consumeSSELine(
                rawLine,
                eventDataLines: &eventDataLines,
                accumulator: &accumulator,
                statusCode: statusCode
            )
            if accumulator.receivedChunkCount > lastReportedChunkCount {
                let now = Date()
                if accumulator.receivedChunkCount == 1 {
                    await progressHandler?(
                        .firstChunk(elapsed: now.timeIntervalSince(startedAt))
                    )
                    lastProgressReportedAt = now
                    lastReportedChunkCount = accumulator.receivedChunkCount
                } else if now.timeIntervalSince(lastProgressReportedAt) >= 10 {
                    await progressHandler?(
                        .active(
                            chunkCount: accumulator.receivedChunkCount,
                            elapsed: now.timeIntervalSince(startedAt)
                        )
                    )
                    lastProgressReportedAt = now
                    lastReportedChunkCount = accumulator.receivedChunkCount
                }
            }
            await emitPendingContentDelta()
            if reachedDone {
                break
            }
        }

        if !reachedDone, !lineBuffer.isEmpty {
            let rawLine = String(decoding: lineBuffer, as: UTF8.self)
            reachedDone = try consumeSSELine(
                rawLine,
                eventDataLines: &eventDataLines,
                accumulator: &accumulator,
                statusCode: statusCode
            )
        }
        if !reachedDone, !eventDataLines.isEmpty {
            reachedDone = try consumeSSEEvent(
                eventDataLines,
                accumulator: &accumulator,
                statusCode: statusCode
            )
        }
        await emitPendingContentDelta()
        if reachedDone {
            await progressHandler?(
                .finished(
                    chunkCount: accumulator.receivedChunkCount,
                    elapsed: Date().timeIntervalSince(startedAt),
                    finishReason: accumulator.finishReason
                )
            )
        }
        return try accumulator.result()
    }

    private static func consumeSSELine(
        _ rawLine: String,
        eventDataLines: inout [String],
        accumulator: inout AgentStreamingResponseAccumulator,
        statusCode: Int
    ) throws -> Bool {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            let reachedDone = try consumeSSEEvent(
                eventDataLines,
                accumulator: &accumulator,
                statusCode: statusCode
            )
            eventDataLines.removeAll(keepingCapacity: true)
            return reachedDone
        }

        // SSE 注释/心跳以及 event/id/retry 字段不属于模型内容。
        guard !line.hasPrefix(":"), line.hasPrefix("data:") else {
            return false
        }
        var value = String(line.dropFirst(5))
        if value.first == " " {
            value.removeFirst()
        }
        eventDataLines.append(value)
        return false
    }

    private static func decodeBufferedEventStream(
        _ data: Data,
        statusCode: Int
    ) throws -> AgentCompletionResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenAICompatibleAgentClientError.invalidResponse("流式响应不是有效 UTF-8。")
        }

        var accumulator = AgentStreamingResponseAccumulator()
        var eventDataLines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                if try consumeSSEEvent(
                    eventDataLines,
                    accumulator: &accumulator,
                    statusCode: statusCode
                ) {
                    return try accumulator.result()
                }
                eventDataLines.removeAll(keepingCapacity: true)
                continue
            }
            if line.hasPrefix(":") || !line.hasPrefix("data:") {
                continue
            }
            var value = String(line.dropFirst(5))
            if value.first == " " {
                value.removeFirst()
            }
            eventDataLines.append(value)
        }

        if !eventDataLines.isEmpty {
            _ = try consumeSSEEvent(
                eventDataLines,
                accumulator: &accumulator,
                statusCode: statusCode
            )
        }
        return try accumulator.result()
    }

    /// 返回 true 表示收到 `[DONE]`，或已收到带 finish_reason 的语义终包。
    private static func consumeSSEEvent(
        _ dataLines: [String],
        accumulator: inout AgentStreamingResponseAccumulator,
        statusCode: Int
    ) throws -> Bool {
        guard !dataLines.isEmpty else { return false }
        let payload = dataLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return false }
        if payload == "[DONE]" {
            return true
        }

        let data = Data(payload.utf8)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(AgentProviderErrorEnvelope.self, from: data) {
            let detail = [envelope.error.code, envelope.error.type, envelope.error.message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            throw OpenAICompatibleAgentClientError.requestFailed(
                statusCode: statusCode,
                detail: detail.isEmpty ? "服务商在流中返回错误。" : detail
            )
        }

        do {
            let chunk = try decoder.decode(AgentChatCompletionStreamChunk.self, from: data)
            accumulator.append(chunk)
            // 完成条件（十五轮审查 P1-2）：[DONE]，或 finish_reason 已到**且**
            // usage 尾包已收（include_usage 协议下 usage 位于 finish_reason
            // 之后的空 choices 块——收到 finish_reason 就停会永远读不到它）。
            // 只收到 finish_reason 而 usage 未到时继续消费：不支持
            // include_usage 的服务由流 EOF / [DONE] / finish 后短空闲兜底
            // （见 decodeStreamingResponse 的 postFinishUsageGrace）。
            return accumulator.isFinished && accumulator.hasUsage
        } catch {
            throw OpenAICompatibleAgentClientError.invalidResponse(
                "无法解析流式数据块。\(decodingSummary(error, data: data))"
            )
        }
    }

    private static func looksLikeEventStream(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(64), encoding: .utf8) else { return false }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("data:")
    }

    private static func providerErrorMessage(from data: Data, decoder: JSONDecoder) -> String? {
        if let envelope = try? decoder.decode(AgentProviderErrorEnvelope.self, from: data) {
            let parts = [envelope.error.code, envelope.error.type, envelope.error.message]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }
        return responseSnippet(data)
    }

    private static func decodingSummary(_ error: Error, data: Data) -> String {
        var parts: [String] = []
        if let decodingError = error as? DecodingError {
            parts.append(
                AgentDecodingErrorFormatter.describe(
                    decodingError,
                    trailingPeriod: true
                )
            )
        } else {
            parts.append(error.localizedDescription)
        }
        if let snippet = responseSnippet(data) {
            parts.append("返回片段：\(snippet)")
        }
        return parts.joined(separator: " ")
    }

    private static func responseSnippet(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(220))
    }

    private static func nowTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - 请求 / 响应封装

private struct AgentChatCompletionRequest: Encodable {
    let model: String
    let messages: [AgentChatMessage]
    let tools: [AgentToolDefinition]?
    let toolChoice: AgentToolChoice?
    let temperature: Double
    let maxTokens: Int?
    let stream: Bool
    /// stream_options（仅 stream=true 有意义）：include_usage 让供应商在
    /// finish_reason 之后的空 choices 尾包里携带 usage——预算台账的计量
    /// 来源（OpenAI 官方流式协议；十五轮审查 P1-2）。
    let streamOptions: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case streamOptions = "stream_options"
    }
}

private struct AgentChatCompletionResponse: Decodable {
    let choices: [AgentChatChoice]
    let usage: AgentTokenUsage?
}

private struct AgentChatChoice: Decodable {
    let message: AgentChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct AgentChatCompletionStreamChunk: Decodable {
    let choices: [Choice]
    let usage: AgentTokenUsage?

    struct Choice: Decodable {
        let index: Int?
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let role: AgentChatRole?
        let content: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let type: String?
        let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}

private struct AgentStreamingResponseAccumulator {
    private struct PendingToolCall {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""
    }

    private var role: AgentChatRole = .assistant
    private(set) var content = ""
    private var receivedContent = false
    private var pendingToolCalls: [Int: PendingToolCall] = [:]
    private(set) var finishReason: String?
    private var receivedChoice = false
    private(set) var receivedChunkCount = 0
    private var usage: AgentTokenUsage?

    var isFinished: Bool {
        finishReason != nil
    }

    /// 已收到 usage 尾包（include_usage 的最终计量块）。
    var hasUsage: Bool {
        usage != nil
    }

    mutating func append(_ chunk: AgentChatCompletionStreamChunk) {
        // usage 尾包（choices 为空、只带 usage 的块）也要收集，不能随 choices 一起丢。
        if let chunkUsage = chunk.usage {
            usage = chunkUsage
        }
        // choices 为空通常是 include_usage 的尾包，delta 部分直接忽略。
        guard let choice = chunk.choices.first(where: { $0.index == 0 }) ?? chunk.choices.first else {
            return
        }
        receivedChunkCount += 1
        receivedChoice = true
        if let finishReason = choice.finishReason {
            self.finishReason = finishReason
        }
        guard let delta = choice.delta else { return }

        if let role = delta.role {
            self.role = role
        }
        if let fragment = delta.content {
            content += fragment
            receivedContent = true
        }
        for (position, fragment) in (delta.toolCalls ?? []).enumerated() {
            let index = fragment.index ?? position
            var pending = pendingToolCalls[index] ?? PendingToolCall()
            if let id = fragment.id {
                pending.id += id
            }
            if let type = fragment.type, !type.isEmpty {
                pending.type = type
            }
            if let name = fragment.function?.name {
                pending.name += name
            }
            if let arguments = fragment.function?.arguments {
                pending.arguments += arguments
            }
            pendingToolCalls[index] = pending
        }
    }

    func result() throws -> AgentCompletionResult {
        guard receivedChoice else {
            throw OpenAICompatibleAgentClientError.invalidResponse("流式响应缺少 choices 数据块。")
        }

        let toolCalls = try pendingToolCalls.keys.sorted().map { index -> AgentToolCall in
            guard let pending = pendingToolCalls[index] else {
                throw OpenAICompatibleAgentClientError.invalidResponse("流式工具调用索引 \(index) 丢失。")
            }
            guard !pending.id.isEmpty else {
                throw OpenAICompatibleAgentClientError.invalidResponse("流式工具调用 \(index) 缺少 id。")
            }
            guard !pending.name.isEmpty else {
                throw OpenAICompatibleAgentClientError.invalidResponse("流式工具调用 \(index) 缺少 function.name。")
            }
            return AgentToolCall(
                id: pending.id,
                function: AgentToolFunctionCall(
                    name: pending.name,
                    arguments: pending.arguments.isEmpty ? "{}" : pending.arguments
                ),
                type: pending.type
            )
        }

        let resolvedFinishReason = finishReason ?? (toolCalls.isEmpty ? nil : "tool_calls")
        let message = AgentChatMessage(
            role: role,
            content: receivedContent ? content : nil,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
        return AgentCompletionResult(
            assistantMessage: message,
            toolCalls: toolCalls,
            stopReason: AgentStopReason(finishReason: resolvedFinishReason),
            finishReason: resolvedFinishReason,
            usage: usage
        )
    }
}

private struct AgentProviderErrorEnvelope: Decodable {
    let error: AgentProviderError
}

private struct AgentProviderError: Decodable {
    let message: String?
    let type: String?
    let code: String?
}
