import Foundation

// 阶段一：内嵌趋势研究 Agent 的传输层数据模型。
//
// 这些类型描述 OpenAI-compatible chat/completions 协议里的消息、工具定义、
// 工具调用与工具结果。它们只负责协议形状，不含任何趋势分析业务规则。
// 业务规则在 TrendResearchTool / TrendResearchAgent / Validator 中实现。

// MARK: - JSON 值

/// 通用 JSON 值树，用于构造发送给模型的工具参数 JSON Schema。
///
/// 不引入第三方 JSON Schema 运行时；每个工具用各自的 Codable 参数类型完成
/// 运行时校验，这里只负责把 Schema 形状忠实地序列化进请求体。
indirect enum AgentJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
}

extension AgentJSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // 顺序敏感：先布尔再数字，避免 true/false 被当成 1.0。
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法解码为 AgentJSONValue"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension AgentJSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension AgentJSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AgentJSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

// 注：不 conform ExpressibleByDoubleLiteral —— 当前构建工具链下该协议名无法解析。
// 需要浮点字面量时用 .number(value) 显式构造；schema 中实际只用整数字面量。

extension AgentJSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension AgentJSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: AgentJSONValue...) { self = .array(elements) }
}

extension AgentJSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral pairs: (String, AgentJSONValue)...) {
        self = .object(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - 消息与工具调用

enum AgentChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// 一条 chat/completions 消息。
///
/// 同一个类型既用于编码发出的 system/user/tool 消息，也用于解码模型返回的
/// assistant 消息。assistant 消息即使 `content` 为 `null`、只要带有 `tool_calls`
/// 就属于合法响应。
struct AgentChatMessage: Codable, Hashable, Sendable {
    let role: AgentChatRole
    let content: String?
    let toolCalls: [AgentToolCall]?
    let toolCallID: String?

    init(
        role: AgentChatRole,
        content: String? = nil,
        toolCalls: [AgentToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

struct AgentToolCall: Codable, Hashable, Sendable {
    let id: String
    let type: String
    let function: AgentToolFunctionCall

    init(id: String, function: AgentToolFunctionCall, type: String = "function") {
        self.id = id
        self.type = type
        self.function = function
    }
}

struct AgentToolFunctionCall: Codable, Hashable, Sendable {
    let name: String
    /// 模型给出的参数，是字符串化的 JSON，由具体工具用 Codable 参数类型解码校验。
    let arguments: String

    init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - 工具定义与 tool_choice

/// 发送给模型的工具声明。
struct AgentToolDefinition: Codable, Hashable, Sendable {
    let type: String
    let function: Function

    struct Function: Codable, Hashable, Sendable {
        let name: String
        let description: String
        let parameters: AgentJSONValue
    }

    static func function(name: String, description: String, parameters: AgentJSONValue) -> AgentToolDefinition {
        AgentToolDefinition(type: "function", function: Function(name: name, description: description, parameters: parameters))
    }

    enum CodingKeys: String, CodingKey {
        case type
        case function
    }
}

/// `tool_choice` 取值：字符串形式（auto/required）或指定函数的对象形式。
///
/// 只编码、不解码（仅出现在请求体里）。
enum AgentToolChoice: Sendable, Hashable, Encodable {
    case auto
    case required
    case function(name: String)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            var functionContainer = container.nestedContainer(keyedBy: FunctionCodingKeys.self, forKey: .function)
            try functionContainer.encode(name, forKey: .name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case function
    }

    private enum FunctionCodingKeys: String, CodingKey {
        case name
    }
}

// MARK: - 响应解析

/// 一轮模型请求的结果。Agent 循环据此决定执行工具还是结束。
struct AgentCompletionResult: Sendable, Hashable {
    /// 原始 assistant 消息，含原始 `tool_calls`，用于原样回灌下一轮请求。
    let assistantMessage: AgentChatMessage
    /// 从 `tool_calls` 提取出的工具调用；普通文本响应时为空数组。
    let toolCalls: [AgentToolCall]
    let stopReason: AgentStopReason
    let finishReason: String?
}

/// OpenAI-compatible SSE 响应的传输进度。
///
/// 只暴露时序和分片数量，不把模型正文或工具参数写入运行日志。
enum AgentStreamProgress: Sendable, Hashable {
    case firstChunk(elapsed: Double)
    case active(chunkCount: Int, elapsed: Double)
    case finished(chunkCount: Int, elapsed: Double, finishReason: String?)
}

enum AgentStopReason: Sendable, Hashable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case other(String)

    init(finishReason: String?) {
        switch finishReason?.lowercased() {
        case nil, "stop":
            self = .stop
        case "tool_calls":
            self = .toolCalls
        case "length":
            self = .length
        case "content_filter":
            self = .contentFilter
        case let .some(other):
            self = .other(other)
        }
    }
}

/// 把 Codable 解码错误转换成可回灌给模型或展示给用户的稳定文本。
///
/// Agent 的多个提交入口都依赖同一套字段/路径提示，统一后模型修复行为不会因
/// 工作流不同而漂移；需要响应诊断元数据的客户端仍可在此文本之外追加上下文。
enum AgentDecodingErrorFormatter {
    static func describe(
        _ error: Error,
        trailingPeriod: Bool = false
    ) -> String {
        let message: String
        guard let decodingError = error as? DecodingError else {
            message = error.localizedDescription
            return trailingPeriod ? appendingPeriod(to: message) : message
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            message = "缺少字段 \(key.stringValue)\(codingPathSuffix(context.codingPath))"
        case .valueNotFound(_, let context):
            message = "缺少必要值\(codingPathSuffix(context.codingPath))"
        case .typeMismatch(_, let context):
            message = "字段类型不匹配\(codingPathSuffix(context.codingPath))"
        case .dataCorrupted(let context):
            message = context.debugDescription
        @unknown default:
            message = error.localizedDescription
        }
        return trailingPeriod ? appendingPeriod(to: message) : message
    }

    private static func codingPathSuffix(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "" }
        return "（路径：\(path.map(\.stringValue).joined(separator: "."))）"
    }

    private static func appendingPeriod(to text: String) -> String {
        guard !text.hasSuffix("。") else { return text }
        return text + "。"
    }
}
