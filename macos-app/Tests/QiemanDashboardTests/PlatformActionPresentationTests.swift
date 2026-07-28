import XCTest
@testable import QiemanDashboard

final class PlatformActionPresentationTests: XCTestCase {
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

    private func action(
        id: String,
        side: String,
        fundName: String,
        fundCode: String,
        title: String
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
            txnDate: nil,
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
