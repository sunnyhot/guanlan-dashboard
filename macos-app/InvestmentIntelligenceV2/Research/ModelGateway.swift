import Foundation

// MARK: - LLM Model Gateway（RES-1，V3.1 §46）
//
// V2 Research 子系统访问 LLM 的唯一通道：Workflow / Harness / Signal
// Extraction 只见 `ModelProvider` 协议与 `ModelGateway`，不直接触碰任何
// 供应商 SDK 或 HTTP 细节；具体传输由桥接实现（OpenAICompatibleModelProvider
// → Core/Clients/OpenAICompatibleAgentClient）承担——B.3「V2 可调现有
// client 取数但封装切断依赖」。
//
// Gateway 职责（rollout RES-1）：
// - **provider selection**：按优先级序的候选列表；请求失败按序 failover
//   到下一 provider（配置缺失的 provider 直接跳过）。
// - **timeout / retry**：单请求超时由 provider 实现承担；Gateway 对可重试
//   错误（超时 / 429 / 5xx / 网络失败）做有限重试，间隔经 sleeper 注入
//   （测试零等待）。
// - **token budget**：运行级预算 **fail-closed**——请求前检查「已消耗 +
//   本次输出上限」，超额直接拒绝，不是先花超再记账。预算是治理边界，
//   不是供应商配额的镜像。
// - **tracing + usage 记录**：每次尝试产出一条 `ModelCallTrace`（经 sink
//   注入，默认丢弃）；usage 经 actor ledger 记账，供应商未上报 usage 如实
//   记 unreported（不伪造 0 token）。
//
// 铁律（Epic 11）：Gateway 只搬运消息与工具调用，不理解任何投资语义——
// 不写 DB、不产 Signal、不产置信度。取消（Task cancellation）原样透传，
// 不重试不吞。

// MARK: - JSON 值树（工具参数 Schema 用）

/// 通用 JSON 值树（V2 协议层自有形态；与 Core/TrendResearch 的
/// AgentJSONValue 在桥接层互转，不在类型上互通）。
indirect enum ModelJSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ModelJSONValue])
    case object([String: ModelJSONValue])

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
        if let value = try? container.decode([ModelJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: ModelJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法解码为 ModelJSONValue"
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

// 字面量构造（schema 声明用；与 AgentJSONValue 同款约定——不实现
// DoubleLiteral，浮点值用 .number 显式构造）。
extension ModelJSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension ModelJSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ModelJSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension ModelJSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension ModelJSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: ModelJSONValue...) { self = .array(elements) }
}

