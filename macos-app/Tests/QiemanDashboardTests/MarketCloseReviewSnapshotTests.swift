import XCTest
@testable import QiemanDashboard

final class MarketCloseReviewSnapshotTests: XCTestCase {
    func testAfterCloseCombinesMarketAndPortfolioReview() {
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            portfolioSnapshot: makePortfolioSnapshot(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .ready)
        XCTAssertTrue(review.headline.contains("机器人"))
        XCTAssertEqual(review.marketPulse.map(\.name), ["沪深300", "黄金"])
        XCTAssertEqual(review.strongThemes.map(\.name), ["机器人"])
        XCTAssertEqual(review.weakThemes.map(\.name), ["地产"])
        XCTAssertEqual(review.portfolioReview?.holdingCount, 2)
        XCTAssertEqual(review.portfolioReview?.coveredHoldingCount, 2)
        XCTAssertEqual(
            review.portfolioReview?.holdingImpacts.map(\.name),
            ["成长基金", "稳健基金"]
        )
        XCTAssertEqual(
            review.portfolioReview?.holdingImpacts.first?.analysis,
            "涨跌归因：机器人板块走强，与成长基金当日上涨方向一致。"
        )
        XCTAssertFalse(review.summary.contains("个人组合"))
        XCTAssertEqual(review.tomorrowWatch.count, 3)
        XCTAssertTrue(review.tomorrowWatch.contains { $0.contains("持仓验证 · 成长基金") })
        XCTAssertTrue(review.dataBoundary.contains("收盘时冻结的个人持仓涨跌"))
        XCTAssertFalse(review.dataBoundary.contains("不读取个人持仓"))
    }

    func testHeaderSummaryKeepsCompleteMarketRationale() {
        let rationale = String(repeating: "完整收盘信息需要保留。", count: 20)
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(marketRationale: rationale),
            portfolioSnapshot: makePortfolioSnapshot(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertTrue(review.summary.contains(rationale))
        XCTAssertFalse(review.summary.hasSuffix("…"))
    }

    func testBeforeCloseLabelsResultAsObservationInsteadOfCloseConclusion() {
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 14:20:00"
        )

        XCTAssertEqual(review.state, .awaitingClose)
        XCTAssertEqual(review.eyebrow, "盘中观察")
        XCTAssertTrue(review.dataBoundary.contains("不把盘中变化冒充收盘结论"))
    }

    func testCloseReviewFreshnessUsesItsOwnModuleTimestamp() {
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00",
            closeReviewGeneratedAt: "2026-08-06 21:05:00"
        )

