import Foundation

// 阶段三：TrendResearchAgent 运行循环。
//
// 维护消息状态，逐轮调用模型；模型返回 tool_call 后经 Registry 执行只读工具，
// 工具结果作为 tool message 回灌；分模块报告在本地组装并通过最终校验后结束，
// 校验失败把错误回灌模型做有限次自动修正。运行时有轮次、工具次数、修正次数、
// 超时和取消边界。

/// Agent 抽象，便于 AppModel 注入（测试可替换为 Fake Agent）。
protocol TrendResearchAgentProtocol: Sendable {
    func run(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        alphaVantageSettings: AlphaVantageSettings,
        scope: TrendResearchRunScope,
        baselineReport: TrendAnalysisReport?,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async throws -> TrendAnalysisReport
}

extension TrendResearchAgent: TrendResearchAgentProtocol {}

// MARK: - 客户端协议（便于注入 Fake Client 做循环测试）

protocol TrendResearchAgentClient: Sendable {
    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice,
        temperature: Double,
        settings: TrendAIProviderSettings,
        timeout: Double?,
        deadline: Date?,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult
}

extension OpenAICompatibleAgentClient: TrendResearchAgentClient {
    // 协议见证：客户端 complete 新增了 maxOutputTokens/deadline 参数（带默认值），
    // 与协议签名不再逐字匹配，这里显式桥接；旧链路语义不变（不限输出长度、无运行截止）。
    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice,
        temperature: Double,
        settings: TrendAIProviderSettings,
        timeout: Double?,
        deadline: Date?,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult {
        try await complete(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            temperature: temperature,
            maxOutputTokens: nil,
            settings: settings,
            timeout: timeout,
            deadline: deadline,
            streamProgress: streamProgress
        )
    }
}

// MARK: - 运行策略与事件

struct TrendResearchRunPolicy: Sendable {
    /// 单轮模型请求不能独占整次运行预算。流式输出按“分片间空闲”判定：只要持续
    /// 有字节到达就续期，超过 perRequestTimeoutSeconds 无新数据才判超时，由 Harness
    /// 收敛任务后自动重试。彻底无字节的卡死由 URLSession 的 timeoutInterval 兜底，
    /// 整体上限由 totalTimeoutSeconds 在轮与轮之间保证。
    /// 取 180s：推理模型（如 GLM-5.2）首 token 前常有较长的静默思考期，90s 偏短会误杀。
    static let defaultPerRequestTimeoutSeconds: Double = 180
    /// 整次运行总预算：宽松兜底，只在极端失控（远超正常轮次耗时）时截断。
    /// 正常运行靠单轮空闲超时 + 轮次/工具上限自然终止，慢但正常推进的运行应能跑完。
    static let defaultTotalTimeoutSeconds: Double = 1800
    static let defaultMaxRequestTimeoutRecoveries = 1

    var maxTurns: Int = 18
    var maxToolCalls: Int = 40
    var expandedMaxTurns: Int = 48
    var expandedMaxToolCalls: Int = 96
    var reservedSubmitToolCalls: Int = 8
    var maxInvalidSubmissions: Int = 4
    var maxPlainTextResponses: Int = 2
    var perRequestTimeoutSeconds: Double = Self.defaultPerRequestTimeoutSeconds
    var totalTimeoutSeconds: Double = Self.defaultTotalTimeoutSeconds
    /// 2026-09-01 根治:上限从 1800 提到 3600,让 `effectiveTotalTimeout` 的
    /// 随组合规模扩容(1800 + 4s/只)真正生效——之前 base=cap=1800,
    /// min(1800, 1800+4n) 恒等于 1800,扩容是死代码。2026-08-31 实证单轮流式
    /// 405-725s,fanout 874s 失败回退后 1800s 必然撞墙。
    /// 晚闸门换完成度:超预算时走降级完成(W5),不再整 run 报废。
    var expandedTotalTimeoutSeconds: Double = 3600
    var totalTimeoutPerAssetSeconds: Double = 4
    var maxRequestTimeoutRecoveries: Int = Self.defaultMaxRequestTimeoutRecoveries
    var maxToolResultBytes: Int = 32 * 1024
    var temperature: Double = 0.2

    init() {}

    /// get_portfolio_assets 每页最多 20 个标的；首屏预算已包含在基础值中，
    /// 后续每多一页就为本次运行增加一轮和一次工具调用，最终仍受硬上限约束。
    func effectiveLimits(
        assetCount: Int,
        sectorCount: Int = 0,
        reportAssetCount: Int? = nil,
        scope: TrendResearchRunScope = .full
    ) -> (
        maxTurns: Int,
        maxToolCalls: Int
    ) {
        let pageSize = 20
        let pageCount = max(1, (max(0, assetCount) + pageSize - 1) / pageSize)
        let extraPages = max(0, pageCount - 1)
        let reportBatchCount = (
            max(0, reportAssetCount ?? assetCount)
                + TrendReportDraftStore.assetBatchSize
                - 1
        ) / TrendReportDraftStore.assetBatchSize
        // 基础 18 轮已为常见的 15 只以内组合预留 3 个持仓报告批次。
        let extraReportBatches = max(0, reportBatchCount - 3)
        switch scope {
        case .marketRadar:
            return (18, 28)
        case .closeReview:
            return (
                min(expandedMaxTurns, 8 + extraPages + max(1, reportBatchCount)),
                min(expandedMaxToolCalls, 16 + extraPages + max(1, reportBatchCount))
            )
        case .longTerm:
            return (
                min(expandedMaxTurns, 14 + extraPages + max(1, reportBatchCount)),
                min(expandedMaxToolCalls, 28 + extraPages + max(1, reportBatchCount))
            )
        case .full:
            return (
                maxTurns: min(
                    expandedMaxTurns,
                    maxTurns + extraPages + extraReportBatches
                ),
                maxToolCalls: min(
                    expandedMaxToolCalls,
                    maxToolCalls + extraPages + extraReportBatches
                )
            )
        }
    }

