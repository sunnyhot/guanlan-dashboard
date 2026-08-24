import XCTest
@testable import QiemanDashboard

/// DEC-8 单元测试：CriterionComparator / IndifferenceBand / PartialDecisionPolicy
/// （ADR-D003：Pareto 语义 + unknown 阻断 + 非传递性 + unresolvedTradeoff）。
final class CriterionComparatorTests: XCTestCase {

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func score(_ id: String, _ value: Decimal?) -> CriterionScore {
        CriterionScore(
            definition: CriterionDefinition(
                id: id, version: "v1", evaluatorKind: .weightedSum,
                inputReferences: [
                    CriterionDefinition.InputReference(kind: .factorMetric, referenceID: "\(id)-in", weight: 1)
                ],
                unit: .ratio
            ),
            value: value,
            missingInputs: value == nil ? ["\(id)-in"] : [],
            computation: "test"
        )
    }

    private var band: IndifferenceBand {
        IndifferenceBand(
            policyID: "compare-band", version: "v1",
            defaultBand: d("0.01"),
            rationale: "1% 内差异视为无差异（交易摩擦量级）"
        )
    }

    private func compare(_ plans: [String: [CriterionScore]]) -> PlanComparisonResult {
        CriterionComparator().compare(plans: plans, band: band)
    }

    // MARK: - Effective Dominance

    func testClearDominance_singlePreferred() {
        // A 两项全优且超带 → dominate B;前沿 = [A]
        let result = compare([
            "A": [score("momentum", d("0.05")), score("cost", d("-0.001"))],
            "B": [score("momentum", d("0.02")), score("cost", d("-0.005"))],
        ])
        XCTAssertEqual(result.pairwise["A|B"], .aDominatesB)
        XCTAssertEqual(result.paretoFront, ["A"])
        let decision = PartialDecisionPolicy().decide(result, allPlanKeys: ["A", "B"])
        XCTAssertEqual(decision.status, .singlePreferred)
        XCTAssertEqual(decision.admissiblePlans, ["A"])
    }

    func testIncomparable_yieldsUnresolvedTradeoffWithTwoAdmissible() {
        // A momentum 优(0.04 > 带)、B costScore 优(0.025 > 带)→ 各有优势 incomparable
        let result = compare([
            "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
            "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
        ])
        XCTAssertEqual(result.pairwise["A|B"], .incomparable)
        XCTAssertEqual(result.paretoFront, ["A", "B"])
        let decision = PartialDecisionPolicy().decide(result, allPlanKeys: ["A", "B"])
        XCTAssertEqual(decision.status, .unresolvedTradeoff, "unresolvedTradeoff 真的可触发(D003 §5)")
        XCTAssertEqual(decision.admissiblePlans, ["A", "B"])
        XCTAssertTrue(decision.explanation.contains("互不支配"))
    }

    // MARK: - IndifferenceBand

    func testIndifferenceBandIgnoresSmallDifferences() {
        // A momentum 0.052 vs B 0.05(差 0.002 ≤ 0.01 带)→ indifferent;
        // cost 相等 → 无严格优 → incomparable(不因带内微差判优)
        let result = compare([
            "A": [score("momentum", d("0.052")), score("cost", d("-0.005"))],
            "B": [score("momentum", d("0.05")), score("cost", d("-0.005"))],
        ])
        XCTAssertEqual(result.pairwise["A|B"], .incomparable, "全部 criterion 带内 indifferent → 无 dominance")
    }

    func testIndifferenceBandRequiresRationale_heuristicNeverSilent() {
        // 空 rationale 由 init precondition 拒绝(heuristic 不允许静默)——
        // 类型契约层面表达,不做运行时崩溃断言。
        // per-criterion 带覆盖默认带
        let custom = IndifferenceBand(
            policyID: "p", version: "v1",
            bandsByCriterion: ["cost": d("0.0005")],
            defaultBand: d("0.01"),
            rationale: "cost 带收紧到 5bp(交易成本敏感)"
        )
        XCTAssertEqual(custom.band(for: "cost"), d("0.0005"))
        XCTAssertEqual(custom.band(for: "momentum"), d("0.01"))
    }

