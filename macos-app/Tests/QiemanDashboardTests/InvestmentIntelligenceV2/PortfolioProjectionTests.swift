import XCTest
@testable import QiemanDashboard

/// DEC-3 单元测试：PortfolioSnapshot / ProjectedPortfolio 的投影语义。
final class PortfolioProjectionTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }

    private func position(_ key: String, _ cls: AssetClass, _ w: String) -> PortfolioPosition {
        PortfolioPosition(subjectKey: key, assetClass: cls, weight: r(w))
    }

    private var base: PortfolioSnapshot {
        PortfolioSnapshot(asOf: day, positions: [
            position("fund|A", .equity, "0.5"),
            position("fund|B", .fixedIncome, "0.3"),
            position("listing|L1", .equity, "0.1"),
        ])
    }

    // MARK: - Snapshot 基础

    func testSnapshotAggregatesAndCashGap() {
        let snapshot = base
        let weights = snapshot.assetClassWeights()
        XCTAssertEqual(weights[.equity]?.value, Decimal(string: "0.6"))
        XCTAssertEqual(weights[.fixedIncome]?.value, Decimal(string: "0.3"))
        XCTAssertEqual(snapshot.cashGap.value, Decimal(string: "0.1"), "1 − 0.9 现金缺口显式")
        // 持仓确定性排序
        XCTAssertEqual(snapshot.positions.map(\.subjectKey), ["fund|A", "fund|B", "listing|L1"])
    }

    // MARK: - 投影

    func testProjectAppliesDeltasAndMerges() {
        // A 减 0.2;L1 加 0.05;两动作同作用于 A 时合并
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [
                PortfolioAction(subjectKey: "fund|A", deltaWeight: r("-0.15")),
                PortfolioAction(subjectKey: "fund|A", deltaWeight: r("-0.05")),
                PortfolioAction(subjectKey: "listing|L1", deltaWeight: r("0.05")),
            ]
        )
        let byKey = Dictionary(uniqueKeysWithValues: projected.positions.map { ($0.subjectKey, $0) })
        XCTAssertEqual(byKey["fund|A"]?.weight.value, Decimal(string: "0.3"), "0.5 − 0.2(两动作合并)")
        XCTAssertEqual(byKey["fund|B"]?.weight.value, Decimal(string: "0.3"), "无动作原样")
        XCTAssertEqual(byKey["listing|L1"]?.weight.value, Decimal(string: "0.15"))
        XCTAssertTrue(projected.unresolvedNewSubjects.isEmpty)
        XCTAssertEqual(projected.appliedActions.count, 3, "动作原样留档")

        // 投影后资产类聚合
        let weights = projected.assetClassWeights()
        XCTAssertEqual(weights[.equity]?.value, Decimal(string: "0.45"))
        XCTAssertEqual(weights[.fixedIncome]?.value, Decimal(string: "0.3"))
    }

    func testNegativeWeightPreservedNotClamped() {
        // 减持超过持仓 → 负权重保留(忠实投影;非法判定是 DEC-6 Gate 职责)
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|L1", deltaWeight: r("-0.5"))]
        )
        let l1 = projected.positions.first { $0.subjectKey == "listing|L1" }!
        XCTAssertEqual(l1.weight.value, Decimal(string: "-0.4"), "不 clamp——模拟层不越权修补")
    }

    func testNewSubjectRequiresExplicitAssetClass() {
        // 新标的无声明 → 进 unresolvedNewSubjects(fail-closed:不猜分类、不静默)
        let unclassified = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.1"))]
        )
        XCTAssertEqual(unclassified.unresolvedNewSubjects, ["listing|NEW"])
        XCTAssertFalse(unclassified.positions.contains { $0.subjectKey == "listing|NEW" })

        // 有声明 → 正常进入持仓
        let classified = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.1"))],
            assetClassForNewSubjects: ["listing|NEW": .equity]
        )
        XCTAssertTrue(classified.unresolvedNewSubjects.isEmpty)
        let new = classified.positions.first { $0.subjectKey == "listing|NEW" }!
        XCTAssertEqual(new.assetClass, .equity)
        XCTAssertEqual(new.weight.value, Decimal(string: "0.1"))
    }

    func testZeroDeltaPositionKept() {
        // delta 恰好抵消 → 权重 0 的持仓保留(存在过这一事实不抹除)
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|L1", deltaWeight: r("-0.1"))]
        )
        let l1 = projected.positions.first { $0.subjectKey == "listing|L1" }!
        XCTAssertEqual(l1.weight.value, 0)
    }

    func testCodableRoundTrip() throws {
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|NEW", deltaWeight: r("0.1"))]
        )
        let data = try JSONEncoder().encode(projected)
        let decoded = try JSONDecoder().decode(ProjectedPortfolio.self, from: data)
        XCTAssertEqual(decoded, projected)

        let snapshotData = try JSONEncoder().encode(base)
        let decodedSnapshot = try JSONDecoder().decode(PortfolioSnapshot.self, from: snapshotData)
        XCTAssertEqual(decodedSnapshot, base)
    }
}