    /// 整次运行总预算随组合规模扩张：分块报告比单次提交更耗时，固定基线对大组合偏紧。
    /// 最终受 expandedTotalTimeoutSeconds 约束。
    func effectiveTotalTimeout(assetCount: Int) -> Double {
        let scaled = totalTimeoutSeconds
            + Double(max(0, assetCount)) * totalTimeoutPerAssetSeconds
        return min(expandedTotalTimeoutSeconds, scaled)
    }
}

enum TrendResearchAgentEvent: Sendable {
    case started(runID: UUID)
    case harnessConfigured(maxTurns: Int, maxToolCalls: Int)
    case moduleProgress(completedSections: Int, totalSections: Int, nextToolName: String?)
    case harnessGuidance(message: String)
    case turnStarted(Int)
    case modelRequestStarted(turn: Int)
    case modelRequestTimedOut(turn: Int, timeout: Double, recoveryAttempt: Int, maxRecoveryAttempts: Int)
    case modelStreamProgress(turn: Int, progress: AgentStreamProgress)
    case modelResponseReceived(turn: Int, duration: Double)
    case modelCorrection(message: String)
    case toolStarted(name: String)
    case toolFinished(name: String, summary: String)
    case reportValidationFailed(errors: [String], remainingAttempts: Int)
    case auditArtifactReady(TrendAgentRunArtifact)
    case completed(duration: Double)
    case failed(message: String)
    case cancelled
}

enum TrendResearchAgentError: Error, LocalizedError {
    case missingConfiguration
    case turnLimitExceeded
    case toolCallLimitExceeded
    case missingToolCalls
    case invalidSubmissionLimitExceeded(errors: [String])
    case modelRequestTimeoutRecoveryExceeded(timeout: Double)
    case totalTimeoutExceeded(limit: Double)
    /// 剩余预算为正但低于单步最小预算：直接终止而不是发起一次注定中途超时的计费请求。
    /// 与 totalTimeoutExceeded 区分：预算「止损不发」，语义可观测。
    case budgetSkipBeforeRequest(remaining: Double)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "尚未配置趋势分析模型。请填写模型地址、模型名称和 API Key。"
        case .turnLimitExceeded:
            return "趋势 Agent 已达最大轮次仍未提交有效报告。"
        case .toolCallLimitExceeded:
            return "趋势 Agent 已达最大工具调用次数。"
        case .missingToolCalls:
            return "模型连续返回普通文本，未调用工具。"
        case .invalidSubmissionLimitExceeded(let errors):
            return "报告多次校验未通过：\n" + errors.joined(separator: "\n")
        case .modelRequestTimeoutRecoveryExceeded(let timeout):
            return "趋势模型连续请求超时（单轮上限 \(Int(timeout.rounded())) 秒）。Agent 已自动收敛任务并重试，但模型服务仍未返回；已保留上一次报告，请检查模型服务状态后重试。"
        case .totalTimeoutExceeded(let limit):
            return "趋势 Agent 已达到 \(Int(limit.rounded())) 秒整体运行上限。已保留上一次报告，请检查模型服务状态后重试。"
        case .budgetSkipBeforeRequest(let remaining):
            return "趋势 Agent 剩余预算仅 \(Int(remaining.rounded())) 秒，低于单步最小预算，已止损终止而不发起注定超时的模型请求。已保留上一次报告。"
        }
    }
}

// MARK: - Agent

struct TrendResearchAgent: Sendable {
    let client: any TrendResearchAgentClient
    let registry: TrendResearchToolRegistry
    let promptBuilder: TrendResearchPromptBuilder
    let policy: TrendResearchRunPolicy

    /// 运行时强制：submit 前必须先调用的工具。
    static let overviewToolName = "get_portfolio_overview"
    static let alphaVantageToolName = "alpha_vantage_research"
    static let submitToolName = "submit_trend_report"
    static let moduleSubmitToolNames = TrendReportModuleToolName.all
    /// 修复预算 = 基础 + 每 8 只基金 1 次额外额度（大组合终审错误多，预算必须够用）。
    static func effectiveInvalidSubmissionBudget(fundCount: Int, base: Int) -> Int {
        base + max(0, fundCount / TrendReportDraftStore.assetBatchSize)
    }

    /// 一次有意义的 LLM 往返所需最小秒数（对拍 DSA runner 的 _MIN_STEP_BUDGET_S）。
    /// 剩余预算为正但低于此值时按 budgetSkip 终止，不浪费一次计费请求。
    /// 单步最小预算护栏:2026-09-01 从 8s 提到 60s——8s 形同虚设(2026-08-31 实证
    /// 剩 23s 照样放行第 10 轮,流式 405s 超限 382s 才终止)。60s 仍远小于正常单轮,
    /// 但能拦住「注定跑不完一轮」的请求,让预算止损真正发生。
    static let minimumStepBudgetSeconds: Double = 60

    init(
        // 经 LLM 网关：预算 / 记账 / trace 立即生效；重试关闭（本 Agent 自带
        // 超时恢复循环，网关级重试会造成双重等待）。
        client: any TrendResearchAgentClient = GatewayAgentClient(
            purpose: "trend-research",
            policy: ModelGatewayPolicy(maxRetriesPerProvider: 0)
        ),
        alphaVantageClient: any AlphaVantageClientProtocol = AlphaVantageClient(),
        alphaVantageCache: AlphaVantageResponseCache = .shared,
        policy: TrendResearchRunPolicy = .init()
    ) {
        self.client = client
        self.registry = TrendResearchToolRegistry(
            alphaVantageClient: alphaVantageClient,
            alphaVantageCache: alphaVantageCache
        )
        self.promptBuilder = TrendResearchPromptBuilder()
        self.policy = policy
    }

