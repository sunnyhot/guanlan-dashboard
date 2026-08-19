import XCTest
@testable import QiemanDashboard

// MARK: - 「今日研判」摘要行派生测试(P1)
//
// 行收录规则见 InvestmentTodayResearchSummary.make:
// 复盘按 state 排除占位态(noScan/scanning 的 headline 是提示文案,不是结论);
// 盘中支持 validUntil 的两种格式("HH:mm" 固定槽 / "yyyy-MM-dd HH:mm" 手动槽)。

final class InvestmentTodayResearchSummaryTests: XCTestCase {
    private let now = "2026-08-19 22:00:00"

    private func emptyInputs(
        closeReview: MarketCloseReviewSnapshot = MarketCloseReviewSnapshot.make(
            report: nil,
            generationState: .idle,
            currentTimestamp: "2026-08-19 15:00:00"
        )
    ) -> InvestmentTodayResearchSummary {
        InvestmentTodayResearchSummary.make(
            closeReview: closeReview,
            closeReviewTitle: "今日收盘复盘",
            intraday: nil,
            marketAnalysis: nil,
            trendReport: nil,
            currentTimestamp: now
        )
    }

    // MARK: 复盘行

    func testPlaceholderSnapshotsAreNotIncluded() {
        // noScan:无任何复盘
        XCTAssertTrue(emptyInputs().rows.isEmpty)

        // scanning:生成中且无旧报告,headline 是占位文案
        let scanning = MarketCloseReviewSnapshot.make(
            report: nil,
            generationState: .generating,
            currentTimestamp: "2026-08-19 15:00:00"
        )
        XCTAssertTrue(emptyInputs(closeReview: scanning).rows.isEmpty)
    }

