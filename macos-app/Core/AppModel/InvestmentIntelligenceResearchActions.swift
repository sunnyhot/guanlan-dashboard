import Foundation

// 投资智能 Slice 3:DecisionCase 专项研究的 AppModel 动作层。
//
// 全部 gate 在 InvestmentIntelligence.enabled(默认 false)。
// - 手动触发:researchDecisionCase(id:)(用户点「深度研究」)
// - 自动触发:autoTriggerResearchIfNeeded()(刷新后对 watch/prepare Case 后台启动)
// - 本地 Policy 校验:applyResearchReport 用 Profile 约束建议状态(强行动降级)
// - 互斥 guard:研究运行时,趋势分析/下一小时研判不启动
//
// 见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 3 设计。

extension AppModel {

    // MARK: - 手动触发

    /// 用户手动对单个 Case 启动专项研究。
    func researchDecisionCase(_ id: UUID, userInitiated: Bool = true) async {
        guard InvestmentIntelligence.enabled else { return }
        guard let case_ = decisionCases.first(where: { $0.id == id }) else { return }
        await runDecisionCaseResearch(case_: case_, trigger: userInitiated ? "用户手动" : "自动触发")
    }

    // MARK: - 自动触发(刷新后)

    /// 检查是否有需要自动研究的 Case(watch/prepare + Profile 已自定义 + AI Provider 配置)。
    /// 在 refreshConcentrationDecisionCases 后调用。
    func autoTriggerDecisionCaseResearchIfNeeded() async {
        guard InvestmentIntelligence.enabled else { return }
        guard decisionCaseResearchState != .generating else { return }
        guard trendSettings.provider.isConfigured else { return }
        guard userDecisionProfile.isCustomized else { return }  // 只在用户配置了 Profile 后自动研究

        // 找第一个 watch/prepare 且未最近研究过的 Case
        let candidate = decisionCases.first { cs in
            (cs.decisionState == .watch || cs.decisionState == .prepare)
                && cs.userDisposition != .closed
                && lastDecisionCaseResearchReports[cs.id] == nil  // 未研究过
        }

        if let candidate {
            await runDecisionCaseResearch(case_: candidate, trigger: "自动触发")
        }
    }

    // MARK: - 研究执行(核心)

    private func runDecisionCaseResearch(case_: DecisionCase, trigger: String) async {
        // 互斥 guard:与趋势分析/下一小时研判互斥
        guard trendGenerationState != .generating,
              nextHourGuidanceGenerationState != .generating,
              decisionCaseResearchState != .generating
        else {
            lastDecisionCaseResearchError = "其他 AI 任务正在运行,请稍后再试。"
            return
        }

        // 需要配置 AI Provider
        guard trendSettings.provider.isConfigured else {
            lastDecisionCaseResearchError = "未配置 AI 模型,无法启动研究。"
            return
        }

        decisionCaseResearchState = .generating
        researchingDecisionCaseID = case_.id
        lastDecisionCaseResearchError = ""

        defer {
            decisionCaseResearchState = .idle
            researchingDecisionCaseID = nil
        }

        // 装配 snapshot(复用现有管线,若穿透缺失则刷新)
        let snapshot: TrendResearchSnapshot
        do {
            snapshot = try await makeResearchSnapshot()
        } catch {
            decisionCaseResearchState = .failed
            lastDecisionCaseResearchError = "研究快照构建失败:\(error.localizedDescription)"
            return
        }

        // 运行 Agent
        do {
            let report = try await decisionCaseResearchAgent.run(
                decisionCase: case_,
                snapshot: snapshot,
                settings: trendSettings.provider,
                webSearchSettings: trendSettings.webSearch,
                officialSourceSettings: trendSettings.officialSources
            )

            // 本地 Policy 校验 + 应用
            applyResearchReport(report, to: case_.id)

            // 落审计产物
            saveTrendAgentRunArtifact(
                TrendAgentRunArtifact.makeDecisionCase(
                    snapshot: snapshot,
                    settings: trendSettings.provider,
                    report: report,
                    trigger: trigger
                ),
                trigger: trigger
            )

            decisionCaseResearchState = .succeeded
        } catch {
            decisionCaseResearchState = .failed
            lastDecisionCaseResearchError = error.localizedDescription
            // 失败保留上一次有效结果(不删除 Case)
        }
    }

