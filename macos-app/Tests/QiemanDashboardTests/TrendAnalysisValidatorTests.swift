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
