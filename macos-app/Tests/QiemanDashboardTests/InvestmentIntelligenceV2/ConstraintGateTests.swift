import XCTest
@testable import QiemanDashboard

/// DEC-6 单元测试：双层 Constraint Gate。
final class ConstraintGateTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func planned(_ key: String, _ delta: String) -> PlannedAction {
        PlannedAction(
            action: PortfolioAction(subjectKey: key, deltaWeight: r(delta)),
            provenance: .userDirective(.init(directiveID: "test-\(key)-\(delta)", note: nil))
        )
    }

    private var base: PortfolioSnapshot {
        PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: r("0.5")),
            PortfolioPosition(subjectKey: "listing|B", assetClass: .equity, weight: r("0.3")),
        ])
    }

    // MARK: - Layer 1：action-level pruning

    func testPruneDropsSmallTradesAndOversizedDeltas() {
        let gate = ConstraintGate()
        let result = gate.prune(
            actions: [planned("listing|A", "0.005"), planned("listing|A", "0.15"), planned("listing|B", "-0.05")],
            rules: [.minTradeSize(d("0.01")), .maxSingleDelta(d("0.1"))]
        )
        XCTAssertEqual(result.kept.map(\.action.subjectKey), ["listing|B"], "0.005 碎单剔除;0.15 超单动作剔除")
        XCTAssertEqual(result.pruned.count, 2)
        XCTAssertEqual(result.pruned[0].ruleLabel, "minTradeSize(0.01)")
        XCTAssertEqual(result.pruned[1].ruleLabel, "maxSingleDelta(0.1)")
    }

    func testPruneEmptyRulesKeepsAll() {
        let gate = ConstraintGate()
        let actions = [planned("listing|A", "0.005")]
        let result = gate.prune(actions: actions, rules: [])
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertTrue(result.pruned.isEmpty)
    }

    // MARK: - Layer 2：portfolio-level 联合约束

    func testNegativeWeightsRejected() {
        // 卖超过持仓 → 投影负权重 → 违反
        let gate = ConstraintGate()
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|B", deltaWeight: r("-0.4"))]
        )
        let verdict = gate.evaluate(
            projected: projected,
            actions: projected.appliedActions,
            rules: [.noNegativeWeights]
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.violations[0].contains("listing|B"))
        XCTAssertTrue(verdict.violations[0].contains("noNegativeWeights"))
    }

    func testWeightsSumAtMostOne() {
        let gate = ConstraintGate()
        // Σ 0.8 + 0.3 买入 = 1.1 > 1 + 0.001 → 违反(无杠杆)
        let projected = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|A", deltaWeight: r("0.3"))]
        )
        let violated = gate.evaluate(
            projected: projected, actions: projected.appliedActions,
            rules: [.weightsSumAtMostOne(tolerance: d("0.001"))]
        )
        XCTAssertFalse(violated.passed)
        XCTAssertTrue(violated.violations[0].contains("weightsSumAtMostOne"))

        // Σ 1.0 恰好 → 通过
        let ok = ProjectedPortfolio.project(
            base: base,
            applying: [
                PortfolioAction(subjectKey: "listing|A", deltaWeight: r("0.2")),
                PortfolioAction(subjectKey: "listing|B", deltaWeight: r("0.0")),
            ]
        )
        let okVerdict = gate.evaluate(
            projected: ok, actions: ok.appliedActions,
            rules: [.weightsSumAtMostOne(tolerance: d("0.001"))]
        )
        XCTAssertTrue(okVerdict.passed)
    }

    func testRebalanceZeroSum() {
        let gate = ConstraintGate()
        // 零和再平衡:A −0.1 + B +0.1 → ΣΔ = 0 通过
        let balanced = ProjectedPortfolio.project(
            base: base,
            applying: [
                PortfolioAction(subjectKey: "listing|A", deltaWeight: r("-0.1")),
                PortfolioAction(subjectKey: "listing|B", deltaWeight: r("0.1")),
            ]
        )
        XCTAssertTrue(gate.evaluate(
            projected: balanced, actions: balanced.appliedActions,
            rules: [.rebalanceZeroSum(tolerance: d("0.001"))]
        ).passed)

        // 单边买入 → 违反
        let oneSided = ProjectedPortfolio.project(
            base: base,
            applying: [PortfolioAction(subjectKey: "listing|A", deltaWeight: r("0.1"))]
        )
        XCTAssertFalse(gate.evaluate(
            projected: oneSided, actions: oneSided.appliedActions,
            rules: [.rebalanceZeroSum(tolerance: d("0.001"))]
        ).passed)
    }

    func testTotalBudget() {
        let gate = ConstraintGate()
        let actions = [
            PortfolioAction(subjectKey: "listing|A", deltaWeight: r("-0.1")),
            PortfolioAction(subjectKey: "listing|B", deltaWeight: r("0.05")),
        ]
        let projected = ProjectedPortfolio.project(base: base, applying: actions)
        // Σ|Δ| = 0.15 > 0.1 → 违反
        XCTAssertFalse(gate.evaluate(
            projected: projected, actions: actions,
            rules: [.totalBudget(cap: d("0.1"))]
        ).passed)
        // cap 0.2 → 通过
        XCTAssertTrue(gate.evaluate(
            projected: projected, actions: actions,
            rules: [.totalBudget(cap: d("0.2"))]
        ).passed)
    }

    // MARK: - 相关性联合约束

    private func correlationPair(_ a: String, _ b: String, _ rho: String) -> CorrelationPair {
        CorrelationPair(
            listingA: ListingID(rawValue: a), listingB: ListingID(rawValue: b),
            pearson: r(rho), sampleCount: 40, insufficiency: nil
        )
    }

    /// 审查 P1 回归:CorrelationPair 存裸 ListingID(生产形态),
    /// 投影主体键是 listing| 前缀——键域剥前缀后必须命中。
    func testCorrelationMatchesWithBareListingIDs() {
        let gate = ConstraintGate()
        let projected = ProjectedPortfolio.project(base: base, applying: [])
        // 裸 ID 的 pair(顺序反向也要命中:无序对)
        let verdict = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("B", "A", "0.9")]
        )
        XCTAssertFalse(verdict.passed, "裸 ID + 反序 pair 必须命中(修复前全 skipped)")
        XCTAssertEqual(verdict.correlationSkippedPairs, 0)
    }

    func testFundSubjectPairsSkipped() {
        // 基金主体(fund| 前缀)无法映射行情序列 → skipped,不猜
        let gate = ConstraintGate()
        let fundPortfolio = PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(subjectKey: "fund|A", assetClass: .equity, weight: r("0.6")),
            PortfolioPosition(subjectKey: "fund|B", assetClass: .equity, weight: r("0.4")),
        ])
        let projected = ProjectedPortfolio.project(base: fundPortfolio, applying: [])
        let verdict = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.9")]
        )
        XCTAssertTrue(verdict.passed, "基金主体对跳过 → 无均值不判违规")
        XCTAssertEqual(verdict.correlationSkippedPairs, 1)
    }

    func testMaxAverageCorrelation() {
        let gate = ConstraintGate()
        // 组合 A 0.5 + B 0.3(正权重);ρ(A,B) = 0.9
        // 加权平均 = |0.9| → 0.9 > 0.8 → 违反
        let projected = ProjectedPortfolio.project(base: base, applying: [])
        let violated = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.9")]
        )
        XCTAssertFalse(violated.passed)
        XCTAssertTrue(violated.violations[0].contains("maxAverageCorrelation"))

        // ρ = 0.5 → 通过
        let ok = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.5")]
        )
        XCTAssertTrue(ok.passed)
        XCTAssertEqual(ok.correlationSkippedPairs, 0)
    }

    func testCorrelationUnknownPairsSkippedNotGuessed() {
        // ρ unknown(pearson nil)→ 跳过该对(不猜 0),skippedPairs 记录
        let gate = ConstraintGate()
        let projected = ProjectedPortfolio.project(base: base, applying: [])
        let unknownPair = CorrelationPair(
            listingA: ListingID(rawValue: "A"), listingB: ListingID(rawValue: "B"),
            pearson: nil, sampleCount: 5,
            insufficiency: .init(reason: .insufficientSamples, requiredSamples: 30)
        )
        let verdict = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [unknownPair]
        )
        XCTAssertTrue(verdict.passed, "全部对 unknown → 无均值不判违规(不猜)")
        XCTAssertEqual(verdict.correlationSkippedPairs, 1)
    }

    func testReversedDuplicatePairsMergeDeterministically() {
        // 二轮审查 P2-8 回归:(A,B) 与 (B,A) 同时输入不再 trap;
        // 值一致幂等,值不一致确定性选择
        let gate = ConstraintGate()
        let projected = ProjectedPortfolio.project(base: base, applying: [])
        // 同值反序对:幂等保留,正常评估
        XCTAssertNoThrow(try gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.5"), correlationPair("B", "A", "0.5")]
        ))
        let consistent = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.5"), correlationPair("B", "A", "0.5")]
        )
        XCTAssertTrue(consistent.passed)
        XCTAssertEqual(consistent.correlationSkippedPairs, 0)

        // 矛盾对(0.9 vs 0.5):确定性合并(序列化字典序小者:0.5),不崩溃
        let conflicting = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("A", "B", "0.9"), correlationPair("B", "A", "0.5")]
        )
        XCTAssertTrue(conflicting.passed, "合并选择 |0.5|(字典序较小)→ 0.5 ≤ 0.8 通过")
        // 输入顺序无关:反转输入顺序结果一致(确定性)
        let reversed = gate.evaluate(
            projected: projected, actions: [],
            rules: [.maxAverageCorrelation(cap: d("0.8"))],
            correlations: [correlationPair("B", "A", "0.5"), correlationPair("A", "B", "0.9")]
        )
        XCTAssertEqual(reversed.passed, conflicting.passed)
    }

    // MARK: - Rescale(不引入新 Δw)

    func testRescaleProportionalWithProvenanceKept() {
        let gate = ConstraintGate()
        let actions = [planned("listing|A", "-0.1"), planned("listing|B", "0.05")]
        let rescaled = gate.rescaled(actions: actions, toBudget: d("0.075"))
        // Σ|Δ| = 0.15 → 缩放 0.5 → −0.05 / +0.025
        XCTAssertEqual(rescaled[0].action.deltaWeight.value, d("-0.05"))
        XCTAssertEqual(rescaled[1].action.deltaWeight.value, d("0.025"))
        // provenance 原样保留(不引入新来源)
        XCTAssertEqual(rescaled.map(\.provenance), actions.map(\.provenance))

        // 预算内 → 原样
        let unchanged = gate.rescaled(actions: actions, toBudget: d("0.2"))
        XCTAssertEqual(unchanged, actions)
    }
}
