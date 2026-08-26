import Foundation

// MARK: - Research Tool 协议（RES-2 定义，RES-3 落地具体工具）
//
// V2 工具协议与 Slice 0-7 的 TrendResearchTool 刻意不共用（rollout RES-3：
// 不复用 TrendResearchToolRegistry，新建 V2 版）：V2 工具的返回携带
// EvidenceID（进运行内登记簿），Context 是 ResearchTask 而非旧快照。

/// Research 工具（只读研究动作：取数 / 检索 / 查询）。
protocol ResearchTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// 参数 JSON Schema（发给模型的声明）。
    var parameters: ModelJSONValue { get }
    /// 执行；返回回灌内容 + 本动作产出/引用的 evidence IDs。
    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult
}

/// 工具执行上下文（任务级只读 + 数据面注入：外部源配置与本地取数白名单）。
struct ResearchToolContext: Sendable {
    let task: ResearchTask
    var sources: ResearchSourcesConfiguration = .empty
    var dataAccess: (any ResearchDataAccess)? = nil

    init(
        task: ResearchTask,
        sources: ResearchSourcesConfiguration = .empty,
        dataAccess: (any ResearchDataAccess)? = nil
    ) {
        self.task = task
        self.sources = sources
        self.dataAccess = dataAccess
    }
}

/// 工具执行结果。
struct ResearchToolResult: Sendable, Hashable {
    /// 回灌给模型的完整内容（成功信封 / 错误信封由工具自定）。
    let contentJSON: ModelJSONValue
    let isError: Bool
    /// 本次动作产出的 evidence IDs（登记进运行簿；空 = 无证据产出）。
    let evidenceIDs: [EvidenceID]

    static func content(_ json: ModelJSONValue, evidenceIDs: [EvidenceID] = []) -> ResearchToolResult {
        ResearchToolResult(contentJSON: json, isError: false, evidenceIDs: evidenceIDs)
    }

    /// 错误信封便利形态（信封内容 + isError 标记）。
    static func content(_ json: ModelJSONValue, isError: Bool) -> ResearchToolResult {
        ResearchToolResult(contentJSON: json, isError: isError, evidenceIDs: [])
    }

    /// 标准错误信封（ResearchToolEnvelope.error + isError——工具错误路径的
    /// 统一出口，避免信封组合样板散落各工具）。
    static func errorEnvelope(code: String, message: String) -> ResearchToolResult {
        ResearchToolResult(
            contentJSON: ResearchToolEnvelope.error(code: code, message: message),
            isError: true,
            evidenceIDs: []
        )
    }

    static func error(code: String, message: String) -> ResearchToolResult {
        ResearchToolResult(
            contentJSON: [
                "success": false,
                "error": ["code": .string(code), "message": .string(message)]
            ],
            isError: true,
            evidenceIDs: []
        )
    }
}

// MARK: - 运行策略

/// Harness 运行预算（纯值；边界与 TrendResearchRunPolicy 同源经验，量级
/// 按单任务研究收敛——无分模块报告，轮次显著少于旧 Agent）。
struct ResearchHarnessPolicy: Sendable, Hashable {
    /// 最大轮次（一轮 = 一次模型请求）。
    var maxTurns: Int = 12
    /// 最大工具调用次数（不含 submit）。
    var maxToolCalls: Int = 24
    /// 单条工具结果回灌上限（字节；超出截断并注明）。
    var maxToolResultBytes: Int = 32 * 1024
    /// 上下文总体积预算（字节；超出触发确定性裁剪）。
    var contextBudgetBytes: Int = 384 * 1024
    /// 裁剪时保留的最近消息条数。
    var contextPreserveRecentMessages: Int = 6
    /// 纯文本响应容忍上限（超过判定模型不配合工具循环）。
    var maxPlainTextResponses: Int = 2
    /// 无效提交（校验失败）重试上限。
    var maxInvalidSubmissions: Int = 3
    var temperature: Double = 0.2
    /// 单请求输出上限（token；进 Gateway 预算检查）。
    var maxOutputTokens: Int = 4096
    /// 整次运行总预算（秒；极端失控兜底）。
    var totalTimeoutSeconds: TimeInterval = 900
}

// MARK: - Research Harness（RES-2 主循环）

/// 多轮 Tool Calling 研究循环：模型经 Gateway 访问，工具调用经 ResearchTool
/// 执行并登记 evidence，最终模型经提交工具产出 ResearchNotes。
///
/// 行为契约（与 TrendResearchAgent 的关键差异）：
/// - 模型访问只经 ModelGateway（selection/retry/budget 在 Gateway 层）
/// - 提交解码只走 StructuredGeneration（无文本 parse 路径）
/// - 提交门禁：至少一次工具调用 + claims 的 evidence 引用全部在运行内
///   登记簿中（RES-8 Evidence Matcher 落地前的最低完整性）
/// - 失败返回 outcome（job.failed + errorDetail）；取消 rethrow
///   CancellationError（结构化并发语义不吞）
struct ResearchHarness: Sendable {
    static let workflowKind = "research"
    static let submitToolName = ResearchNotesSubmission.schema.functionName

