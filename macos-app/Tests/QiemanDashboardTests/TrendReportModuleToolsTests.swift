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

    func testDraftAdvancesInOrderAndBatchesFundAssets() async throws {
        let codes = (1...10).map { String(format: "%06d", $0) }
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
        XCTAssertEqual(progress.remainingFundCodes.count, 10)

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.prefix(TrendReportDraftStore.assetBatchSize).map { makeAsset(code: $0) }
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.remainingFundCodes, [codes[8], codes[9]])

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.suffix(2).map { makeAsset(code: $0) }
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
        let codes = (1...9).map { String(format: "%06d", $0) }
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
        // W4:复用的基线 market 模块经 BaselineContractPatch 满足明确性契约后透传
        // (方向词前缀 + uncertain 待观察信号出口),其余字段不变。
        XCTAssertEqual(assembled?.marketOutlook, TrendBaselineContractPatch.markets(base.marketOutlook))
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

// MARK: - 2026-08-28 死循环修复：批次全错收集 + 归因自动降级

final class AssetBatchRejectionLoopFixTests: XCTestCase {
    private func asset(
        code: String,
        impactText: String,
        supportingEvidenceIDs: [String] = []
    ) -> TrendAssetView {
        TrendAssetView(
            id: "asset-\(code)",
            name: "基金\(code)",
            code: code,
            sector: "A股",
            impactText: impactText,
            horizons: [],
            rationale: "观察。",
            counterSignals: ["若行情变化则重新评估。"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: supportingEvidenceIDs)
        )
    }

    func testBatchCollectsAllFundErrorsAtOnce() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000001", "000002", "000003"])
        let batch = [
            asset(code: "000001", impactText: "市值较高，持仓集中。"),          // 错前缀
            asset(code: "000002", impactText: "涨跌归因：跟随板块上涨。"),      // 无证据 → 自动降级（不再报错）
            asset(code: "000003", impactText: "组合核心，长期持有。"),          // 错前缀
        ]
        do {
            try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
            XCTFail("两只错前缀基金应整批拒收")
        } catch let error as TrendReportDraftError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("2 个问题"), "一次性列出全部问题，实际：\(message)")
            XCTAssertTrue(message.contains("000001"))
            XCTAssertTrue(message.contains("000003"))
        }
    }

    func testBatchWithAttributionButNoEvidenceIsAutoDowngradedAndAccepted() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000369", "019524"])
        let batch = [
            asset(
                code: "000369",
                impactText: "涨跌归因：当日盘中估值跌0.31%，跟随港股科技回调。",
                supportingEvidenceIDs: ["manager:forumHit:86149"]
            ),
            asset(
                code: "019524",
                impactText: "涨跌归因：重仓股上涨带动净值回升。",
                supportingEvidenceIDs: []
            ),
        ]
        // v4.7.0 线上正是这两类基金把修复预算耗尽——现在应整批通过
        try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
        let progress = await store.progress()
        XCTAssertEqual(progress.completedSections, 1, "持仓分批已暂存")
    }

    func testMixedBatchPartialAcceptanceViaFullErrorList() async throws {
        // 未知代码 + 无证据归因：前者报错，后者降级——错误信息只含前者
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        let batch = [
            asset(code: "999999", impactText: "涨跌归因：板块上涨。"),
            asset(code: "000001", impactText: "涨跌归因：板块上涨。"),
        ]
        do {
            try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
            XCTFail("未知代码应报错")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("999999"))
            XCTAssertFalse(error.localizedDescription.contains("涨跌归因"), "降级后不再报归因类错误")
        }
    }
}
