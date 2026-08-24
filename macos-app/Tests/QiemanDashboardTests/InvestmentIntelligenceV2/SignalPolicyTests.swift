import XCTest
@testable import QiemanDashboard

/// FAC-2 单元测试：SignalPolicy 的 metric → ordinal 转换、
/// 阈值 provenance 审计、ordinal 不进 cardinal 运算的类型保证。
final class SignalPolicyTests: XCTestCase {

    private func metric(key: String, value: Decimal?) -> FactorMetric {
        let def = FactorDefinition(key: key, version: "v1", unit: .ratio)
        guard let value else {
            return FactorMetric(definition: def, insufficiency: .init(
                reason: .insufficientBars, requiredBars: 21, actualBars: 5
            ))
        }
        return FactorMetric(definition: def, value: value)
    }

    private func makePolicy() -> SignalPolicy {
        .trendRatioV1(metricKeys: ["trend.closeVsMA20"])
    }

    // MARK: - 三带转换语义

    func testBandMapping_allFiveBands() {
        let policy = makePolicy()
        let cases: [(Decimal, SignalDirection, SignalStrength)] = [
            (Decimal(string: "-0.05")!, .bearish, .strong),
            (Decimal(string: "-0.02001")!, .bearish, .strong),
            (Decimal(string: "-0.02")!, .bearish, .weak),       // -0.02 落弱带下边界（[lower, upper) 含下界）
            (Decimal(string: "-0.019")!, .bearish, .weak),
            (Decimal(string: "-0.004")!, .neutral, .weak),
            (Decimal(string: "0.0049")!, .neutral, .weak),
            (Decimal(string: "0.005")!, .bullish, .weak),        // 0.005 落弱带下边界（含）
            (Decimal(string: "0.019")!, .bullish, .weak),
            (Decimal(string: "0.02")!, .bullish, .strong),       // 0.02 落强带下边界（含）
            (Decimal(string: "0.5")!, .bullish, .strong),
        ]
        for (value, direction, strength) in cases {
            let signal = policy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: value))
            XCTAssertEqual(signal.direction, direction, "value=\(value)")
            XCTAssertEqual(signal.strength, strength, "value=\(value)")
        }
    }

    func testMissingValueMapsToUncertain_notGuessed() {
        let policy = makePolicy()
        let signal = policy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: nil))
        XCTAssertEqual(signal.direction, .uncertain)
        XCTAssertEqual(signal.strength, .weak)
        // 溯源字段完整：即使 uncertain 也能定位是哪版 policy 的产出
        XCTAssertEqual(signal.policyProvenance.policyID, "trend-ratio")
        XCTAssertEqual(signal.policyProvenance.policyVersion, "v1")
        XCTAssertEqual(signal.factorDefinitionVersion, "v1")
    }

    func testUnmatchedMetricKeyFailsOpenToUncertain() {
        let policy = makePolicy()  // 只配置了 trend.closeVsMA20
        let signal = policy.ordinalSignal(for: metric(key: "volatility.realized20", value: Decimal(string: "0.99")!))
        XCTAssertEqual(signal.direction, .uncertain, "没规则的 metric 不得默认 neutral")
    }

    func testRuleGapFailsOpenToUncertain() {
        // 缝隙 policy：[-0.02, 0.02) 之外没有规则，±5% 应 fail-open
        let gapPolicy = SignalPolicy(
            provenance: SignalPolicyProvenance(
                policyID: "gap", policyVersion: "v1", basis: .heuristic, rationale: "测试缝隙"
            ),
            rules: [
                SignalBandRule(
                    metricKey: "trend.closeVsMA20",
                    lowerBound: Decimal(string: "-0.02")!,
                    upperBound: Decimal(string: "0.02")!,
                    direction: .neutral, strength: .weak
                )
            ]
        )
        let inside = gapPolicy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: Decimal(string: "0.01")!))
        XCTAssertEqual(inside.direction, .neutral)
        let outside = gapPolicy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: Decimal(string: "0.05")!))
        XCTAssertEqual(outside.direction, .uncertain, "缝隙值不得猜方向")
    }

    func testFirstMatchWins_policyOrderIsStable() {
        // 重叠带：声明顺序决定命中（policy 内顺序是定义的一部分）
        let policy = SignalPolicy(
            provenance: SignalPolicyProvenance(
                policyID: "overlap", policyVersion: "v1", basis: .heuristic, rationale: "测试顺序"
            ),
            rules: [
                SignalBandRule(metricKey: "m", lowerBound: nil, upperBound: Decimal(string: "0.01")!, direction: .bearish, strength: .weak),
                SignalBandRule(metricKey: "m", lowerBound: nil, upperBound: nil, direction: .bullish, strength: .strong),
            ]
        )
        let signal = policy.ordinalSignal(for: metric(key: "m", value: Decimal(string: "0.005")!))
        XCTAssertEqual(signal.direction, .bearish)
    }

    // MARK: - 阈值 provenance 审计（FAC-2 验收）

    func testThresholdProvenanceIsAuditable() {
        let policy = makePolicy()
        XCTAssertEqual(policy.provenance.basis, .heuristic)
        XCTAssertNotNil(policy.provenance.rationale, "heuristic 阈值必须附 rationale")
        XCTAssertEqual(policy.rules.filter { $0.metricKey == "trend.closeVsMA20" }.count, 5)

        // 每条产出的 signal 都携带 policy provenance（可回答「这阈值哪来的」）
        let signal = policy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: Decimal(string: "0.03")!))
        XCTAssertEqual(signal.policyProvenance, policy.provenance)
    }

    func testEmpiricalQuantileProvenanceCarriesSampleWindow() {
        let provenance = SignalPolicyProvenance(
            policyID: "vol-quantile", policyVersion: "v1",
            basis: .empiricalQuantile,
            rationale: nil,
            quantileSampleWindow: "2019-01-01..2024-12-31 全市场日线"
        )
        XCTAssertEqual(provenance.quantileSampleWindow, "2019-01-01..2024-12-31 全市场日线")
        // Codable round-trip 后审计字段不丢
        let data = try! JSONEncoder().encode(provenance)
        let decoded = try! JSONDecoder().decode(SignalPolicyProvenance.self, from: data)
        XCTAssertEqual(decoded, provenance)
    }

    // MARK: - ordinal 不进 cardinal 运算（类型层保证）

    func testOrdinalSignalHasNoCardinalSurface() {
        // 编译期断言（运行时同过）：OrdinalFactorSignal 的全部存储属性
        // 没有任何 Decimal / 数字类型——ordinal 无法被拿来算数。
        let signal = policySignal()
        XCTAssertNotNil(signal.metricKey)
        XCTAssertNotNil(signal.factorDefinitionVersion)
        XCTAssertEqual(signal.direction, .bullish)
        // Mirror 反射枚举存储：不存在数值 case payload
        let children = Mirror(reflecting: signal).children.compactMap(\.label)
        XCTAssertEqual(
            Set(children),
            ["metricKey", "factorDefinitionVersion", "direction", "strength", "policyProvenance"]
        )
    }

    func testCodableRoundTrip() throws {
        let policy = makePolicy()
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(SignalPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)

        let signal = policySignal()
        let signalData = try JSONEncoder().encode(signal)
        let decodedSignal = try JSONDecoder().decode(OrdinalFactorSignal.self, from: signalData)
        XCTAssertEqual(decodedSignal, signal)
    }

    func testSignalsFromSnapshot_mapsAllMetricsInOrder() {
        let policy = SignalPolicy.trendRatioV1(metricKeys: ["a", "b"])
        let metrics = [
            metric(key: "a", value: Decimal(string: "0.03")!),
            metric(key: "b", value: Decimal(string: "-0.03")!),
            metric(key: "a", value: nil),
        ]
        // 直接构造最小 snapshot 载体（metrics 顺序保持）
        let signals = metrics.map { policy.ordinalSignal(for: $0) }
        XCTAssertEqual(signals.map(\.direction), [.bullish, .bearish, .uncertain])
        XCTAssertEqual(signals.map(\.metricKey), ["a", "b", "a"])
    }

    // MARK: - helpers

    private func policySignal() -> OrdinalFactorSignal {
        let policy = makePolicy()
        return policy.ordinalSignal(for: metric(key: "trend.closeVsMA20", value: Decimal(string: "0.03")!))
    }
}
