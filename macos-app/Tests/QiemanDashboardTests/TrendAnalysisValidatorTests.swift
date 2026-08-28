import XCTest
@testable import QiemanDashboard

final class TrendAnalysisValidatorTests: XCTestCase {
    func testRejectsMandatoryBuySellLanguage() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingActions([
                TrendActionCandidate(
                    id: "buy-now",
                    kind: .considerIncrease,
                    title: "必须买入沪深300",
                    detail: "保证上涨。",
                    targetName: "沪深300ETF",
                    confidence: TrendConfidence(score: 90, label: "高"),
                    triggerConditions: ["放量突破"],
                    invalidatingConditions: ["跌破均线"]
                )
            ])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("absolute") || $0.contains("强制") })
    }

    func testRejectsActionWithoutConditions() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingActions([
                TrendActionCandidate(
                    id: "watch",
                    kind: .watch,
                    title: "关注纳指",
                    detail: "波动加大。",
                    targetName: "纳指ETF",
                    confidence: TrendConfidence(score: 60, label: "中"),
                    triggerConditions: [],
                    invalidatingConditions: ["美元流动性改善"]
                )
            ])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("trigger") || $0.contains("触发") })
    }

    func testRejectsTopLevelHorizonWithoutRationale() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingHorizons([
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 60, label: "中"),
                    rationale: "",
                    counterSignals: []
                )
            ])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("判断依据") || $0.contains("rationale") })
    }

    func testRejectsReportMissingRequiredHorizonCoverage() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingHorizons([
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 60, label: "中"),
                    rationale: "短期震荡。",
                    counterSignals: ["若放量突破则上修。"]
                )
            ])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("short/medium/long") || $0.contains("短中长期") })
    }

    func testRejectsConfidentViewWithoutCounterSignals() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingHorizons([
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutralPositive,
                    confidence: TrendConfidence(score: 78, label: "高"),
                    rationale: "短期信号偏强。",
                    counterSignals: []
                ),
                TrendHorizonView(
                    horizon: .medium,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 62, label: "中"),
                    rationale: "中期等待确认。",
                    counterSignals: ["若盈利下修则降级。"]
                ),
                TrendHorizonView(
                    horizon: .long,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 58, label: "中"),
                    rationale: "长期维持观察。",
                    counterSignals: ["若结构性风险上升则降级。"]
                )
            ])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("反证") || $0.contains("counterSignals") })
    }

    func testRejectsAvailableExternalStatusWithoutEvidence() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingEvidence([])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("evidence") || $0.contains("证据") })
    }

    func testRejectsDisclaimerWithoutNonAdviceWording() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingDisclaimer("仅供参考。")

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("非投资建议") })
    }

    func testRejectsEmptyMarketView() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial)
            .replacingMarketView(marketOutlook: [], sectors: [])

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("市场视图不能为空") })
    }

    func testRejectsMissingExpectedHeldFundAssetTrend() {
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .available)
            .replacingAssetTrends([
                TrendAssetView(
                    id: "asset-000001",
                    name: "消费指数基金",
                    code: "000001",
                    sector: "消费",
                    impactText: "对组合波动影响较大。",
                    horizons: [],
                    rationale: "消费修复仍需等待确认。",
                    counterSignals: ["若消费连续放量修复则上修。"]
                )
            ])

        let result = TrendAnalysisValidator().validate(
            report,
            expectedFundCodes: ["000001", "000002"]
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("000002") || $0.contains("已持有基金") })
    }

    func testAcceptsFixtureReport() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-22 12:00:00",
            externalSignalStatus: .partial
        )

        let result = TrendAnalysisValidator().validate(report)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.messages.isEmpty)
    }

    // MARK: - W4 结论明确性契约(2026-08-27 起)

    private func clarityReport(
        horizonRationale: String = "中性,短期缺少明确突破信号。",
        horizonDirection: TrendDirection = .neutral,
        marketRationale: String? = nil
    ) -> TrendAnalysisReport {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-22 12:00:00",
            externalSignalStatus: .partial
        )
        let horizons = base.horizons.map { horizon -> TrendHorizonView in
            guard horizon.horizon == .short else { return horizon }
            return TrendHorizonView(
                horizon: .short,
                direction: horizonDirection,
                confidence: TrendConfidence(score: 60, label: "中"),
                rationale: horizonRationale,
                whatWouldChange: "触发条件变化时重估。",
                counterSignals: ["反证条件"],
                claimEvidence: .empty
            )
        }
        var markets = base.marketOutlook
        if let marketRationale, let first = base.marketOutlook.first {
            markets = [
                TrendMarketOutlook(
                    id: first.id,
                    name: first.name,
                    category: first.category,
                    direction: first.direction,
                    confidence: first.confidence,
                    rationale: marketRationale,
                    evidenceIDs: first.evidenceIDs,
                    counterSignals: first.counterSignals,
                    claimEvidence: first.claimEvidence
                )
            ]
        }
        return TrendAnalysisReport(
            id: base.id,
            generatedAt: base.generatedAt,
            dataAsOf: base.dataAsOf,
            privacyMode: base.privacyMode,
            externalSignalStatus: base.externalSignalStatus,
            portfolio: base.portfolio,
            horizons: horizons,
            marketOutlook: markets,
            sectors: base.sectors,
            opportunities: base.opportunities,
            keyAssets: base.keyAssets,
            assetTrends: base.assetTrends,
            actions: base.actions,
            evidence: base.evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: base.schemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
        )
    }

    func testRejectsRationaleWithoutDirectionLeadWord() {
        let report = clarityReport(horizonRationale: "市场震荡,多空交织,需密切关注。")
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(
            result.messages.contains { $0.contains("short 周期趋势") && $0.contains("方向词") },
            "零信息量开头必须拒批: \(result.messages)"
        )
    }

    func testRejectsUncertainClaimWithoutWatchSignal() {
        // 大盘 uncertain 有方向词但没有「待观察信号」出口。
        let report = clarityReport(marketRationale: "暂不明确,信号不足。")
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(
            result.messages.contains { $0.contains("待观察信号") },
            "uncertain 必须写清在等什么: \(result.messages)"
        )
    }

    func testRejectsMissingWhatWouldChange() {
        let base = clarityReport()
        let stripped = base.horizons.map { horizon in
            TrendHorizonView(
                horizon: horizon.horizon,
                direction: horizon.direction,
                confidence: horizon.confidence,
                rationale: horizon.rationale,
                whatWouldChange: "",
                counterSignals: horizon.counterSignals,
                claimEvidence: horizon.claimEvidence
            )
        }
        let report = base.replacingHorizons(stripped)
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(
            result.messages.contains { $0.contains("whatWouldChange") },
            "结论四要素的作废条件必须非空: \(result.messages)"
        )
    }

    func testAcceptsDirectionLeadWordVocabulary() {
        // 词表内的任意方向词开头都应通过首句校验。
        for lead in ["看多", "偏弱", "中性", "观望", "暂不明确", "择机"] {
            let report = clarityReport(horizonRationale: "\(lead),测试理由。")
            let result = TrendAnalysisValidator().validate(report)
            XCTAssertTrue(
                result.messages.allSatisfy { !$0.contains("方向词") },
                "「\(lead)」开头不应触发方向词拒批: \(result.messages)"
            )
        }
    }

    func testBaselinePatchMakesLegacyReuseSatisfyClarityContract() {
        // 旧基线数据(无方向词/uncertain 无出口/缺作废条件)经 BaselineContractPatch
        // 后必须通过三条新校验——增量运行复用旧报告不得整份拒批。
        let legacy = TrendHorizonView(
            horizon: .short,
            direction: .uncertain,
            confidence: TrendConfidence(score: 40, label: "低"),
            rationale: "市场信号不足。",
            counterSignals: []
        )
        let patched = TrendBaselineContractPatch.horizon(legacy)
        let base = clarityReport()
        let report = base.replacingHorizons(
            base.horizons.map { $0.horizon == .short ? patched : $0 }
        )
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertTrue(
            result.messages.allSatisfy { !$0.contains("short 周期趋势") },
            "补丁后的短期结论不得再触发明确性拒批: \(result.messages)"
        )
        XCTAssertTrue(patched.rationale.contains("待观察信号"))
        XCTAssertFalse(patched.whatWouldChange.isEmpty)
    }
}

private extension TrendAnalysisReport {
    func replacingMarketView(
        marketOutlook: [TrendMarketOutlook],
        sectors: [TrendSectorView]
    ) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            marketOutlook: marketOutlook,
            sectors: sectors,
            opportunities: opportunities,
            keyAssets: keyAssets,
            assetTrends: assetTrends,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer,
            schemaVersion: schemaVersion,
            disposition: disposition,
            sourceStatuses: sourceStatuses
        )
    }

    func replacingHorizons(_ horizons: [TrendHorizonView]) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }

    func replacingEvidence(_ evidence: [TrendEvidence]) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }

    func replacingDisclaimer(_ disclaimer: String) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }

    func replacingAssetTrends(_ assetTrends: [TrendAssetView]) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            assetTrends: assetTrends,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }
}
