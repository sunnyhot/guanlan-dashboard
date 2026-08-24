import XCTest
@testable import QiemanDashboard

/// FAC-6 单元测试：DrawdownFactorCalculator 的当前 / 最大回撤 metric。
final class DrawdownFactorTests: XCTestCase {

    private func metrics(for closes: [Decimal], window: Int = 252) -> [String: FactorMetric] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let series = closes.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "b\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: c
            )
        }
        return Dictionary(
            uniqueKeysWithValues: DrawdownFactorCalculator(windowBars: window)
                .compute(inputs: FactorInputs(assetSeries: series))
                .map { ($0.definition.key, $0) }
        )
    }

    // MARK: - golden（手算序列）

    func testGolden_vShapeWithPartialRecovery() {
        // [100, 120, 90, 110, 80, 95]：
        // runningMax 终值 120；current = 95/120 − 1 = −5/24 = −0.208333333333...
        // 深度低点 80/120 − 1 = −1/3 = −0.333333333333...
        let m = metrics(for: [100, 120, 90, 110, 80, 95].map { Decimal($0) })
        XCTAssertEqual(m["drawdown.current252"]?.value, Decimal(string: "-0.208333333333"))
        XCTAssertEqual(m["drawdown.max252"]?.value, Decimal(string: "-0.333333333333"))
    }

    func testGolden_newHighAtEnd_currentIsZero() {
        // 收盘创新高：current 恰 0（不是 nil——数据足够，值就是 0）
        // max = 90/120 − 1 = −0.25
        let m = metrics(for: [100, 120, 90, 130].map { Decimal($0) })
        XCTAssertEqual(m["drawdown.current252"]?.value, 0)
        XCTAssertEqual(m["drawdown.max252"]?.value, Decimal(string: "-0.25"))
    }

    func testMonotonicRise_hasZeroDrawdowns() {
        let closes = (0..<60).map { Decimal(100 + $0) }
        let m = metrics(for: closes)
        XCTAssertEqual(m["drawdown.current252"]?.value, 0)
        XCTAssertEqual(m["drawdown.max252"]?.value, 0)
    }

    // MARK: - 窗口截断（cap 语义）

    func testWindowCap_excludesBarsBeyond252() {
        // 256 根：全局最高 1000 在 index 0（窗口外）。窗口 = 尾部 252 根
        // （index 4..255，递增 104..355）→ current = 0、max = 0；
        // 若 1000 被错误纳入窗口：current = 355/1000 − 1 = −0.645。
        var closes: [Decimal] = [1000]
        closes.append(contentsOf: (0..<255).map { Decimal(100 + $0) })
        let m = metrics(for: closes)
        XCTAssertEqual(m["drawdown.current252"]?.value, 0)
        XCTAssertEqual(m["drawdown.max252"]?.value, 0)
    }

    func testWindowCap_shortSeriesStillComputes() {
        // 不足 252 根：用全部可得（cap 语义），3 根序列照样计算
        let m = metrics(for: [100, 150, 120].map { Decimal($0) })
        XCTAssertEqual(m["drawdown.current252"]?.value, Decimal(string: "-0.2"))
        XCTAssertEqual(m["drawdown.max252"]?.value, Decimal(string: "-0.2"))
        XCTAssertNil(m["drawdown.current252"]?.insufficiency)
    }

    // MARK: - 数据不足

    func testInsufficiency_emptySeries() {
        let m = metrics(for: [])
        XCTAssertEqual(m["drawdown.current252"]?.insufficiency?.reason, .emptySeries)
        XCTAssertEqual(m["drawdown.max252"]?.insufficiency?.reason, .emptySeries)
    }

    func testInsufficiency_singleBar_maxDrawdownUndefined() {
        // 1 根：current = 0 良定义；max 回撤无「高点之后的点」，不产 0 冒充
        let m = metrics(for: [Decimal(100)])
        XCTAssertEqual(m["drawdown.current252"]?.value, 0)
        XCTAssertNil(m["drawdown.max252"]?.value)
        XCTAssertEqual(m["drawdown.max252"]?.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(m["drawdown.max252"]?.insufficiency?.requiredBars, 2)
    }

    func testDefinitionsDeclareWindowPolicy() {
        let defs = DrawdownFactorCalculator().definitions
        XCTAssertEqual(defs.map(\.key), ["drawdown.current252", "drawdown.max252"])
        XCTAssertTrue(defs.allSatisfy { $0.version == "v1" && $0.unit == .ratio })
        // cap 政策显式声明（与 MA 类 exact 窗口的差异可审计）
        XCTAssertTrue(defs.allSatisfy { def in
            def.parameters.contains { $0.name == "windowPolicy" && $0.value == "cap" }
                && def.parameters.contains { $0.name == "windowBars" && $0.intValue == 252 }
        })
    }
}
