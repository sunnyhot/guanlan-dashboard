import XCTest
@testable import QiemanDashboard

final class PlatformActionPresentationTests: XCTestCase {
    @MainActor
    func testMonthlySummaryIncludesCompleteHistoryAndFillsInactiveMonths() {
        let model = AppModel()
        let actions = [
            action(
                id: "history-buy",
                side: "buy",
                fundName: "宽基",
                fundCode: "000300",
                title: "买入宽基",
                txnDate: "2023-01-06"
            ),
            action(
                id: "history-sell",
                side: "sell",
                fundName: "宽基",
                fundCode: "000300",
                title: "卖出宽基",
                txnDate: "2024-03-08"
            ),
        ]
        model.platformPayload = PlatformPayload(
            supported: true,
            prodCode: "LONG_WIN",
            count: actions.count,
            buyCount: 1,
            sellCount: 1,
            adjustmentCount: actions.count,
            latest: actions.last,
            actions: actions,
            holdings: nil,
            timeline: nil,
            error: nil
        )
        model._cachedMonthlyPlatformSummary = nil

        let summary = model.monthlyPlatformSummary

        XCTAssertEqual(summary.count, 15)
        XCTAssertEqual(summary.first?.month, "2023-01")
        XCTAssertEqual(summary.last?.month, "2024-03")
        XCTAssertEqual(summary.first?.buyCount, 1)
        XCTAssertEqual(summary.last?.sellCount, 1)
        XCTAssertEqual(summary.first(where: { $0.month == "2023-02" })?.totalCount, 0)
    }

    func testAdjustmentHistoryIsMergedIntoExpandedBrowserAsLineChart() throws {
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let overview = try source(at: "Views/Platform/PlatformMonthlyOverview.swift")

        XCTAssertFalse(platform.contains("交易时间总览"))
        XCTAssertFalse(platform.contains("isMonthlyExpanded"))
        XCTAssertTrue(platform.contains("PlatformMonthlyOverview(months: model.monthlyPlatformSummary)"))
        XCTAssertTrue(platform.contains("@State private var isAdjustmentDetailsExpanded = false"))
        XCTAssertTrue(platform.contains("Label(\"调仓明细\", systemImage: \"list.bullet.rectangle\")"))
        XCTAssertTrue(overview.contains("Text(\"完整历史\")"))
        XCTAssertTrue(overview.contains("LineMark("))
        XCTAssertFalse(overview.contains("BarMark("))
        XCTAssertFalse(overview.contains("近 12 个月"))
    }

    func testWorkspaceListWidthStaysReadableAcrossWideWindows() {
        XCTAssertEqual(PlatformWorkspaceLayout.listWidth(for: 900), 500)
        XCTAssertEqual(PlatformWorkspaceLayout.listWidth(for: 1_600), 576)
        XCTAssertEqual(PlatformWorkspaceLayout.listWidth(for: 2_400), 680)
        XCTAssertEqual(PlatformWorkspaceLayout.actionListHeight, 430)
        XCTAssertEqual(PlatformWorkspaceLayout.adjustmentWorkspaceHeight, 520)
    }

    func testForumListHeightFillsTallWorkspacesAndPreservesTheMinimumViewport() {
        XCTAssertEqual(PlatformWorkspaceLayout.forumListHeight(for: 500), 430)
        XCTAssertEqual(PlatformWorkspaceLayout.forumListHeight(for: 900), 776)
        XCTAssertEqual(PlatformWorkspaceLayout.forumListHeight(for: 1_200), 1_076)
    }

    func testCountsUseProvidedValuesWhenBothSidesAreKnown() {
        let actions = [
            action(id: "sell-1", side: "sell", fundName: "债券基金", fundCode: "000001", title: "卖出债券"),
            action(id: "sell-2", side: "sell", fundName: "红利低波", fundCode: "000922", title: "卖出红利")
        ]

        let counts = PlatformActionCounts.make(actions: actions, buyCount: 12, sellCount: 8)

        XCTAssertEqual(counts, PlatformActionCounts(all: 2, buy: 12, sell: 8))
    }

    func testPresentationFiltersBySideAndSearchAndPaginatesOnce() throws {
        let actions = [
            action(id: "buy-wide", side: "buy", fundName: "沪深300", fundCode: "000300", title: "买入宽基"),
            action(id: "sell-bond", side: "sell", fundName: "债券基金", fundCode: "000001", title: "卖出债券"),
            action(id: "buy-dividend", side: "buy", fundName: "红利低波", fundCode: "000922", title: "买入红利")
        ]

        let presentation = PlatformActionPresentation.make(
            actions: actions,
            sideFilter: .buy,
            searchText: "红利",
            currentPage: 0,
            pageSize: 10
        )

        XCTAssertEqual(presentation.counts.all, 3)
        XCTAssertEqual(presentation.counts.buy, 2)
        XCTAssertEqual(presentation.counts.sell, 1)
        XCTAssertEqual(presentation.filteredActions.map(\.id), ["buy-dividend"])
        XCTAssertEqual(presentation.pageActions.map(\.id), ["buy-dividend"])
        XCTAssertEqual(presentation.totalPages, 1)
        XCTAssertEqual(presentation.currentPage, 0)
    }

    func testPresentationClampsOutOfRangePage() {
        let actions = (0..<23).map {
            action(id: "action-\($0)", side: $0.isMultiple(of: 2) ? "buy" : "sell", fundName: "基金\($0)", fundCode: "\($0)", title: "调仓\($0)")
        }

        let presentation = PlatformActionPresentation.make(
            actions: actions,
            sideFilter: .all,
            searchText: "",
            currentPage: 9,
            pageSize: 10
        )

        XCTAssertEqual(presentation.totalPages, 3)
        XCTAssertEqual(presentation.currentPage, 2)
        XCTAssertEqual(presentation.pageActions.map(\.id), ["action-20", "action-21", "action-22"])
    }

    private func source(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func action(
        id: String,
        side: String,
        fundName: String,
        fundCode: String,
        title: String,
        txnDate: String? = nil
    ) -> PlatformActionPayload {
        PlatformActionPayload(
            actionKey: id,
            adjustmentId: nil,
            adjustmentTitle: title,
            title: title,
            actionTitle: title,
            fundName: fundName,
            fundCode: fundCode,
            side: side,
            action: side,
            tradeUnit: nil,
            postPlanUnit: nil,
            createdAt: nil,
            txnDate: txnDate,
            createdTs: nil,
            txnTs: nil,
            articleUrl: nil,
            comment: nil,
            strategyType: nil,
            largeClass: nil,
            buyDate: nil,
            nav: nil,
            navDate: nil,
            orderCountInAdjustment: nil,
            tradeValuation: nil,
            tradeValuationDate: nil,
            tradeValuationSource: nil,
            currentValuation: nil,
            currentValuationTime: nil,
            currentValuationSource: nil,
            valuationChangeAmount: nil,
            valuationChangePct: nil
        )
    }
}
