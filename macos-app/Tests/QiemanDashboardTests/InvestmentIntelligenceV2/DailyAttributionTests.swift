import XCTest
@testable import QiemanDashboard

/// ATTR-2 单元测试：DailyAttribution artifact（immutableHistorical + 确定性 id）。
final class DailyAttributionTests: XCTestCase {

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeResult() -> AttributionResult {
        AttributionEngine().compute(
            positions: [
                .init(subject: .fund(FundProductID(rawValue: "A")), weight: r("0.6"),
                      periodReturn: r("0.1"),
                      sourceObservationID: ObservationID(rawValue: "nav_a")),
                .init(subject: .listing(ListingID(rawValue: "L1")), weight: r("0.4"),
                      periodReturn: r("-0.05"),
                      sourceObservationID: ObservationID(rawValue: "bar_l1")),
            ],
            portfolioReturn: r("0.045")
        )!
    }

    func testValidityPolicyIsImmutableHistorical() {
        let artifact = DailyAttribution(
            attributionDate: day, portfolioKey: "qieman:LONG_WIN",
            result: makeResult(), producedAt: day
        )
        XCTAssertEqual(artifact.validityPolicy, .immutableHistorical)
        // 历史归因在任何查询时点都有效
        XCTAssertTrue(artifact.validityPolicy.isStillValid(at: day.addingTimeInterval(86400 * 365)))
    }

    func testDependenciesCoverContributionSources() {
        let artifact = DailyAttribution(
            attributionDate: day, portfolioKey: "qieman:LONG_WIN",
            result: makeResult(), producedAt: day
        )
        XCTAssertEqual(artifact.dependencies.map(\.referenceID), ["bar_l1", "nav_a"], "排序稳定")
        XCTAssertTrue(artifact.dependencies.allSatisfy { $0.kind == .observation })
    }

    func testDeterministicId_sameInputsSameId() {
        let a = DailyAttribution(attributionDate: day, portfolioKey: "p1", result: makeResult(), producedAt: day)
        let b = DailyAttribution(attributionDate: day, portfolioKey: "p1", result: makeResult(), producedAt: day)
        XCTAssertEqual(a.id, b.id)

        // producedAt 不参与 id(重算幂等的核心:产出时间不同不产生新身份)
        let later = DailyAttribution(
            attributionDate: day, portfolioKey: "p1", result: makeResult(),
            producedAt: day.addingTimeInterval(86400)
        )
        XCTAssertEqual(a.id, later.id)

        // 组合 / 日期 / 内容任一变化 → 新 id
        XCTAssertNotEqual(a.id, DailyAttribution(
            attributionDate: day, portfolioKey: "p2", result: makeResult(), producedAt: day
        ).id)
        XCTAssertNotEqual(a.id, DailyAttribution(
            attributionDate: day.addingTimeInterval(86400), portfolioKey: "p1",
            result: makeResult(), producedAt: day
        ).id)
        let differentResult = AttributionEngine().compute(
            positions: [
                .init(subject: .fund(FundProductID(rawValue: "A")), weight: r("0.5"),
                      periodReturn: r("0.1"),
                      sourceObservationID: ObservationID(rawValue: "nav_a")),
                .init(subject: .listing(ListingID(rawValue: "L1")), weight: r("0.5"),
                      periodReturn: r("0.05"),
                      sourceObservationID: ObservationID(rawValue: "bar_l1")),
            ],
            portfolioReturn: nil
        )!
        XCTAssertNotEqual(a.id, DailyAttribution(
            attributionDate: day, portfolioKey: "p1", result: differentResult, producedAt: day
        ).id)
    }

    func testCodableRoundTrip() throws {
        let artifact = DailyAttribution(
            attributionDate: day, portfolioKey: "qieman:LONG_WIN",
            result: makeResult(), producedAt: day
        )
        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(DailyAttribution.self, from: data)
        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.result.contributions.count, 2)
        XCTAssertEqual(decoded.result.residual?.value, Decimal(string: "0.005"))
    }
}