    func run(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        alphaVantageSettings: AlphaVantageSettings = .empty,
        scope requestedScope: TrendResearchRunScope = .full,
        baselineReport: TrendAnalysisReport? = nil,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async throws -> TrendAnalysisReport {
        guard settings.isConfigured else {
            throw TrendResearchAgentError.missingConfiguration
        }

        let scope = TrendReportDraftStore.effectiveScope(
            requestedScope: requestedScope,
            baselineReport: baselineReport,
            expectedFundCodes: snapshot.expectedFundCodes
        )
        let ledger = TrendEvidenceLedger()
        if let baselineReport {
            await ledger.record(baselineReport.evidence)
        }
        let reportDraftStore = TrendReportDraftStore(
            expectedFundCodes: snapshot.expectedFundCodes,
            scope: scope,
            baselineReport: baselineReport
        )
        let alphaVantageRequired = scope.usesVendorResearch
            && alphaVantageSettings.isConfigured
            && !snapshot.eligibleAlphaVantageSymbols.isEmpty
        var messages = promptBuilder.initialMessages(
            snapshot: snapshot,
            scope: scope,
            alphaVantageConfigured: alphaVantageRequired
        )

        var turnCount = 0
        var toolCallCount = 0
        var plainTextResponses = 0
        var invalidSubmissions = 0
        var executedByID: [String: TrendResearchToolResult] = [:]
        var executedBySignature: [String: TrendResearchToolResult] = [:]
        var toolCallAudits: [TrendAgentToolCallAudit] = []
        var harnessState = TrendResearchHarnessState(
            snapshot: snapshot,
            scope: scope,
            alphaVantageRequired: alphaVantageRequired
        )
        var submissionMode = false
        var consecutiveRequestTimeoutRecoveries = 0
        // 拒批教训去重:同一条校验错误只前移注入一次,避免修复循环里重复刷屏。
        var injectedRejectionLessons: Set<String> = []
        let started = Date()
        let runLimits = policy.effectiveLimits(
            assetCount: snapshot.assets.count,
            sectorCount: snapshot.sectors.count,
            reportAssetCount: snapshot.expectedFundCodes.count,
            scope: scope
        )
        // 2026-08-31 修复 3：修复预算随组合规模扩张——琐碎 schema 错不再挤占终审修复额度。
        let invalidSubmissionBudget = Self.effectiveInvalidSubmissionBudget(
            fundCount: snapshot.expectedFundCodes.count,
            base: policy.maxInvalidSubmissions
        )
        // 整次运行总预算随组合规模动态扩张；固定值对大组合偏紧。
        let effectiveTotal = policy.effectiveTotalTimeout(
            assetCount: snapshot.assets.count
        )
        // 2026-09-01 根治:运行截止时间下传到每次模型请求,流式持续输出也受硬约束
        // (此前只在轮与轮之间检查,单轮流式 405-725s 可无界超时)。
        let runDeadline = started.addingTimeInterval(effectiveTotal)

        await AIAgentDiagnosticLog.record(
            "agent_configured",
            payload: AgentJSONValue.object([
                "scope": .string(scope.rawValue),
                "asset_count": .number(Double(snapshot.assets.count)),
                "expected_fund_count": .number(Double(snapshot.expectedFundCodes.count)),
                "sector_count": .number(Double(snapshot.sectors.count)),
                "privacy_mode": .string(snapshot.privacyMode.rawValue),
                "max_turns": .number(Double(runLimits.maxTurns)),
                "max_tool_calls": .number(Double(runLimits.maxToolCalls)),
                "total_timeout_seconds": .number(effectiveTotal),
            ])
        )

        await eventHandler(.started(runID: snapshot.runID))
        await eventHandler(
            .harnessConfigured(
                maxTurns: runLimits.maxTurns,
                maxToolCalls: runLimits.maxToolCalls
            )
        )
        let initialDraftProgress = await reportDraftStore.progress()
        await eventHandler(
            .moduleProgress(
                completedSections: initialDraftProgress.completedSections,
                totalSections: initialDraftProgress.totalSections,
                nextToolName: initialDraftProgress.nextToolName
            )
        )

        // closeReview 批次并行 fan-out(2026-08-19 耗时优化):逐只归因相互独立,
        // 交互式串行生成占全程 ~97%(线上 15 分钟里 14.8 分钟)。此处 harness 预取
        // 只读数据后并行生成各批,提交/校验/组装终检与交互路径完全同链;任何环节
        // 不顺利返回 nil,落回下方交互循环(带着已暂存批次按 remaining 继续),行为契约不变。
        if scope == .closeReview,
           snapshot.expectedFundCodes.count >= Self.fanOutMinimumFundCount {
            if let report = try await closeReviewFanOut(
                snapshot: snapshot,
                settings: settings,
                scope: scope,
                draftStore: reportDraftStore,
                ledger: ledger,
                policy: policy,
                started: started,
                runDeadline: runDeadline,
                eventHandler: eventHandler
            ) {
                return report
            }
            await AIAgentDiagnosticLog.record(
                "fanout_fallback_to_interactive",
                payload: AgentJSONValue.object([:])
            )
        }

        do {
            while turnCount < runLimits.maxTurns {
                try Task.checkCancellation()
                // 总预算仅作极端失控兜底：正常运行靠单轮空闲超时 + 轮次/工具上限自然终止，
                // 不会触及；真到这里说明远超正常耗时，终止并保留上一份报告。
                let remainingTotal = effectiveTotal - Date().timeIntervalSince(started)
                if remainingTotal <= 0 {
                    throw TrendResearchAgentError.totalTimeoutExceeded(limit: effectiveTotal)
                }
                // 单步最小预算护栏：剩余为正但不足一次有意义的模型往返时直接止损，
                // 不发起注定中途超时的计费请求（语义与 totalTimeout 区分，可观测）。
                if remainingTotal < Self.minimumStepBudgetSeconds {
                    throw TrendResearchAgentError.budgetSkipBeforeRequest(remaining: remainingTotal)
                }
                let configuredTimeout = max(1, settings.timeoutSeconds)
                // 每轮超时不再随总预算缩减：让慢但正常推进的运行能跑完，而不是越到后面越被掐。
                let perRequestTimeout = min(
                    policy.perRequestTimeoutSeconds,
                    configuredTimeout
                )

                let remainingResearchToolCalls = max(
                    0,
                    runLimits.maxToolCalls
                        - policy.reservedSubmitToolCalls
                        - toolCallCount
                )
                let researchToolBudgetExhausted = remainingResearchToolCalls == 0
                let researchReady = harnessState.readyForSubmission()
                if researchReady, !submissionMode {
                    submissionMode = true
                    let guidance = if researchToolBudgetExhausted {
                        "研究工具预算已收敛，已为结构化提交保留 \(policy.reservedSubmitToolCalls) 次调用。立即停止搜索并提交降级市场模块；未完成覆盖的维度不得生成机会结论。"
                    } else {
                        "「\(scope.displayName)」所需数据已覆盖，立即停止新增研究，只提交当前开放模块；其它模块复用上一份已校验结果。"
                    }
                    messages.append(correctionMessage(guidance))
                    await eventHandler(.harnessGuidance(message: guidance))
                }

                let draftProgress = await reportDraftStore.progress()
                let toolsForRequest = registry.definitions.filter { definition in
                    let toolName = definition.function.name
                    if submissionMode {
                        return toolName == draftProgress.nextToolName
                    }
                    if Self.isSubmissionTool(toolName) {
                        return false
                    }
                    guard scope.allowedResearchToolNames.contains(toolName) else {
                        return false
                    }
                    if toolName == Self.alphaVantageToolName {
                        return alphaVantageRequired
                    }
                    return true
                }
                let exposedToolNames = Set(toolsForRequest.map(\.function.name))

                turnCount += 1
                await eventHandler(.turnStarted(turnCount))
                await eventHandler(.modelRequestStarted(turn: turnCount))
                let requestStarted = Date()
                let currentTurn = turnCount

                let response: AgentCompletionResult
                do {
                    response = try await client.complete(
                        messages: messages,
                        tools: toolsForRequest,
                        toolChoice: .auto,
                        temperature: policy.temperature,
                        settings: settings,
                        timeout: perRequestTimeout,
                        deadline: runDeadline,
                        streamProgress: { progress in
                            await eventHandler(
                                .modelStreamProgress(turn: currentTurn, progress: progress)
                            )
                        }
                    )
                } catch OpenAICompatibleAgentClientError.runDeadlineExceeded {
                    // 运行截止时间在流式中途到达:不可恢复,直接终局
                    //(终局路径会尝试用已暂存批次降级完成,见 degradeIfPossible)。
                    throw TrendResearchAgentError.totalTimeoutExceeded(limit: effectiveTotal)
                } catch OpenAICompatibleAgentClientError.timedOut {
                    // 空闲超时恢复前先复查总预算:预算已耗尽/不足时不再花第二轮等待
                    //(2026-08-31 实证:超时恢复重试可再吃 180s 纯等待)。
                    let remainingForRecovery = runDeadline.timeIntervalSinceNow
                    if remainingForRecovery <= 0 {
                        throw TrendResearchAgentError.totalTimeoutExceeded(limit: effectiveTotal)
                    }
                    if remainingForRecovery < Self.minimumStepBudgetSeconds {
                        throw TrendResearchAgentError.budgetSkipBeforeRequest(
                            remaining: remainingForRecovery
                        )
                    }
                    guard consecutiveRequestTimeoutRecoveries < policy.maxRequestTimeoutRecoveries else {
                        throw TrendResearchAgentError.modelRequestTimeoutRecoveryExceeded(
                            timeout: perRequestTimeout
                        )
                    }

                    consecutiveRequestTimeoutRecoveries += 1
                    let researchReady = harnessState.readyForSubmission()
                    if researchReady {
                        submissionMode = true
                    }

                    await eventHandler(
                        .modelRequestTimedOut(
                            turn: currentTurn,
                            timeout: perRequestTimeout,
                            recoveryAttempt: consecutiveRequestTimeoutRecoveries,
                            maxRecoveryAttempts: policy.maxRequestTimeoutRecoveries
                        )
                    )
                    let recoveryProgress = await reportDraftStore.progress()
                    let nextStep = researchReady
                        ? "研究覆盖已经满足要求。停止新增搜索和解释，只调用当前开放的分模块提交工具 \(recoveryProgress.nextToolName ?? TrendReportModuleToolName.actions)。"
                        : "不要重复展开分析，本轮只完成一个必要动作：\(harnessState.nextStepHint())"
                    let guidance = "第 \(currentTurn) 轮模型请求超时。Harness 正在自动恢复：\(nextStep)"
                    messages.append(correctionMessage(guidance))
                    await eventHandler(.harnessGuidance(message: guidance))
                    compactContextIfNeeded(
                        &messages,
                        preserveResearchResults: submissionMode
                    )
                    continue
                }

                consecutiveRequestTimeoutRecoveries = 0
                await eventHandler(.modelResponseReceived(turn: turnCount, duration: Date().timeIntervalSince(requestStarted)))
                messages.append(response.assistantMessage)

                // 响应被 token 上限截断：不执行可能不完整的工具参数，要求模型重发完整 tool call。
                if case .length = response.stopReason {
                    await eventHandler(.modelCorrection(message: "模型响应被长度上限截断，已要求重新发送完整工具调用。"))
                    messages.append(correctionMessage("上次响应被截断，不得执行不完整的工具参数，请重新发出完整 tool call。"))
                    continue
                }

                guard !response.toolCalls.isEmpty else {
                    plainTextResponses += 1
                    await eventHandler(
                        .modelCorrection(
                            message: "模型返回普通文本、未调用工具，正在要求重试（\(plainTextResponses)/\(policy.maxPlainTextResponses + 1)）。"
                        )
                    )
                    if plainTextResponses > policy.maxPlainTextResponses {
                        throw TrendResearchAgentError.missingToolCalls
                    }
                    messages.append(correctionMessage("普通文本不会被接收。研究阶段请调用只读工具；进入提交阶段后只调用当前开放的分模块提交工具。"))
                    continue
                }

                var pendingHarnessGuidance: String?
                for call in response.toolCalls {
                    if toolCallCount >= runLimits.maxToolCalls {
                        throw TrendResearchAgentError.toolCallLimitExceeded
                    }

                    let toolName = call.function.name
                    let isSubmit = Self.isSubmissionTool(toolName)
                    let callSignature = Self.toolCallSignature(call)
                    let unexpectedTool = !exposedToolNames.contains(toolName)
                    // 运行时强制：submit 前必须先调用 get_portfolio_overview。
                    let missingOverview = isSubmit
                        && scope.requiresPortfolioOverview
                        && !harnessState.overviewRead
                    // 标的明细必须完整覆盖，否则模型无法生成完整 assetTrends。
                    let missingAssets = isSubmit
                        && scope.requiresPortfolioAssets
                        && !harnessState.assetCoverageComplete
                    // 有基金穿透快照时必须读取，避免继续把场内/场外基金误当成真实板块。
                    let missingLookThrough = isSubmit
                        && scope.requiresFundLookThrough
                        && !harnessState.lookThroughCoverageComplete
                    let missingAlphaVantage = isSubmit
                        && alphaVantageRequired
                        && harnessState.alphaVantageAttempts == 0
                    let missingRequiredTool = unexpectedTool
                        || missingOverview
                        || missingAssets
                        || missingLookThrough
                        || missingAlphaVantage

                    var rawToolResult: TrendResearchToolResult
                    if unexpectedTool {
                        rawToolResult = .content(
                            TrendResearchToolEnvelope.error(
                                code: "unexpected_tool",
                                message: submissionMode
                                    ? "当前只允许调用 \(draftProgress.nextToolName ?? "当前开放的分模块工具")；不得跳过模块顺序或一次提交整份报告。"
                                    : "工具 \(toolName) 当前未开放，请遵循 harness.next_step_hint。"
                            ),
                            isError: true
                        )
                        await eventHandler(.modelCorrection(message: "模型调用了当前未开放的工具，已要求按 Harness 顺序重试。"))
                    } else if missingOverview {
                        rawToolResult = .content(TrendResearchToolEnvelope.error(code: "missing_required_tool", message: "提交报告前必须先调用 get_portfolio_overview 取得组合基线，请先调用它再重新提交。"), isError: true)
                        await eventHandler(.modelCorrection(message: "报告提交被延后：必须先读取组合概览。"))
                    } else if missingAssets {
                        rawToolResult = .content(
                            TrendResearchToolEnvelope.error(
                                code: "missing_required_tool",
                                message: "提交报告前必须完整读取持仓明细，当前仍有 \(harnessState.unreadAssetCount) 个标的未覆盖。请继续分页调用 get_portfolio_assets。"
                            ),
                            isError: true
                        )
                        await eventHandler(.modelCorrection(message: "报告提交被延后：仍有 \(harnessState.unreadAssetCount) 个标的未读取。"))
                    } else if missingLookThrough {
                        rawToolResult = .content(
                            TrendResearchToolEnvelope.error(
                                code: "missing_required_tool",
                                message: "本次快照包含基金底层资产披露，提交报告前必须调用 get_fund_lookthrough，读取真实行业/证券暴露、披露日期和未知仓位。"
                            ),
                            isError: true
                        )
                        await eventHandler(.modelCorrection(message: "报告提交被延后：必须先读取基金底层资产穿透结果。"))
                    } else if missingAlphaVantage {
                        rawToolResult = .content(
                            TrendResearchToolEnvelope.error(
                                code: "missing_required_tool",
                                message: "已配置 Alpha Vantage 且存在可研究标的；提交前必须至少调用一次 alpha_vantage_research 获取最相关的结构化补充。"
                            ),
                            isError: true
                        )
                        await eventHandler(.modelCorrection(message: "报告提交被延后：必须先完成一次 Alpha Vantage 结构化研究。"))
                    } else if !isSubmit, let cached = executedByID[call.id] {
                        rawToolResult = cached
                        await eventHandler(.toolFinished(name: toolName, summary: "复用本次运行缓存：\(Self.summary(of: cached))"))
                    } else if let callSignature,
                              let cached = executedBySignature[callSignature] {
                        rawToolResult = cached
                        executedByID[call.id] = cached
                        await eventHandler(.toolFinished(name: toolName, summary: "复用本次运行缓存：\(Self.summary(of: cached))"))
                    } else {
                        await eventHandler(.toolStarted(name: toolName))
                        var context = TrendResearchToolContext(
                            snapshot: snapshot,
                            scope: scope,
                            evidenceLedger: ledger,
                            alphaVantageSettings: alphaVantageSettings,
                            reportDraftStore: reportDraftStore
                        )
                        context.invalidSubmissionBudget = invalidSubmissionBudget
                        context.invalidSubmissionsUsed = invalidSubmissions
                        rawToolResult = await registry.execute(call, context: context)
                        executedByID[call.id] = rawToolResult
                        if let callSignature {
                            executedBySignature[callSignature] = rawToolResult
                        }
                        await eventHandler(.toolFinished(name: toolName, summary: Self.summary(of: rawToolResult)))
                    }

                    if Self.moduleSubmitToolNames.contains(toolName) {
                        let moduleProgress = await reportDraftStore.progress()
                        await eventHandler(
                            .moduleProgress(
                                completedSections: moduleProgress.completedSections,
                                totalSections: moduleProgress.totalSections,
                                nextToolName: moduleProgress.nextToolName
                            )
                        )
                    }

                    let toolResult = harnessState.process(
                        toolName: toolName,
                        result: rawToolResult
                    )
                    toolCallCount += 1
                    toolCallAudits.append(
                        TrendAgentToolCallAudit(
                            sequence: toolCallCount,
                            call: call,
                            result: rawToolResult
                        )
                    )
                    let enrichedToolResult = harnessState.attachingHarnessMetadata(
                        to: toolResult,
                        turn: turnCount,
                        maxTurns: runLimits.maxTurns,
                        toolCallsUsed: toolCallCount,
                        maxToolCalls: runLimits.maxToolCalls,
                        reservedSubmitToolCalls: policy.reservedSubmitToolCalls
                    )

                    // 工具结果超过字节上限：截断后再回灌，避免单个超大结果撑爆上下文。
                    // 磁盘诊断日志同时保存完整原始结果和实际回灌模型的内容。
                    let modelToolContent = Self.truncate(
                        enrichedToolResult.contentJSON,
                        limit: policy.maxToolResultBytes
                    )
                    await AIAgentDiagnosticLog.recordToolResult(
                        turn: turnCount,
                        call: call,
                        contentJSON: rawToolResult.contentJSON,
                        modelContentJSON: modelToolContent,
                        isError: rawToolResult.isError
                    )
                    messages.append(
                        toolMessage(callID: call.id, content: modelToolContent)
                    )

                    // submit 成功 → 结束。
                    if case .report(let report) = toolResult.completion {
                        let artifact = TrendAgentRunArtifact.make(
                            snapshot: snapshot,
                            settings: settings,
                            report: report,
                            completedAt: ISO8601DateFormatter().string(from: Date()),
                            toolCalls: toolCallAudits,
                            canonicalEvidence: await ledger.allEvidence()
                        )
                        await eventHandler(.auditArtifactReady(artifact))
                        await eventHandler(.completed(duration: Date().timeIntervalSince(started)))
                        await AIAgentDiagnosticLog.record(
                            "run_completed",
                            payload: report
                        )
                        return report
                    }

                    // submit 校验失败（实际执行了 submit，非缺 overview 的拒绝）→ 记数；超过预算则终止。
                    if isSubmit, toolResult.isError, !missingRequiredTool {
                        invalidSubmissions += 1
                        let errors = Self.parseErrors(from: toolResult.contentJSON)
                        let remaining = max(0, invalidSubmissionBudget - invalidSubmissions)
                        await eventHandler(.reportValidationFailed(errors: errors, remainingAttempts: remaining))
                        // 拒批教训前移:立即以醒目 correction 注入(去重),让后续批次
                        // 不再犯同类证据/格式错误——线上修复循环的放大器正是重复拒批。
                        messages.append(
                            contentsOf: Self.rejectionLessonMessages(
                                errors: errors,
                                seen: &injectedRejectionLessons
                            )
                        )
                        if invalidSubmissions > invalidSubmissionBudget {
                            throw TrendResearchAgentError.invalidSubmissionLimitExceeded(errors: errors)
                        }
                    }

                    // 成功暂存的分批提交:把对应 tool_call 的完整参数替换为短桩
                    // (保留 id/名称,tool 结果的 callID 链不断)。内容已进 DraftStore,
                    // 后续轮次无需在上下文里拖着几十 KB 的已提交 JSON(线上输入雪球主因)。
                    if isSubmit, !toolResult.isError,
                       call.function.name == TrendReportModuleToolName.assetBatch {
                        stubAcceptedBatchArguments(&messages, callID: call.id)
                    }

                }

                if let pendingHarnessGuidance {
                    messages.append(correctionMessage(pendingHarnessGuidance))
                    await eventHandler(.harnessGuidance(message: pendingHarnessGuidance))
                }

                compactContextIfNeeded(
                    &messages,
                    preserveResearchResults: submissionMode
                )
            }

            throw TrendResearchAgentError.turnLimitExceeded
        } catch is CancellationError {
            await AIAgentDiagnosticLog.record(
                "run_cancelled",
                message: "Agent 运行已取消"
            )
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        alphaVantageConfigured: alphaVantageSettings.isConfigured,
                        completedAt: ISO8601DateFormatter().string(from: Date()),
                        toolCalls: toolCallAudits,
                        canonicalEvidence: await ledger.allEvidence(),
                        message: "Agent 运行已取消"
                    )
                )
            )
            await eventHandler(.cancelled)
            throw CancellationError()
        } catch let error as TrendResearchAgentError {
            // 2026-09-01 根治(W5):终局错误先尝试降级完成——已暂存批次不白烧
            //(2026-08-31 实证:29 只覆盖 21 只时整 run 报废,~30 分钟产出清零)。
            // 零暂存或降级终检不过时返回 nil,走下方现行失败契约(基线 §2.5 不破)。
            if let degraded = await degradeIfPossible(
                snapshot: snapshot,
                settings: settings,
                scope: scope,
                draftStore: reportDraftStore,
                ledger: ledger,
                started: started,
                reason: Self.degradationReason(for: error),
                toolCallAudits: toolCallAudits,
                eventHandler: eventHandler
            ) {
                return degraded
            }
            await AIAgentDiagnosticLog.record(
                "run_failed",
                message: error.localizedDescription
            )
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        alphaVantageConfigured: alphaVantageSettings.isConfigured,
                        completedAt: ISO8601DateFormatter().string(from: Date()),
                        toolCalls: toolCallAudits,
                        canonicalEvidence: await ledger.allEvidence(),
                        message: error.localizedDescription
                    )
                )
            )
            await eventHandler(.failed(message: error.localizedDescription))
            throw error
        } catch {
            // 2026-09-01 根治(W5):非预期错误同样先尝试降级完成(网络/服务故障
            // 中断时,已暂存的批次仍有价值)。
            if let degraded = await degradeIfPossible(
                snapshot: snapshot,
                settings: settings,
                scope: scope,
                draftStore: reportDraftStore,
                ledger: ledger,
                started: started,
                reason: "本轮运行因模型服务错误提前终止",
                toolCallAudits: toolCallAudits,
                eventHandler: eventHandler
            ) {
                return degraded
            }
            await AIAgentDiagnosticLog.record(
                "run_failed",
                message: error.localizedDescription
            )
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        alphaVantageConfigured: alphaVantageSettings.isConfigured,
                        completedAt: ISO8601DateFormatter().string(from: Date()),
                        toolCalls: toolCallAudits,
                        canonicalEvidence: await ledger.allEvidence(),
                        message: error.localizedDescription
                    )
                )
            )
            await eventHandler(.failed(message: error.localizedDescription))
            throw error
        }
    }

    // MARK: - 消息构造

    private func correctionMessage(_ text: String) -> AgentChatMessage {
        AgentChatMessage(role: .user, content: text)
    }

    /// 拒批教训 → 注入消息(每条错误只注入一次;单次失败最多取前两条)。
    static func rejectionLessonMessages(
        errors: [String],
        seen: inout Set<String>
    ) -> [AgentChatMessage] {
        var messages: [AgentChatMessage] = []
        for lesson in errors.prefix(2) {
            let trimmed = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            messages.append(
                AgentChatMessage(
                    role: .user,
                    content: "【拒批教训——后续所有批次与提交同样适用,不要重复同类错误】\(trimmed)"
                )
            )
        }
        return messages
    }

    // MARK: - closeReview 批次并行 fan-out(2026-08-19 耗时优化 #5)

    /// 低于该基金数不值得并行(交互循环通常一两轮搞定)。
    private static let fanOutMinimumFundCount = 12

    /// W5:终局错误的降级理由——进入未覆盖基金 impactText 的用户可见文案,
    /// 用短稳定措辞而不是带「请重试」指引的 errorDescription。
    private static func degradationReason(for error: TrendResearchAgentError) -> String {
        switch error {
        case .turnLimitExceeded:
            return "本轮运行达到轮次上限"
        case .toolCallLimitExceeded:
            return "本轮运行达到工具调用上限"
        case .invalidSubmissionLimitExceeded:
            return "本轮报告校验未通过次数达到上限"
        case .missingToolCalls, .missingConfiguration:
            return TrendDegradedAssetFactory.budgetExhaustedReason
        case .totalTimeoutExceeded, .budgetSkipBeforeRequest,
             .modelRequestTimeoutRecoveryExceeded:
            return TrendDegradedAssetFactory.budgetExhaustedReason
        }
    }

    /// W5:用已暂存批次组装降级报告并走 finalizeAssembledReport 同一条终检链。
    /// 组装前提不满足(零暂存/模块缺失)或终检不过 → nil,调用方维持失败契约。
    private func degradeIfPossible(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        scope: TrendResearchRunScope,
        draftStore: TrendReportDraftStore,
        ledger: TrendEvidenceLedger,
        started: Date,
        reason: String,
        toolCallAudits: [TrendAgentToolCallAudit],
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async -> TrendAnalysisReport? {
        let progress = await draftStore.progress()
        let expectedCount = max(snapshot.expectedFundCodes.count, 1)
        let remainingCount = progress.remainingFundCodes.count
        guard let assembled = await draftStore.degradedReport(
            snapshot: snapshot,
            reason: reason
        ) else { return nil }
        let context = TrendResearchToolContext(
            snapshot: snapshot,
            scope: scope,
            evidenceLedger: ledger,
            reportDraftStore: draftStore
        )
        let finalizeResult = await finalizeAssembledReport(assembled, context: context)
        guard case .report(let report)? = finalizeResult.completion else {
            let errors = Self.parseErrors(from: finalizeResult.contentJSON)
            await AIAgentDiagnosticLog.record(
                "run_degrade_finalize_failed",
                payload: AgentJSONValue.object([
                    "errors": .array(errors.prefix(5).map { .string($0) }),
                ])
            )
            await eventHandler(
                .harnessGuidance(
                    message: "降级组装未通过终审，维持失败契约：\(errors.prefix(2).joined(separator: "；"))"
                )
            )
            return nil
        }
        let stagedCount = max(expectedCount - remainingCount, 0)
        let guidance =
            "运行预算终局：已用 \(stagedCount)/\(expectedCount) 只基金的暂存结果降级生成报告，其余按「原因待确认」处理（\(reason)）。"
        await eventHandler(.harnessGuidance(message: guidance))
        await AIAgentDiagnosticLog.record(
            "run_degraded_completed",
            payload: AgentJSONValue.object([
                "staged_funds": .number(Double(stagedCount)),
                "degraded_funds": .number(Double(remainingCount)),
                "reason": .string(reason),
            ])
        )
        let artifact = TrendAgentRunArtifact.make(
            snapshot: snapshot,
            settings: settings,
            report: report,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            toolCalls: toolCallAudits,
            canonicalEvidence: await ledger.allEvidence()
        )
        await eventHandler(.auditArtifactReady(artifact))
        await eventHandler(.completed(duration: Date().timeIntervalSince(started)))
        return report
    }

    private func closeReviewFanOut(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        scope: TrendResearchRunScope,
        draftStore: TrendReportDraftStore,
        ledger: TrendEvidenceLedger,
        policy: TrendResearchRunPolicy,
        started: Date,
        runDeadline: Date,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async throws -> TrendAnalysisReport? {
        let codes = snapshot.expectedFundCodes
        let batches = stride(
            from: 0,
            to: codes.count,
            by: TrendReportDraftStore.assetBatchSize
        ).map {
            Array(codes[$0..<min($0 + TrendReportDraftStore.assetBatchSize, codes.count)])
        }
        await AIAgentDiagnosticLog.record(
            "fanout_started",
            payload: AgentJSONValue.object([
                "fund_count": .number(Double(codes.count)),
                "batch_count": .number(Double(batches.count)),
            ])
        )

        func makeContext(invalidUsed: Int) -> TrendResearchToolContext {
            var context = TrendResearchToolContext(
                snapshot: snapshot,
                scope: scope,
                evidenceLedger: ledger,
                reportDraftStore: draftStore
            )
            context.invalidSubmissionBudget = Self.effectiveInvalidSubmissionBudget(
                fundCount: snapshot.expectedFundCodes.count,
                base: policy.maxInvalidSubmissions
            )
            context.invalidSubmissionsUsed = invalidUsed
            return context
        }

        // 1) 预取只读数据(串行、无 LLM;工具内部照常登记证据)。
        var dataBlocks: [String] = []
        let prefetchTools: [(String, String)] = [
            ("get_portfolio_overview", "{}"),
            ("get_fund_lookthrough", "{}"),
            ("get_market_snapshot", "{}"),
        ]
        for (name, arguments) in prefetchTools {
            let call = AgentToolCall(
                id: "fanout-\(name)",
                function: AgentToolFunctionCall(name: name, arguments: arguments)
            )
            let result = await registry.execute(call, context: makeContext(invalidUsed: 0))
            if !result.isError {
                dataBlocks.append("【\(name)】\n\(Self.truncate(result.contentJSON, limit: policy.maxToolResultBytes))")
            }
        }
        // 持仓分页:读满全部持有基金为止。
        var cursor = 0
        let pageSize = 20
        var fetchedAssets = 0
        while fetchedAssets < codes.count {
            let arguments = #"{"cursor":\#(cursor),"limit":\#(pageSize)}"#
            let call = AgentToolCall(
                id: "fanout-assets-\(cursor)",
                function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: arguments)
            )
            let result = await registry.execute(call, context: makeContext(invalidUsed: 0))
            if result.isError { break }
            dataBlocks.append("【get_portfolio_assets @\(cursor)】\n\(Self.truncate(result.contentJSON, limit: policy.maxToolResultBytes))")
            let returned = Self.jsonInt(result.contentJSON, dataKey: "count") ?? pageSize
            fetchedAssets += returned
            cursor += returned
            if returned < pageSize { break }
        }
        guard fetchedAssets >= codes.count else { return nil }  // 数据没读全 → 交互循环兜底
        let dataPayload = dataBlocks.joined(separator: "\n\n")

        // 2) 并行生成各批(单轮:系统规范 + 预取数据 + 本批基金清单)。
        let systemPrompt = promptBuilder.initialMessages(
            snapshot: snapshot,
            scope: scope,
            alphaVantageConfigured: false
        ).first?.content ?? ""
        let assetBatchTool = SubmitTrendAssetBatchTool()
        let submitDefinition = AgentToolDefinition.function(
            name: TrendReportModuleToolName.assetBatch,
            description: assetBatchTool.description,
            parameters: assetBatchTool.parameters
        )

        func generateBatch(_ batch: [String], repairFeedback: String?) async throws -> AgentToolCall? {
            let repair = repairFeedback.map { "\n\n上一轮校验未通过,务必先修正再提交:\($0)" } ?? ""
            let userPrompt = """
            数据已全部预取(不要调用任何只读工具,数据就在下方):
            \(dataPayload)

            本批必须且只提交这些基金:\(batch.joined(separator: ","))\(repair)

            立即调用一次 \(TrendReportModuleToolName.assetBatch) 提交本批全部基金;证据只能引用上方数据中已登记的 evidence_id。
            """
            let result = try await client.complete(
                messages: [
                    AgentChatMessage(role: .system, content: systemPrompt),
                    AgentChatMessage(role: .user, content: userPrompt),
                ],
                tools: [submitDefinition],
                toolChoice: .auto,
                temperature: policy.temperature,
                settings: settings,
                // 2026-09-01 根治:此前 timeout: nil(回退用户配置且只是空闲语义),
                // fanout 批次生成完全不受预算约束——2026-08-31 实证 fanout 白烧 874s
                // 后回退交互,总预算已被耗掉近半。现在与交互轮同规则:
                // 空闲上限 180s + 运行截止时间硬约束。
                timeout: policy.perRequestTimeoutSeconds,
                deadline: runDeadline,
                streamProgress: nil
            )
            return result.toolCalls.first { $0.function.name == TrendReportModuleToolName.assetBatch }
        }

        var invalidUsed = 0
        var failedBatches: [(codes: [String], errors: [String])] = []
        // 2026-09-01 根治:fanout 阶段纳入总预算(此前整段零检查,`started`/`policy`
        // 传进来却没用)。预算不足一个最小步时直接回退交互循环,由轮间守卫统一终局。
        guard runDeadline.timeIntervalSinceNow >= Self.minimumStepBudgetSeconds else {
            await AIAgentDiagnosticLog.record(
                "fanout_skipped_budget_exhausted",
                payload: AgentJSONValue.object([
                    "remaining_seconds": .number(runDeadline.timeIntervalSinceNow),
                ])
            )
            return nil
        }
        do {
            try await withThrowingTaskGroup(of: (Int, AgentToolCall?).self) { group in
                for (index, batch) in batches.enumerated() {
                    group.addTask { (index, try await generateBatch(batch, repairFeedback: nil)) }
                }
                for try await (index, call) in group {
                    guard let call else {
                        failedBatches.append((batches[index], ["未返回提交工具调用"]))
                        continue
                    }
                    let result = await registry.execute(call, context: makeContext(invalidUsed: invalidUsed))
                    await AIAgentDiagnosticLog.recordToolResult(
                        turn: 0,
                        call: call,
                        contentJSON: result.contentJSON,
                        modelContentJSON: result.contentJSON,
                        isError: result.isError
                    )
                    await eventHandler(
                        .toolFinished(
                            name: TrendReportModuleToolName.assetBatch,
                            summary: "fanout 批次 \(index + 1)/\(batches.count):\(Self.summary(of: result))"
                        )
                    )
                    if result.isError {
                        invalidUsed += 1
                        failedBatches.append((batches[index], Self.parseErrors(from: result.contentJSON)))
                    }
                }
            }
        } catch OpenAICompatibleAgentClientError.runDeadlineExceeded {
            // 批次生成的流式输出撞运行截止时间:回退交互循环,轮间守卫会统一终局/降级。
            await AIAgentDiagnosticLog.record(
                "fanout_deadline_exceeded",
                payload: AgentJSONValue.object([:])
            )
            return nil
        }

        // 3) 失败批次各修复一次(串行、带拒批教训);再失败 → 整体回退交互循环。
        for (batchCodes, errors) in failedBatches {
            // 修复轮发起前查预算:预算不足时不再烧修复轮,直接回退。
            let remaining = runDeadline.timeIntervalSinceNow
            guard remaining >= Self.minimumStepBudgetSeconds else {
                await AIAgentDiagnosticLog.record(
                    "fanout_repair_gave_up",
                    payload: AgentJSONValue.object([
                        "reason": .string("预算剩余 \(Int(remaining.rounded()))s,不足以发起修复轮"),
                        "batch_codes": .array(batchCodes.map { .string($0) }),
                        "last_errors": .array(errors.prefix(3).map { .string($0) }),
                    ])
                )
                return nil
            }
            guard invalidUsed <= policy.maxInvalidSubmissions else {
                await AIAgentDiagnosticLog.record(
                    "fanout_repair_gave_up",
                    payload: AgentJSONValue.object([
                        "reason": .string("修复预算耗尽"),
                        "batch_codes": .array(batchCodes.map { .string($0) }),
                    ])
                )
                return nil
            }
            let repairCall: AgentToolCall?
            do {
                repairCall = try await generateBatch(
                    batchCodes,
                    repairFeedback: errors.prefix(2).joined(separator: ";")
                )
            } catch OpenAICompatibleAgentClientError.runDeadlineExceeded {
                await AIAgentDiagnosticLog.record(
                    "fanout_deadline_exceeded",
                    payload: AgentJSONValue.object(["phase": .string("repair")])
                )
                return nil
            }
            guard let call = repairCall else {
                await AIAgentDiagnosticLog.record(
                    "fanout_repair_gave_up",
                    payload: AgentJSONValue.object([
                        "reason": .string("修复轮未返回提交工具调用"),
                        "batch_codes": .array(batchCodes.map { .string($0) }),
                    ])
                )
                return nil
            }
            let result = await registry.execute(call, context: makeContext(invalidUsed: invalidUsed))
            await AIAgentDiagnosticLog.recordToolResult(
                turn: 0,
                call: call,
                contentJSON: result.contentJSON,
                modelContentJSON: result.contentJSON,
                isError: result.isError
            )
            if result.isError {
                await AIAgentDiagnosticLog.record(
                    "fanout_repair_failed",
                    payload: AgentJSONValue.object([
                        "batch_codes": .array(batchCodes.map { .string($0) }),
                        "errors": .array(Self.parseErrors(from: result.contentJSON).prefix(3).map { .string($0) }),
                    ])
                )
                return nil
            }
        }

        // 4) 组装 + 终检(与交互路径同一条链)。
        guard let assembled = await draftStore.assembledReport(snapshot: snapshot) else {
            return nil
        }
        let finalizeResult = await finalizeAssembledReport(assembled, context: makeContext(invalidUsed: invalidUsed))
        guard case .report(let report)? = finalizeResult.completion else {
            await eventHandler(
                .reportValidationFailed(
                    errors: Self.parseErrors(from: finalizeResult.contentJSON),
                    remainingAttempts: 0
                )
            )
            await AIAgentDiagnosticLog.record(
                "fanout_finalize_failed",
                payload: AgentJSONValue.object([:])
            )
            return nil
        }

        // 5) 成功收尾:镜像主循环(审计产物 + 完成 events)。
        let artifact = TrendAgentRunArtifact.make(
            snapshot: snapshot,
            settings: settings,
            report: report,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            toolCalls: [],
            canonicalEvidence: await ledger.allEvidence()
        )
        await eventHandler(.auditArtifactReady(artifact))
        await eventHandler(.completed(duration: Date().timeIntervalSince(started)))
        await AIAgentDiagnosticLog.record("run_completed", payload: report)
        await AIAgentDiagnosticLog.record(
            "fanout_completed",
            payload: AgentJSONValue.object([
                "batches": .number(Double(batches.count)),
                "repaired": .number(Double(failedBatches.count)),
            ])
        )
        return report
    }

    private static func jsonInt(_ contentJSON: String, dataKey key: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentJSON.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        return (data[key] as? Int) ?? (data[key] as? NSNumber)?.intValue
    }

    /// 已接受批次的上下文瘦身:把该 tool_call 的 arguments 替换为短桩。
    /// 诊断日志在替换前已留全量(recordToolResult 先于本调用),审计不丢。
    /// internal:上下文瘦身逻辑有单测锁定。
    func stubAcceptedBatchArguments(
        _ messages: inout [AgentChatMessage],
        callID: String
    ) {
        for index in messages.indices.reversed() {
            guard let calls = messages[index].toolCalls,
                  calls.contains(where: { $0.id == callID }) else { continue }
            messages[index] = AgentChatMessage(
                role: messages[index].role,
                content: messages[index].content,
                toolCalls: calls.map { call in
                    guard call.id == callID else { return call }
                    return AgentToolCall(
                        id: call.id,
                        function: AgentToolFunctionCall(
                            name: call.function.name,
                            arguments: #"{"accepted":true,"note":"本批已暂存,完整内容在 DraftStore"}"#
                        )
                    )
                },
                toolCallID: messages[index].toolCallID
            )
            return
        }
    }

    private func toolMessage(callID: String, content: String) -> AgentChatMessage {
        AgentChatMessage(role: .tool, content: content, toolCallID: callID)
    }

    // MARK: - 上下文裁剪（确定性）

    /// 第一版不做模型摘要式压缩，只做确定性裁剪：消息体积超预算时，把已被后续 assistant
    /// 消费过的旧 tool 结果内容替换为短摘要。system 与初始 user 永远保留；最近若干条保留。
    private func compactContextIfNeeded(
        _ messages: inout [AgentChatMessage],
        preserveResearchResults: Bool
    ) {
        // 分模块输出仍需引用前序持仓、穿透与网页证据；进入提交阶段后不再裁剪研究结果。
        guard !preserveResearchResults else { return }
        let budget = 384 * 1024
        let total = messages.reduce(0) { partial, message in
            partial
                + (message.content ?? "").utf8.count
                + (message.toolCalls ?? []).reduce(0) {
                    $0 + $1.function.arguments.utf8.count
                }
        }
        guard total > budget, messages.count > 8 else { return }

        let preservedTail = 4
        let lastAllowedIndex = messages.count - preservedTail
        guard lastAllowedIndex > 2 else { return }
        for index in 2..<lastAllowedIndex where messages[index].role == .tool {
            if (messages[index].content ?? "").utf8.count > 200 {
                messages[index] = AgentChatMessage(
                    role: .tool,
                    content: "(早期工具结果已省略，evidence 已登记，可按需重新调用工具)",
                    toolCallID: messages[index].toolCallID
                )
            }
        }
    }

    // MARK: - 工具结果摘要与错误解析

    /// 超过字节上限的工具结果按字节截断并标注，避免单个超大结果整段塞入上下文。
    private static func truncate(_ content: String, limit: Int) -> String {
        let bytes = content.utf8
        guard bytes.count > limit else { return content }
        let truncated = String(decoding: Array(bytes.prefix(limit)), as: UTF8.self)
        return "\(truncated)\n…（结果超过 \(limit) 字节已截断，请缩小范围或分页重新读取完整数据）"
    }

    private static func summary(of result: TrendResearchToolResult) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any] else {
            return result.isError ? "失败" : "完成"
        }
        if result.isError {
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return "失败" + (message.map { "：\($0)" } ?? "")
        }
        if let data = object["data"] as? [String: Any] {
            if (data["accepted"] as? Bool) == true,
               let module = data["module"] as? String {
                let completed = data["completed_sections"] as? Int
                let total = data["total_sections"] as? Int
                let progress = completed.flatMap { completed in
                    total.map { "，进度 \(completed)/\($0)" }
                } ?? ""
                let remaining = (data["remaining_fund_codes"] as? [String])?.count ?? 0
                let remainingText = remaining > 0 ? "，剩余基金 \(remaining) 只" : ""
                return "已暂存 \(module)\(progress)\(remainingText)"
            }
            if let count = data["count"] as? Int {
                let cacheText = (data["cache_hit"] as? Bool) == true ? "，缓存命中" : ""
                let budgetText = (data["remaining_search_budget"] as? Int)
                    .map { "，剩余搜索 \($0) 次" } ?? ""
                return "完成（\(count) 条\(cacheText)\(budgetText)）"
            }
            if let total = data["total_count"] as? Int { return "完成（\(total) 条）" }
        }
        return "完成"
    }

    /// 同一次运行内，相同只读工具 + 相同参数只执行一次。分模块提交必须每次重新校验，不能缓存。
    private static func toolCallSignature(_ call: AgentToolCall) -> String? {
        guard !isSubmissionTool(call.function.name) else { return nil }
        return TrendResearchArgumentCanonicalizer.signature(
            toolName: call.function.name,
            arguments: call.function.arguments
        )
    }

    private static func isSubmissionTool(_ name: String) -> Bool {
        name == submitToolName || moduleSubmitToolNames.contains(name)
    }

    private static func parseErrors(from contentJSON: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentJSON.utf8)) as? [String: Any],
              let errors = object["errors"] as? [String] else { return [] }
        return errors
    }
}
