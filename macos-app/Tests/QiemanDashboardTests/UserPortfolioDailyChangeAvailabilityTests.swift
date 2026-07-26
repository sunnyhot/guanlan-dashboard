import XCTest
@testable import QiemanDashboard

final class UserPortfolioDailyChangeAvailabilityTests: XCTestCase {
    func testMissingDailyChangeFormattingUsesPendingCopy() {
        XCTAssertEqual(dailyChangeCurrencyText(nil), "待公布")
        XCTAssertEqual(dailyChangePercentText(nil), "待公布")
        XCTAssertEqual(dailyChangeCurrencyText(12.34), "¥+12.34")
        XCTAssertEqual(dailyChangePercentText(-1.2), "-1.20%")
    }

    func testRefreshNoticeExplainsThatTodayNAVIsPending() {
        let snapshot = makeSnapshot([
            row(code: "000001", navDate: "2026-07-17", changePct: nil),
            row(code: "000002", navDate: "2026-07-16", changePct: nil),
        ])

        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 0)
        XCTAssertEqual(snapshot.dailyChangePendingCount, 2)
        XCTAssertEqual(snapshot.latestOfficialNavDate, "2026-07-17")
        XCTAssertEqual(
            snapshot.refreshNoticeMessage,
            "持仓净值已刷新至 2026-07-17；涨跌数据待公布。"
        )
    }

    func testRefreshNoticeReportsPartialTodayChangeCoverage() {
        let snapshot = makeSnapshot([
            row(code: "000001", navDate: "2026-07-20", changePct: 1),
            row(code: "000002", navDate: "2026-07-17", changePct: nil),
        ])

        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
        XCTAssertEqual(snapshot.dailyChangePendingCount, 1)
        XCTAssertEqual(
            snapshot.refreshNoticeMessage,
            "个人持仓已刷新；涨跌已更新 1/2，其余待公布。"
        )
    }

    func testChangeTitleDistinguishesCurrentAndLatestTradingDay() {
        let current = makeSnapshot([
            row(code: "000001", navDate: "2026-07-20", changePct: 1),
        ])
        let latest = makeSnapshot([
            row(code: "000001", navDate: "2026-07-17", changePct: 1),
        ])

        XCTAssertEqual(current.dailyChangeTitle(marketDate: "2026-07-20"), "今日涨跌")
        XCTAssertEqual(latest.dailyChangeTitle(marketDate: "2026-07-20"), "最近涨跌")
    }

    private func makeSnapshot(_ rows: [UserPortfolioValuationRow]) -> UserPortfolioSnapshot {
        UserPortfolioSnapshot(
            rows: rows,
            refreshedAt: "2026-07-20 16:52:41",
            totalMarketValue: rows.compactMap(\.marketValue).reduce(0, +),
            totalCostValue: nil,
            totalProfitAmount: nil,
            totalProfitPct: nil
        )
    }

    private func row(code: String, navDate: String, changePct: Double?) -> UserPortfolioValuationRow {
        let holding = UserPortfolioHolding(
            fundCode: code,
            assetType: .fund,
            units: 100,
            costPrice: 1,
            displayName: "测试基金 \(code)",
            fundMarket: .offExchange
        )
        return UserPortfolioValuationRow(
            holding: holding,
            fundName: holding.displayName ?? code,
            currentPrice: 1,
            priceTime: navDate,
            priceSource: "最近净值",
            officialNav: 1,
            officialNavDate: navDate,
            estimatePrice: nil,
            estimatePriceTime: nil,
            marketValue: 100,
            costValue: 100,
            profitAmount: 0,
            profitPct: 0,
            estimateChangePct: changePct
        )
    }
}