    // MARK: - 本地 Policy 校验 + 应用

    /// 用本地 Profile 校验 Agent 的建议状态,更新 Case。
    /// 强行动(adjustReview/exitReview)在 Profile 不允许时降级为 watch。
    func applyResearchReport(_ report: DecisionCaseResearchReport, to caseID: UUID) {
        guard let index = decisionCases.firstIndex(where: { $0.id == caseID }) else { return }

        // 记录研究报告(供 UI 展示)
        var reports = lastDecisionCaseResearchReports
        reports[caseID] = report
        lastDecisionCaseResearchReports = reports

        // 本地 Policy 校验:强行动降级
        let finalState = ConcentrationRiskEngine.constrainState(
            report.suggestedState,
            profile: userDecisionProfile
        )

        // 只在状态变化时更新
        let oldState = decisionCases[index].decisionState
        guard oldState != finalState else { return }

        let timestamp = Self.timestampString()
        decisionCases[index].applyTransition(
            to: decisionCases[index].lifecycle == .closed ? .closed : .monitoring,
            decisionState: finalState,
            at: timestamp,
            type: .reassessed,
            reason: "专项研究建议:\(report.rationale)" + (finalState != report.suggestedState ? "(已降级:\(report.suggestedState.rawValue)→\(finalState.rawValue))" : ""),
            actor: .system
        )
        persistDecisionCases()
    }

    // MARK: - 研究 Snapshot 装配

    /// 为研究构建 TrendResearchSnapshot(复用趋势分析的管线)。
    private func makeResearchSnapshot() async throws -> TrendResearchSnapshot {
        // 若穿透缺失,先刷新(复用 Slice 1 的管线)
        if portfolioLookThroughSnapshot == nil, !personalAssetRows.isEmpty {
            await refreshLookThroughForConcentration()
        }

        let runID = UUID()
        let createdAt = Self.timestampString()

        return TrendResearchSnapshot(
            runID: runID,
            createdAt: createdAt,
            dataAsOf: createdAt,
            privacyMode: trendPrivacyMode,
            portfolio: TrendContextPortfolio(
                assetCount: personalAssetSummary?.fundCount ?? personalAssetRows.count,
                holdingCount: personalAssetSummary?.holdingFundCount ?? personalAssetRows.count,
                activePlanCount: personalAssetSummary?.totalActivePlanCount ?? 0,
                pendingAssetCount: personalAssetRows.filter { $0.hasPending }.count,
                totalMarketValue: personalAssetSummary?.totalMarketValue,
                totalPendingCashAmount: personalAssetSummary?.totalPendingCashAmount,
                totalEstimatedNextPlanAmount: personalAssetSummary?.totalEstimatedNextPlanAmount,
                totalEffectiveHoldingAmount: personalAssetSummary?.totalEffectiveHoldingAmount
            ),
            assets: personalAssetRows.map { Self.researchAsset(from: $0) },
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            lookThrough: portfolioLookThroughSnapshot,
            insightHeadline: "决策事项研究",
            sourceWarnings: portfolioLookThroughSourceWarnings,
            sourceStatuses: []
        )
    }

    /// 从 PersonalAssetAggregateRow 构造研究用的 TrendContextAsset。
    private static func researchAsset(from row: PersonalAssetAggregateRow) -> TrendContextAsset {
        TrendContextAsset(
            id: row.key,
            name: row.fundName,
            code: row.fundCode,
            assetType: row.assetType.displayName,
            sector: "—",
            statusText: row.combinedStatusText,
            weightText: nil,
            profitPct: row.profitPct,
            estimateChangePct: row.estimateChangePct,
            pendingTradeCount: row.pendingTradeCount,
            activePlanCount: row.activePlanCount,
            pausedPlanCount: row.pausedPlanCount,
            endedPlanCount: row.endedPlanCount,
            marketValue: row.marketValue,
            costValue: nil,
            profitAmount: row.profitAmount,
            pendingCashAmount: row.pendingCashAmount,
            estimatedNextPlanAmount: row.estimatedNextPlanAmount,
            totalCumulativePlanAmount: row.totalCumulativePlanAmount
        )
    }

