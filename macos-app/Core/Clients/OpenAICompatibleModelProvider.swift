import Foundation

// MARK: - OpenAI-compatible 桥接 Provider（RES-1）
//
// ModelProvider 的生产实现：复用 Core/Clients/OpenAICompatibleAgentClient
// 的 HTTP / SSE 传输（不重复造轮子，FREE001），把 V2 协议层类型映射到
// 传输层类型。桥接是单向依赖：V2 Research 之外不出现 Agent* 传输类型，
// Workflow 层不感知 OpenAI 协议形状。

/// 一个 OpenAI-compatible 供应商的连接配置（V2 自有形态；apiKey 只在
/// 桥接内转成传输层 settings，不进 descriptor / trace / 日志）。
/// **刻意不做 Codable**（含明文 apiKey——与 ResearchSourcesConfiguration
/// 同一防密钥落盘策略）：持久化接线时只编码非凭据字段，密钥走 Keychain。
struct LLMProviderConfiguration: Sendable, Hashable {
    /// 稳定标识（trace / failover 统计用）。
    let providerID: String
    let baseURL: String
    let model: String
    let apiKey: String

    init(providerID: String, baseURL: String, model: String, apiKey: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 配置指纹（baseURL|model|apiKey 的稳定摘要；不含明文 key，可入 trace）。
    var fingerprint: String {
        StableDigest.digest("\(baseURL)|\(model)|\(apiKey)")
    }
}

/// 桥接实现：ModelProvider → OpenAICompatibleAgentClient。
struct OpenAICompatibleModelProvider: ModelProvider {
    let configuration: LLMProviderConfiguration
    private let client: OpenAICompatibleAgentClient

    init(configuration: LLMProviderConfiguration, client: OpenAICompatibleAgentClient = OpenAICompatibleAgentClient()) {
        self.configuration = configuration
        self.client = client
    }

    var descriptor: ModelProviderDescriptor {
        ModelProviderDescriptor(
            providerID: configuration.providerID,
            model: configuration.model,
            fingerprint: configuration.fingerprint
        )
    }

    func complete(
        _ request: ModelCompletionRequest,
        timeout: TimeInterval
    ) async throws -> ModelCompletionResponse {
        guard configuration.isConfigured else {
            throw ModelProviderError.missingConfiguration(providerID: configuration.providerID)
        }
        let settings = TrendAIProviderSettings(
            providerName: configuration.providerID,
            baseURL: configuration.baseURL,
            model: configuration.model,
            apiKey: configuration.apiKey,
            timeoutSeconds: timeout
        )
        do {
            let result = try await client.complete(
                messages: request.messages.map(Self.transportMessage),
                tools: request.tools.map(Self.transportTool),
                toolChoice: Self.transportToolChoice(request.toolChoice),
                temperature: request.temperature,
                maxOutputTokens: request.maxOutputTokens,
                settings: settings,
                timeout: timeout
            )
            return Self.domainResponse(result)
        } catch let error as OpenAICompatibleAgentClientError {
            throw Self.domainError(error, providerID: configuration.providerID)
        }
    }
}

// MARK: - V2 ↔ 传输层映射（桥接私有）

extension OpenAICompatibleModelProvider {

    static func transportMessage(_ message: ModelChatMessage) -> AgentChatMessage {
        AgentChatMessage(
            role: transportRole(message.role),
            content: message.content,
            toolCalls: message.toolCalls.map { calls in
                calls.map { call in
                    AgentToolCall(
                        id: call.id,
                        function: AgentToolFunctionCall(name: call.name, arguments: call.argumentsJSON)
                    )
                }
            },
            toolCallID: message.toolCallID
        )
    }

    static func transportRole(_ role: ModelChatRole) -> AgentChatRole {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    static func domainRole(_ role: AgentChatRole) -> ModelChatRole {
        switch role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    static func transportTool(_ tool: ModelToolSpec) -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: tool.name,
            description: tool.description,
            parameters: transportJSON(tool.parameters)
        )
    }

    static func transportToolChoice(_ choice: ModelToolChoice) -> AgentToolChoice {
        switch choice {
        case .auto: return .auto
        case .required: return .required
        case .function(let name): return .function(name: name)
        }
    }

    static func transportJSON(_ value: ModelJSONValue) -> AgentJSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(transportJSON))
        case .object(let entries): return .object(entries.mapValues(transportJSON))
        }
    }

    static func domainJSON(_ value: AgentJSONValue) -> ModelJSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(domainJSON))
        case .object(let entries): return .object(entries.mapValues(domainJSON))
        }
    }

    static func domainMessage(_ message: AgentChatMessage) -> ModelChatMessage {
        ModelChatMessage(
            role: domainRole(message.role),
            content: message.content,
            toolCalls: message.toolCalls.map { calls in
                calls.map { call in
                    ModelToolCall(
                        id: call.id,
                        name: call.function.name,
                        argumentsJSON: call.function.arguments
                    )
                }
            },
            toolCallID: message.toolCallID
        )
    }

    static func domainStopReason(_ reason: AgentStopReason) -> ModelStopReason {
        switch reason {
        case .stop: return .stop
        case .toolCalls: return .toolCalls
        case .length: return .length
        case .contentFilter: return .contentFilter
        case .other(let value): return .other(value)
        }
    }

    static func domainUsage(_ usage: AgentTokenUsage?) -> ModelTokenUsage? {
        usage.map { ModelTokenUsage(
            promptTokens: $0.promptTokens,
            completionTokens: $0.completionTokens,
            totalTokens: $0.totalTokens
        ) }
    }

    static func domainResponse(_ result: AgentCompletionResult) -> ModelCompletionResponse {
        ModelCompletionResponse(
            assistantMessage: domainMessage(result.assistantMessage),
            toolCalls: result.toolCalls.map { call in
                ModelToolCall(
                    id: call.id,
                    name: call.function.name,
                    argumentsJSON: call.function.arguments
                )
            },
            stopReason: domainStopReason(result.stopReason),
            usage: domainUsage(result.usage)
        )
    }

    static func domainError(
        _ error: OpenAICompatibleAgentClientError,
        providerID: String
    ) -> ModelProviderError {
        switch error {
        case .missingConfiguration:
            return .missingConfiguration(providerID: providerID)
        case .invalidBaseURL:
            return .invalidConfiguration(providerID: providerID, detail: "base URL 无效")
        case .timedOut(let seconds):
            return .timedOut(providerID: providerID, seconds: seconds)
        case .requestFailed(let statusCode, let detail):
            return .requestFailed(providerID: providerID, statusCode: statusCode, detail: detail)
        case .invalidResponse(let detail):
            return .invalidResponse(providerID: providerID, detail: detail)
        }
    }
}
