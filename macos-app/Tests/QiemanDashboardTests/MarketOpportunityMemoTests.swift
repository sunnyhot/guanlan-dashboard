import XCTest
@testable import QiemanDashboard

// MARK: - 「全市场机会」分析 memo 测试(P1 #9)
//
// 面板与摘要卡共用 AppModel.marketOpportunities;输入(报告 id/generatedAt +
// 雷达模块时间)未变时必须复用,变化时必须重算。

@MainActor
final class MarketOpportunityMemoTests: XCTestCase {
    func testSameInputReusesMemoAndInputChangeInvalidates() {
        let model = AppModel()
        model.trendReport = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-19 09:00:00",
            externalSignalStatus: .available
        )

        _ = model.marketOpportunities
        XCTAssertEqual(model.marketOpportunityMemoHitCount, 0, "首次调用应重算")

        _ = model.marketOpportunities
        XCTAssertEqual(model.marketOpportunityMemoHitCount, 1, "同输入第二次应命中缓存")

        model.trendReport?.generatedAt = "2026-08-19 09:30:00"
        _ = model.marketOpportunities
        XCTAssertEqual(model.marketOpportunityMemoHitCount, 1, "输入变化应重算,不命中")

        _ = model.marketOpportunities
        XCTAssertEqual(model.marketOpportunityMemoHitCount, 2, "变化后同输入再次命中")
    }

    func testNilReportIsAlsoMemoized() {
        let model = AppModel()
        XCTAssertNil(model.marketOpportunities)
        XCTAssertNil(model.marketOpportunities)
        XCTAssertEqual(model.marketOpportunityMemoHitCount, 1, "无报告同样走缓存")
    }
}
