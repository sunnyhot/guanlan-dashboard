import Foundation

// DecisionCaseResearchAgent:为单个 DecisionCase 做专项研究。
//
// 复制 NextHourGuidanceAgent 的骨架(独立循环 + 复用基础设施),
// 不抽取通用 Harness(见 docs/ai-pipeline-baseline.md 第 9.3 节)。
//
// 与 NextHourGuidance 的差异:
// - 预算更轻(单 Case 研究 < 盘中全标的):8 轮 / 15 工具 / 240s
// - 无 web 搜索硬门禁(NextHour 的 minimumWebSearchAttempts 不适用)
// - 前置门禁:get_case_context 必调一次(了解 Case 上下文)
// - 输出:DecisionCaseResearchReport(findings + 建议状态),不是买卖建议
// - Agent 不直接改 Case,AppModel 校验后才采纳

// MARK: - 协议(AppModel 注入点)

protocol DecisionCaseResearchAgentProtocol: Sendable {
    func run(
        decisionCase: DecisionCase,
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings,
        officialSourceSettings: OfficialSourceSettings
    ) async throws -> DecisionCaseResearchReport
}

// MARK: - 错误

enum DecisionCaseResearchAgentError: Error, LocalizedError {
    case missingConfiguration
    case turnLimitExceeded
    case toolCallLimitExceeded
    case missingToolCalls
    case invalidSubmissionLimitExceeded(errors: [String])
    case totalTimeoutExceeded

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "研究 Agent 未配置模型"
        case .turnLimitExceeded: return "研究轮次超限"
        case .toolCallLimitExceeded: return "工具调用次数超限"
        case .missingToolCalls: return "模型未返回工具调用"
        case .invalidSubmissionLimitExceeded(let errors):
            return "研究报告多次未通过校验:\(errors.joined(separator: "、"))"
        case .totalTimeoutExceeded: return "研究总超时"
        }
    }
}

// MARK: - Agent

struct DecisionCaseResearchAgent: DecisionCaseResearchAgentProtocol, Sendable {

    // 预算(内联常量,比 NextHour 更轻)
    private static let maxTurns = 8
    private static let maxToolCalls = 15
    private static let maxInvalidSubmissions = 3
    private static let totalTimeoutSeconds: Double = 240
    private static let temperature: Double = 0.2

    // 工具名
    private static let contextToolName = "get_case_context"
    private static let submitToolName = "submit_case_research"

    // 共享工具(从 Registry filter)
    private static let sharedToolNames: Set<String> = [
        "get_portfolio_overview",
        "get_fund_lookthrough",
        "official_sec_research",
        "web_search"
    ]

    let client: any TrendResearchAgentClient
    let registry: TrendResearchToolRegistry

    init(
        client: any TrendResearchAgentClient = OpenAICompatibleAgentClient(),
        webSearchClient: any TavilySearchClientProtocol = TavilySearchClient(),
        officialSourceClient: any SECOfficialSourceClientProtocol = SECOfficialSourceClient(),
        officialSourceCache: SECOfficialSourceCache = .shared
    ) {
        self.client = client
        self.registry = TrendResearchToolRegistry(
            webSearchClient: webSearchClient,
            officialSourceClient: officialSourceClient,
            officialSourceCache: officialSourceCache
        )
    }

    // MARK: - 主循环

