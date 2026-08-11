import XCTest
@testable import QiemanDashboard

final class TrendReportModuleToolsTests: XCTestCase {
    func testAssetBatchDecodesCommonAgentDirectionAliases() throws {
        let json = """
        {
          "assetTrends": [{
            "name": "测试基金",
            "code": "000001",
            "sector": "A股",
            "impactText": "涨跌归因：底层半导体持仓上涨，带动基金净值走强。",
            "horizons": [{
              "horizon": "short",
              "direction": "up",
              "confidence": {"score": 70, "label": "中"},
              "rationale": "当日走势偏强。",
              "counterSignals": []
            }],
            "rationale": "结合当日行情判断。",
            "counterSignals": []
          }]
        }
        """

        let module = try JSONDecoder().decode(
            TrendReportAssetBatchModule.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(module.assetTrends.first?.horizons.first?.direction, .bullish)
    }

    func testUnknownAgentDirectionFallsBackToUncertainAndEncodingStaysCanonical() throws {
        let decoded = try JSONDecoder().decode(
            TrendDirection.self,
            from: Data("\"unexpected-direction\"".utf8)
        )
        XCTAssertEqual(decoded, .uncertain)

        let encoded = try JSONEncoder().encode(TrendDirection.neutralPositive)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"neutralPositive\"")
    }

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

    func testDraftRejectsStaticHoldingDescriptionAsDailyAttribution() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        let invalid = TrendAssetView(
            id: "asset-000001",
            name: "测试基金",
            code: "000001",
            sector: "A股",
            impactText: "组合核心持仓，穿透集中于若干半导体股票。",
            horizons: [],
            rationale: "基于当前持仓观察。",
            counterSignals: ["若行情变化则重新评估。"]
        )

        do {
            try await store.storeAssetBatch(
                TrendReportAssetBatchModule(assetTrends: [invalid])
            )
            XCTFail("Expected non-causal impact text rejection")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("必须以「涨跌归因：」或「原因待确认：」开头"))
        }
    }

    func testMarketRadarOnlyRequestsMarketModuleAndReusesBaseline() async throws {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )
        let codes = base.assetTrends.compactMap(\.code)
        let store = TrendReportDraftStore(
            expectedFundCodes: codes,
            scope: .marketRadar,
            baselineReport: base
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.market)
        XCTAssertEqual(progress.totalSections, 1)

        try await store.storeMarket(
            TrendReportMarketModule(
                marketOutlook: [makeMarketOutlook()],
                sectors: [],
                opportunities: []
            )
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let assembled = await store.assembledReport(snapshot: makeSnapshot(codes: codes))
        XCTAssertEqual(assembled?.portfolio, base.portfolio)
        XCTAssertEqual(assembled?.assetTrends, base.assetTrends)
        XCTAssertEqual(assembled?.marketOutlook.first?.name, "市场环境")
    }

    func testCloseReviewOnlyRequestsAssetBatches() async throws {
        let code = "000001"
        let base = reportWithAssets([makeAsset(code: code)])
        let store = TrendReportDraftStore(
            expectedFundCodes: [code],
            scope: .closeReview,
            baselineReport: base
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.totalSections, 1)

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: code)])
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let assembled = await store.assembledReport(snapshot: makeSnapshot(codes: [code]))
        XCTAssertEqual(assembled?.marketOutlook, base.marketOutlook)
        XCTAssertEqual(assembled?.portfolio, base.portfolio)
        XCTAssertEqual(assembled?.assetTrends.count, 1)
    }

    private func makeAsset(code: String) -> TrendAssetView {
        TrendAssetView(
            id: "asset-\(code)",
            name: "基金\(code)",
            code: code,
            sector: "A股",
            impactText: "原因待确认：测试快照没有底层证券当日行情。",
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

    private func reportWithAssets(_ assets: [TrendAssetView]) -> TrendAnalysisReport {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )
        return TrendAnalysisReport(
            id: base.id,
            generatedAt: base.generatedAt,
            dataAsOf: base.dataAsOf,
            privacyMode: base.privacyMode,
            externalSignalStatus: base.externalSignalStatus,
            portfolio: base.portfolio,
            horizons: base.horizons,
            marketOutlook: [makeMarketOutlook()],
            sectors: base.sectors,
            opportunities: base.opportunities,
            keyAssets: base.keyAssets,
            assetTrends: assets,
            actions: base.actions,
            evidence: base.evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
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
