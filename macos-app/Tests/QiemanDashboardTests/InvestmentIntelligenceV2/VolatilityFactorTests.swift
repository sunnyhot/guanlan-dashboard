import XCTest
@testable import QiemanDashboard

/// FAC-5 单元测试：VolatilityFactorCalculator 的已实现波动 metric。
///
/// golden 策略：交替 ±10% 收益率序列（c_{i+1} = c_i × 1.1 / × 0.9 交替）
/// 的收益率恰为 ±0.1，均值恰为 0——闭式 vol = sqrt(w × 0.01 / (w−1))，
/// 与实现的逐收益率路径构成交叉验证；w=2 时 sqrt(0.02) 是可手算的经典值。
final class VolatilityFactorTests: XCTestCase {

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

    /// 交替 ±10% 收益序列（bar 数 = returns + 1）。
    private func alternatingSeries(returns: Int) -> [Decimal] {
        var closes: [Decimal] = [Decimal(100)]
        let up = Decimal(string: "1.1")!
        let down = Decimal(string: "0.9")!
        for i in 0..<returns {
            let next = closes.last! * (i % 2 == 0 ? up : down)
            closes.append(next)
        }
        return closes
    }

    private func metrics(for closes: [Decimal], windows: [Int] = [20, 60]) -> [String: FactorMetric] {
        Dictionary(
            uniqueKeysWithValues: VolatilityFactorCalculator(windows: windows)
                .compute(inputs: FactorInputs(assetSeries: series(closes)))
                .map { ($0.definition.key, $0) }
        )
    }

    // MARK: - golden

    func testGolden_window2_handComputable() {
        // [100, 110, 99]：r = [+0.1, −0.1]，mean = 0，
        // var = (0.01+0.01)/1 = 0.02，vol = sqrt(0.02) = 0.141421356237...
        let m = metrics(for: [Decimal(100), Decimal(110), Decimal(99)], windows: [2])
        XCTAssertEqual(m["volatility.realized2"]?.value, Decimal(string: "0.141421356237"))
        XCTAssertNil(m["volatility.realized2"]?.insufficiency)
    }

    func testGolden_window20_crossCheckWithClosedForm() {
        // 交替序列 20 个收益率：mean = 0，var = 20 × 0.01 / 19，闭式 vs 实现逐收益路径
        let m = metrics(for: alternatingSeries(returns: 20))
        let closedForm = (Decimal(string: "0.2")! / 19).decimalSquareRoot().rounded(toScale: 12)
        XCTAssertEqual(m["volatility.realized20"]?.value, closedForm)
        // 60 窗口同序列仍不足（需 61 根）
        XCTAssertNil(m["volatility.realized60"]?.value)
    }

    func testGolden_window60_crossCheckWithClosedForm() {
        let m = metrics(for: alternatingSeries(returns: 60))
        let closedForm = (Decimal(string: "0.6")! / 59).decimalSquareRoot().rounded(toScale: 12)
        XCTAssertEqual(m["volatility.realized60"]?.value, closedForm)
    }

    // MARK: - 语义

    func testConstantSeriesHasZeroVol_whenDataSufficient() {
        // 恒定价格 → 收益全 0 → vol = 0（计算结果，非默认值）
        let m = metrics(for: Array(repeating: Decimal(100), count: 21))
        XCTAssertEqual(m["volatility.realized20"]?.value, 0)
    }

    func testInsufficiencyTiers() {
        let empty = metrics(for: [])
        XCTAssertEqual(empty["volatility.realized20"]?.insufficiency?.reason, .emptySeries)

        let at20 = metrics(for: Array(repeating: Decimal(100), count: 20))
        XCTAssertEqual(at20["volatility.realized20"]?.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(at20["volatility.realized20"]?.insufficiency?.requiredBars, 21)
        XCTAssertEqual(at20["volatility.realized20"]?.insufficiency?.actualBars, 20)

        let at61 = metrics(for: Array(repeating: Decimal(100), count: 61))
        XCTAssertNotNil(at61["volatility.realized60"]?.value)
    }

    func testDefinitionsDeclareUnitsAndDenominator() {
        let defs = VolatilityFactorCalculator().definitions
        XCTAssertEqual(defs.map(\.key), ["volatility.realized20", "volatility.realized60"])
        XCTAssertTrue(defs.allSatisfy { $0.version == "v1" && $0.unit == .ratioPerDay })
        // 样本分母 n−1（Bessel）作为参数显式声明，可审计
        XCTAssertTrue(defs.allSatisfy { def in
            def.parameters.contains { $0.name == "denominator" && $0.value == "n-1" }
        })
    }
}