    func run(
        decisionCase: DecisionCase,
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings,
        officialSourceSettings: OfficialSourceSettings
    ) async throws -> DecisionCaseResearchReport {
        guard settings.isConfigured else { throw DecisionCaseResearchAgentError.missingConfiguration }

        let ledger = TrendEvidenceLedger()
        let governor = TrendWebSearchGovernor(maxNetworkSearches: 5)
        let started = Date()

        // 装配工具上下文(共享工具用)
        func makeToolContext() -> TrendResearchToolContext {
            TrendResearchToolContext(
                snapshot: snapshot,
                evidenceLedger: ledger,
                webSearchSettings: webSearchSettings,
                webSearchGovernor: governor,
                officialSourceSettings: officialSourceSettings,
                alphaVantageSettings: .empty
            )
        }

        // 装配工具定义
        var tools: [AgentToolDefinition] = [Self.caseContextTool()]
        let sharedDefinitions = registry.definitions.filter { def in
            guard Self.sharedToolNames.contains(def.function.name) else { return false }
            // web_search 只在配置时提供
            if def.function.name == "web_search" { return webSearchSettings.isConfigured }
            // official_sec_research 只在配置时提供
            if def.function.name == "official_sec_research" { return officialSourceSettings.isSECConfigured }
            return true
        }
        tools.append(contentsOf: sharedDefinitions)
        tools.append(Self.submitTool())

        // 消息
        var messages: [AgentChatMessage] = [
            AgentChatMessage(role: .system, content: Self.systemMessage(for: decisionCase)),
            AgentChatMessage(role: .user, content: Self.userMessage(for: decisionCase, snapshot: snapshot))
        ]

        var turnCount = 0
        var toolCallCount = 0
        var invalidSubmissions = 0
        var didReadContext = false
        var toolCallAudits: [TrendAgentToolCallAudit] = []

        while turnCount < Self.maxTurns {
            try Task.checkCancellation()

            // 超时检查
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > Self.totalTimeoutSeconds {
                throw DecisionCaseResearchAgentError.totalTimeoutExceeded
            }

            turnCount += 1
            let remainingTimeout = max(30, Self.totalTimeoutSeconds - elapsed)

            let result = try await client.complete(
                messages: messages,
                tools: tools,
                toolChoice: .auto,
                temperature: Self.temperature,
                settings: settings,
                timeout: remainingTimeout,
                streamProgress: nil
            )

            // 追加 assistant 消息(含 tool_calls,原样回灌)
            messages.append(result.assistantMessage)

            // 无工具调用 → 模型返回纯文本,不符合要求(要求用工具)
            if result.toolCalls.isEmpty {
                if result.stopReason == .length {
                    // 长度截断,提示继续
                    messages.append(AgentChatMessage(
                        role: .user,
                        content: "上一次响应被截断。请继续调用工具提交研究报告。"
                    ))
                    continue
                }
                throw DecisionCaseResearchAgentError.missingToolCalls
            }

            // 处理工具调用
            for call in result.toolCalls {
                try Task.checkCancellation()
                toolCallCount += 1
                if toolCallCount > Self.maxToolCalls {
                    throw DecisionCaseResearchAgentError.toolCallLimitExceeded
                }

                let toolName = call.function.name
                let succeeded: Bool

                if toolName == Self.contextToolName {
                    // 自定义:get_case_context,从 Case 装配证据
                    let evidence = Self.caseContextEvidence(for: decisionCase, snapshot: snapshot)
                    await ledger.record([evidence])
                    didReadContext = true
                    let envelope = TrendResearchToolEnvelope.success(
                        ["case": Self.caseContextJSON(for: decisionCase) as Any],
                        evidenceIDs: [evidence.id]
                    )
                    messages.append(AgentChatMessage(role: .tool, content: envelope, toolCallID: call.id))
                    succeeded = true
                } else if toolName == Self.submitToolName {
                    // 自定义:submit_case_research
                    // 前置门禁:必须先调 get_case_context
                    if !didReadContext {
                        let err = TrendResearchToolEnvelope.submitValidationError(
                            code: "missing_case_context",
                            message: "提交前必须先调 get_case_context 了解 Case 上下文。",
                            errors: ["未调用 get_case_context"],
                            remainingRepairAttempts: max(0, Self.maxInvalidSubmissions - invalidSubmissions - 1)
                        )
                        messages.append(AgentChatMessage(role: .tool, content: err, toolCallID: call.id))
                        invalidSubmissions += 1
                        succeeded = false
                    } else {
                        // 解码 + 校验
                        let (report, errors) = await Self.processSubmission(
                            argumentsJSON: call.function.arguments,
                            caseID: decisionCase.id,
                            ledger: ledger,
                            snapshot: snapshot
                        )
                        if let report = report, errors.isEmpty {
                            // 成功:记录审计并返回
                            let accepted = TrendResearchToolEnvelope.success(["accepted": true])
                            await AIAgentDiagnosticLog.recordToolResult(
                                turn: turnCount,
                                call: call,
                                contentJSON: accepted,
                                modelContentJSON: accepted,
                                isError: false
                            )
                            toolCallAudits.append(makeAudit(sequence: toolCallCount, call: call, succeeded: true))
                            return report
                        } else {
                            // 校验失败:回灌错误
                            invalidSubmissions += 1
                            if invalidSubmissions > Self.maxInvalidSubmissions {
                                throw DecisionCaseResearchAgentError.invalidSubmissionLimitExceeded(errors: errors)
                            }
                            let err = TrendResearchToolEnvelope.submitValidationError(
                                code: "research_validation_failed",
                                message: "研究报告未通过校验,请按 errors 修正后重新提交。",
                                errors: errors,
                                remainingRepairAttempts: max(0, Self.maxInvalidSubmissions - invalidSubmissions)
                            )
                            messages.append(AgentChatMessage(role: .tool, content: err, toolCallID: call.id))
                            succeeded = false
                        }
                    }
                } else if Self.sharedToolNames.contains(toolName) {
                    // 共享工具:走 Registry
                    let toolResult = await registry.execute(call, context: makeToolContext())
                    messages.append(AgentChatMessage(
                        role: .tool, content: toolResult.contentJSON, toolCallID: call.id
                    ))
                    succeeded = !toolResult.isError
                } else {
                    // 未知工具
                    let err = TrendResearchToolEnvelope.error(
                        code: "unknown_tool", message: "未知工具:\(toolName)"
                    )
                    messages.append(AgentChatMessage(role: .tool, content: err, toolCallID: call.id))
                    succeeded = false
                }

                let toolContent = messages.last(where: {
                    $0.role == .tool && $0.toolCallID == call.id
                })?.content ?? TrendResearchToolEnvelope.error(
                    code: "missing_tool_result",
                    message: "工具结果未写入消息上下文。"
                )
                await AIAgentDiagnosticLog.recordToolResult(
                    turn: turnCount,
                    call: call,
                    contentJSON: toolContent,
                    modelContentJSON: toolContent,
                    isError: !succeeded
                )
                toolCallAudits.append(makeAudit(sequence: toolCallCount, call: call, succeeded: succeeded))
            }
        }

        throw DecisionCaseResearchAgentError.turnLimitExceeded
    }

