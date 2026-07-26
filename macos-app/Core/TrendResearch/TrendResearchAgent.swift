import Foundation

// 阶段三：TrendResearchAgent 运行循环。
//
// 维护消息状态，逐轮调用模型；模型返回 tool_call 后经 Registry 执行只读工具，
// 工具结果作为 tool message 回灌；submit_trend_report 成功则结束并返回报告，
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
    var maxTurns: Int = 12
    var maxToolCalls: Int = 32
    var expandedMaxTurns: Int = 24
    var expandedMaxToolCalls: Int = 64
    var preferredWebSearches: Int = 6
    var maxWebSearches: Int = 10
    var expandedMaxWebSearches: Int = 12
    var reservedSubmitToolCalls: Int = 3
    var reservedSubmitTurns: Int = 2
    var maxInvalidSubmissions: Int = 2
    var maxPlainTextResponses: Int = 2
    var perRequestTimeoutSeconds: Double = TrendAIProviderSettings.defaultGenerationTimeoutSeconds
    var totalTimeoutSeconds: Double = 300
    var maxToolResultBytes: Int = 32 * 1024
    var temperature: Double = 0.2

    init() {}

    /// get_portfolio_assets 每页最多 20 个标的；首屏预算已包含在基础值中，
    /// 后续每多一页就为本次运行增加一轮和一次工具调用，最终仍受硬上限约束。
    func effectiveLimits(
        assetCount: Int,
        sectorCount: Int = 0
    ) -> (
        maxTurns: Int,
        maxToolCalls: Int,
        preferredWebSearches: Int,
        maxWebSearches: Int
    ) {
        let pageSize = 20
        let pageCount = max(1, (max(0, assetCount) + pageSize - 1) / pageSize)
        let extraPages = max(0, pageCount - 1)
        // 组合板块更多时允许少量额外定向搜索，但增长缓慢且有独立硬上限。
        let extraSectorGroups = max(0, (max(0, sectorCount) - 4 + 3) / 4)
        let effectiveMaxWebSearches = min(
            expandedMaxWebSearches,
            maxWebSearches + extraSectorGroups
        )
        return (
            maxTurns: min(expandedMaxTurns, maxTurns + extraPages),
            maxToolCalls: min(expandedMaxToolCalls, maxToolCalls + extraPages),
            preferredWebSearches: min(
                effectiveMaxWebSearches,
                preferredWebSearches + extraSectorGroups
            ),
            maxWebSearches: effectiveMaxWebSearches
        )
    }
}

enum TrendResearchAgentEvent: Sendable {
    case started(runID: UUID)
    case harnessConfigured(maxTurns: Int, maxToolCalls: Int, preferredWebSearches: Int, maxWebSearches: Int)
    case harnessGuidance(message: String)
    case turnStarted(Int)
    case modelRequestStarted(turn: Int)
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
    case totalTimeoutExceeded

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
        case .totalTimeoutExceeded:
            return "趋势 Agent 整体超时。"
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
        var didWarnPreferredWebSearches = false
        var didWarnWebSearchExhausted = false
        let started = Date()
        let runLimits = policy.effectiveLimits(
            assetCount: snapshot.assets.count,
            sectorCount: snapshot.sectors.count
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
                // 整体超时是硬截止：剩余预算不足则不再发起新请求；单次请求超时不超过剩余预算。
                let remainingTotal = policy.totalTimeoutSeconds - Date().timeIntervalSince(started)
                if remainingTotal <= 0 {
                    throw TrendResearchAgentError.totalTimeoutExceeded
                }
                let configuredTimeout = max(1, settings.timeoutSeconds)
                let perRequestTimeout = min(
                    policy.perRequestTimeoutSeconds,
                    configuredTimeout,
                    remainingTotal
                )

                let webStatusBeforeRequest = await webSearchGovernor.status()
                let shouldReserveForSubmission = harnessState.readyForSubmission(
                    webSearchConfigured: webSearchSettings.isConfigured,
                    allowInsufficientWebEvidence: harnessState.webSearchAttempts > 0
                        && (
                            webStatusBeforeRequest.remainingNetworkSearches == 0
                                || webSearchUnavailableResult != nil
                        )
                ) && (
                    toolCallCount >= max(0, runLimits.maxToolCalls - policy.reservedSubmitToolCalls)
                        || turnCount >= max(0, runLimits.maxTurns - policy.reservedSubmitTurns)
                )
                if shouldReserveForSubmission, !submissionMode {
                    submissionMode = true
                    let guidance = "研究数据已覆盖，Harness 已保留最后 \(policy.reservedSubmitTurns) 轮和 \(policy.reservedSubmitToolCalls) 次工具调用用于提交与校验修复；下一步必须调用 submit_trend_report。"
                    messages.append(correctionMessage(guidance))
                    await eventHandler(.harnessGuidance(message: guidance))
                }

                let toolsForRequest = registry.definitions.filter { definition in
                    if submissionMode {
                        return definition.function.name == Self.submitToolName
                    }
                    if definition.function.name == Self.webSearchToolName {
                        return webSearchSettings.isConfigured
                            && webStatusBeforeRequest.remainingNetworkSearches > 0
                            && webSearchUnavailableResult == nil
                    }
                    return true
                }

                turnCount += 1
                await eventHandler(.turnStarted(turnCount))
                await eventHandler(.modelRequestStarted(turn: turnCount))
                let requestStarted = Date()
                let currentTurn = turnCount

                let response = try await client.complete(
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
                    messages.append(correctionMessage("普通文本不会被接收。请先调用只读工具读取数据，最后通过 submit_trend_report 提交。"))
                    continue
                }

                var pendingHarnessGuidance: String?
                for call in response.toolCalls {
                    if toolCallCount >= runLimits.maxToolCalls {
                        throw TrendResearchAgentError.toolCallLimitExceeded
                    }

                    let toolName = call.function.name
                    let isSubmit = toolName == Self.submitToolName
                    let callSignature = Self.toolCallSignature(call)
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
                    let missingRequiredTool = missingOverview || missingAssets || missingLookThrough || missingWebSearch

                    var rawToolResult: TrendResearchToolResult
                    if missingOverview {
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
                            webSearchGovernor: webSearchGovernor
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

                compactContextIfNeeded(&messages)
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
    private func compactContextIfNeeded(_ messages: inout [AgentChatMessage]) {
        let budget = 64 * 1024
        let total = messages.reduce(0) { $0 + ($1.content ?? "").utf8.count }
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

    /// 同一次运行内，相同只读工具 + 相同参数只执行一次。submit 必须每次重新校验，不能缓存。
    private static func toolCallSignature(_ call: AgentToolCall) -> String? {
        guard call.function.name != submitToolName else { return nil }
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
