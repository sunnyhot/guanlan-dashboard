import Foundation

// MARK: - LLM 网关接线（旧链路 TrendResearchAgentClient → ModelGateway）
//
// 旧 AI 链路的模型入口经网关编排：重试 / failover / token 预算 / 用量记账 /
// 尝试级 trace（写进既有 AI 运行日志，见 DiagnosticModelTraceSink）。
// 错误统一映射回 OpenAICompatibleAgentClientError——调用方的错误分诊
// （TrendErrorTriage）与超时恢复逻辑不感知网关存在。
//
// 已知取舍：
// - 候选列表：旧设置模型是单服务商，多服务商 failover 要等配置层扩展后
//   才生效；重试 / 预算 / 记账 / trace 立即生效。
// - 流式进度：网关不透传流式分片，streamProgress 回调不会被调用（各
//   Agent 的请求开始 / 结束事件不受影响）。

struct GatewayAgentClient: TrendResearchAgentClient {
    /// trace 的 purpose 标注（如 "trend-research"），进运行日志便于区分链路。
    let purpose: String
    /// 网关策略基底（requestTimeout 按每次调用覆盖）。趋势研究应传
    /// maxRetriesPerProvider = 0——它有自己的超时恢复循环，网关级重试会
    /// 造成双重等待。
    var policy: ModelGatewayPolicy
    /// provider 构造（测试注入 scripted 实现）。
    var providerFactory: @Sendable (LLMProviderConfiguration) -> any ModelProvider
    private let traceSink: any ModelTraceSink

    init(
        purpose: String,
        policy: ModelGatewayPolicy = ModelGatewayPolicy(),
        providerFactory: @escaping @Sendable (LLMProviderConfiguration) -> any ModelProvider = {
            OpenAICompatibleModelProvider(configuration: $0)
        },
        traceSink: (any ModelTraceSink)? = nil
    ) {
        self.purpose = purpose
        self.policy = policy
        self.providerFactory = providerFactory
        self.traceSink = traceSink ?? DiagnosticModelTraceSink()
    }

    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice,
        temperature: Double,
        settings: TrendAIProviderSettings,
        timeout: Double?,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult {
        guard settings.isConfigured else {
            throw OpenAICompatibleAgentClientError.missingConfiguration
        }
        let trimmedProviderName = settings.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = LLMProviderConfiguration(
            providerID: trimmedProviderName.isEmpty ? "primary" : trimmedProviderName,
            baseURL: settings.baseURL,
            model: settings.model,
            apiKey: settings.apiKey
        )
        var policy = self.policy
        policy.requestTimeout = timeout ?? settings.timeoutSeconds
        let gateway = ModelGateway(
            providers: [providerFactory(configuration)],
            policy: policy,
            traceSink: traceSink
        )
        let request = ModelCompletionRequest(
            messages: messages.map(OpenAICompatibleModelProvider.domainMessage),
            tools: tools.map(Self.domainTool),
            toolChoice: Self.domainToolChoice(toolChoice),
            temperature: temperature,
            purpose: purpose
        )
        do {
            let response = try await gateway.complete(request)
            return Self.transportResult(response)
        } catch let error as ModelProviderError {
            throw Self.transportError(error)
        } catch let error as ModelGatewayError {
            throw Self.transportGatewayError(error)
        }
    }
}

// MARK: - 映射（复用 OpenAICompatibleModelProvider 的双向静态映射）

extension GatewayAgentClient {

    static func domainTool(_ tool: AgentToolDefinition) -> ModelToolSpec {
        ModelToolSpec(
            name: tool.function.name,
            description: tool.function.description,
            parameters: OpenAICompatibleModelProvider.domainJSON(tool.function.parameters)
        )
    }

    static func domainToolChoice(_ choice: AgentToolChoice) -> ModelToolChoice {
        switch choice {
        case .auto: return .auto
        case .required: return .required
        case .function(let name): return .function(name: name)
        }
    }

    static func transportResult(_ response: ModelCompletionResponse) -> AgentCompletionResult {
        AgentCompletionResult(
            assistantMessage: OpenAICompatibleModelProvider.transportMessage(response.assistantMessage),
            toolCalls: response.toolCalls.map { call in
                AgentToolCall(
                    id: call.id,
                    function: AgentToolFunctionCall(name: call.name, arguments: call.argumentsJSON)
                )
            },
            stopReason: transportStopReason(response.stopReason),
            // 网关响应不带原始 finish_reason，按语义停因还原等价字符串（仅诊断日志消费）。
            finishReason: finishReason(from: response.stopReason),
            usage: transportUsage(response.usage)
        )
    }

    static func transportStopReason(_ reason: ModelStopReason) -> AgentStopReason {
        switch reason {
        case .stop: return .stop
        case .toolCalls: return .toolCalls
        case .length: return .length
        case .contentFilter: return .contentFilter
        case .other(let value): return .other(value)
        }
    }

    static func finishReason(from reason: ModelStopReason) -> String? {
        switch reason {
        case .stop: return "stop"
        case .toolCalls: return "tool_calls"
        case .length: return "length"
        case .contentFilter: return "content_filter"
        case .other(let value): return value
        }
    }

    static func transportUsage(_ usage: ModelTokenUsage?) -> AgentTokenUsage? {
        usage.map {
            AgentTokenUsage(
                promptTokens: $0.promptTokens,
                completionTokens: $0.completionTokens,
                totalTokens: $0.totalTokens
            )
        }
    }

    /// 网关/供应商错误 → 旧客户端错误（保持调用方 catch 分支不变）。
    static func transportError(_ error: ModelProviderError) -> OpenAICompatibleAgentClientError {
        switch error {
        case .missingConfiguration:
            return .missingConfiguration
        case .invalidConfiguration:
            return .invalidBaseURL
        case .timedOut(_, let seconds):
            return .timedOut(seconds)
        case .requestFailed(_, let statusCode, let detail):
            return .requestFailed(statusCode: statusCode, detail: detail)
        case .invalidResponse(_, let detail):
            return .invalidResponse(detail)
        }
    }

    static func transportGatewayError(_ error: ModelGatewayError) -> OpenAICompatibleAgentClientError {
        switch error {
        case .noProvidersConfigured:
            return .missingConfiguration
        case .tokenBudgetExhausted(let consumed, let requested, let budget):
            return .requestFailed(
                statusCode: nil,
                detail: "token 预算已耗尽（已消耗 \(consumed) + 本次预计 \(requested) > 预算 \(budget)）"
            )
        case .allProvidersFailed(let last, _):
            return transportError(last)
        }
    }
}

// MARK: - trace → 既有 AI 运行日志

/// 网关尝试级 trace 写进 TaskLocal 的 AI 运行日志（JSONL，自动脱敏；
/// 无活跃运行时静默 no-op）。每次尝试一条：provider、耗时、结果、错误
/// 摘要、token 用量——排查「哪次尝试、多久、错在哪」用。
struct DiagnosticModelTraceSink: ModelTraceSink {
    func record(_ trace: ModelCallTrace) async {
        await AIAgentDiagnosticLog.record("model_gateway_trace", payload: trace)
    }
}
