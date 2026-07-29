import XCTest
@testable import QiemanDashboard

final class TrendReportModuleToolsTests: XCTestCase {
    func testDraftAdvancesInOrderAndBatchesFundAssetsByFive() async throws {
        let codes = (1...6).map { String(format: "%06d", $0) }
        let store = TrendReportDraftStore(expectedFundCodes: codes)
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.overview)
        XCTAssertEqual(progress.totalSections, 5)

        try await store.storeOverview(
            TrendReportOverviewModule(
                portfolio: base.portfolio,
                horizons: base.horizons
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.market)

        try await store.storeMarket(
            TrendReportMarketModule(
                marketOutlook: [makeMarketOutlook()],
                sectors: [],
                opportunities: []
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.remainingFundCodes.count, 6)

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.prefix(5).map { makeAsset(code: $0) }
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.remainingFundCodes, [codes[5]])

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: [makeAsset(code: codes[5])]
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.actions)

        try await store.storeActions(
            TrendReportActionsModule(
                keyAssets: [],
                actions: [],
                warnings: [],
                disclaimer: "非投资建议，仅供个人研究参考。"
            )
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let snapshot = makeSnapshot(codes: codes)
        let assembled = await store.assembledReport(snapshot: snapshot)
        XCTAssertEqual(assembled?.assetTrends.compactMap(\.code), codes)
    }

    func testDraftRejectsEmptyMarketView() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: [])

        do {
            try await store.storeMarket(
                TrendReportMarketModule(
                    marketOutlook: [],
                    sectors: [],
                    opportunities: []
                )
            )
            XCTFail("Expected empty market view rejection")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("至少提交一项"))
        }
    }

    func testDraftRejectsOversizedAssetBatch() async throws {
        let codes = (1...6).map { String(format: "%06d", $0) }
        let store = TrendReportDraftStore(expectedFundCodes: codes)

        do {
            try await store.storeAssetBatch(
                TrendReportAssetBatchModule(
                    assetTrends: codes.map { makeAsset(code: $0) }
                )
            )
            XCTFail("Expected oversized batch rejection")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("最多"))
        }
    }

    private func makeAsset(code: String) -> TrendAssetView {
        TrendAssetView(
            id: "asset-\(code)",
            name: "基金\(code)",
            code: code,
            sector: "A股",
            impactText: "组合持仓",
            horizons: [],
            rationale: "基于当前持仓与行情观察。",
            counterSignals: ["若行情方向变化则重新评估。"]
        )
    }

    private func makeMarketOutlook() -> TrendMarketOutlook {
        TrendMarketOutlook(
            id: "market-environment",
            name: "市场环境",
            category: "index",
            direction: .uncertain,
            confidence: TrendConfidence(score: 40, label: "低"),
            rationale: "当前市场信号仍需进一步确认。",
            evidenceIDs: [],
            counterSignals: ["若主要指数趋势改变则重新评估。"]
        )
    }

    private func makeSnapshot(codes: [String]) -> TrendResearchSnapshot {
        let assets = codes.map {
            TrendContextAsset(
                id: $0,
                name: "基金\($0)",
                code: $0,
                assetType: PersonalAssetType.fund.displayName,
                sector: "A股",
                statusText: "已持有",
                weightText: nil,
                profitPct: nil,
                estimateChangePct: nil,
                pendingTradeCount: 0,
                activePlanCount: 0,
                pausedPlanCount: 0,
                endedPlanCount: 0,
                marketValue: nil,
                costValue: nil,
                profitAmount: nil,
                pendingCashAmount: nil,
                estimatedNextPlanAmount: nil,
                totalCumulativePlanAmount: nil
            )
        }
        return TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-07-26 10:00:00",
            dataAsOf: "2026-07-26 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: assets.count,
                holdingCount: assets.count,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: assets,
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            insightHeadline: "",
            sourceWarnings: []
        )
    }
}
