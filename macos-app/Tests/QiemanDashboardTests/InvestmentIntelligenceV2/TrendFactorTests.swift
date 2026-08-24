import XCTest
@testable import QiemanDashboard

/// FAC-3 单元测试：TrendFactorCalculator 的四个趋势 metric。
///
/// golden 策略：等差序列（close[i] = 100 + i）的 MA 可闭式手算——
/// MA20_t = close_{t−19..t} 均值 = 100 + t − 9.5；期望值同时用测试内
/// **独立朴素实现**（逐根循环求和）交叉验证，防止实现与手算同源错误。
final class TrendFactorTests: XCTestCase {

    /// 等差序列 close[i] = 100 + i（i = 0..<count）。
    /// effectiveAt 只需单调递增（趋势因子按 bar 计数取窗口）。
    private func ascendingSeries(count: Int) -> [AdjustedClosePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "b\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: Decimal(100 + i)
            )
        }
    }

    /// 独立朴素 MA（逐根循环，与实现不同代码路径）。
    private func naiveMA(_ closes: [Decimal], window: Int, endIdx: Int) -> Decimal {
        var sum: Decimal = 0
        for i in (endIdx - window + 1)...endIdx { sum += closes[i] }
        return sum / Decimal(window)
    }

    private func metrics(for count: Int, horizon: Int = 5) -> [String: FactorMetric] {
        let calc = TrendFactorCalculator(slopeHorizon: horizon)
        let result = calc.compute(inputs: FactorInputs(assetSeries: ascendingSeries(count: count)))
        return Dictionary(uniqueKeysWithValues: result.map { ($0.definition.key, $0) })
    }

    // MARK: - golden 值（等差序列闭式解，手算锁定）

    func testGoldenValues_onAscendingSeries70Bars() {
        // closes[i] = 100 + i, i = 0..69；t = 69
        // MA20 = mean(150...169) = 159.5; close = 169 → 169/159.5 − 1
        // MA60 = mean(110...169) = 139.5 → 169/139.5 − 1
        // MA20@t−5 = mean(145...164) = 154.5 → 159.5/154.5 − 1
        // MA60@t−5 = mean(105...164) = 134.5 → 139.5/134.5 − 1
        let m = metrics(for: 70)
        XCTAssertEqual(m["trend.closeVsMA20"]?.value, Decimal(string: "0.059561128527"))
        XCTAssertEqual(m["trend.closeVsMA60"]?.value, Decimal(string: "0.21146953405"))
        XCTAssertEqual(m["trend.ma20Slope"]?.value, Decimal(string: "0.032362459547"))
        XCTAssertEqual(m["trend.ma60Slope"]?.value, Decimal(string: "0.03717472119"))
        // 全部充足：无 insufficiency
        XCTAssertTrue(m.values.allSatisfy { $0.insufficiency == nil })
    }

    // MARK: - 独立实现交叉验证（非等差序列）

    func testCrossCheckAgainstNaiveImplementation_onVariedSeries() {
        // 非等差序列（确定性伪随机），70 根
        var closes: [Decimal] = []
        var seed: UInt64 = 42
        for _ in 0..<70 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let wobble = Decimal(Int((seed >> 33) % 7)) - 3   // −3..+3
            let next = (closes.last ?? Decimal(100)) + wobble
            closes.append(next)
        }
        let series = closes.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "b\(i)"),
                effectiveAt: Date(timeIntervalSince1970: Double(i) * 86400),
                adjustedClose: c
            )
        }
        let m = Dictionary(
            uniqueKeysWithValues: TrendFactorCalculator(slopeHorizon: 5)
                .compute(inputs: FactorInputs(assetSeries: series))
                .map { ($0.definition.key, $0) }
        )

        let t = closes.count - 1
        let expectedCloseVsMA20 = closes[t] / naiveMA(closes, window: 20, endIdx: t) - 1
        let expectedCloseVsMA60 = closes[t] / naiveMA(closes, window: 60, endIdx: t) - 1
        let expectedSlope20 = naiveMA(closes, window: 20, endIdx: t) / naiveMA(closes, window: 20, endIdx: t - 5) - 1
        let expectedSlope60 = naiveMA(closes, window: 60, endIdx: t) / naiveMA(closes, window: 60, endIdx: t - 5) - 1

        XCTAssertEqual(m["trend.closeVsMA20"]?.value, expectedCloseVsMA20.rounded(toScale: 12))
        XCTAssertEqual(m["trend.closeVsMA60"]?.value, expectedCloseVsMA60.rounded(toScale: 12))
        XCTAssertEqual(m["trend.ma20Slope"]?.value, expectedSlope20.rounded(toScale: 12))
        XCTAssertEqual(m["trend.ma60Slope"]?.value, expectedSlope60.rounded(toScale: 12))
    }

    // MARK: - 数据不足分级（requiredBars 20 / 60 / 25 / 65）

    func testInsufficiencyTiers() {
        // 0 根：emptySeries
        let empty = metrics(for: 0)
        XCTAssertEqual(empty["trend.closeVsMA20"]?.insufficiency?.reason, .emptySeries)

        // 19 根：连最小窗口都不够
        let at19 = metrics(for: 19)
        XCTAssertEqual(at19["trend.closeVsMA20"]?.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(at19["trend.closeVsMA20"]?.insufficiency?.requiredBars, 20)
        XCTAssertEqual(at19["trend.closeVsMA20"]?.insufficiency?.actualBars, 19)

        // 24 根：closeVsMA20 有值，ma20Slope 仍缺 1 根（20+5）
        let at24 = metrics(for: 24)
        XCTAssertNotNil(at24["trend.closeVsMA20"]?.value)
        XCTAssertNil(at24["trend.ma20Slope"]?.value)
        XCTAssertEqual(at24["trend.ma20Slope"]?.insufficiency?.requiredBars, 25)

        // 60 根：closeVsMA60 有值，ma60Slope 仍缺（60+5）
        let at60 = metrics(for: 60)
        XCTAssertNotNil(at60["trend.closeVsMA60"]?.value)
        XCTAssertNil(at60["trend.ma60Slope"]?.value)
        XCTAssertEqual(at60["trend.ma60Slope"]?.insufficiency?.requiredBars, 65)

        // 65 根：ma60Slope 恰好够
        let at65 = metrics(for: 65)
        XCTAssertNotNil(at65["trend.ma60Slope"]?.value)
    }

    func testSlopeHorizonIsVersionedParameter() {
        let calc = TrendFactorCalculator(slopeHorizon: 10)
        let slopeDef = calc.definitions.first { $0.key == "trend.ma20Slope" }!
        XCTAssertEqual(
            slopeDef.parameters.first { $0.name == "slopeHorizon" }?.intValue, 10
        )
        XCTAssertEqual(
            slopeDef.parameters.first { $0.name == "windowBars" }?.intValue, 20
        )
        // horizon 影响 requiredBars（20+10）
        let at29 = Dictionary(
            uniqueKeysWithValues: calc.compute(inputs: FactorInputs(assetSeries: ascendingSeries(count: 29)))
                .map { ($0.definition.key, $0) }
        )
        XCTAssertNil(at29["trend.ma20Slope"]?.value)
        XCTAssertEqual(at29["trend.ma20Slope"]?.insufficiency?.requiredBars, 30)
    }

    func testDefinitionsDeclareUnitsAndVersions() {
        let defs = TrendFactorCalculator().definitions
        XCTAssertEqual(defs.map(\.key), [
            "trend.closeVsMA20", "trend.closeVsMA60", "trend.ma20Slope", "trend.ma60Slope",
        ])
        XCTAssertTrue(defs.allSatisfy { $0.version == "v1" })
        XCTAssertTrue(defs.allSatisfy { $0.unit == .ratio })
    }
}
