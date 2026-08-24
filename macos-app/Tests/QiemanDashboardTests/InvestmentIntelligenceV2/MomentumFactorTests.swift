import XCTest
@testable import QiemanDashboard

/// FAC-4 单元测试：MomentumFactorCalculator 的三个区间收益 metric。
final class MomentumFactorTests: XCTestCase {

    private func series(_ closes: [Decimal]) -> [AdjustedClosePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "b\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: c
            )
        }
    }

    private func metrics(for closes: [Decimal]) -> [String: FactorMetric] {
        Dictionary(
            uniqueKeysWithValues: MomentumFactorCalculator()
                .compute(inputs: FactorInputs(assetSeries: series(closes)))
                .map { ($0.definition.key, $0) }
        )
    }

    // MARK: - golden（等比序列闭式解）

    func testGoldenValues_onGeometricSeries() {
        // 等比序列 close[i] = 100 × 1.01^i（每根 +1%）：
        // return_w = 1.01^w − 1（与起点无关，闭式可算）
        var closes: [Decimal] = []
        var value = Decimal(100)
        let growth = Decimal(string: "1.01")!
        for _ in 0..<130 { closes.append(value); value = value * growth }

        let m = metrics(for: closes)
        // 1.01^20 − 1 = 0.22019003994803276...
        XCTAssertEqual(m["momentum.return20"]?.value, Decimal(string: "0.220190039948"))
        // 1.01^60 − 1 = 0.8166966985640915...
        XCTAssertEqual(m["momentum.return60"]?.value, Decimal(string: "0.816696698564"))
        // 1.01^120 − 1 = 2.300386894574...（1.01^100 × 1.01^20 交叉核算）
        XCTAssertEqual(m["momentum.return120"]?.value, Decimal(string: "2.300386894574"))
        XCTAssertTrue(m.values.allSatisfy { $0.insufficiency == nil })
    }

    // MARK: - 简单比率核对

    func testSimpleRatio_arbitraryEndpoints() {
        // 21 根：return20 = close[20]/close[0] − 1
        let closes = (0..<21).map { Decimal(100 + $0 * 3) }
        let m = metrics(for: closes)
        XCTAssertEqual(m["momentum.return20"]?.value, Decimal(string: "0.6")) // 160/100 − 1
        // 21 根对 60/120 窗口仍不足
        XCTAssertNil(m["momentum.return60"]?.value)
        XCTAssertNil(m["momentum.return120"]?.value)
    }

    // MARK: - 数据不足分级（requiredBars 21 / 61 / 121）

    func testInsufficiencyTiers() {
        let empty = metrics(for: [])
        XCTAssertEqual(empty["momentum.return20"]?.insufficiency?.reason, .emptySeries)

        let at20 = metrics(for: Array(repeating: Decimal(100), count: 20))
        XCTAssertEqual(at20["momentum.return20"]?.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(at20["momentum.return20"]?.insufficiency?.requiredBars, 21)
        XCTAssertEqual(at20["momentum.return20"]?.insufficiency?.actualBars, 20)

        let at60 = metrics(for: Array(repeating: Decimal(100), count: 60))
        XCTAssertNil(at60["momentum.return60"]?.value)   // 60 < 61
        XCTAssertNotNil(at60["momentum.return20"]?.value)

        let at61 = metrics(for: Array(repeating: Decimal(100), count: 61))
        XCTAssertEqual(at61["momentum.return60"]?.value, 0)  // 恒定序列收益恰为 0（数据足够时 0 是计算结果，不是猜的默认值）

        let at121 = metrics(for: Array(repeating: Decimal(100), count: 121))
        XCTAssertNotNil(at121["momentum.return120"]?.value)
    }

    func testNegativeMomentumComputedNotGuessed() {
        // 下跌序列：close[i] = 100 × 0.99^i → return20 = 0.99^20 − 1 ≈ −0.1821
        var closes: [Decimal] = []
        var value = Decimal(100)
        let decay = Decimal(string: "0.99")!
        for _ in 0..<130 { closes.append(value); value = value * decay }
        let m = metrics(for: closes)
        let ret20 = m["momentum.return20"]?.value
        XCTAssertNotNil(ret20)
        XCTAssertLessThan(ret20!, Decimal.zero)
        // 0.99^20 − 1 = −0.18209306240276914（0.99^10 = 0.9043820750088044，平方核算）
        XCTAssertEqual(ret20!, Decimal(string: "-0.182093062403"))
    }

    func testDefinitionsDeclareKeysUnitsVersions() {
        let defs = MomentumFactorCalculator().definitions
        XCTAssertEqual(defs.map(\.key), ["momentum.return20", "momentum.return60", "momentum.return120"])
        XCTAssertTrue(defs.allSatisfy { $0.version == "v1" && $0.unit == .ratio })
    }
}