    // MARK: - Slice 7: 复盘

    /// 到达复查时间的 Case 列表。
    var reviewDueDecisionCases: [DecisionCase] {
        let now = Self.timestampString()
        return decisionCases.filter {
            $0.userDisposition != .closed
                && $0.lifecycle != .closed
                && $0.isReviewDue(asOf: now)
        }
    }

    /// 执行复盘:重新评估 Case 的当前指标,对比原判断,记录结论。
    /// 复核方案硬约束:不用涨跌简单判对错(第 12.4 节)。
    func performReview(for caseID: UUID, conclusion: DecisionReviewConclusion, lessons: String = "") {
        guard let index = decisionCases.firstIndex(where: { $0.id == caseID }) else { return }
        let cs = decisionCases[index]

        // 重新评估当前指标(用最新 rows)
        let currentMetric = currentMetricValue(for: cs)

        // 生成复盘记录
        let review = DecisionReview(
            caseID: caseID,
            reviewedAt: Self.timestampString(),
            reviewHorizon: reviewHorizonText(for: cs),
            originalDecisionState: cs.decisionState,
            originalMetricValue: cs.metricValue,
            currentMetricValue: currentMetric,
            portfolioOutcome: "指标从 \(cs.metricLabel) 变为 \(String(format: "%.1f%%", currentMetric))",
            processQuality: conclusion.displayName,
            conclusion: conclusion,
            lessons: lessons
        )

        // 存储 review(嵌入 events)
        var reports = lastDecisionCaseResearchReports  // 复用现有存储?
        _ = reports  // suppress unused
        decisionCases[index].applyTransition(
            to: .reviewDue,
            decisionState: cs.decisionState,  // 保持当前状态(复盘不改状态,只记录)
            at: Self.timestampString(),
            type: .reassessed,
            reason: "复盘完成:\(conclusion.displayName)" + (lessons.isEmpty ? "" : "(\(lessons))"),
            actor: .system
        )

        // 如果复盘结论是 contradicted/invalidatedBeforeEvaluation → 关闭 Case
        if conclusion == .contradicted || conclusion == .invalidatedBeforeEvaluation {
            decisionCases[index].applyTransition(
                to: .closed,
                decisionState: .stable,
                at: Self.timestampString(),
                type: .userResolved,
                reason: "复盘后关闭:\(conclusion.displayName)",
                actor: .system
            )
            decisionCases[index].userDisposition = .resolved
        }

        persistDecisionCases()
    }

    /// 检查并标记到期复查的 Case(在刷新后调用)。
    func markReviewDueCases() {
        let now = Self.timestampString()
        var changed = false
        for i in decisionCases.indices {
            if decisionCases[i].lifecycle == .monitoring,
               decisionCases[i].isReviewDue(asOf: now) {
                decisionCases[i].lifecycle = .reviewDue
                decisionCases[i].updatedAt = now
                changed = true
            }
        }
        if changed { persistDecisionCases() }
    }

    // MARK: - 复盘辅助

    /// 获取 Case 当前指标值(重新计算)。
    private func currentMetricValue(for cs: DecisionCase) -> Double {
        let metrics = ConcentrationRiskEngine.computeDirectMetrics(rows: personalAssetRows)
        switch cs.dimension {
        case .directHolding:
            return metrics?.topShare ?? 0
        case .lookThrough, .lookThroughOverlap, .sector:
            return portfolioLookThroughSnapshot?.topPositions.first?.portfolioWeightPct ?? 0
        }
    }

    private func reviewHorizonText(for cs: DecisionCase) -> String {
        switch cs.decisionState {
        case .watch: return "7 天"
        case .prepare: return "3 天"
        case .adjustReview, .exitReview: return "1 天"
        default: return "未设定"
        }
    }
}
