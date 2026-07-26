import XCTest
@testable import QiemanDashboard

final class UserPortfolioDropdownQuoteTests: XCTestCase {
    func testStockUsesRealtimeQuote() {
        let row = valuationRow(
            fundCode: "600519",
            assetType: .stock,
            stockMarket: .aShare,
            currentPrice: 1520.5,
            priceTime: "2026-06-17 14:30",
            officialNav: 1500,
            officialNavDate: "2026-06-16",
            estimatePrice: 1530
        )

        let quote = row.dropdownQuote(marketDate: "2026-06-17")

        XCTAssertEqual(quote.label, "实时净值")
        XCTAssertEqual(quote.price, 1520.5)
        XCTAssertEqual(quote.trimmedTime, "2026-06-17 14:30")
        XCTAssertEqual(quote.compactText, "实时 1520.5000")
    }

    func testOnExchangeFundUsesRealtimeQuote() {
        let row = valuationRow(
            fundCode: "510300",
            fundMarket: .onExchange,
            currentPrice: 4.321,
            priceTime: "2026-06-17 14:31",
            officialNav: 4.2,
            officialNavDate: "2026-06-16",
            estimatePrice: 4.4
        )

        let quote = row.dropdownQuote(marketDate: "2026-06-17")

        XCTAssertEqual(quote.label, "实时净值")
        XCTAssertEqual(quote.price, 4.321)
        XCTAssertEqual(quote.trimmedTime, "2026-06-17 14:31")
        XCTAssertEqual(quote.compactText, "实时 4.3210")
    }

    func testStockUsesLatestQuoteAfterMarketClose() {
        let row = valuationRow(
            fundCode: "600519",
            assetType: .stock,
            stockMarket: .aShare,
            currentPrice: 1520.5,
            priceTime: "2026-06-16 15:00",
            officialNav: 1500,
            officialNavDate: "2026-06-16",
            estimateChangePct: 1.37
        )

        let quote = row.dropdownQuote(marketDate: "2026-06-17")

        XCTAssertEqual(quote.label, "最新净值")
        XCTAssertEqual(quote.price, 1520.5)
        XCTAssertEqual(quote.trimmedTime, "2026-06-16 15:00")
        XCTAssertEqual(row.changePeriodTitle(marketDate: "2026-06-17"), "最近涨跌")
    }

    func testOffExchangeFundUsesEstimateBeforeTodayNav() {
        let row = valuationRow(
            fundCode: "000001",
            fundMarket: .offExchange,
            officialNav: 1.2,
            officialNavDate: "2026-06-16",
            estimatePrice: 1.2345,
            estimatePriceTime: "2026-06-17 14:45"
        )

        let quote = row.dropdownQuote(marketDate: "2026-06-17")

        XCTAssertEqual(quote.label, "预估净值")
        XCTAssertEqual(quote.price, 1.2345)
        XCTAssertEqual(quote.trimmedTime, "2026-06-17 14:45")
        XCTAssertEqual(quote.compactText, "预估 1.2345")
    }

    func testOffExchangeFundUsesConfirmedQuoteAfterTodayNav() {
        let row = valuationRow(
            fundCode: "000001",
            fundMarket: .offExchange,
            officialNav: 1.2368,
            officialNavDate: "2026-06-17",
            estimatePrice: 1.2345,
            estimatePriceTime: "2026-06-17 14:45"
        )

        let quote = row.dropdownQuote(marketDate: "2026-06-17")

        XCTAssertEqual(quote.label, "确认净值")
        XCTAssertEqual(quote.price, 1.2368)
        XCTAssertEqual(quote.trimmedTime, "2026-06-17")
        XCTAssertEqual(quote.compactText, "确认 1.2368")
    }

    private func valuationRow(
        fundCode: String,
        assetType: PersonalAssetType = .fund,
        stockMarket: StockMarket? = nil,
        fundMarket: FundMarket? = nil,
        currentPrice: Double? = nil,
        priceTime: String? = nil,
        priceSource: String? = nil,
        officialNav: Double? = nil,
        officialNavDate: String? = nil,
        estimatePrice: Double? = nil,
        estimatePriceTime: String? = nil,
        estimateChangePct: Double? = nil
    ) -> UserPortfolioValuationRow {
        let holding = UserPortfolioHolding(
            fundCode: fundCode,
            assetType: assetType,
            units: 100,
            costPrice: 1,
            displayName: "测试标的",
            stockMarket: stockMarket,
            fundMarket: fundMarket
        )

        return UserPortfolioValuationRow(
            holding: holding,
            fundName: "测试标的",
            currentPrice: currentPrice,
            priceTime: priceTime,
            priceSource: priceSource,
            officialNav: officialNav,
            officialNavDate: officialNavDate,
            estimatePrice: estimatePrice,
            estimatePriceTime: estimatePriceTime,
            marketValue: nil,
            costValue: nil,
            profitAmount: nil,
            profitPct: nil,
            estimateChangePct: estimateChangePct
        )
    }
}
