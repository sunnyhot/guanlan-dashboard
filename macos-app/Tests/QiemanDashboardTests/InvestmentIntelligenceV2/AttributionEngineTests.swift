import XCTest
@testable import QiemanDashboard

/// ATTR-1 单元测试：AttributionEngine 的 contribution / coverage / residual 数学。
final class AttributionEngineTests: XCTestCase {

    private func fund(_ id: String) -> AttributionSubject { .fund(FundProductID(rawValue: id)) }
    private func listing(_ id: String) -> AttributionSubject { .listing(ListingID(rawValue: id)) }
    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }

    // MARK: - 核心数学(golden)

    func testTwoPositionContributionMath() {
        // A 60% 收益 +10%,B 40% 收益 −5%
        // attributed = 0.6×0.1 + 0.4×(−0.05) = 0.06 − 0.02 = 0.04;coverage = 1
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("A"), weight: r("0.6"), periodReturn: r("0.1")),
                .init(subject: fund("B"), weight: r("0.4"), periodReturn: r("-0.05")),
            ],
            portfolioReturn: nil
        )!

        XCTAssertEqual(result.attributedReturn.value, Decimal(string: "0.04"))
        XCTAssertEqual(result.coverage.value, 1)
        XCTAssertEqual(result.unattributedWeight.value, 0)
        XCTAssertNil(result.residual)

        // 贡献排序:|0.06| > |−0.02| → A 在前
        XCTAssertEqual(result.contributions.map(\.subject.stableKey), ["fund|A", "fund|B"])
        XCTAssertEqual(result.contributions[0].contribution.value, Decimal(string: "0.06"))
        XCTAssertEqual(result.contributions[1].contribution.value, Decimal(string: "-0.02"))
    }

    func testCoverageGapWhenReturnUnknown() {
        // A 60% 已知 +10%;B 40% 未知(不猜)
        // attributed = 0.06;coverage = 0.6;unattributed = 0.4
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("A"), weight: r("0.6"), periodReturn: r("0.1")),
                .init(subject: fund("B"), weight: r("0.4"), periodReturn: nil),
            ],
            portfolioReturn: nil
        )!
        XCTAssertEqual(result.attributedReturn.value, Decimal(string: "0.06"))
        XCTAssertEqual(result.coverage.value, Decimal(string: "0.6"))
        XCTAssertEqual(result.unattributedWeight.value, Decimal(string: "0.4"))
        XCTAssertEqual(result.contributions.count, 1, "未知成分不进 contributions")
    }

    func testResidualWhenPortfolioReturnProvided() {
        // 同上(coverage 0.6),组合实际 +8% → residual = 0.08 − 0.06 = 0.02
        // (含未知成分 B 的隐含贡献;Renderer 负责明示语义)
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("A"), weight: r("0.6"), periodReturn: r("0.1")),
                .init(subject: fund("B"), weight: r("0.4"), periodReturn: nil),
            ],
            portfolioReturn: r("0.08")
        )!
        XCTAssertEqual(result.residual?.value, Decimal(string: "0.02"))
    }

    // MARK: - 边界

    func testNegativeAttributionDay() {
        // 全下跌:A 50% −3%,B 50% −1% → attributed = −0.02
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("A"), weight: r("0.5"), periodReturn: r("-0.03")),
                .init(subject: fund("B"), weight: r("0.5"), periodReturn: r("-0.01")),
            ],
            portfolioReturn: nil
        )!
        XCTAssertEqual(result.attributedReturn.value, Decimal(string: "-0.02"))
    }

    func testWeightNormalization() {
        // 权重 3:1(和 4)等价 0.75:0.25
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: listing("L1"), weight: r("3"), periodReturn: r("0.08")),
                .init(subject: listing("L2"), weight: r("1"), periodReturn: r("0.04")),
            ],
            portfolioReturn: nil
        )!
        XCTAssertEqual(result.contributions[0].contribution.value, Decimal(string: "0.06"))
        XCTAssertEqual(result.contributions[1].contribution.value, Decimal(string: "0.01"))
        XCTAssertEqual(result.attributedReturn.value, Decimal(string: "0.07"))
        XCTAssertEqual(result.contributions[0].weight.value, Decimal(string: "0.75"))
    }

    func testEmptyOrZeroWeightReturnsNil() {
        XCTAssertNil(AttributionEngine().compute(positions: [], portfolioReturn: nil))
        XCTAssertNil(AttributionEngine().compute(
            positions: [.init(subject: fund("A"), weight: r("0"), periodReturn: r("0.1"))],
            portfolioReturn: nil
        ))
    }

    func testAllUnknownYieldsZeroAttributionFullGap() {
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("A"), weight: r("0.5"), periodReturn: nil),
                .init(subject: fund("B"), weight: r("0.5"), periodReturn: nil),
            ],
            portfolioReturn: r("0.03")
        )!
        XCTAssertEqual(result.attributedReturn.value, 0)
        XCTAssertEqual(result.coverage.value, 0)
        XCTAssertEqual(result.unattributedWeight.value, 1)
        XCTAssertEqual(result.residual?.value, Decimal(string: "0.03"), "未知日 residual 承载全部组合收益")
        XCTAssertTrue(result.contributions.isEmpty)
    }

    // MARK: - 确定性 / Codable

    func testDeterministicOutput() {
        let positions = [
            AttributionPositionInput(subject: fund("A"), weight: r("0.6"), periodReturn: r("0.02")),
            AttributionPositionInput(subject: fund("B"), weight: r("0.4"), periodReturn: r("-0.01")),
        ]
        let a = AttributionEngine().compute(positions: positions, portfolioReturn: r("0.005"))!
        let b = AttributionEngine().compute(positions: positions, portfolioReturn: r("0.005"))!
        XCTAssertEqual(a, b)

        let data = try! JSONEncoder().encode(a)
        let decoded = try! JSONDecoder().decode(AttributionResult.self, from: data)
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(decoded.engineVersion, "v1")
    }

    func testContributionOrderingTieBreaks() {
        // 同 |contribution| 按 stableKey 升序(确定性)
        let result = AttributionEngine().compute(
            positions: [
                .init(subject: fund("B"), weight: r("0.5"), periodReturn: r("0.02")),
                .init(subject: fund("A"), weight: r("0.5"), periodReturn: r("-0.02")),
                .init(subject: fund("C"), weight: r("0.5"), periodReturn: r("0.04")),
            ],
            portfolioReturn: nil
        )!
        // |0.01| |−0.01| |0.02| → C 在前;A/B 同值按 key
        XCTAssertEqual(result.contributions.map(\.subject.stableKey), ["fund|C", "fund|A", "fund|B"])
    }
}
