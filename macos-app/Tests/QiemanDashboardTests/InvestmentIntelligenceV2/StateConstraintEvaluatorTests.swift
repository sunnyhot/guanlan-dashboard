import XCTest
@testable import QiemanDashboard

/// DEC-2 单元测试：StateConstraintEvaluator 三态判定 + RemediationRequirement
/// + Operational Obligation 分离。
final class StateConstraintEvaluatorTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - fixture（直构 ExposureReport；引擎级正确性已由 ExposureEngineTests 覆盖）

    private func exposureReport(
        securities: [(key: String, lower: String, upper: String)],
        assetClasses: [(key: String, lower: String, upper: String)] = [],
        unknownWeight: Decimal = 0
    ) -> ExposureReport {
        func estimate(_ dim: ExposureEstimate.Dimension, _ key: String, _ lower: Decimal, _ upper: Decimal)
            -> ExposureEstimate
        {
            ExposureEstimate(
                dimension: dim, key: key,
                lowerBound: Ratio(value: lower), upperBound: Ratio(value: upper),
                sourceObservationIDs: []
            )
        }
        return ExposureReport(
            id: ArtifactID(rawValue: "exp_test"),
            producedAt: day,
            validityPolicy: .untilDependencyChanges,
            dependencies: [],
            asOf: day,
            engineVersion: "test",
            unknownPortfolioWeight: Ratio(value: unknownWeight),
            estimates:
                securities.map { estimate(.singleSecurity, $0.key, Decimal(string: $0.lower) ?? 0, Decimal(string: $0.upper) ?? 0) }
                + assetClasses.map { estimate(.assetClass, $0.key, Decimal(string: $0.lower) ?? 0, Decimal(string: $0.upper) ?? 0) },
            fundOverlaps: []
        )
    }

    private func constraint(_ kind: StateConstraintDefinition.Kind, _ params: [String: String]) -> StateConstraintDefinition {
        StateConstraintDefinition(
            id: "test-\(kind.rawValue)", version: "v1", kind: kind,
            parameters: params.map { .init(name: $0.key, value: $0.value) }
        )
    }

    private let maxSecurity = StateConstraintDefinition(
        id: "c-single", version: "v1", kind: .maxSingleSecurityExposure,
        parameters: [.init(name: "threshold", value: "0.1")]
    )

    // MARK: - 单标的暴露三态

    func testSingleSecurityViolated_whenConfirmedOverThreshold() {
        // 确认暴露 0.15 > 0.1 → violated + remediation（不是 veto：finding 只描述修复方向）
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: [("X", "0.15", "0.15")]),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .violated)
        XCTAssertEqual(finding.remediation?.constraintID, "c-single")
        XCTAssertEqual(finding.remediation?.relatedKey, "X")
        XCTAssertTrue(finding.remediation?.directive.contains("X") ?? false)
        XCTAssertTrue(finding.remediation?.directive.contains("10%") ?? false)
        XCTAssertNil(finding.insufficiencyNote)
    }

    func testSingleSecuritySatisfied_whenWorstCaseUnderThreshold() {
        // 最坏情况 0.08 ≤ 0.1 → satisfied（确认满足）
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: [("X", "0.05", "0.08")]),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .satisfied)
        XCTAssertNil(finding.remediation)
    }

    func testSingleSecurityUnknown_whenBoundsStraddleThreshold() {
        // lower 0.08 ≤ 0.1 < upper 0.12 → unknown（披露缺口内可能违规,不猜）
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: [("X", "0.08", "0.12")], unknownWeight: Decimal(string: "0.04")!),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .unknown)
        XCTAssertNil(finding.remediation, "unknown 不产修复要求(方向不明)")
        XCTAssertNotNil(finding.insufficiencyNote)
    }

    func testSingleSecurityNoDataIsUnknown() {
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: []),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .unknown)
    }

    // MARK: - 资产类偏差

    func testAssetClassDeviationAgainstTarget() {
        let deviation = constraint(.maxAssetClassDeviation, ["threshold": "0.05"])
        let target = try! StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.6")!)),
                AllocationTargetEntry(assetClass: .fixedIncome, targetWeight: Ratio(value: Decimal(string: "0.4")!)),
            ],
            note: nil, now: day
        )
        // equity 确认 0.72(vs target 0.6)偏差 0.12 > 0.05 → violated
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [deviation],
            exposure: exposureReport(
                securities: [],
                assetClasses: [("EQUITY", "0.72", "0.72"), ("FIXED_INCOME", "0.38", "0.38")]
            ),
            target: target
        )[0]
        XCTAssertEqual(finding.status, .violated)
        XCTAssertEqual(finding.remediation?.relatedKey, "EQUITY")

        // 偏差在阈值内 → satisfied
        let ok = StateConstraintEvaluator().evaluate(
            constraints: [deviation],
            exposure: exposureReport(
                securities: [],
                assetClasses: [("EQUITY", "0.63", "0.65"), ("FIXED_INCOME", "0.37", "0.39")]
            ),
            target: target
        )[0]
        XCTAssertEqual(ok.status, .satisfied, "最坏偏差 0.05 ≤ 0.05")
    }

    func testAssetClassDeviationWithoutTargetIsUnknown() {
        // 无 Target → 偏差无定义 → unknown(Target 不可从数据推断,D000)
        let deviation = constraint(.maxAssetClassDeviation, ["threshold": "0.05"])
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [deviation],
            exposure: exposureReport(securities: [], assetClasses: [("EQUITY", "0.7", "0.7")]),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .unknown)
        XCTAssertTrue(finding.insufficiencyNote?.contains("D000") ?? false)
    }

    // MARK: - 披露覆盖下限

    func testDisclosureCoverageThreshold() {
        let minCoverage = constraint(.minDisclosureCoverage, ["minCoverage": "0.5"])
        let evaluator = StateConstraintEvaluator()

        // coverage 0.4 < 0.5 → violated(修复 = 补数据,不是调仓)
        let low = evaluator.evaluate(
            constraints: [minCoverage],
            exposure: exposureReport(securities: [], unknownWeight: Decimal(string: "0.6")!),
            target: nil
        )[0]
        XCTAssertEqual(low.status, .violated)
        XCTAssertTrue(low.remediation?.directive.contains("披露") ?? false)

        // coverage 0.9 → satisfied
        let ok = evaluator.evaluate(
            constraints: [minCoverage],
            exposure: exposureReport(securities: [], unknownWeight: Decimal(string: "0.1")!),
            target: nil
        )[0]
        XCTAssertEqual(ok.status, .satisfied)
    }

    // MARK: - Operational Obligation 分离 + 形态

    func testSingleSecurity_confirmedViolationNotMaskedByWiderBound() {
        // 审查 P1 回归:A=[8%,30%](upper 最大)、B=[15%,16%](lower 已超 10%)
        // 旧实现只看 A(upper 最大)→ unknown,漏掉 B 已确认违规
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: [("A", "0.08", "0.30"), ("B", "0.15", "0.16")]),
            target: nil
        )[0]
        XCTAssertEqual(finding.status, .violated, "任一标的 lower 超阈 → violated,不被更宽的区间掩盖")
        XCTAssertEqual(finding.remediation?.relatedKey, "B")
    }

    func testAssetClassDeviation_targetInsideIntervalLowerIsZero() {
        // 审查 P1 回归:暴露区间 [30%,70%]、Target 50% → 真实偏差区间 [0,20%]
        // 旧实现 |30−50|=20 / |70−50|=20 → 误报 violated;正确为 unknown(20% > 10% 阈)
        let deviation = constraint(.maxAssetClassDeviation, ["threshold": "0.1"])
        let target = try! StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.5")!)),
                AllocationTargetEntry(assetClass: .fixedIncome, targetWeight: Ratio(value: Decimal(string: "0.5")!)),
            ],
            note: nil, now: day
        )
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [deviation],
            exposure: exposureReport(
                securities: [],
                assetClasses: [("EQUITY", "0.3", "0.7"), ("FIXED_INCOME", "0.5", "0.5")]
            ),
            target: target
        )[0]
        XCTAssertEqual(finding.status, .unknown, "Target 在区间内 → 偏差下界 0,上界 20% 跨阈 → unknown")
        XCTAssertTrue(finding.insufficiencyNote?.contains("0%") ?? false)

        // 区间收紧到 [45%,55%]:偏差 [0,5%] ≤ 10% → satisfied
        let ok = StateConstraintEvaluator().evaluate(
            constraints: [deviation],
            exposure: exposureReport(
                securities: [],
                assetClasses: [("EQUITY", "0.45", "0.55"), ("FIXED_INCOME", "0.45", "0.55")]
            ),
            target: target
        )[0]
        XCTAssertEqual(ok.status, .satisfied, "最坏偏差 5% ≤ 10%")
    }

    func testOperationalObligationIsSeparateKind() throws {
        let obligation = OperationalObligation(
            id: "ob-refresh", version: "v1",
            trigger: .beforeRebalance,
            obligation: "调仓前刷新个人持仓估值"
        )
        XCTAssertEqual(obligation.trigger, .beforeRebalance)
        // 与祈使约束是不同类型(无评估耦合):StateConstraintEvaluator 的
        // 公开 API 不接受 Obligation 输入
        let data = try JSONEncoder().encode(obligation)
        let decoded = try JSONDecoder().decode(OperationalObligation.self, from: data)
        XCTAssertEqual(decoded, obligation)
    }

    func testFindingIsRemediationNotVeto() {
        // finding 的字段集合不含否决 / 阻断语义——违规只产修复要求,
        // 计划否决是 DEC-6 Constraint Gate 的职责
        let finding = StateConstraintEvaluator().evaluate(
            constraints: [maxSecurity],
            exposure: exposureReport(securities: [("X", "0.15", "0.15")]),
            target: nil
        )[0]
        let labels = Mirror(reflecting: finding).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["constraint", "status", "remediation", "insufficiencyNote"])
        let findingData = try! JSONEncoder().encode(finding)
        let decoded = try! JSONDecoder().decode(StateConstraintFinding.self, from: findingData)
        XCTAssertEqual(decoded, finding)
    }
}
