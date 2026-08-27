import Foundation

// MARK: - AppModel 收盘复盘集成（审计 A1，macOS）
//
// 触发：手动（复盘卡按钮 / 菜单命令）或批次 3 的 21:00 调度。
// 组装：UserPortfolioSnapshot（当日表现 + 逐持仓影响）+ V2 归因 artifact
// （同源数据，落库关联）+ 明日关注（决策事项 + 目标偏差 + 盘中结论）+
// 市场摘要（指数行情 + 发现报告因子评分）→ MarketCloseReviewWorkflow。
// LLM 叙述在 Provider 已配置时启用；失败降级本地因子，不阻断冻结。

extension AppModel {

    // MARK: - 运行入口

    /// 生成收盘复盘（manual = 用户动作，调度层同样调用本入口）。
    func runMarketCloseReview(manual: Bool = true) {
        guard let runtime = intelligenceRuntime else {
            closeReviewOperationState = .failed(IntelligenceUserFacingError(
                title: "运行时未就绪",
                message: "投资智能运行时尚未初始化完成，请稍后重试。",
                recovery: .retry,
                diagnosticCode: "INTL-RUNTIME-NOT-READY"))
            return
        }
        guard !isRunningCloseReview else { return }
        guard let snapshot = userPortfolioSnapshot, !snapshot.rows.isEmpty else {
            closeReviewOperationState = .failed(IntelligenceUserFacingError(
                title: "暂无持仓数据",
                message: "生成收盘复盘需要先刷新个人持仓估值。",
                recovery: .retry,
                diagnosticCode: "INTL-CLOSE-REVIEW-NO-PORTFOLIO"))
            return
        }
        isRunningCloseReview = true
        closeReviewOperationState = .running(startedAt: Date(), stage: .preparing)

        let now = Date()
        let reviewDate = Self.attributionV2Date(latestChangeDate: snapshot.latestChangeDate)
        let decisionsForWatch = decisionCases
        let allocationRows = intelligenceDashboardSnapshot?.allocation.rows ?? []
        let intradaySummary = intelligenceDashboardSnapshot?.intraday
        let indexQuotes = marketIndexQuotes
        let discoveryCandidates = latestDiscoveryReport?.candidates ?? []
        let providerConfigured = IntelligenceV2ProviderSettings.isConfigured

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningCloseReview = false } }
            do {
                await MainActor.run {
                    self?.closeReviewOperationState = .running(startedAt: now, stage: .evaluating)
                }

                // 1. 纯计算：组合当日表现 + 逐持仓影响（估值快照冻结数字）
                let portfolioReview = Self.assemblePortfolioReview(from: snapshot)

                // 2. 归因 artifact（同源确定性；落库关联）
                var attributionID: String?
                let attributionWorkflow = DailyAttributionWorkflow(
                    provider: UserPortfolioAttributionProvider(snapshot: snapshot))
                let attributionOutcome = attributionWorkflow.run(
                    portfolioKey: "app:userPortfolio", on: reviewDate, now: now)
                if let attribution = attributionOutcome.artifact {
                    try await runtime.repository.database.queue.write { db in
                        try ArtifactRow.write(try ArtifactRow.from(attribution), into: db)
                    }
                    attributionID = attribution.id.rawValue
                }

                // 3. 明日关注（决策事项 + 目标偏差 + 盘中结论）
                let tomorrowWatch = Self.assembleTomorrowWatch(
                    decisionCases: decisionsForWatch,
                    allocationRows: allocationRows,
                    intraday: intradaySummary)

                // 4. 市场摘要（指数行情 + 发现报告因子）
                let digest = Self.assembleMarketDigest(
                    indexQuotes: indexQuotes, candidates: discoveryCandidates)

                // 5. LLM 叙述（可选；失败在 workflow 内降级本地因子）
                var narrativeProvider: MarketCloseReviewWorkflow.NarrativeProvider?
                if providerConfigured,
                   let configuration = IntelligenceV2ProviderSettings.providerConfiguration() {
                    let synthesizer = MarketCloseNarrativeSynthesizer(
                        gateway: ModelGateway(providers: [
                            OpenAICompatibleModelProvider(configuration: configuration)
                        ], policy: ModelGatewayPolicy()))
                    narrativeProvider = { digestJSON in
                        try await synthesizer.synthesize(digestJSON: digestJSON)
                    }
                }

                let workflow = MarketCloseReviewWorkflow(narrativeProvider: narrativeProvider)
                let input = MarketCloseReviewWorkflow.Input(
                    portfolioKey: "app:userPortfolio",
                    reviewDate: reviewDate,
                    portfolioReview: portfolioReview,
                    marketDigest: digest,
                    tomorrowWatch: tomorrowWatch,
                    dataBoundary: Self.assembleDataBoundary(from: snapshot),
                    attributionArtifactID: attributionID)
                await MainActor.run {
                    self?.closeReviewOperationState = .running(startedAt: now, stage: .persisting)
                }
                let outcome = await workflow.run(input: input, now: now)
                guard let artifact = outcome.artifact else {
                    throw NSError(
                        domain: "intelligence", code: 5,
                        userInfo: [NSLocalizedDescriptionKey:
                                   outcome.errorDetail ?? "收盘复盘生成失败"])
                }
                try runtime.repository.writeMarketCloseReview(artifact)
                await MainActor.run {
                    self?.closeReviewOperationState = .idle
                    self?.refreshIntelligenceDashboard()
                }
                if outcome.narrativeFallback {
                    await AIAgentDiagnosticLog.record(
                        "close-review",
                        message: "LLM 叙述失败，已降级本地因子版（manual=\(manual)）")
                }
            } catch {
                await MainActor.run {
                    self?.closeReviewOperationState = .failed(
                        IntelligenceUserFacingError.from(error))
                }
            }
        }
    }

    // MARK: - 组装（纯函数，可测）

    /// 估值快照 → 当日表现（涨跌额/幅 + 覆盖 + 逐持仓影响 top 8）。
    nonisolated static func assemblePortfolioReview(
        from snapshot: UserPortfolioSnapshot
    ) -> MarketCloseReview.PortfolioReview {
        let impacts = snapshot.rows
            .compactMap { row -> MarketCloseReview.PortfolioReview.HoldingImpact? in
                let changeAmount = row.estimatedDailyChangeAmount
                let changePct = row.estimateChangePct
                guard changeAmount != nil || changePct != nil else { return nil }
                return MarketCloseReview.PortfolioReview.HoldingImpact(
                    name: row.fundName,
                    code: row.holding.fundCode,
                    changeAmount: changeAmount,
                    changePct: changePct)
            }
            .sorted {
                abs($0.changeAmount ?? 0) == abs($1.changeAmount ?? 0)
                    ? $0.name < $1.name
                    : abs($0.changeAmount ?? 0) > abs($1.changeAmount ?? 0)
            }
        return MarketCloseReview.PortfolioReview(
            totalMarketValue: snapshot.totalMarketValue,
            dailyChangeAmount: snapshot.dailyChangeSummary.amount,
            dailyChangePct: snapshot.dailyChangeSummary.pct,
            holdingCount: snapshot.holdingCount,
            coveredHoldingCount: snapshot.dailyChangeCoverageCount,
            topImpacts: Array(impacts.prefix(8)))
    }

    /// 明日关注（≤3 条）：开放决策事项 > 最大目标偏差 > 盘中结论。
    nonisolated static func assembleTomorrowWatch(
        decisionCases: [DecisionCase],
        allocationRows: [InvestmentIntelligenceDashboardSnapshot.AllocationSummary.Row],
        intraday: InvestmentIntelligenceDashboardSnapshot.IntradaySummary?
    ) -> [String] {
        var items: [String] = []
        let notableCases = decisionCases
            .filter { $0.lifecycle != .closed && $0.decisionState != .stable }
            .prefix(2)
        for decisionCase in notableCases {
            items.append("\(decisionCase.title)（\(decisionCase.metricLabel)）")
        }
        if let worstDeviation = allocationRows
            .compactMap({ row -> (String, Decimal)? in
                guard let deviation = row.deviation else { return nil }
                return (IntelligencePresentationFormatter.assetClassName(row.assetClass), deviation)
            })
            .max(by: { abs($0.1) < abs($1.1) }),
           abs(worstDeviation.1) > Decimal(string: "0.05")! {
            let pct = (worstDeviation.1 * 100).rounded(toScale: 1)
            items.append("\(worstDeviation.0)配置偏差 \(pct)%，关注再平衡窗口")
        }
        if let intraday {
            items.append(intraday.decision == .executeRebalance
                ? "盘中结论建议执行再平衡——开盘对照执行计划"
                : "盘中结论为持有不动——明日继续观察偏差")
        }
        return Array(items.prefix(3))
    }

    /// 市场摘要（指数行情 + 发现报告因子评分）。
    nonisolated static func assembleMarketDigest(
        indexQuotes: [MarketIndexKind: MarketIndexQuote],
        candidates: [DiscoveryCandidate]
    ) -> [MarketCloseReviewWorkflow.MarketDigestItem] {
        var digest: [MarketCloseReviewWorkflow.MarketDigestItem] = []
        for (_, quote) in indexQuotes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            digest.append(MarketCloseReviewWorkflow.MarketDigestItem(
                name: quote.name,
                changePct: quote.changePct,
                kind: "index"))
        }
        for candidate in candidates.prefix(6) {
            digest.append(MarketCloseReviewWorkflow.MarketDigestItem(
                name: candidate.displayName,
                factorScore: (candidate.score as NSDecimalNumber).doubleValue,
                kind: "factor"))
        }
        return digest
    }

    /// 数据边界说明（覆盖 / 口径，人话）。
    nonisolated static func assembleDataBoundary(
        from snapshot: UserPortfolioSnapshot
    ) -> String {
        let coverage = AttributionDataCoverage(
            holdingCount: snapshot.holdingCount,
            valuedCount: snapshot.rows.filter { ($0.marketValue ?? 0) > 0 }.count,
            changeCount: snapshot.dailyChangeCoverageCount)
        return coverage.summaryText
    }
}