    // MARK: - Prompt

    private static func systemMessage(for cs: DecisionCase) -> String {
        """
        你是一个投资组合研究助手,专门为单个决策事项做专项研究。

        当前研究目标:\(cs.title)
        标的:\(cs.subjectName)\(cs.subjectCode.map { "(\($0))" } ?? "")
        当前指标:\(cs.metricDescription) \(cs.metricLabel)
        当前判断:\(cs.decisionState.rawValue)

        研究规则:
        1. 必须先调 get_case_context 了解 Case 上下文和已知事实。
        2. 有 get_fund_lookthrough 时,对基金标的调一次穿透。
        3. 有 official_sec_research 时,查官方披露。
        4. 有 web_search 时,搜索相关行业/政策/事件。
        5. 证据只能引用工具返回的 evidence_id,不得编造。
        6. 研究完成后调 submit_case_research 提交:
           - findings:支持当前风险判断的发现(若结论为风险不成立可留空,改在 rationale 说明)
             每条 finding 必须用这些字段值:
             direction ∈ {supportive, counter, neutral}
             significance ∈ {high, medium, low}
           - counterFindings:削弱风险判断的发现(同样字段值)
           - uncertainties:数据缺口和不确定因素
           - suggestedState:建议的决策状态(stable/watch/prepare/adjustReview/exitReview/insufficientEvidence)
           - rationale:建议理由
        7. exitReview 需要至少 2 个独立的反向证据(不同来源)。
        8. 不得给出直接交易指令;只输出研究发现和建议状态。
        """
    }