    let gateway: ModelGateway
    let tools: [any ResearchTool]
    let policy: ResearchHarnessPolicy
    /// 外部源配置（进工具 Context；RES-3）。
    var sources: ResearchSourcesConfiguration = .empty
    /// 本地取数白名单（进工具 Context；nil = 本地取数不可用）。
    var dataAccess: (any ResearchDataAccess)? = nil
    private let clock: @Sendable () -> Date

    init(
        gateway: ModelGateway,
        tools: [any ResearchTool],
        policy: ResearchHarnessPolicy = ResearchHarnessPolicy(),
        sources: ResearchSourcesConfiguration = .empty,
        dataAccess: (any ResearchDataAccess)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.tools = tools
        self.policy = policy
        self.sources = sources
        self.dataAccess = dataAccess
        self.clock = clock
    }

    /// 默认 system prompt（研究角色 + 循环规则）。
    static func systemPrompt(for task: ResearchTask) -> String {
        var prompt = """
        你是投资研究助手。针对给定的研究任务，先调用可用的研究工具收集事实证据，\
        然后用 \(submitToolName) 工具提交结构化研究笔记。

        规则：
        1. 先用工具研究，再提交；提交前必须至少调用过一次研究工具。
        2. 每条 claim 的 evidence_ids 只能引用工具结果中出现过的 evidence_id，\
        不允许编造。
        3. 证据不足时如实给 LOW 充分度或缩小 claim 范围，不夸大。
        4. 不做任何仓位、买卖或数值置信度的判断——只陈述事实与逻辑。
        """
        if let guidance = task.guidance, !guidance.isEmpty {
            prompt += "\n\n补充约束：\(guidance)"
        }
        return prompt
    }