    func testReadySnapshotProducesCloseReviewRowWithTitlePassedThrough() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-19 21:03:00",
            externalSignalStatus: .available
        )
        let snapshot = MarketCloseReviewSnapshot.make(
            report: report,
            generationState: .succeeded,
            currentTimestamp: now
        )
        let summary = emptyInputs(closeReview: snapshot)
        XCTAssertEqual(summary.rows.map(\.kind), [.closeReview])
        XCTAssertEqual(summary.rows.first?.title, "今日收盘复盘")
        XCTAssertFalse(summary.rows.first?.headline.isEmpty ?? true)
        XCTAssertTrue(summary.hasAnyContent)
    }

    // MARK: 盘中行

    private func intradayReport(
        validUntil: String,
        actions: [NextHourGuidanceAction] = [
            .init(
                targetName: "组合整体",
                action: .hold,
                instruction: "保持现有计划。",
                rationale: "没有明确反向信号。",
                trigger: "估值维持当前区间",
                invalidation: "尾盘快速转弱",
                confidence: 60
            )
        ]
    ) -> NextHourGuidanceReport {
        NextHourGuidanceReport(
            generatedAt: "2026-08-19 14:00:00",
            validUntil: validUntil,
            slotKey: "2026-08-19 14:00",
            scope: .closingWindow,
            headline: "收盘前以复核为主",
            posture: .balanced,
            summary: "场外基金只在此窗口参与。",
            actions: actions,
            riskChecks: ["确认估值时间"],
            assetCount: 1
        )
    }

    func testIntradayRowUsesFirstActionAndFullFormatValidUntil() {
        let summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: intradayReport(validUntil: "2026-08-19 22:30"),
            marketAnalysis: nil,
            trendReport: nil,
            currentTimestamp: now
        )
        let row = summary.rows.first { $0.kind == .intraday }
        XCTAssertNotNil(row)
        XCTAssertTrue(row?.headline.contains("均衡") ?? false)
        XCTAssertTrue(row?.headline.contains("组合整体") ?? false)
        XCTAssertEqual(row?.footnote, "有效至 22:30")
    }

    func testIntradayShortFormatValidUntilAndExpiry() {
        var summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: intradayReport(validUntil: "22:30"),
            marketAnalysis: nil,
            trendReport: nil,
            currentTimestamp: "2026-08-19 22:00:00"
        )
        XCTAssertEqual(
            summary.rows.first { $0.kind == .intraday }?.footnote,
            "有效至 22:30"
        )

        summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: intradayReport(validUntil: "21:30"),
            marketAnalysis: nil,
            trendReport: nil,
            currentTimestamp: "2026-08-19 22:00:00"
        )
        XCTAssertEqual(
            summary.rows.first { $0.kind == .intraday }?.footnote,
            "已过期"
        )
    }

    func testIntradayWithoutActionsFallsBackToHeadline() {
        let summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: intradayReport(validUntil: "22:30", actions: []),
            marketAnalysis: nil,
            trendReport: nil,
            currentTimestamp: now
        )
        let row = summary.rows.first { $0.kind == .intraday }
        XCTAssertTrue(row?.headline.contains("收盘前以复核为主") ?? false)
    }

    // MARK: 雷达行

    private func signal(
        name: String,
        recommendation: InvestmentDirectionRecommendation,
        confidenceScore: Int
    ) -> InvestmentDirectionSignal {
        InvestmentDirectionSignal(
            id: "test-\(name)",
            name: name,
            dimension: .marketSector,
            recommendation: recommendation,
            direction: .bullish,
            confidence: TrendConfidence(score: confidenceScore, label: "高"),
            rationale: "测试信号",
            triggerConditions: [],
            invalidatingConditions: [],
            counterSignals: [],
            evidence: [],
            independentExternalSourceCount: 0,
            hasAuthoritativeEvidence: false
        )
    }

    func testRadarRowPicksStrongestSignal() {
        // 优先级:keyOpportunity(1) 先于 startWatching(2),即使把握分更低。
        let analysis = MarketOpportunityAnalysis(
            assetClasses: [],
            markets: [],
            marketSectorOpportunities: [
                signal(name: "高股息红利", recommendation: .keyOpportunity, confidenceScore: 60),
                signal(name: "AI 算力链", recommendation: .startWatching, confidenceScore: 90)
            ],
            marketScanCompleted: true,
            generatedAt: "2026-08-19 09:00:12"
        )
        let summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: nil,
            marketAnalysis: analysis,
            trendReport: nil,
            currentTimestamp: now
        )
        let row = summary.rows.first { $0.kind == .marketRadar }
        XCTAssertEqual(row?.headline, "高股息红利 · 重点机会")
        // 带秒时间戳截取 "HH:mm",不是 "mm:ss"。
        XCTAssertEqual(row?.footnote, "共 2 个方向 · 更新 09:00")
    }

    func testRadarTieBreaksByConfidence() {
        let analysis = MarketOpportunityAnalysis(
            assetClasses: [
                signal(name: "黄金", recommendation: .keyOpportunity, confidenceScore: 80)
            ],
            markets: [
                signal(name: "沪深300", recommendation: .keyOpportunity, confidenceScore: 60)
            ],
            marketSectorOpportunities: [],
            marketScanCompleted: true,
            generatedAt: "2026-08-19 09:00:00"
        )
        XCTAssertEqual(
            InvestmentTodayResearchSummary.topSignal(analysis)?.name,
            "黄金"
        )
    }

    // MARK: 长期行

    func testLongTermRowUsesMediumHorizon() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-16 20:00:00",
            externalSignalStatus: .available
        )
        let summary = InvestmentTodayResearchSummary.make(
            closeReview: MarketCloseReviewSnapshot.make(
                report: nil, generationState: .idle, currentTimestamp: now
            ),
            closeReviewTitle: "今日收盘复盘",
            intraday: nil,
            marketAnalysis: nil,
            trendReport: report,
            currentTimestamp: now
        )
        let row = summary.rows.first { $0.kind == .longTerm }
        XCTAssertNotNil(row, "fixture 含 medium horizon,应产出长期行")
        XCTAssertTrue(row?.headline.hasPrefix("中性 ·") ?? false)
        XCTAssertEqual(row?.footnote, "生成于 2026-08-16")
    }

    // MARK: 行序

    func testRowOrderIsStable() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-19 21:03:00",
            externalSignalStatus: .available
        )
        let closeReview = MarketCloseReviewSnapshot.make(
            report: report,
            generationState: .succeeded,
            currentTimestamp: now
        )
        let analysis = MarketOpportunityAnalysis(
            assetClasses: [signal(name: "黄金", recommendation: .keyOpportunity, confidenceScore: 80)],
            markets: [],
            marketSectorOpportunities: [],
            marketScanCompleted: true,
            generatedAt: "2026-08-19 09:00:00"
        )
        let summary = InvestmentTodayResearchSummary.make(
            closeReview: closeReview,
            closeReviewTitle: "今日收盘复盘",
            intraday: intradayReport(validUntil: "22:30"),
            marketAnalysis: analysis,
            trendReport: report,
            currentTimestamp: now
        )
        XCTAssertEqual(
            summary.rows.map(\.kind),
            [.closeReview, .intraday, .marketRadar, .longTerm]
        )
    }
}