    // MARK: - unknown 阻断

    func testUnknownCriterionBlocksDominance() {
        // A 两项全优但 momentum unknown → 不判 dominance(DATA006:不假装 0)
        let result = compare([
            "A": [score("momentum", nil), score("cost", d("-0.009"))],
            "B": [score("momentum", d("0.02")), score("cost", d("-0.005"))],
        ])
        XCTAssertEqual(result.pairwise["A|B"], .incomparable)
        XCTAssertEqual(result.blockingUnknowns, ["momentum"], "阻断来源透明记录")
        let decision = PartialDecisionPolicy().decide(result, allPlanKeys: ["A", "B"])
        XCTAssertEqual(decision.status, .unresolvedTradeoff)
        XCTAssertTrue(decision.explanation.contains("momentum"))
    }

    // MARK: - 非传递性

    func testNonTransitiveCycle_notBroken_allMembersAdmissible() {
        // 三方案循环:rock > scissors > paper > rock(单向各胜一项)
        // c1: A>B; c2: B>C; c3: C>A → A dom B? A 只在 c1 优,c3 劣 → incomparable!
        // 构造真循环需 per-pair 不同的 criterion 值——用统一 criterion 集:
        // A: [10, 1], B: [9, 5], C: [8, 6] → A vs B:c1 A 优 c2 B 优 → incomparable
        // 真循环在纯 Pareto 语义下不可构造(dominance 是传递的)——
        // PartialDecisionPolicy 对空前沿的兜底是防御性设计,测试构造:
        // 直接给一个手工 PlanComparisonResult(空前沿)验证策略行为。
        let handmade = PlanComparisonResult(
            pairwise: ["A|B": .aDominatesB, "B|C": .aDominatesB, "A|C": .bDominatesA],
            paretoFront: [],  // A dom B, B dom C, C dom A → 全被 dominate
            blockingUnknowns: []
        )
        let decision = PartialDecisionPolicy().decide(handmade, allPlanKeys: ["A", "B", "C"])
        XCTAssertEqual(decision.status, .unresolvedTradeoff)
        XCTAssertEqual(decision.admissiblePlans, ["A", "B", "C"], "循环成员全部可采纳,不强行打破")
        XCTAssertTrue(decision.explanation.contains("循环"))
    }

    // MARK: - 方向参数与确定性

    func testHigherIsBetterDirection() {
        // cost 类 criterion:值小者优(higherIsBetter false)
        let comparator = CriterionComparator()
        let plans = [
            "A": [score("cost", d("-0.001"))],
            "B": [score("cost", d("-0.02"))],   // 差 0.019 > 带,cost 小者优
        ]
        let result = comparator.compare(plans: plans, band: band, higherIsBetter: ["cost": false])
        // −0.001 > −0.009 但 cost 越小越好 → B 优
        XCTAssertEqual(result.pairwise["A|B"], .bDominatesA)
    }

    func testDeterministicAndCodable() throws {
        let plans = [
            "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
            "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
        ]
        let comparator = CriterionComparator()
        let a = comparator.compare(plans: plans, band: band)
        let b = comparator.compare(plans: plans, band: band)
        XCTAssertEqual(a, b)

        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(PlanComparisonResult.self, from: data)
        XCTAssertEqual(decoded, a)

        let decisionData = try JSONEncoder().encode(PartialDecisionPolicy().decide(a, allPlanKeys: ["A", "B"]))
        let decodedDecision = try JSONDecoder().decode(PartialDecision.self, from: decisionData)
        XCTAssertEqual(decodedDecision.status, .unresolvedTradeoff)
    }

    // MARK: - helpers

    // rationale 非空语义由 init precondition 保证(空串即违反,debug 构建
    // trap);不做运行时崩溃断言。
}
