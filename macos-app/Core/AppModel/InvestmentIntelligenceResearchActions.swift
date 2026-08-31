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
            setDecisionCaseResearchError("其他 AI 任务正在运行，请稍后再试。", for: case_.id)
            return
        }

        // 需要配置 AI Provider
        guard trendSettings.provider.isConfigured else {
            setDecisionCaseResearchError("未配置 AI 模型，无法启动研究。", for: case_.id)
            return
        }

        let runID = UUID()
        let startedAt = Self.timestampString()
        decisionCaseResearchState = .generating
        researchingDecisionCaseID = case_.id
        lastDecisionCaseResearchError = ""
        decisionCaseResearchErrors[case_.id] = nil
        let runningRecord = DecisionCaseResearchRunRecord(
            id: runID,
            caseID: case_.id,
            startedAt: startedAt,
            trigger: trigger,
            status: .running
        )
        latestDecisionCaseResearchRuns[case_.id] = runningRecord
        persistResearchRun(runningRecord)

        // defer 只清 researchingDecisionCaseID,不重置 state。
        // succeeded/failed 保持到下次运行(修复缺陷:旧代码 defer 把 state 重置为 idle)。
        defer {
            researchingDecisionCaseID = nil
        }

        // 装配 snapshot(复用现有管线,若穿透缺失则刷新)
        let snapshot: TrendResearchSnapshot
        do {
            snapshot = try await makeResearchSnapshot()
        } catch {
            decisionCaseResearchState = .failed
            let message = "研究快照构建失败：\(error.localizedDescription)"
            setDecisionCaseResearchError(message, for: case_.id)
            persistResearchFailure(
                runID: runID,
                caseID: case_.id,
                startedAt: startedAt,
                trigger: trigger,
                message: message
            )
            return
        }

        // 运行 Agent
        let diagnosticRecorder: AIAgentDiagnosticRecorder?
        do {
            diagnosticRecorder = try makeAIAgentDiagnosticRecorder(
                runID: runID,
                agentKind: "decision-case-research",
                scope: case_.kind.rawValue,
                trigger: trigger,
                provider: trendSettings.provider,
                privacyMode: snapshot.privacyMode,
                startedAt: startedAt
            )
        } catch {
            diagnosticRecorder = nil
            setDecisionCaseResearchError(
                "专项研究会继续，但完整诊断日志初始化失败：\(error.localizedDescription)",
                for: case_.id
            )
        }
        do {
            let report = try await AIAgentDiagnosticLog.$recorder.withValue(
                diagnosticRecorder
            ) {
                do {
                    let result = try await decisionCaseResearchAgent.run(
                        decisionCase: case_,
                        snapshot: snapshot,
                        settings: trendSettings.provider,
                    )
                    await AIAgentDiagnosticLog.record("run_completed", payload: result)
                    return result
                } catch is CancellationError {
                    await AIAgentDiagnosticLog.record(
                        "run_cancelled",
                        message: "专项研究已取消"
                    )
                    throw CancellationError()
                } catch {
                    await AIAgentDiagnosticLog.record(
                        "run_failed",
                        message: error.localizedDescription
                    )
                    throw error
                }
            }

            // 本地 Policy 校验 + 应用
            applyResearchReport(
                report,
                to: case_.id,
                runID: runID,
                startedAt: startedAt,
                trigger: trigger
            )

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
            let message = error.localizedDescription
            setDecisionCaseResearchError(message, for: case_.id)
            persistResearchFailure(
                runID: runID,
                caseID: case_.id,
                startedAt: startedAt,
                trigger: trigger,
                message: message
            )
            // 失败保留上一次有效结果(不删除 Case)
        }
    }

    // MARK: - 本地 Policy 校验 + 应用

    /// 用本地 Profile 校验 Agent 的建议状态,更新 Case。
    /// 强行动(adjustReview/exitReview)在 Profile 不允许时降级为 watch。
    /// 即使状态不变也保存研究报告(Step 2 要求)。
    func applyResearchReport(
        _ report: DecisionCaseResearchReport,
        to caseID: UUID,
        runID: UUID = UUID(),
        startedAt: String? = nil,
        trigger: String = "研究完成"
    ) {
        guard let index = decisionCases.firstIndex(where: { $0.id == caseID }) else { return }

        // 1. 保存研究报告到内存 + 文件(重启恢复)
        var reports = lastDecisionCaseResearchReports
        reports[caseID] = report
        lastDecisionCaseResearchReports = reports

        let completedAt = Self.timestampString()
        let record = DecisionCaseResearchRunRecord(
            id: runID,
            caseID: caseID,
            startedAt: startedAt ?? report.generatedAt,
            finishedAt: completedAt,
            trigger: trigger,
            status: .succeeded,
            report: report
        )
        lastDecisionCaseResearchError = ""
        decisionCaseResearchErrors[caseID] = nil
        persistResearchRun(record)
        latestDecisionCaseResearchRuns[caseID] = record
        decisionCases[index].latestResearchRunID = runID

        // 2. 本地 Policy 校验:强行动降级
        let finalState = ConcentrationRiskEngine.constrainState(
            report.suggestedState,
            profile: userDecisionProfile
        )

        // 3. 更新状态(即使不变也保存 Case,记录研究完成事件)
        let timestamp = completedAt
        if decisionCases[index].decisionState != finalState {
            decisionCases[index].applyTransition(
                to: decisionCases[index].lifecycle == .closed ? .closed : .monitoring,
                decisionState: finalState,
                at: timestamp,
                type: .reassessed,
                reason: "专项研究建议:\(report.rationale)" + (finalState != report.suggestedState ? "(已降级:\(report.suggestedState.rawValue)→\(finalState.rawValue))" : ""),
                actor: .system
            )
        } else {
            // 状态不变,但仍记录事件 + 持久化
            decisionCases[index].applyTransition(
                to: decisionCases[index].lifecycle == .closed ? .closed : .monitoring,
                decisionState: finalState,
                at: timestamp,
                type: .reassessed,
                reason: "专项研究完成,建议维持当前状态:\(report.suggestedState.rawValue)",
                actor: .system
            )
        }
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
        let totalHolding = personalAssetRows.reduce(0) { $0 + max(0, $1.effectiveHoldingAmount) }
        let sectorContext = (portfolioLookThroughSnapshot?.industries ?? []).prefix(12).map { industry in
            TrendContextSector(
                name: industry.name,
                assetCount: 0,
                exposureText: String(format: "%.1f%%", industry.portfolioWeightPct),
                exposureAmount: nil
            )
        }

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
            assets: personalAssetRows.map { Self.researchAsset(from: $0, totalHolding: totalHolding) },
            sectors: Array(sectorContext),
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
    private static func researchAsset(from row: PersonalAssetAggregateRow, totalHolding: Double) -> TrendContextAsset {
        let weightText = totalHolding > 0
            ? String(format: "%.1f%%", max(0, row.effectiveHoldingAmount) / totalHolding * 100)
            : nil
        return TrendContextAsset(
            id: row.key,
            name: row.fundName,
            code: row.fundCode,
            assetType: row.assetType.displayName,
            sector: "—",
            statusText: row.combinedStatusText,
            weightText: weightText,
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

    /// 执行复盘:用 MetricResolver 算正确指标,持久化 Review,执行状态转换。
    /// 复核方案硬约束:不用涨跌简单判对错(第 12.4 节)。
    @discardableResult
    func performReview(for caseID: UUID, conclusion: DecisionReviewConclusion, lessons: String = "") -> Bool {
        guard let index = decisionCases.firstIndex(where: { $0.id == caseID }) else { return false }
        let cs = decisionCases[index]
        let now = Self.timestampString()

        // 用 MetricResolver 算当前指标(修复缺陷:旧代码对 lookThrough/sector 读 topPositions.first)
        let resolver = DecisionMetricResolver()
        let resolution = resolver.resolve(
            decisionCase: cs,
            rows: personalAssetRows,
            lookThroughSnapshot: portfolioLookThroughSnapshot,
            profile: userDecisionProfile
        )
        let currentMetric = resolution.value ?? cs.metricValue

        // 生成并持久化复盘记录
        let review = DecisionReview(
            caseID: caseID,
            reviewedAt: now,
            reviewHorizon: reviewHorizonText(for: cs),
            originalDecisionState: cs.decisionState,
            originalMetricValue: cs.metricValue,
            currentMetricValue: currentMetric,
            portfolioOutcome: "指标从 \(cs.metricLabel) 变为 \(String(format: "%.1f", currentMetric))",
            processQuality: conclusion.displayName,
            conclusion: conclusion,
            lessons: lessons
        )
        guard persistReview(review) else { return false }
        decisionCases[index].latestReviewID = review.id

        // 状态转换(根据结论)
        switch conclusion {
        case .supported, .partiallySupported, .unresolved:
            // 风险仍存在 → 回到 monitoring,生成新 reviewDueAt
            decisionCases[index].applyTransition(
                to: .monitoring,
                decisionState: cs.decisionState,
                at: now,
                type: .reassessed,
                reason: "复盘:\(conclusion.displayName)",
                actor: .system
            )
            decisionCases[index].reviewDueAt = DecisionCase.computeReviewDueAt(
                decisionState: cs.decisionState, from: now
            )

        case .contradicted, .invalidatedBeforeEvaluation:
            // 判断被推翻 → 关闭
            decisionCases[index].applyTransition(
                to: .closed,
                decisionState: .stable,
                at: now,
                type: .userResolved,
                reason: "复盘后关闭:\(conclusion.displayName)",
                actor: .system
            )
            decisionCases[index].userDisposition = .resolved
            decisionCases[index].resolvedAt = now
            decisionCases[index].reviewDueAt = nil

        case .insufficientData:
            // 数据不足 → 回到 monitoring,缩短复查周期(3 天)
            decisionCases[index].applyTransition(
                to: .monitoring,
                decisionState: .insufficientEvidence,
                at: now,
                type: .reassessed,
                reason: "复盘:数据不足,缩短复查周期",
                actor: .system
            )
            decisionCases[index].reviewDueAt = DecisionCase.computeReviewDueAt(
                decisionState: .insufficientEvidence, from: now
            )
        }

        var reviews = decisionCaseReviews
        reviews[caseID, default: []].append(review)
        decisionCaseReviews = reviews
        lastDecisionReviewError = ""
        persistDecisionCases()
        return true
    }

    /// 持久化 Review 到 JournalStore。
    private func persistReview(_ review: DecisionReview) -> Bool {
        guard let journalDir = decisionCaseJournalDirectoryURL else {
            lastDecisionReviewError = "决策历史目录不可用，复盘未保存。"
            return false
        }
        do {
            try DecisionCaseJournalStore(baseDirectory: journalDir).saveReview(review)
            return true
        } catch {
            lastDecisionReviewError = "复盘保存失败：\(error.localizedDescription)"
            errorMessage = lastDecisionReviewError
            return false
        }
    }

    // MARK: - 研究运行持久化

    private func setDecisionCaseResearchError(_ message: String, for caseID: UUID) {
        lastDecisionCaseResearchError = message
        decisionCaseResearchErrors[caseID] = message
    }

    private func persistResearchFailure(
        runID: UUID,
        caseID: UUID,
        startedAt: String,
        trigger: String,
        message: String
    ) {
        let record = DecisionCaseResearchRunRecord(
            id: runID,
            caseID: caseID,
            startedAt: startedAt,
            finishedAt: Self.timestampString(),
            trigger: trigger,
            status: .failed,
            errorMessage: message
        )
        persistResearchRun(record)
        latestDecisionCaseResearchRuns[caseID] = record
    }

    private func persistResearchRun(_ record: DecisionCaseResearchRunRecord) {
        guard let journalDir = decisionCaseJournalDirectoryURL else {
            setDecisionCaseResearchError("研究历史目录不可用，结果仅保留在本次运行中。", for: record.caseID)
            return
        }
        do {
            try DecisionCaseJournalStore(baseDirectory: journalDir).saveResearchRun(record)
        } catch {
            let message = "研究历史保存失败：\(error.localizedDescription)"
            setDecisionCaseResearchError(message, for: record.caseID)
            errorMessage = message
        }
    }

    /// 检查并标记到期复查的 Case(在刷新后调用)。
    func markReviewDueCases() {
        let now = Self.timestampString()
        var changed = false
        for i in decisionCases.indices {
            if decisionCases[i].lifecycle == .monitoring,
               decisionCases[i].isReviewDue(asOf: now) {
                decisionCases[i].lifecycle = .reviewDue
                // 不改 updatedAt(Schema V2:reviewDueAt 是显式的,
                // 改 updatedAt 会导致旧代码重新推迟复查时间)
                changed = true
            }
        }
        if changed { persistDecisionCases() }
    }

    // MARK: - 复盘辅助

    private func reviewHorizonText(for cs: DecisionCase) -> String {
        switch cs.decisionState {
        case .watch: return "7 天"
        case .prepare: return "3 天"
        case .adjustReview, .exitReview: return "1 天"
        default: return "未设定"
        }
    }
}
