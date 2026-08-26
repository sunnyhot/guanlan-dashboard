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

}
