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
        webSearchSettings: TavilySearchSettings,
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
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult
}

extension OpenAICompatibleAgentClient: TrendResearchAgentClient {}

// MARK: - 运行策略与事件

struct TrendResearchRunPolicy: Sendable {
    /// 单轮模型请求不能独占整次运行预算。流式输出按“分片间空闲”判定：只要持续
    /// 有字节到达就续期，超过 perRequestTimeoutSeconds 无新数据才判超时，由 Harness
    /// 收敛任务后自动重试。彻底无字节的卡死由 URLSession 的 timeoutInterval 兜底，
    /// 整体上限由 totalTimeoutSeconds 在轮与轮之间保证。
    static let defaultPerRequestTimeoutSeconds: Double = 90
    /// 整次运行总预算：宽松兜底，只在极端失控（远超正常轮次耗时）时截断。
    /// 正常运行靠单轮空闲超时 + 轮次/工具上限自然终止，慢但正常推进的运行应能跑完。
    static let defaultTotalTimeoutSeconds: Double = 1800
    static let defaultMaxRequestTimeoutRecoveries = 1

    var maxTurns: Int = 18
    var maxToolCalls: Int = 40
    var expandedMaxTurns: Int = 48
    var expandedMaxToolCalls: Int = 96
    var preferredWebSearches: Int = 6
    var maxWebSearches: Int = 10
    var expandedMaxWebSearches: Int = 12
    var reservedSubmitToolCalls: Int = 8
    var reservedSubmitTurns: Int = 8
    var maxInvalidSubmissions: Int = 4
    var maxPlainTextResponses: Int = 2
    var perRequestTimeoutSeconds: Double = Self.defaultPerRequestTimeoutSeconds
    var totalTimeoutSeconds: Double = Self.defaultTotalTimeoutSeconds
    var expandedTotalTimeoutSeconds: Double = 1800
    var totalTimeoutPerAssetSeconds: Double = 4
    var totalTimeoutPerWebSearchSeconds: Double = 15
    var maxRequestTimeoutRecoveries: Int = Self.defaultMaxRequestTimeoutRecoveries
    var maxToolResultBytes: Int = 32 * 1024
    var temperature: Double = 0.2

    init() {}

    /// get_portfolio_assets 每页最多 20 个标的；首屏预算已包含在基础值中，
    /// 后续每多一页就为本次运行增加一轮和一次工具调用，最终仍受硬上限约束。
    func effectiveLimits(
        assetCount: Int,
        sectorCount: Int = 0,
        reportAssetCount: Int? = nil
    ) -> (
        maxTurns: Int,
        maxToolCalls: Int,
        preferredWebSearches: Int,
        maxWebSearches: Int
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
        // 组合板块更多时允许少量额外定向搜索，但增长缓慢且有独立硬上限。
        let extraSectorGroups = max(0, (max(0, sectorCount) - 4 + 3) / 4)
        let effectiveMaxWebSearches = min(
            expandedMaxWebSearches,
            maxWebSearches + extraSectorGroups
        )
        return (
            maxTurns: min(
                expandedMaxTurns,
                maxTurns + extraPages + extraReportBatches
            ),
            maxToolCalls: min(
                expandedMaxToolCalls,
                maxToolCalls + extraPages + extraReportBatches
            ),
            preferredWebSearches: min(
                effectiveMaxWebSearches,
                preferredWebSearches + extraSectorGroups
            ),
            maxWebSearches: effectiveMaxWebSearches
        )
    }

    /// 整次运行总预算随组合规模和搜索预算扩张：分块报告与多次联网搜索都比单次提交
    /// 更耗时，固定基线对大组合偏紧。最终受 expandedTotalTimeoutSeconds 约束。
    func effectiveTotalTimeout(assetCount: Int, maxWebSearches: Int) -> Double {
        let scaled = totalTimeoutSeconds
            + Double(max(0, assetCount)) * totalTimeoutPerAssetSeconds
            + Double(max(0, maxWebSearches)) * totalTimeoutPerWebSearchSeconds
        return min(expandedTotalTimeoutSeconds, scaled)
    }
}

enum TrendResearchAgentEvent: Sendable {
    case started(runID: UUID)
    case harnessConfigured(maxTurns: Int, maxToolCalls: Int, preferredWebSearches: Int, maxWebSearches: Int)
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
        }
    }
}

