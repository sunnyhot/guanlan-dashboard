import XCTest
@testable import QiemanDashboard

final class TodayBriefBuilderTests: XCTestCase {
    func testMakeItemsPrioritizesActionablePortfolioSignals() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            pendingActionCount: 3,
            pendingCashAmount: 710.93,
            activePlanCount: 6,
            nextExecutionDate: "2026-06-10",
            dailyChangeAmount: -120.5,
            dailyChangePct: -0.42,
            largestMovementName: "沪深300增强",
            largestMovementAmount: -88.2,
            largestMovementPct: -1.6,
            latestPlatformTitle: "买入中证红利",
            latestPlatformDate: "2026-06-03",
            latestForumTitle: "本周组合观察",
            latestForumDate: "2026-06-03",
            managerWatchEnabled: true,
            managerWatchScopeText: "LONG_WIN · ETF拯救世界 · 调仓 + 发言",
            managerWatchError: nil
        )

        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)

        XCTAssertEqual(
            items.map(\.kind),
            [.pendingTrades, .investmentPlan, .dailyChange, .largestMovement]
        )
        XCTAssertEqual(items.first?.metric, "¥710.93")
    }

    func testMakeItemsShowsSetupWhenPortfolioIsMissing() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: false
        )

        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)

        XCTAssertEqual(items.map(\.kind), [.importPortfolio])
        XCTAssertEqual(items.first?.destination, .portfolio)
    }

    // MARK: - W3.5 错过窗口与连续失败升级

    func testMissedLongTermSurfacesAsActionableEntry() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            missedLongTerm: true
        )
        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)
        let missed = items.first { $0.kind == .longTermMissed }
        XCTAssertEqual(missed?.destination, .aiResearch)
        XCTAssertEqual(missed?.tone, .warning)
        XCTAssertTrue(missed?.detail.contains("补做") ?? false)
    }

    func testRepeatedAutoFailureEscalatesWithReason() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            autoFailureScopeName: "今日收盘复盘",
            autoFailureStreakCount: 3,
            autoFailureReasonText: "Key 无效或过期"
        )
        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)
        let failure = items.first { $0.kind == .autoAnalysisRepeatedFailure }
        XCTAssertNotNil(failure, "连击 ≥ 2 必须升级提示")
        XCTAssertEqual(failure?.tone, .danger)
        XCTAssertTrue(failure?.title.contains("3") ?? false)
        XCTAssertTrue(failure?.detail.contains("今日收盘复盘") ?? false)
        XCTAssertTrue(failure?.detail.contains("Key 无效或过期") ?? false)
    }

    func testSingleFailureStreakDoesNotEscalate() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            autoFailureScopeName: "今日收盘复盘",
            autoFailureStreakCount: 1
        )
        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)
        XCTAssertFalse(items.contains { $0.kind == .autoAnalysisRepeatedFailure })
    }

    func testMakeItemsSurfacesMissedCloseReviewAsActionableWarning() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            pendingActionCount: 1,
            closeReviewAutoMissed: true
        )

        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)

        XCTAssertTrue(items.contains { $0.kind == .closeReviewMissed })
        let missed = items.first { $0.kind == .closeReviewMissed }
        XCTAssertEqual(missed?.destination, .aiResearch)
        XCTAssertEqual(missed?.tone, .warning)
        // 排在待确认交易之后、计划之前：需要处理但不是资金动作。
        XCTAssertEqual(
            items.map(\.kind),
            [.pendingTrades, .closeReviewMissed]
        )
    }

    func testMakeItemsOmitsCloseReviewEntryWhenTonightRanOrIsPending() {
        let context = TodayBriefContext(
            hasPersonalPortfolio: true,
            closeReviewAutoMissed: false
        )

        let items = TodayBriefBuilder.makeItems(context: context, maxCount: 4)

        XCTAssertFalse(items.contains { $0.kind == .closeReviewMissed })
    }
}
