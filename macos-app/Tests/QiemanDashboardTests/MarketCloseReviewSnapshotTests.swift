import XCTest
@testable import QiemanDashboard

final class MarketCloseReviewSnapshotTests: XCTestCase {
    func testAfterCloseBuildsMarketReviewWithoutUsingPortfolioSections() {
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .ready)
        XCTAssertTrue(review.headline.contains("机器人"))
        XCTAssertEqual(review.marketPulse.map(\.name), ["沪深300", "黄金"])
        XCTAssertEqual(review.strongThemes.map(\.name), ["机器人"])
        XCTAssertEqual(review.weakThemes.map(\.name), ["地产"])
        XCTAssertFalse(review.headline.contains("第一大持仓"))
        XCTAssertTrue(review.dataBoundary.contains("不读取个人持仓"))
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

    func testLegacyPortfolioOnlyReportIsNotRepackagedAsMarketReview() {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-07 15:10:00",
            externalSignalStatus: .partial
        )
        let review = MarketCloseReviewSnapshot.make(
            report: base,
            generationState: .succeeded,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .noScan)
        XCTAssertTrue(review.headline.contains("没有全市场收盘结论"))
        XCTAssertTrue(review.summary.contains("不能拿来拼凑市场复盘"))
    }

    func testGeneratingStateShowsScanProgressPlaceholder() {
        let review = MarketCloseReviewSnapshot.make(
            report: makeReport(),
            generationState: .generating,
            currentTimestamp: "2026-08-07 15:30:00"
        )

        XCTAssertEqual(review.state, .scanning)
        XCTAssertTrue(review.headline.contains("正在整理"))
        XCTAssertTrue(review.marketPulse.isEmpty)
    }

    func testMacTopModuleIsMarketCloseReviewAndContainsNoHoldingOrDecisionSummary() throws {
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

        XCTAssertTrue(dashboard.contains("MarketCloseReviewSection()"))
        XCTAssertTrue(section.contains("今日收盘复盘"))
        XCTAssertTrue(section.contains("市场温度"))
        XCTAssertTrue(section.contains("主线与风险"))
        XCTAssertTrue(section.contains("次日观察"))
        XCTAssertFalse(section.contains("第一大持仓"))
        XCTAssertFalse(section.contains("组合涨跌"))
        XCTAssertFalse(section.contains("DecisionCase"))
    }

    private func makeReport() -> TrendAnalysisReport {
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
                    rationale: "权重指数尾盘企稳，风险偏好较盘中改善。",
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
}
