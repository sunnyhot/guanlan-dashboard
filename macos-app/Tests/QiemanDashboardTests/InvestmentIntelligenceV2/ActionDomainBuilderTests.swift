import XCTest
@testable import QiemanDashboard

/// DEC-4 单元测试：ActionDomainBuilder 的搜索空间裁剪。
final class ActionDomainBuilderTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }

    private var portfolio: PortfolioSnapshot {
        PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(subjectKey: "fund|A", assetClass: .equity, weight: r("0.5")),
            PortfolioPosition(subjectKey: "fund|B", assetClass: .fixedIncome, weight: r("0.3")),
        ])
    }

    func testExistingPositionsGetSellLowerAndBuyUpper() {
        let domain = ActionDomainBuilder(parameters: .init(buyHeadroom: r("0.1")))
            .buildActionDomain(portfolio: portfolio)

        let a = domain.perSubjectBounds["fund|A"]!
        XCTAssertEqual(a.lower.value, Decimal(string: "-0.5"), "卖出下界 = −当前权重")
        XCTAssertEqual(a.upper.value, Decimal(string: "0.1"))

        // 域内判定:边界含
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("-0.5"))))
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("-0.5000001"))) == false)
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("0.1"))))
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("0.1000001"))))
    }

    func testNewSubjectsExcludedByDefault_searchSpacePruned() {
        // 默认参数:新标的不在域内(裁剪的核心语义)
        let domain = ActionDomainBuilder().buildActionDomain(portfolio: portfolio)
        XCTAssertTrue(domain.eligibleNewSubjects.isEmpty)
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.05"))))
        // 无 headroom:增持上界为 0
        XCTAssertEqual(domain.perSubjectBounds["fund|A"]?.upper.value, 0)
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("0.01"))))
    }

    func testWhitelistedNewSubjectsBuyOnly() {
        let domain = ActionDomainBuilder(parameters: .init(
            eligibleNewSubjects: ["listing|NEW": .equity],
            buyHeadroom: r("0.1")
        )).buildActionDomain(portfolio: portfolio)

        XCTAssertEqual(domain.eligibleNewSubjects["listing|NEW"], .equity)
        // 白名单新标的:买入(> 0 且 ≤ headroom)允许
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.05"))))
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.1"))))
        // 卖出 / 超额不允许
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("-0.01"))))
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.11"))))
        // 非白名单新标的仍然排除
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "listing|OTHER", deltaWeight: r("0.05"))))
    }

    func testWhitelistedExistingSubjectGoesThroughExistingBranch() {
        // 白名单里含既有标的:走既有持仓分支(可卖),不进 eligibleNewSubjects
        let domain = ActionDomainBuilder(parameters: .init(
            eligibleNewSubjects: ["fund|A": .equity],
            buyHeadroom: r("0.1")
        )).buildActionDomain(portfolio: portfolio)
        XCTAssertNil(domain.eligibleNewSubjects["fund|A"])
        XCTAssertEqual(domain.eligibleNewSubjects.count, 0)
        XCTAssertTrue(domain.contains(action: PortfolioAction(subjectKey: "fund|A", deltaWeight: r("-0.2"))))
    }

    func testZeroWeightPositionCannotSell() {
        // 权重 0 的持仓:卖出下界 0(没有可卖)
        let zeroPortfolio = PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(subjectKey: "fund|Z", assetClass: .cash, weight: r("0")),
        ])
        let domain = ActionDomainBuilder(parameters: .init(buyHeadroom: r("0.2")))
            .buildActionDomain(portfolio: zeroPortfolio)
        XCTAssertEqual(domain.perSubjectBounds["fund|Z"]?.lower.value, 0)
        XCTAssertFalse(domain.contains(action: PortfolioAction(subjectKey: "fund|Z", deltaWeight: r("-0.01"))))
    }

    func testDeterministicAndCodable() throws {
        let builder = ActionDomainBuilder(parameters: .init(buyHeadroom: r("0.1")))
        let a = builder.buildActionDomain(portfolio: portfolio)
        let b = builder.buildActionDomain(portfolio: portfolio)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.builderVersion, "v1")

        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(ActionDomain.self, from: data)
        XCTAssertEqual(decoded, a)
    }
}