    /// 执行一次研究 job。
    func run(
        task: ResearchTask,
        now: Date? = nil,
        eventHandler: (@Sendable (ResearchHarnessEvent) async -> Void)? = nil
    ) async throws -> ResearchRunOutcome {
        let events = eventHandler ?? { _ in }
        let startedAt = now ?? clock()
        var job = AgentJob(workflowKind: Self.workflowKind, inputFingerprint: task.inputFingerprint, createdAt: startedAt)

        var messages: [ModelChatMessage] = [
            ModelChatMessage(role: .system, content: Self.systemPrompt(for: task)),
            ModelChatMessage(role: .user, content: """
            研究对象：\(task.subject.entityType)/\(task.subject.entityIDRawValue)
            研究目标：\(task.objective)
            """),
        ]
        var registeredEvidence: Set<String> = []
        var toolCallCount = 0
        var plainTextResponses = 0
        var invalidSubmissions = 0
        var turn = 0

        await events(.started(
            task: task,
            limits: "turns=\(policy.maxTurns) tools=\(policy.maxToolCalls) timeout=\(Int(policy.totalTimeoutSeconds))s"
        ))
        try job.transition(to: .running, at: startedAt, detail: nil)

        func fail(_ detail: String, at timestamp: Date) async -> ResearchRunOutcome {
            try? job.transition(to: .failed, at: timestamp, detail: detail)
            await events(.failed(detail: detail))
            return ResearchRunOutcome(job: job, notes: nil, transcript: messages, errorDetail: detail)
        }

        do {
            while turn < policy.maxTurns {
                try Task.checkCancellation()
                turn += 1
                if clock().timeIntervalSince(startedAt) > policy.totalTimeoutSeconds {
                    return await fail("总预算超时（\(Int(policy.totalTimeoutSeconds))s）", at: clock())
                }
                await events(.turnStarted(turn: turn))

                let request = ModelCompletionRequest(
                    messages: messages,
                    tools: toolSpecs(),
                    toolChoice: .auto,
                    temperature: policy.temperature,
                    maxOutputTokens: policy.maxOutputTokens,
                    purpose: "research.turn"
                )
                let response = try await gateway.complete(request)
                messages.append(response.assistantMessage)

                // 截断的响应不执行工具（参数可能不完整），要求重发。
                if case .length = response.stopReason {
                    messages.append(ModelChatMessage(
                        role: .user,
                        content: "上一次响应被截断。不要执行不完整的工具参数，请重新发出完整调用。"
                    ))
                    continue
                }

                guard !response.toolCalls.isEmpty else {
                    plainTextResponses += 1
                    if plainTextResponses > policy.maxPlainTextResponses {
                        return await fail("模型连续 \(plainTextResponses) 次未发起工具调用", at: clock())
                    }
                    messages.append(ModelChatMessage(
                        role: .user,
                        content: "请通过工具调用开展研究或提交笔记，不要输出纯文本。"
                    ))
                    continue
                }

                for call in response.toolCalls {
                    try Task.checkCancellation()
                    if call.name == Self.submitToolName {
                        let verdict = submitVerdict(
                            call: call, registeredEvidence: registeredEvidence,
                            toolCallCount: toolCallCount
                        )
                        switch verdict {
                        case .failure(let detail):
                            invalidSubmissions += 1
                            let remaining = policy.maxInvalidSubmissions - invalidSubmissions
                            await events(.submissionRejected(detail: detail, remainingAttempts: max(0, remaining)))
                            if invalidSubmissions >= policy.maxInvalidSubmissions {
                                return await fail("提交多次未通过校验：\(detail)", at: clock())
                            }
                            messages.append(ModelChatMessage(
                                role: .tool,
                                content: Self.toolResultJSON(.error(code: "submit_validation_failed", message: detail)),
                                toolCallID: call.id
                            ))
                        case .success(let submission):
                            let notes = ResearchNotes(
                                task: task,
                                notes: submission.notes,
                                claims: submission.claims,
                                producedBy: response.resolvedProvider
                                    ?? producedByDescriptor
                                    ?? ModelProviderDescriptor(
                                        providerID: "unknown", model: "unknown", fingerprint: ""
                                    ),
                                producedAt: clock()
                            )
                            try job.transition(to: .completed, at: clock(), detail: notes.contentFingerprint)
                            await events(.notesAccepted(
                                claimCount: notes.claims.count,
                                evidenceCount: Set(notes.claims.flatMap { $0.evidenceReferences.map(\.rawValue) }).count
                            ))
                            return ResearchRunOutcome(
                                job: job, notes: notes, transcript: messages, errorDetail: nil
                            )
                        }
                        continue
                    }

                    guard let tool = tools.first(where: { $0.name == call.name }) else {
                        messages.append(ModelChatMessage(
                            role: .tool,
                            content: Self.toolResultJSON(.error(
                                code: "unknown_tool",
                                message: "未知工具 \(call.name)。可用工具：\(tools.map(\.name).joined(separator: ", "))"
                            )),
                            toolCallID: call.id
                        ))
                        continue
                    }

                    toolCallCount += 1
                    if toolCallCount > policy.maxToolCalls {
                        return await fail("工具调用次数超限（\(policy.maxToolCalls)）", at: clock())
                    }

                    let result = await tool.execute(
                        argumentsJSON: call.argumentsJSON,
                        context: ResearchToolContext(
                            task: task, sources: sources, dataAccess: dataAccess
                        )
                    )
                    for evidenceID in result.evidenceIDs {
                        registeredEvidence.insert(evidenceID.rawValue)
                    }
                    await events(.toolExecuted(
                        name: call.name,
                        evidenceCount: result.evidenceIDs.count,
                        isError: result.isError
                    ))

                    var content = Self.toolResultJSON(result)
                    if content.utf8.count > policy.maxToolResultBytes {
                        // 截断前缀含任意字符（引号/反斜杠/换行），必须经 JSONEncoder
                        // 转义——字符串插值拼 JSON 会产出非法 tool message。
                        let envelope: ModelJSONValue = [
                            "truncated": true,
                            "notice": .string("工具结果超过回灌上限被截断，完整 evidence 已登记，可换更小范围参数重试"),
                            "prefix": .string(String(content.prefix(policy.maxToolResultBytes)))
                        ]
                        content = Self.toolResultJSON(ResearchToolResult.content(envelope))
                    }
                    messages.append(ModelChatMessage(role: .tool, content: content, toolCallID: call.id))
                }

                compactContextIfNeeded(&messages)
            }
            return await fail("轮次耗尽（\(policy.maxTurns)）仍未提交有效研究笔记", at: clock())
        } catch is CancellationError {
            try? job.transition(to: .cancelled, at: clock(), detail: nil)
            await events(.cancelled)
            throw CancellationError()
        } catch {
            return await fail(String(describing: error), at: clock())
        }
    }

    // MARK: - 私有

    /// 产出溯源回退（审查 P3-1 修复后的兜底路径）：Gateway 已在响应里回填
    /// resolvedProvider（实际完成请求的 provider，failover 后准确）；
    /// 仅当响应缺失该字段（非经 Gateway 构造）时退回首选候选。
    private var producedByDescriptor: ModelProviderDescriptor? {
        gateway.providers.first?.descriptor
    }

