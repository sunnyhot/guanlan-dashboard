import XCTest
@testable import QiemanDashboard

final class PersonalAssetDetailSummaryTests: XCTestCase {
    func testMakeSummaryPrioritizesPendingTradeBeforeActivePlan() {
        let row = assetRow(
            pendingTrades: [
                PersonalPendingTrade(
                    occurredAt: "2026-06-05 09:30",
                    actionLabel: "买入",
                    fundName: "易方达沪深300",
                    fundCode: "110020",
                    amountText: "500.00",
                    amountValue: 500,
                    status: "待确认"
                )
            ],
            plans: [
                PersonalInvestmentPlan(
                    planTypeLabel: "智能定投",
                    fundName: "易方达沪深300",
                    fundCode: "110020",
                    scheduleText: "每周三",
                    amountText: "200.00",
                    nextExecutionDate: "2026-06-10",
                    status: "进行中"
                )
            ]
        )

        let summary = PersonalAssetDetailSummary.make(row: row)

        XCTAssertEqual(summary.title, "易方达沪深300")
        XCTAssertEqual(summary.attentionItems.map(\.kind), [.pendingTrade, .investmentPlan])
        XCTAssertEqual(summary.attentionItems.first?.metric, "¥500.00")
        XCTAssertEqual(summary.attentionItems.last?.metric, "¥200.00")
        XCTAssertEqual(
            summary.metrics.map(\.title),
            ["总收益", row.changePeriodTitle, "单位净值", "持仓成本", "待确认", "下次计划"]
        )
        XCTAssertEqual(summary.metrics[2].value, "1.3000")
        XCTAssertEqual(summary.metrics[2].detail, "更新 06-05 15:00")
    }

    func testMakeSummaryIncludesArchivedHoldingAttentionForArchivedOnlyRow() {
        let archivedHolding = UserPortfolioHolding(
            fundCode: "110020",
            assetType: .fund,
            units: 100,
            costPrice: 1.2,
            displayName: "易方达沪深300",
            isArchived: true,
            archivedAt: "2026-06-01 10:00"
        )
        let row = PersonalAssetAggregateRow(
            key: "110020",
            assetType: .fund,
            fundName: "易方达沪深300",
            fundCode: "110020",
            holdingRow: nil,
            rawHolding: nil,
            archivedHolding: archivedHolding,
            pendingTrades: [],
            plans: []
        )

        let summary = PersonalAssetDetailSummary.make(row: row)

        XCTAssertEqual(summary.statusText, "已归档")
        XCTAssertEqual(summary.attentionItems.map(\.kind), [.archivedHolding])
        XCTAssertEqual(summary.attentionItems.first?.detail, "归档于 2026-06-01")
    }

    private func assetRow(
        pendingTrades: [PersonalPendingTrade],
        plans: [PersonalInvestmentPlan]
    ) -> PersonalAssetAggregateRow {
        let holding = UserPortfolioHolding(
            fundCode: "110020",
            assetType: .fund,
            units: 100,
            costPrice: 1.2,
            displayName: "易方达沪深300"
        )
        let valuationRow = UserPortfolioValuationRow(
            holding: holding,
            fundName: "易方达沪深300",
            currentPrice: 1.3,
            priceTime: "2026-06-05 15:00",
            priceSource: nil,
            officialNav: nil,
            officialNavDate: nil,
            estimatePrice: 1.31,
            estimatePriceTime: "2026-06-05 14:45",
            marketValue: 130,
            costValue: 120,
            profitAmount: 10,
            profitPct: 8.33,
            estimateChangePct: 0.77
        )
        return PersonalAssetAggregateRow(
            key: "110020",
            assetType: .fund,
            fundName: "易方达沪深300",
            fundCode: "110020",
            holdingRow: valuationRow,
            rawHolding: holding,
            archivedHolding: nil,
            pendingTrades: pendingTrades,
            plans: plans
        )
    }
}