        XCTAssertEqual(review.state, .stale)
        XCTAssertTrue(review.subtitle.contains("2026-08-06 21:05"))
    }

    func testHoldingStillAppearsWhenItsDailyChangeIsPending() {
        let row = portfolioRow(
            code: "000003",
            name: "待公布基金",
            marketValue: 8_000,
            changePct: nil
        )
        let snapshot = UserPortfolioSnapshot(
            rows: [row],
            refreshedAt: "2026-08-07 15:20:00",
            totalMarketValue: 8_000,
            totalCostValue: 8_000,
            totalProfitAmount: 0,
            totalProfitPct: 0
        )

        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            portfolioSnapshot: snapshot,
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.portfolioReview?.coveredHoldingCount, 0)
        XCTAssertEqual(review.portfolioReview?.holdingImpacts.map(\.name), ["待公布基金"])
        XCTAssertNil(review.portfolioReview?.holdingImpacts.first?.changeAmount)
    }

    func testPortfolioOnlyReportDoesNotDependOnMarketWideConclusion() {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-07 15:10:00",
            externalSignalStatus: .partial
        )
        let review = MarketCloseReviewSnapshot.make(
            report: base,
            portfolioSnapshot: makePortfolioSnapshot(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .ready)
        XCTAssertTrue(review.headline.contains("组合"))
        XCTAssertNotNil(review.portfolioReview)
        XCTAssertFalse(review.summary.contains("先跑全市场机会雷达"))
    }

    func testGeneratingStateShowsScanProgressPlaceholder() {
        // 生成中且没有可用旧报告：显示扫描中占位，脉搏为空。
        let review = MarketCloseReviewSnapshot.make(
            report: nil,
            generationState: .generating,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .scanning)
        XCTAssertTrue(review.headline.contains("正在整理"))
        XCTAssertTrue(review.marketPulse.isEmpty)
    }

    func testGeneratingStateRetainsPreviousReportData() {
        // 生成中但有可用旧报告（含 marketWide）：沿用旧结论，避免整片空白。
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            generationState: .generating,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .scanning)
        XCTAssertTrue(review.eyebrow.contains("展示旧结果"))
        XCTAssertTrue(review.subtitle.contains("暂时展示"))
        // 旧报告的市场温度/主线仍在，不丢成空。
        XCTAssertFalse(review.marketPulse.isEmpty)
        XCTAssertEqual(review.marketPulse.map(\.name), ["沪深300", "黄金"])
    }

    @MainActor
    func testArchivedCloseReviewKeepsYesterdayPortfolioInsteadOfLiveIntradayData() {
        let frozen = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            portfolioSnapshot: makePortfolioSnapshot(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 21:10:00",
            closeReviewGeneratedAt: "2026-08-07 21:10:00"
        )
        let model = AppModel()
        model.marketCloseReviewArchive = MarketCloseReviewArchive(
            generatedAt: "2026-08-07 21:10:00",
            snapshot: frozen
        )
        model.userPortfolioSnapshot = UserPortfolioSnapshot(
            rows: [
                portfolioRow(
                    code: "000001",
                    name: "成长基金",
                    marketValue: 99_999,
                    changePct: 9.9
                )
            ],
            refreshedAt: "2026-08-08 10:00:00",
            totalMarketValue: 99_999,
            totalCostValue: 10_000,
            totalProfitAmount: 89_999,
            totalProfitPct: 899.99
        )

        let displayed = model.marketCloseReview

        XCTAssertEqual(displayed.state, .stale)
        XCTAssertEqual(displayed.portfolioReview?.totalMarketValue, 20_100)
        XCTAssertEqual(displayed.portfolioReview?.holdingCount, 2)
        XCTAssertTrue(displayed.subtitle.contains("2026-08-07 21:10"))
    }

    @MainActor
    func testLegacyFallbackRejectsTodaySharedReportAndIntradayPortfolio() {
        let model = AppModel()
        model.trendReport = makeReport()
        model.trendSettings.markModuleGenerated(
            scope: .closeReview,
            generatedAt: "2026-08-06 21:10:00"
        )
        model.userPortfolioSnapshot = makePortfolioSnapshot()

        let displayed = model.marketCloseReview

        XCTAssertEqual(displayed.state, .noScan)
        XCTAssertNil(displayed.portfolioReview)
        XCTAssertTrue(displayed.marketPulse.isEmpty)
    }

    func testMarketCloseReviewArchiveRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("close-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("market-close-review.json")
        let snapshot = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            portfolioSnapshot: makePortfolioSnapshot(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 21:10:00",
            closeReviewGeneratedAt: "2026-08-07 21:10:00"
        )
        let archive = MarketCloseReviewArchive(
            generatedAt: "2026-08-07 21:10:00",
            snapshot: snapshot
        )

        try MarketCloseReviewArchiveStore().save(archive, to: fileURL)
        let restored = try XCTUnwrap(MarketCloseReviewArchiveStore().load(from: fileURL))

        XCTAssertEqual(restored, archive)
    }

    func testCloseReviewTitleFollowsFrozenReviewDay() {
        XCTAssertEqual(
            MarketCloseReviewArchive.displayTitle(
                generatedAt: "2026-08-11 21:10:00",
                currentTimestamp: "2026-08-11 22:00:00"
            ),
            "今日收盘复盘"
        )
        XCTAssertEqual(
            MarketCloseReviewArchive.displayTitle(
                generatedAt: "2026-08-10 21:10:00",
                currentTimestamp: "2026-08-11 10:00:00"
            ),
            "昨日收盘复盘"
        )
        XCTAssertEqual(
            MarketCloseReviewArchive.displayTitle(
                generatedAt: "2026-08-08 21:10:00",
                currentTimestamp: "2026-08-11 10:00:00"
            ),
            "最近收盘复盘"
        )
    }

    func testLegacyCloseReviewRecoversFromLocalDiagnosticLogWithoutNetwork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("close-review-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = makeReport()
        let frozenAsset = recoveredAsset()
        try writeRecoveryLog(report: report, assets: [frozenAsset], to: directory)

        let recovered = MarketCloseReviewArchiveRecovery().latestRun(
            in: directory,
            generatedAt: "2026-08-07 21:10:00"
        )

        XCTAssertEqual(recovered?.report, report)
        XCTAssertEqual(recovered?.portfolioAssets, [frozenAsset])

        let snapshot = MarketCloseReviewSnapshot.make(
            report: recovered?.report,
            recoveredPortfolioAssets: recovered?.portfolioAssets ?? [],
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 21:10:00",
            closeReviewGeneratedAt: "2026-08-07 21:10:00"
        )
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.portfolioReview?.holdingCount, 1)
        XCTAssertEqual(snapshot.portfolioReview?.dailyChangeAmount ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(snapshot.portfolioReview?.holdingImpacts.map(\.name), ["成长基金"])
    }

    @MainActor
    func testLoadingRepairsOldEmptyArchiveFromFrozenLocalAssets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("close-review-repair-\(UUID().uuidString)", isDirectory: true)
        let logsDirectory = directory.appendingPathComponent("ai-analysis-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generatedAt = "2026-08-07 21:10:00"
        let oldSnapshot = MarketCloseReviewSnapshot.make(
            report: nil,
            generationState: .idle,
            currentTimestamp: generatedAt,
            closeReviewGeneratedAt: generatedAt
        )
        let oldArchive = MarketCloseReviewArchive(
            generatedAt: generatedAt,
            snapshot: oldSnapshot,
            schemaVersion: 1
        )
        try MarketCloseReviewArchiveStore().save(
            oldArchive,
            to: directory.appendingPathComponent("market-close-review.json")
        )
        try writeRecoveryLog(
            report: makeReport(),
            assets: [recoveredAsset()],
            to: logsDirectory
        )

        let model = AppModel()
        model.dataDirectoryURL = directory
        model.trendSettings.markModuleGenerated(scope: .closeReview, generatedAt: generatedAt)
        model.loadMarketCloseReviewArchive()

        XCTAssertEqual(
            model.marketCloseReviewArchive?.schemaVersion,
            MarketCloseReviewArchive.currentSchemaVersion
        )
        XCTAssertEqual(model.marketCloseReviewArchive?.snapshot.state, .ready)
        XCTAssertEqual(model.marketCloseReviewArchive?.snapshot.portfolioReview?.holdingCount, 1)
        XCTAssertEqual(
            model.marketCloseReviewArchive?.snapshot.portfolioReview?.holdingImpacts.map(\.name),
            ["成长基金"]
        )
    }

    func testMacTopModuleUsesUnifiedIntelligenceCardsAndSheetDetails() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboard = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/InvestmentIntelligenceDashboardView.swift"
            ),
            encoding: .utf8
        )
        let section = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewSection.swift"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewHeaderView.swift"
            ),
            encoding: .utf8
        )
        let metrics = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/CloseReviewMetricsView.swift"
            ),
            encoding: .utf8
        )
        let holdings = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/CloseReviewHoldingSummaryView.swift"
            ),
            encoding: .utf8
        )
        let tomorrow = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/CloseReviewTomorrowWatchView.swift"
            ),
            encoding: .utf8
        )
        let details = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewDetailsView.swift"
            ),
            encoding: .utf8
        )
        let detailSheet = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewDetailSheet.swift"
            ),
            encoding: .utf8
        )
        let holdingCard = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/CloseReviewHoldingImpactCard.swift"
            ),
            encoding: .utf8
        )
        let pulse = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewMarketPulseView.swift"
            ),
            encoding: .utf8
        )
        let themes = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/MarketCloseReviewThemeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(dashboard.contains("MarketCloseReviewSection()"))
        XCTAssertTrue(section.contains("model.marketCloseReviewTitle"))
        XCTAssertTrue(section.contains("@State private var isShowingDetails = false"))
        XCTAssertTrue(section.contains("查看完整复盘"))
        XCTAssertTrue(section.contains("MarketCloseReviewDetailSheet"))
        XCTAssertFalse(section.contains("DisclosureGroup"))
        XCTAssertTrue(section.contains("PortfolioCloseReviewView"))
        XCTAssertFalse(section.contains("DecisionCase"))
        XCTAssertTrue(header.contains("TintedCapsuleBadge"))
        XCTAssertTrue(header.contains(".title2"))
        XCTAssertTrue(header.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(metrics.contains("组合今日表现"))
        XCTAssertTrue(metrics.contains("首要影响"))
        XCTAssertTrue(metrics.contains("fill: AppPalette.cardStrong"))
        XCTAssertTrue(holdings.contains("主要持仓影响"))
        XCTAssertTrue(holdings.contains("holdingImpacts.prefix(3)"))
        XCTAssertTrue(tomorrow.contains("明日关注"))
        XCTAssertTrue(tomorrow.contains("items.prefix(3)"))
        XCTAssertTrue(tomorrow.contains("HStack(alignment: .center"))
        XCTAssertTrue(tomorrow.contains(".padding(.vertical, AppPalette.spaceS)"))
        XCTAssertTrue(tomorrow.contains(".staticSurface("))
        XCTAssertTrue(holdingCard.contains(".padding(.vertical, AppPalette.spaceS)"))
        XCTAssertFalse(holdingCard.contains("VStack(alignment: .trailing"))
        XCTAssertTrue(holdingCard.contains(".staticSurface("))
        XCTAssertTrue(detailSheet.contains("MarketCloseReviewDetailsView"))
        XCTAssertTrue(detailSheet.contains(".background(AppPalette.surface)"))
        XCTAssertTrue(details.contains("组合明细"))
        XCTAssertTrue(pulse.contains("市场温度"))
        XCTAssertTrue(themes.contains("主线与风险"))

        let portfolioSection = try String(
            contentsOf: root.appendingPathComponent(
                "Views_macOS/InvestmentIntelligence/PortfolioCloseReviewView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(portfolioSection.contains("CloseReviewHoldingSummaryView"))
        XCTAssertTrue(portfolioSection.contains("CloseReviewTomorrowWatchView"))
        XCTAssertFalse(portfolioSection.contains("ViewThatFits"))
    }

    private func makeReport(
        marketRationale: String = "权重指数尾盘企稳，风险偏好较盘中改善。"
    ) -> TrendAnalysisReport {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-07 15:10:00",
            externalSignalStatus: .partial
        )
        let evidenceID = "web:market-close"
        return TrendAnalysisReport(
            id: base.id,
            generatedAt: "2026-08-07 15:10:00",
            dataAsOf: "2026-08-07 15:00:00",
            privacyMode: base.privacyMode,
            externalSignalStatus: .available,
            portfolio: base.portfolio,
            horizons: base.horizons,
            marketOutlook: [
                TrendMarketOutlook(
                    id: "csi300",
                    name: "沪深300",
                    category: "index",
                    direction: .neutralPositive,
                    confidence: confidence(72),
                    rationale: marketRationale,
                    evidenceIDs: [evidenceID],
                    counterSignals: ["成交额若继续缩量，需要下调结论。"]
                )
            ],
            sectors: [
                TrendSectorView(
                    id: "held-consumer",
                    name: "消费持仓",
                    exposureText: "组合已有暴露",
                    direction: .bearish,
                    confidence: confidence(80),
                    rationale: "这是持仓判断，不应进入市场复盘。",
                    evidenceIDs: [],
                    counterSignals: []
                )
            ],
            opportunities: [
                opportunity("黄金", category: "assetClass", direction: .neutralPositive, score: 66),
                opportunity("机器人", category: "sector", direction: .bullish, score: 82),
                opportunity("地产", category: "sector", direction: .bearish, score: 74)
            ],
            keyAssets: base.keyAssets,
            assetTrends: [
                assetTrend(
                    name: "成长基金",
                    code: "000001",
                    impact: "涨跌归因：机器人板块走强，与成长基金当日上涨方向一致。",
                    watch: "若机器人板块缩量转弱，需要下调影响判断。"
                ),
                assetTrend(
                    name: "稳健基金",
                    code: "000002",
                    impact: "涨跌归因：地产板块承压，与稳健基金当日回撤方向一致。",
                    watch: "关注地产风险是否继续扩散。"
                )
            ],
            actions: base.actions,
            evidence: base.evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: base.schemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
        )
    }

    private struct RecoveryPortfolioToolPayload: Encodable {
        let result: RecoveryPortfolioToolResult
    }

    private struct RecoveryPortfolioToolResult: Encodable {
        let data: RecoveryPortfolioToolPage
    }

    private struct RecoveryPortfolioToolPage: Encodable {
        let assets: [TrendContextAsset]
    }

    private func recoveredAsset() -> TrendContextAsset {
        TrendContextAsset(
            id: "fund:000001",
            name: "成长基金",
            code: "000001",
            assetType: "基金",
            sector: "混合",
            statusText: "持有",
            weightText: "50%",
            profitPct: 2,
            estimateChangePct: 2,
            pendingTradeCount: 0,
            activePlanCount: 0,
            pausedPlanCount: 0,
            endedPlanCount: 0,
            marketValue: 10_200,
            costValue: 10_000,
            profitAmount: 200,
            pendingCashAmount: nil,
            estimatedNextPlanAmount: nil,
            totalCumulativePlanAmount: nil
        )
    }

    private func writeRecoveryLog(
        report: TrendAnalysisReport,
        assets: [TrendContextAsset],
        to directory: URL
    ) throws {
        let toolEntry = AIAgentDiagnosticTraceEntry(
            sequence: 8,
            timestamp: "2026-08-07T13:09:00Z",
            event: "tool_result",
            turn: 2,
            toolName: "get_portfolio_assets",
            toolCallID: "call-assets",
            payload: AIAgentDiagnosticRedactor.payload(
                RecoveryPortfolioToolPayload(
                    result: RecoveryPortfolioToolResult(
                        data: RecoveryPortfolioToolPage(assets: assets)
                    )
                )
            )
        )
        let completedEntry = AIAgentDiagnosticTraceEntry(
            sequence: 9,
            timestamp: "2026-08-07T13:10:00Z",
            event: "run_completed",
            turn: nil,
            toolName: nil,
            toolCallID: nil,
            payload: AIAgentDiagnosticRedactor.payload(report)
        )
        var data = Data()
        for entry in [toolEntry, completedEntry] {
            data.append(try JSONEncoder().encode(entry))
            data.append(0x0A)
        }
        try data.write(
            to: directory.appendingPathComponent(
                "2026-08-07-closeReview-\(UUID().uuidString).jsonl"
            )
        )
    }

    private func opportunity(
        _ name: String,
        category: String,
        direction: TrendDirection,
        score: Int
    ) -> TrendOpportunity {
        TrendOpportunity(
            id: "\(category)-\(name)",
            name: name,
            category: category,
            scope: .marketWide,
            direction: direction,
            confidence: confidence(score),
            rationale: "\(name)的全市场扫描结论。",
            triggerConditions: ["量价和基本面信号继续确认。"],
            invalidatingConditions: ["核心逻辑被新数据否定。"],
            evidenceIDs: ["web:market-close"],
            counterSignals: ["短期波动仍可能反复。"]
        )
    }

    private func confidence(_ score: Int) -> TrendConfidence {
        TrendConfidence(score: score, label: TrendConfidence.label(for: score))
    }

    private func assetTrend(
        name: String,
        code: String,
        impact: String,
        watch: String
    ) -> TrendAssetView {
        TrendAssetView(
            id: code,
            name: name,
            code: code,
            sector: "混合",
            impactText: impact,
            horizons: [],
            rationale: impact,
            counterSignals: [watch],
            claimEvidence: TrendClaimEvidence(
                supportingEvidenceIDs: ["web:tavily:market-close"]
            )
        )
    }

    private func makePortfolioSnapshot() -> UserPortfolioSnapshot {
        let rows = [
            portfolioRow(
                code: "000001",
                name: "成长基金",
                marketValue: 10_200,
                changePct: 2
            ),
            portfolioRow(
                code: "000002",
                name: "稳健基金",
                marketValue: 9_900,
                changePct: -1
            )
        ]
        return UserPortfolioSnapshot(
            rows: rows,
            refreshedAt: "2026-08-07 15:20:00",
            totalMarketValue: 20_100,
            totalCostValue: 20_000,
            totalProfitAmount: 100,
            totalProfitPct: 0.5
        )
    }

    private func portfolioRow(
        code: String,
        name: String,
        marketValue: Double,
        changePct: Double?
    ) -> UserPortfolioValuationRow {
        let holding = UserPortfolioHolding(
            fundCode: code,
            units: 10_000,
            costPrice: 1,
            displayName: name,
            fundMarket: .offExchange
        )
        return UserPortfolioValuationRow(
            holding: holding,
            fundName: name,
            currentPrice: marketValue / holding.units,
            priceTime: "2026-08-07 15:00:00",
            priceSource: "收盘估值",
            officialNav: marketValue / holding.units,
            officialNavDate: "2026-08-07",
            estimatePrice: nil,
            estimatePriceTime: nil,
            marketValue: marketValue,
            costValue: 10_000,
            profitAmount: marketValue - 10_000,
            profitPct: (marketValue / 10_000 - 1) * 100,
            estimateChangePct: changePct
        )
    }
}