    private static func userMessage(for cs: DecisionCase, snapshot: TrendResearchSnapshot) -> String {
        """
        请研究以下决策事项:\(cs.title)
        详情:\(cs.detail)
        数据截止:\(snapshot.dataAsOf)
        请调用工具收集证据后提交研究报告。
        """
    }

    // MARK: - 自定义工具定义

    private static func caseContextTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: contextToolName,
            description: "获取当前决策事项的上下文:标的、指标、已知事实、历史事件。提交前必须调用一次。",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        )
    }

    private static func submitTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: submitToolName,
            description: "提交专项研究报告并结束本次研究。",
            parameters: [
                "type": "object",
                "properties": [
                    "findings": [
                        "type": "array",
                        "description": "支持当前风险判断的发现（若结论为风险不成立可留空，在 rationale 说明）",
                        "items": Self.findingItemSchema
                    ],
                    "counterFindings": [
                        "type": "array",
                        "description": "削弱风险判断的发现",
                        "items": Self.findingItemSchema
                    ],
                    "uncertainties": ["type": "array", "items": ["type": "string"], "description": "数据缺口和不确定因素"],
                    "suggestedState": ["type": "string", "description": "建议的决策状态:stable/watch/prepare/adjustReview/exitReview/insufficientEvidence"],
                    "rationale": ["type": "string", "description": "建议理由"]
                ],
                "required": ["suggestedState", "rationale"]
            ]
        )
    }

    /// findings / counterFindings 数组元素的 JSON Schema。
    /// 显式声明 direction / significance 的 enum 取值，避免模型输出同义词导致解码失败。
    private static let findingItemSchema: AgentJSONValue = [
        "type": "object",
        "properties": [
            "claim": ["type": "string", "description": "一句话发现"],
            "direction": ["type": "string", "enum": ["supportive", "counter", "neutral"], "description": "方向：supportive 支持 / counter 反向 / neutral 中性"],
            "significance": ["type": "string", "enum": ["high", "medium", "low"], "description": "重要性：high / medium / low"],
            "evidenceIDs": ["type": "array", "items": ["type": "string"], "description": "引用的证据 ID（工具返回的真实 ID）"]
        ],
        "required": ["claim", "direction", "significance"]
    ]

    // MARK: - Case 上下文证据

    private static func caseContextEvidence(for cs: DecisionCase, snapshot: TrendResearchSnapshot) -> TrendEvidence {
        TrendEvidence(
            id: "decision-case:context:\(cs.id.uuidString)",
            sourceName: "决策事项",
            title: cs.title,
            url: nil, publishedAt: nil,
            retrievedAt: snapshot.createdAt,
            summary: cs.detail,
            metadata: TrendEvidenceMetadata(
                sourceKind: .portfolioSnapshot,
                sourceTier: .primary,
                entityNames: [cs.subjectName],
                metadataConfidence: .deterministic
            )
        )
    }

    private static func caseContextJSON(for cs: DecisionCase) -> [String: Any] {
        [
            "title": cs.title,
            "subject": cs.subjectName,
            "metric": cs.metricLabel,
            "metricDescription": cs.metricDescription,
            "currentState": cs.decisionState.rawValue,
            "detail": cs.detail,
            "historyCount": cs.events.count
        ]
    }

    // MARK: - 审计辅助

    /// 构造工具调用审计条目(TrendAgentToolCallAudit 的 init 需要 TrendResearchToolResult,
    /// 这里用成功/失败的占位 result 构造)。
    private func makeAudit(sequence: Int, call: AgentToolCall, succeeded: Bool) -> TrendAgentToolCallAudit {
        let placeholder = TrendResearchToolResult.content(
            succeeded
                ? TrendResearchToolEnvelope.success(["ok": true])
                : TrendResearchToolEnvelope.error(code: "tool_error", message: "工具执行失败"),
            isError: !succeeded
        )
        return TrendAgentToolCallAudit(sequence: sequence, call: call, result: placeholder)
    }

    // MARK: - Submit 处理(解码 + 校验 + 证据过滤)

    private static func processSubmission(
        argumentsJSON: String,
        caseID: UUID,
        ledger: TrendEvidenceLedger,
        snapshot: TrendResearchSnapshot
    ) async -> (DecisionCaseResearchReport?, [String]) {
        // 1. 解析 JSON
        guard let argsData = argumentsJSON.data(using: .utf8),
              let argsObject = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        else {
            return (nil, ["提交参数不是合法 JSON"])
        }
        // 兼容:顶层可能是 {"report": {...}} 或直接 {...}
        let reportObject = (argsObject["report"] as? [String: Any]) ?? argsObject
        let reportData = (try? JSONSerialization.data(withJSONObject: reportObject)) ?? Data()

        // 2. 解码 Submission（不吞解码错误：失败时把具体原因回灌给模型，便于修正）
        let submission: DecisionCaseResearchSubmission
        do {
            submission = try JSONDecoder().decode(DecisionCaseResearchSubmission.self, from: reportData)
        } catch {
            return (nil, ["报告解码失败：\(AgentDecodingErrorFormatter.describe(error))"])
        }

        var errors: [String] = []
        if !submission.missingFields.isEmpty {
            errors.append("缺少必填字段:\(submission.missingFields.joined(separator: "、"))")
        }

        // 3. 收集引用的证据 ID,用 Ledger 过滤(防伪造)
        let allFindings = submission.findings + submission.counterFindings
        var referencedIDs: Set<String> = []
        for f in allFindings {
            referencedIDs.formUnion(f.evidenceIDs)
        }

        var canonicalEvidence: [TrendEvidence] = []
        var seen = Set<String>()
        for id in referencedIDs.sorted() {
            if seen.contains(id) { continue }
            if let canonical = await ledger.canonical(for: id) {
                canonicalEvidence.append(canonical)
                seen.insert(id)
            }
            // Ledger 不存在的 → 静默丢弃(防伪造)
        }

        // 4. exitReview 门槛:用 ClaimAssessmentEngine 评估反证独立性(Slice 4 升级)
        if submission.suggestedState == .exitReview {
            let counterEvidenceIDs = Set(submission.counterFindings.flatMap(\.evidenceIDs))
            let counterEvidence = canonicalEvidence.filter { counterEvidenceIDs.contains($0.id) }
            let supportingEvidenceIDs = Set(submission.findings.flatMap(\.evidenceIDs))
            let supportingEvidence = canonicalEvidence.filter { supportingEvidenceIDs.contains($0.id) }

            let assessment = ClaimAssessmentEngine.assess(
                supportingEvidence: supportingEvidence,
                counterEvidence: counterEvidence,
                targetName: nil  // Agent 的 finding 不绑定特定标的代码
            )
            if !assessment.meetsExitReviewThreshold {
                errors.append("exitReview 需要至少 2 个独立来源的反向证据,当前独立来源数:\(assessment.counterIndependentGroupCount)")
            }
        }

        // 5. 校验 evidenceIDs 引用真实存在(至少一条 finding 要有证据)
        let findingsWithEvidence = allFindings.filter { !$0.evidenceIDs.isEmpty }
        if findingsWithEvidence.isEmpty && !allFindings.isEmpty {
            errors.append("至少一条发现需要引用真实证据")
        }

        guard errors.isEmpty else { return (nil, errors) }

        let report = DecisionCaseResearchReport(
            caseID: caseID,
            generatedAt: snapshot.createdAt,
            findings: submission.findings,
            counterFindings: submission.counterFindings,
            uncertainties: submission.uncertainties,
            evidence: canonicalEvidence,
            suggestedState: submission.suggestedState,
            rationale: submission.rationale
        )
        return (report, [])
    }

}