    private func toolSpecs() -> [ModelToolSpec] {
        let researchSpecs = tools.map { tool in
            ModelToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
        return researchSpecs + [ResearchNotesSubmission.schema.toolSpec]
    }

    /// 提交校验：decode（RES-7 通道）→ 枚举转换 → evidence 引用闭包。
    private func submitVerdict(
        call: ModelToolCall,
        registeredEvidence: Set<String>,
        toolCallCount: Int
    ) -> SubmitVerdict {
        if toolCallCount == 0 {
            return .failure("提交前必须至少调用一次研究工具收集证据")
        }
        let decoded: ResearchNotesSubmission
        do {
            let singleCallResponse = ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant),
                toolCalls: [call],
                stopReason: .toolCalls,
                usage: nil
            )
            decoded = try StructuredGeneration.decode(
                singleCallResponse, as: ResearchNotesSubmission.self,
                schema: ResearchNotesSubmission.schema
            )
        } catch let error as StructuredGenerationError {
            return .failure(Self.submitFailureDetail(error))
        } catch {
            return .failure("提交解码失败：\(error)")
        }

        var claims: [ResearchClaim] = []
        for submitted in decoded.claims {
            guard let label = ResearchConfidenceLabel(rawValue: submitted.confidenceLabel) else {
                return .failure("confidence_label 必须是 HIGH/MEDIUM/LOW 之一，收到 \(submitted.confidenceLabel)")
            }
            let dimension = submitted.dimension.flatMap { raw in
                SignalDimension(rawValue: raw)
            }
            if let raw = submitted.dimension, dimension == nil {
                return .failure("dimension 必须是 \(SignalDimension.allCases.map(\.rawValue)) 之一，收到 \(raw)")
            }
            let direction = submitted.direction.flatMap { raw in
                SignalDirection(rawValue: raw)
            }
            if let raw = submitted.direction, direction == nil {
                return .failure("direction 必须是 BULLISH/BEARISH/NEUTRAL/UNCERTAIN 之一，收到 \(raw)")
            }
            claims.append(ResearchClaim(
                statement: submitted.statement,
                evidenceReferences: submitted.evidenceIds.map { EvidenceID(rawValue: $0) },
                confidenceLabel: label,
                dimension: dimension,
                direction: direction
            ))
        }

        let unknown = Set(decoded.claims.flatMap(\.evidenceIds)).subtracting(registeredEvidence)
        if !unknown.isEmpty {
            let known = registeredEvidence.sorted()
            return .failure("evidence_ids 引用了未登记的证据：\(unknown.sorted().joined(separator: ", "))。只能引用工具结果中出现过的 evidence_id（已登记：\(known.joined(separator: ", "))）")
        }
        return .success(ResearchNotesSubmission.Decoded(notes: decoded.notes, claims: claims))
    }

    private enum SubmitVerdict {
        case failure(String)
        case success(ResearchNotesSubmission.Decoded)
    }

    private static func submitFailureDetail(_ error: StructuredGenerationError) -> String {
        switch error {
        case .missingStructuredOutput:
            return "提交缺少工具调用参数"
        case .unexpectedFunction(let expected, let actual):
            return "提交函数不匹配（期望 \(expected)，收到 \(actual)）"
        case .malformedJSON(_, let detail):
            return "提交参数不是合法 JSON：\(detail)"
        case .decodingFailed(_, let detail):
            return "提交参数不符合结构：\(detail)"
        }
    }

    private static func toolResultJSON(_ result: ResearchToolResult) -> String {
        guard let data = try? JSONEncoder().encode(result.contentJSON) else {
            return "{\"success\": false, \"error\": {\"code\": \"encoding_failed\"}}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 确定性上下文裁剪：超预算时把已被后续消息消费过的旧 tool 结果替换为
    /// 占位（保留 system / 初始 user 与最近若干条；提交已接受的内容不裁——
    /// 那是运行结束时点，不会走到这里）。
    private func compactContextIfNeeded(_ messages: inout [ModelChatMessage]) {
        let totalBytes = messages.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) }
        guard totalBytes > policy.contextBudgetBytes,
              messages.count > policy.contextPreserveRecentMessages + 2 else { return }
        let lastAllowedIndex = messages.count - policy.contextPreserveRecentMessages
        for index in 2..<lastAllowedIndex where messages[index].role == .tool {
            if (messages[index].content ?? "").utf8.count > 200 {
                messages[index] = ModelChatMessage(
                    role: .tool,
                    content: "(早期工具结果已省略；evidence 已登记，可按需用更小范围参数重新调用工具)",
                    toolCallID: messages[index].toolCallID
                )
            }
        }
    }
}

extension ResearchNotesSubmission {
    /// 解码后的领域形态（notes + 强类型 claims）。
    struct Decoded: Sendable, Hashable {
        let notes: String
        let claims: [ResearchClaim]
    }
}