// MARK: - Agent

struct TrendResearchAgent: Sendable {
    let client: any TrendResearchAgentClient
    let registry: TrendResearchToolRegistry
    let promptBuilder: TrendResearchPromptBuilder
    let policy: TrendResearchRunPolicy
    let webSearchCache: TrendWebSearchResponseCache

    /// 运行时强制：submit 前必须先调用的工具。
    static let overviewToolName = "get_portfolio_overview"
    static let lookThroughToolName = "get_fund_lookthrough"
    static let webSearchToolName = "web_search"
    static let submitToolName = "submit_trend_report"
    static let moduleSubmitToolNames = TrendReportModuleToolName.all

    init(
        client: any TrendResearchAgentClient = OpenAICompatibleAgentClient(),
        webSearchClient: any TavilySearchClientProtocol = TavilySearchClient(),
        webSearchCache: TrendWebSearchResponseCache = TrendWebSearchResponseCache(),
        policy: TrendResearchRunPolicy = .init()
    ) {
        self.client = client
        self.registry = TrendResearchToolRegistry(webSearchClient: webSearchClient)
        self.promptBuilder = TrendResearchPromptBuilder()
        self.webSearchCache = webSearchCache
        self.policy = policy
    }

    func run(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings = .empty,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async throws -> TrendAnalysisReport {
        guard settings.isConfigured else {
            throw TrendResearchAgentError.missingConfiguration
        }

        let ledger = TrendEvidenceLedger()
        let reportDraftStore = TrendReportDraftStore(
            expectedFundCodes: snapshot.expectedFundCodes
        )
        var messages = promptBuilder.initialMessages(snapshot: snapshot)

        var turnCount = 0
        var toolCallCount = 0
        var plainTextResponses = 0
        var invalidSubmissions = 0
        var executedByID: [String: TrendResearchToolResult] = [:]
        var executedBySignature: [String: TrendResearchToolResult] = [:]
        var toolCallAudits: [TrendAgentToolCallAudit] = []
        var webSearchUnavailableResult: TrendResearchToolResult?
        var harnessState = TrendResearchHarnessState(snapshot: snapshot)
        var submissionMode = false
        var consecutiveRequestTimeoutRecoveries = 0
        var didWarnPreferredWebSearches = false
        var didWarnWebSearchExhausted = false
        let started = Date()
        let runLimits = policy.effectiveLimits(
            assetCount: snapshot.assets.count,
            sectorCount: snapshot.sectors.count,
            reportAssetCount: snapshot.expectedFundCodes.count
        )
        // 整次运行总预算随组合规模与搜索预算动态扩张；固定值对大组合+联网搜索偏紧。
        let effectiveTotal = policy.effectiveTotalTimeout(
            assetCount: snapshot.assets.count,
            maxWebSearches: runLimits.maxWebSearches
        )
        let webSearchGovernor = TrendWebSearchGovernor(
            maxNetworkSearches: runLimits.maxWebSearches,
            cache: webSearchCache
        )

        await eventHandler(.started(runID: snapshot.runID))
        await eventHandler(
            .harnessConfigured(
                maxTurns: runLimits.maxTurns,
                maxToolCalls: runLimits.maxToolCalls,
                preferredWebSearches: runLimits.preferredWebSearches,
                maxWebSearches: runLimits.maxWebSearches
            )
        )

        do {
            while turnCount < runLimits.maxTurns {
                try Task.checkCancellation()
                // 总预算仅作极端失控兜底：正常运行靠单轮空闲超时 + 轮次/工具上限自然终止，
                // 不会触及；真到这里说明远超正常耗时，终止并保留上一份报告。
                let remainingTotal = effectiveTotal - Date().timeIntervalSince(started)
                if remainingTotal <= 0 {
                    throw TrendResearchAgentError.totalTimeoutExceeded(limit: effectiveTotal)
                }
                let configuredTimeout = max(1, settings.timeoutSeconds)
                // 每轮超时不再随总预算缩减：让慢但正常推进的运行能跑完，而不是越到后面越被掐。
                let perRequestTimeout = min(
                    policy.perRequestTimeoutSeconds,
                    configuredTimeout
                )

                let webStatusBeforeRequest = await webSearchGovernor.status()
                let researchReady = harnessState.readyForSubmission(
                    webSearchConfigured: webSearchSettings.isConfigured,
                    allowInsufficientWebEvidence: harnessState.webSearchAttempts > 0
                        && (
                            webStatusBeforeRequest.remainingNetworkSearches == 0
                                || webSearchUnavailableResult != nil
                        )
                )
                if researchReady, !submissionMode {
                    submissionMode = true
                    let guidance = "研究数据已覆盖，立即停止新增搜索并进入分模块提交：组合判断 → 市场与板块 → 持仓基金每批最多 \(TrendReportDraftStore.assetBatchSize) 只 → 操作与风险。App 将在本地组装并统一校验。"
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
                    if toolName == Self.webSearchToolName {
                        return webSearchSettings.isConfigured
                            && webStatusBeforeRequest.remainingNetworkSearches > 0
                            && webSearchUnavailableResult == nil
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
                        streamProgress: { progress in
                            await eventHandler(
                                .modelStreamProgress(turn: currentTurn, progress: progress)
                            )
                        }
                    )
                } catch OpenAICompatibleAgentClientError.timedOut {
                    guard consecutiveRequestTimeoutRecoveries < policy.maxRequestTimeoutRecoveries else {
                        throw TrendResearchAgentError.modelRequestTimeoutRecoveryExceeded(
                            timeout: perRequestTimeout
                        )
                    }

                    consecutiveRequestTimeoutRecoveries += 1
                    let webStatus = await webSearchGovernor.status()
                    let researchReady = harnessState.readyForSubmission(
                        webSearchConfigured: webSearchSettings.isConfigured,
                        allowInsufficientWebEvidence: harnessState.webSearchAttempts > 0
                            && (
                                webStatus.remainingNetworkSearches == 0
                                    || webSearchUnavailableResult != nil
                            )
                    )
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
                        : "不要重复展开分析，本轮只完成一个必要动作：\(harnessState.nextStepHint(webSearchConfigured: webSearchSettings.isConfigured, remainingWebSearches: webStatus.remainingNetworkSearches))"
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
                    let missingOverview = isSubmit && !harnessState.overviewRead
                    // 标的明细必须完整覆盖，否则模型无法生成完整 assetTrends。
                    let missingAssets = isSubmit && !harnessState.assetCoverageComplete
                    // 有基金穿透快照时必须读取，避免继续把场内/场外基金误当成真实板块。
                    let missingLookThrough = isSubmit && !harnessState.lookThroughCoverageComplete
                    // 配置了 Tavily 时至少尝试一次联网搜索，避免把模型记忆冒充最新行业/政策信息。
                    let missingWebSearch = isSubmit
                        && webSearchSettings.isConfigured
                        && harnessState.webSearchAttempts == 0
                    let missingRequiredTool = unexpectedTool
                        || missingOverview
                        || missingAssets
                        || missingLookThrough
                        || missingWebSearch

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
                    } else if missingWebSearch {
                        rawToolResult = .content(TrendResearchToolEnvelope.error(code: "missing_required_tool", message: "已配置 Tavily，提交报告前必须至少调用一次 web_search 获取最新行业或政策信息。"), isError: true)
                        await eventHandler(.modelCorrection(message: "报告提交被延后：已配置 Tavily，必须先完成一次联网搜索。"))
                    } else if !isSubmit, let cached = executedByID[call.id] {
                        rawToolResult = cached
                        await eventHandler(.toolFinished(name: toolName, summary: "复用本次运行缓存：\(Self.summary(of: cached))"))
                    } else if let callSignature,
                              let cached = executedBySignature[callSignature] {
                        rawToolResult = cached
                        executedByID[call.id] = cached
                        await eventHandler(.toolFinished(name: toolName, summary: "复用本次运行缓存：\(Self.summary(of: cached))"))
                    } else if toolName == Self.webSearchToolName,
                              let unavailable = webSearchUnavailableResult {
                        rawToolResult = unavailable
                        executedByID[call.id] = unavailable
                        if let callSignature {
                            executedBySignature[callSignature] = unavailable
                        }
                        await eventHandler(.modelCorrection(message: "Tavily 本次运行已失败，已阻止重复联网请求以避免继续消耗搜索额度。"))
                        await eventHandler(.toolFinished(name: toolName, summary: "已熔断重复请求：\(Self.summary(of: unavailable))"))
                    } else {
                        await eventHandler(.toolStarted(name: toolName))
                        var context = TrendResearchToolContext(
                            snapshot: snapshot,
                            evidenceLedger: ledger,
                            webSearchSettings: webSearchSettings,
                            webSearchGovernor: webSearchGovernor,
                            reportDraftStore: reportDraftStore
                        )
                        context.invalidSubmissionBudget = policy.maxInvalidSubmissions
                        context.invalidSubmissionsUsed = invalidSubmissions
                        rawToolResult = await registry.execute(call, context: context)
                        executedByID[call.id] = rawToolResult
                        if let callSignature {
                            executedBySignature[callSignature] = rawToolResult
                        }
                        if toolName == Self.webSearchToolName,
                           rawToolResult.isError,
                           Self.isNonRecoverableWebSearchFailure(rawToolResult) {
                            webSearchUnavailableResult = rawToolResult
                        }
                        await eventHandler(.toolFinished(name: toolName, summary: Self.summary(of: rawToolResult)))
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
                    let webStatus = await webSearchGovernor.status()
                    let enrichedToolResult = harnessState.attachingHarnessMetadata(
                        to: toolResult,
                        turn: turnCount,
                        maxTurns: runLimits.maxTurns,
                        toolCallsUsed: toolCallCount,
                        maxToolCalls: runLimits.maxToolCalls,
                        reservedSubmitToolCalls: policy.reservedSubmitToolCalls,
                        webStatus: webStatus,
                        webSearchConfigured: webSearchSettings.isConfigured
                    )

                    // 工具结果超过字节上限：截断后再回灌，避免单个超大结果撑爆上下文。
                    messages.append(toolMessage(callID: call.id, content: Self.truncate(enrichedToolResult.contentJSON, limit: policy.maxToolResultBytes)))

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
                        return report
                    }

                    // submit 校验失败（实际执行了 submit，非缺 overview 的拒绝）→ 记数；超过预算则终止。
                    if isSubmit, toolResult.isError, !missingRequiredTool {
                        invalidSubmissions += 1
                        let errors = Self.parseErrors(from: toolResult.contentJSON)
                        let remaining = max(0, policy.maxInvalidSubmissions - invalidSubmissions)
                        await eventHandler(.reportValidationFailed(errors: errors, remainingAttempts: remaining))
                        if invalidSubmissions > policy.maxInvalidSubmissions {
                            throw TrendResearchAgentError.invalidSubmissionLimitExceeded(errors: errors)
                        }
                    }

                    if webStatus.networkSearchesUsed >= runLimits.preferredWebSearches,
                       !didWarnPreferredWebSearches {
                        didWarnPreferredWebSearches = true
                        pendingHarnessGuidance = "已完成 \(webStatus.networkSearchesUsed) 次真实 Tavily 搜索并取得 \(harnessState.seenWebEvidenceIDs.count) 条去重证据。请先评估现有证据；只有明确缺口才继续搜索，否则整理并提交报告。"
                    }
                    if webStatus.remainingNetworkSearches == 0,
                       !didWarnWebSearchExhausted {
                        didWarnWebSearchExhausted = true
                        pendingHarnessGuidance = "Tavily 实际请求预算已用完，后续轮次将不再暴露 web_search；请使用已有网页证据和本地工具完成研究并提交报告。"
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
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        webSearchConfigured: webSearchSettings.isConfigured,
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
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        webSearchConfigured: webSearchSettings.isConfigured,
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
            await eventHandler(
                .auditArtifactReady(
                    TrendAgentRunArtifact.makeFailure(
                        snapshot: snapshot,
                        settings: settings,
                        webSearchConfigured: webSearchSettings.isConfigured,
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
        let rawArguments = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArguments: String
        if let data = rawArguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let canonical = String(data: canonicalData, encoding: .utf8) {
            normalizedArguments = canonical
        } else {
            normalizedArguments = rawArguments
        }
        return "\(call.function.name)|\(normalizedArguments)"
    }

    private static func isSubmissionTool(_ name: String) -> Bool {
        name == submitToolName || moduleSubmitToolNames.contains(name)
    }

    private static func isNonRecoverableWebSearchFailure(_ result: TrendResearchToolResult) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? String else {
            return false
        }
        return ["web_search_failed", "web_search_not_configured"].contains(code)
    }

    private static func parseErrors(from contentJSON: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentJSON.utf8)) as? [String: Any],
              let errors = object["errors"] as? [String] else { return [] }
        return errors
    }
}