extension ModelJSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral pairs: (String, ModelJSONValue)...) {
        self = .object(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - 消息模型（V2 协议层）

enum ModelChatRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// 一条 chat 消息。同一类型既用于编码发出的 system/user/tool 消息，也用于
/// 承载模型返回的 assistant 消息（content 为 nil、带 toolCalls 合法）。
struct ModelChatMessage: Sendable, Codable, Hashable {
    let role: ModelChatRole
    let content: String?
    let toolCalls: [ModelToolCall]?
    let toolCallID: String?

    init(
        role: ModelChatRole,
        content: String? = nil,
        toolCalls: [ModelToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// 模型发起的一次工具调用（arguments 是字符串化 JSON，由具体工具解码校验）。
struct ModelToolCall: Sendable, Codable, Hashable {
    let id: String
    let name: String
    let argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// 发送给模型的工具声明。
struct ModelToolSpec: Sendable, Codable, Hashable {
    let name: String
    let description: String
    let parameters: ModelJSONValue

    init(name: String, description: String, parameters: ModelJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// `tool_choice` 取值（只编码不解码）。
enum ModelToolChoice: Sendable, Hashable {
    case auto
    case required
    case function(name: String)
}

enum ModelStopReason: Sendable, Hashable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case other(String)
}

// MARK: - 请求 / 响应

/// 一次补全请求（Gateway 层；`purpose` 是 tracing 语义标注，如
/// "research.turn" / "signalExtraction"，不进模型上下文）。
struct ModelCompletionRequest: Sendable, Hashable {
    var messages: [ModelChatMessage]
    var tools: [ModelToolSpec]
    var toolChoice: ModelToolChoice
    var temperature: Double
    var maxOutputTokens: Int?
    var purpose: String

    init(
        messages: [ModelChatMessage],
        tools: [ModelToolSpec] = [],
        toolChoice: ModelToolChoice = .auto,
        temperature: Double = 0.2,
        maxOutputTokens: Int? = nil,
        purpose: String
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.purpose = purpose
    }
}

/// 供应商上报的 token 用量（未上报为 nil；字段全可选，缺失不视为协议错误）。
struct ModelTokenUsage: Sendable, Hashable, Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    /// 预算记账取值：上报了 total 用 total；否则退 prompt + completion
    ///（仍缺失按 0——usage 缺失由 ledger 的 unreported 计数另行透明）。
    var budgetRelevantTokens: Int {
        if let total = totalTokens { return total }
        return (promptTokens ?? 0) + (completionTokens ?? 0)
    }
}

/// 一次补全响应：assistant 消息 + 工具调用 + 停止原因 + usage。
struct ModelCompletionResponse: Sendable, Hashable {
    let assistantMessage: ModelChatMessage
    let toolCalls: [ModelToolCall]
    let stopReason: ModelStopReason
    let usage: ModelTokenUsage?
    /// 实际完成本次请求的 provider 身份（Gateway 在 failover 后回填；
    /// 直接构造的响应为 nil——产出溯源用，审查 P3-1）。
    var resolvedProvider: ModelProviderDescriptor? = nil

    init(
        assistantMessage: ModelChatMessage,
        toolCalls: [ModelToolCall],
        stopReason: ModelStopReason,
        usage: ModelTokenUsage?,
        resolvedProvider: ModelProviderDescriptor? = nil
    ) {
        self.assistantMessage = assistantMessage
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
        self.resolvedProvider = resolvedProvider
    }
}

// MARK: - ModelProvider 协议

/// provider 身份描述（选择 / 健康 / trace 用；不含明文 key）。
struct ModelProviderDescriptor: Sendable, Hashable, Codable {
    /// 稳定 provider 标识（如 "primary" / "fallback-glm"）。
    let providerID: String
    let model: String
    /// 配置指纹（同配置同指纹；变更即视为不同 provider 状态）。
    let fingerprint: String
}

/// LLM 供应商错误（Gateway 的重试 / failover 依据）。
enum ModelProviderError: Error, Equatable, Sendable {
    case missingConfiguration(providerID: String)
    case invalidConfiguration(providerID: String, detail: String)
    case timedOut(providerID: String, seconds: Double)
    case requestFailed(providerID: String, statusCode: Int?, detail: String?)
    case invalidResponse(providerID: String, detail: String)

    /// 同 provider 内是否值得重试（超时 / 429 / 5xx / 网络失败）。
    /// 配置类与协议类错误重试无意义，但 failover 到下一 provider 仍合理。
    var isRetryable: Bool {
        switch self {
        case .timedOut:
            return true
        case .requestFailed(_, let statusCode, _):
            guard let statusCode else { return true }
            return statusCode == 429 || (500..<600).contains(statusCode)
        case .missingConfiguration, .invalidConfiguration, .invalidResponse:
            return false
        }
    }
}

/// LLM 供应商抽象：一次补全。实现负责真实传输（HTTP / SSE / 重试语义里的
/// 单请求超时）；Gateway 在其上编排 selection / retry / budget / 记账。
protocol ModelProvider: Sendable {
    var descriptor: ModelProviderDescriptor { get }
    func complete(
        _ request: ModelCompletionRequest,
        timeout: TimeInterval
    ) async throws -> ModelCompletionResponse
}

// MARK: - Gateway 策略 / 记账 / 追踪

/// Gateway 编排策略（纯值；全部可注入覆盖，测试用极端值）。
struct ModelGatewayPolicy: Sendable, Hashable {
    /// 单请求超时（秒；传给 provider 实现）。
    var requestTimeout: TimeInterval = 180
    /// 同 provider 对可重试错误的最大重试次数（0 = 不重试，一次失败即 failover）。
    var maxRetriesPerProvider: Int = 1
    /// 重试间隔（秒；经 sleeper 注入，测试传 0）。
    var retryInterval: TimeInterval = 1
    /// 运行级 token 预算（上报 usage 之和；fail-closed）。
    var tokenBudget: Int = 2_000_000
    /// 请求未声明 maxOutputTokens 时的预算占位估算（审查 P3-3：
    /// 未声明不能按 0 计，否则预算检查形同虚设）。
    var perRequestOutputEstimate: Int = 4096
    /// 是否允许 failover 到下一 provider（关闭 = 只用首个可用 provider）。
    var failoverEnabled: Bool = true
}

/// usage 记账（actor；跨请求累计，供预算检查与运行摘要）。
actor ModelUsageLedger {
    private(set) var reportedTotalTokens = 0
    private(set) var requestsWithReportedUsage = 0
    private(set) var requestsWithoutReportedUsage = 0

    func record(usage: ModelTokenUsage?) {
        if let usage {
            reportedTotalTokens += usage.budgetRelevantTokens
            requestsWithReportedUsage += 1
        } else {
            requestsWithoutReportedUsage += 1
        }
    }

    /// 预算检查口径：已消耗 = 上报 total 之和（未上报请求不折算——预算
    /// fail-closed 只对「可测量消耗」生效，unreported 计数另行透明）。
    func consumedTokens() -> Int {
        reportedTotalTokens
    }
}

/// 运行摘要（usage 快照）。
struct ModelUsageSnapshot: Sendable, Hashable, Codable {
    let reportedTotalTokens: Int
    let requestsWithReportedUsage: Int
    let requestsWithoutReportedUsage: Int
}

/// 单次尝试的调用追踪（时间、身份、结果、用量；不含消息正文——正文体积大
/// 且可能含隐私，tracing 只记形状不记内容）。
struct ModelCallTrace: Sendable, Hashable, Codable {
    enum Outcome: String, Sendable, Codable, Hashable {
        case succeeded
        case failed
    }

    let requestID: String
    let purpose: String
    let providerID: String
    let model: String
    /// 候选序号（0 起）+ 尝试序号（1 起）定位一次尝试。
    let providerIndex: Int
    let attempt: Int
    let durationSeconds: Double
    let outcome: Outcome
    let errorSummary: String?
    let usage: ModelTokenUsage?
}

/// 追踪出口（默认丢弃；App / 测试注入收集器或文件写入器）。
protocol ModelTraceSink: Sendable {
    func record(_ trace: ModelCallTrace) async
}

/// 默认 no-op sink。
struct NullModelTraceSink: ModelTraceSink {
    func record(_ trace: ModelCallTrace) async {}
}

// MARK: - ModelGateway

enum ModelGatewayError: Error, Equatable, Sendable {
    /// 候选列表为空 / 全部 provider 配置缺失
    case noProvidersConfigured
    /// 预算 fail-closed 拒绝（consumed + 本次输出上限 > budget）
    case tokenBudgetExhausted(consumed: Int, requested: Int, budget: Int)
    /// 全部候选的全部尝试失败（附最后一次错误与总尝试数）
    case allProvidersFailed(last: ModelProviderError, attempts: Int)
}

/// LLM Gateway：provider selection + retry + failover + token budget +
/// tracing / usage 记账。Workflow 层的唯一模型入口。
struct ModelGateway: Sendable {
    /// 按优先级序的候选 provider。
    let providers: [any ModelProvider]
    let policy: ModelGatewayPolicy
    let ledger: ModelUsageLedger
    private let traceSink: any ModelTraceSink
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let requestIDFactory: @Sendable () -> String
    private let clock: @Sendable () -> Date

    init(
        providers: [any ModelProvider],
        policy: ModelGatewayPolicy = ModelGatewayPolicy(),
        ledger: ModelUsageLedger = ModelUsageLedger(),
        traceSink: (any ModelTraceSink)? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.policy = policy
        self.ledger = ledger
        self.traceSink = traceSink ?? NullModelTraceSink()
        self.sleeper = sleeper
        self.requestIDFactory = requestIDFactory
        self.clock = clock
    }

    /// 一次补全（含预算检查、failover、重试、记账、追踪）。
    func complete(_ request: ModelCompletionRequest) async throws -> ModelCompletionResponse {
        guard !providers.isEmpty else {
            throw ModelGatewayError.noProvidersConfigured
        }

        if let violation = await budgetViolation(request) {
            throw violation
        }

        var totalAttempts = 0
        var sawConfiguredProvider = false
        var lastError: ModelProviderError?

        for (providerIndex, provider) in providers.enumerated() {
            guard policy.failoverEnabled || providerIndex == 0 else { break }
            for attempt in 1...(policy.maxRetriesPerProvider + 1) {
                try Task.checkCancellation()
                totalAttempts += 1
                let requestID = requestIDFactory()
                let startedAt = clock()
                do {
                    var response = try await provider.complete(request, timeout: policy.requestTimeout)
                    response.resolvedProvider = provider.descriptor
                    await ledger.record(usage: response.usage)
                    await recordTrace(
                        requestID, request, provider, providerIndex, attempt,
                        from: startedAt, outcome: .succeeded,
                        errorSummary: nil, usage: response.usage
                    )
                    return response
                } catch let error as ModelProviderError {
                    // 未配置的 provider 直接跳过：不计失败尝试、不产 trace
                    //（它没有发生真实调用）。
                    if case .missingConfiguration = error {
                        totalAttempts -= 1
                        break
                    }
                    sawConfiguredProvider = true
                    lastError = error
                    await recordTrace(
                        requestID, request, provider, providerIndex, attempt,
                        from: startedAt, outcome: .failed,
                        errorSummary: String(describing: error), usage: nil
                    )
                    // 重试只对可重试错误；不可重试直接换下一 provider。
                    guard error.isRetryable, attempt <= policy.maxRetriesPerProvider else { break }
                    // 重试前复查预算（可见前次尝试之后新记账的消耗）。
                    if let violation = await budgetViolation(request) {
                        throw violation
                    }
                    await sleeper(policy.retryInterval)
                }
            }
        }

        guard sawConfiguredProvider else {
            throw ModelGatewayError.noProvidersConfigured
        }
        throw ModelGatewayError.allProvidersFailed(
            last: lastError ?? ModelProviderError.invalidResponse(
                providerID: "gateway", detail: "无候选 provider 完成请求"
            ),
            attempts: totalAttempts
        )
    }

    /// usage 快照（运行摘要）。
    func usageSnapshot() async -> ModelUsageSnapshot {
        await ledger.snapshot()
    }

    /// 预算检查（审查 P3-3）：未声明输出上限的请求按估算值占预算
    ///（fail-closed 保守）；nil = 通过。
    private func budgetViolation(
        _ request: ModelCompletionRequest
    ) async -> ModelGatewayError? {
        let consumed = await ledger.consumedTokens()
        let requested = request.maxOutputTokens ?? policy.perRequestOutputEstimate
        if consumed + requested > policy.tokenBudget {
            return .tokenBudgetExhausted(
                consumed: consumed, requested: requested, budget: policy.tokenBudget
            )
        }
        return nil
    }

    /// 一次尝试的 trace 记录（成功 / 失败同一出口）。
    private func recordTrace(
        _ requestID: String,
        _ request: ModelCompletionRequest,
        _ provider: any ModelProvider,
        _ providerIndex: Int,
        _ attempt: Int,
        from startedAt: Date,
        outcome: ModelCallTrace.Outcome,
        errorSummary: String?,
        usage: ModelTokenUsage?
    ) async {
        await traceSink.record(ModelCallTrace(
            requestID: requestID,
            purpose: request.purpose,
            providerID: provider.descriptor.providerID,
            model: provider.descriptor.model,
            providerIndex: providerIndex,
            attempt: attempt,
            durationSeconds: clock().timeIntervalSince(startedAt),
            outcome: outcome,
            errorSummary: errorSummary,
            usage: usage
        ))
    }
}

extension ModelUsageLedger {
    /// 快照（供 Gateway 的 usageSnapshot）。
    func snapshot() -> ModelUsageSnapshot {
        ModelUsageSnapshot(
            reportedTotalTokens: reportedTotalTokens,
            requestsWithReportedUsage: requestsWithReportedUsage,
            requestsWithoutReportedUsage: requestsWithoutReportedUsage
        )
    }
}
