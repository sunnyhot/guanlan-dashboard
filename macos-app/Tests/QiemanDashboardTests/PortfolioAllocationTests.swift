import XCTest
@testable import QiemanDashboard

final class PortfolioAllocationTests: XCTestCase {
    func testDistributionGroupsFundsAndStocksByDirectHoldingType() throws {
        let rows = [
            makeRow(
                code: "000001",
                name: "场外基金",
                assetType: .fund,
                marketValue: 60_000,
                fundMarket: .offExchange
            ),
            makeRow(
                code: "ETF:510300",
                name: "场内基金",
                assetType: .fund,
                marketValue: 20_000,
                fundMarket: .onExchange
            ),
            makeRow(
                code: "600519",
                name: "A 股",
                assetType: .stock,
                marketValue: 15_000,
                stockMarket: .aShare
            ),
            makeRow(
                code: "US:AAPL",
                name: "美股",
                assetType: .stock,
                marketValue: 5_000,
                stockMarket: .us
            )
        ]

        let summary = try XCTUnwrap(
            PortfolioAssetDistributionSummary.make(rows: rows)
        )

        XCTAssertEqual(summary.totalExposure, 100_000, accuracy: 0.001)
        XCTAssertEqual(summary.items.map(\.category), [
            .offExchangeFund,
            .onExchangeFund,
            .aShareStock,
            .usStock,
        ])
        XCTAssertEqual(summary.items.map(\.weightPct), [60, 20, 15, 5])
        XCTAssertEqual(summary.items.map(\.assetCount), [1, 1, 1, 1])
    }

    func testDistributionUsesEffectiveExposureAndIgnoresEmptyRows() throws {
        let pending = PersonalPendingTrade(
            occurredAt: "2026-07-29 10:00:00",
            actionLabel: "买入",
            fundName: "买入中基金",
            fundCode: "000002",
            amountText: "2000",
            amountValue: 2_000,
            status: "买入中",
            note: nil
        )
        let pendingRow = PersonalAssetAggregateRow(
            key: "pending",
            assetType: .fund,
            fundName: "买入中基金",
            fundCode: "000002",
            holdingRow: nil,
            rawHolding: nil,
            archivedHolding: nil,
            pendingTrades: [pending],
            plans: []
        )
        let emptyRow = PersonalAssetAggregateRow(
            key: "empty",
            assetType: .fund,
            fundName: "空记录",
            fundCode: "000003",
            holdingRow: nil,
            rawHolding: nil,
            archivedHolding: nil,
            pendingTrades: [],
            plans: []
        )

        let summary = try XCTUnwrap(
            PortfolioAssetDistributionSummary.make(rows: [pendingRow, emptyRow])
        )

        XCTAssertEqual(summary.totalExposure, 2_000, accuracy: 0.001)
        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items.first?.category, .offExchangeFund)
        XCTAssertEqual(summary.items.first?.assetCount, 1)
        XCTAssertEqual(summary.items.first?.weightPct, 100)
    }

    private func makeRow(
        code: String,
        name: String,
        assetType: PersonalAssetType,
        marketValue: Double,
        stockMarket: StockMarket? = nil,
        fundMarket: FundMarket? = nil
    ) -> PersonalAssetAggregateRow {
        let holding = UserPortfolioHolding(
            fundCode: code,
            assetType: assetType,
            units: 10_000,
            costPrice: 1,
            displayName: name,
            stockMarket: stockMarket,
            fundMarket: fundMarket
        )
        let valuation = UserPortfolioValuationRow(
            holding: holding,
            fundName: name,
            currentPrice: nil,
            priceTime: nil,
            priceSource: nil,
            officialNav: nil,
            officialNavDate: nil,
            estimatePrice: nil,
            estimatePriceTime: nil,
            marketValue: marketValue,
            costValue: nil,
            profitAmount: nil,
            profitPct: nil,
            estimateChangePct: nil
        )
        return PersonalAssetAggregateRow(
            key: code,
            assetType: assetType,
            fundName: name,
            fundCode: code,
            holdingRow: valuation,
            rawHolding: holding,
            archivedHolding: nil,
            pendingTrades: [],
            plans: []
        )
    }
}
