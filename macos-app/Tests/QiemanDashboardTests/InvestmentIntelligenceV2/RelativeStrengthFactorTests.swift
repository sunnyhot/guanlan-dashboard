import XCTest
@testable import QiemanDashboard

/// FAC-7 单元测试：RelativeStrengthFactorCalculator 的相对强度 metric。
final class RelativeStrengthFactorTests: XCTestCase {

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

    private func metrics(
        asset: [Decimal], benchmark: [Decimal]?,
        benchmarkID: ListingID? = ListingID(rawValue: "bench"),
        windows: [Int] = [20]
    ) -> [String: FactorMetric] {
        let calc = RelativeStrengthFactorCalculator(benchmarkListingID: benchmarkID, windows: windows)
        let inputs = FactorInputs(
            assetSeries: series(asset),
            benchmarkSeries: benchmark.map { series($0) } ?? []
        )
        return Dictionary(
            uniqueKeysWithValues: calc.compute(inputs: inputs).map { ($0.definition.key, $0) }
        )
    }

    /// 首尾锚定、中间线性插值的序列（区间收益只看首尾，中间形状无关）。
    private func bridging(count: Int, from first: Decimal, to last: Decimal) -> [Decimal] {
        guard count > 1 else { return [first] }
        return (0..<count).map { i in
            first + (last - first) * Decimal(i) / Decimal(count - 1)
        }
    }

    // MARK: - golden

    func testGolden_assetOutperformsBenchmark() {
        // asset 21 根：100 → 110（ret20 = +0.1）
        // benchmark 21 根：200 → 190（ret20 = −0.05）
        // RS20 = 0.1 − (−0.05) = 0.15
        let asset = bridging(count: 21, from: 100, to: 110)
        let benchmark = bridging(count: 21, from: 200, to: 190)
        let m = metrics(asset: asset, benchmark: benchmark)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.value, Decimal(string: "0.15"))
        XCTAssertNil(m["relativeStrength.vsBenchmark20"]?.insufficiency)
    }

    func testGolden_assetUnderperforms() {
        let asset = bridging(count: 21, from: 100, to: 90)        // −0.1
        let benchmark = bridging(count: 21, from: 200, to: 204)   // +0.02
        let m = metrics(asset: asset, benchmark: benchmark)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.value, Decimal(string: "-0.12"))
    }

    // MARK: - 独立尾部对齐（跨市场日历错开）

    func testIndependentTailAlignment_calendarOffsetSeries() {
        // asset 与 benchmark 交易日历错开（effectiveAt 偏移 12 小时），
        // 两侧 bar 数相同即可计算——不做逐日对齐
        let asset = bridging(count: 21, from: 100, to: 120)       // +0.2
        let benchmark = bridging(count: 21, from: 500, to: 500)   // 0
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let assetSeries = asset.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "a\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: c
            )
        }
        let benchmarkSeries = benchmark.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "bm\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400 + 43200),
                adjustedClose: c
            )
        }
        let result = RelativeStrengthFactorCalculator(
            benchmarkListingID: ListingID(rawValue: "bench"), windows: [20]
        ).compute(inputs: FactorInputs(assetSeries: assetSeries, benchmarkSeries: benchmarkSeries))
        XCTAssertEqual(result.first?.value, Decimal(string: "0.2"))
    }

    // MARK: - benchmark 显式 + 缺失语义

    func testBenchmarkMissing_whenNotSpecified() {
        // 未指定 benchmark（engine 没传 benchmarkListingID）→ benchmarkMissing，不猜代理
        let asset = bridging(count: 21, from: 100, to: 110)
        let m = metrics(asset: asset, benchmark: nil, benchmarkID: nil)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.insufficiency?.reason, .benchmarkMissing)
        XCTAssertNil(m["relativeStrength.vsBenchmark20"]?.value)
    }

    func testBenchmarkMissing_whenSeriesEmpty() {
        // 声明了 benchmark 但序列为空（benchmark 尚未回填）→ benchmarkMissing
        let asset = bridging(count: 21, from: 100, to: 110)
        let m = metrics(asset: asset, benchmark: [])
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.insufficiency?.reason, .benchmarkMissing)
    }

    func testInsufficientBars_reportsBottleneckSide() {
        // asset 21 根充足，benchmark 只有 15 根 → actualBars = 15（瓶颈侧）
        let asset = bridging(count: 21, from: 100, to: 110)
        let benchmark = bridging(count: 15, from: 200, to: 190)
        let m = metrics(asset: asset, benchmark: benchmark)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.insufficiency?.requiredBars, 21)
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.insufficiency?.actualBars, 15)

        // 反向：benchmark 充足、asset 不足 → actualBars = asset 数
        let m2 = metrics(asset: bridging(count: 10, from: 100, to: 110), benchmark: benchmark)
        // benchmark 也只有 15 根仍不足 → min(10, 15) = 10
        XCTAssertEqual(m2["relativeStrength.vsBenchmark20"]?.insufficiency?.actualBars, 10)
    }

    func testDefinitionsDeclareBenchmarkExplicitly() {
        let bench = ListingID(rawValue: "list_sh000300")
        let defs = RelativeStrengthFactorCalculator(benchmarkListingID: bench, windows: [20, 60]).definitions
        XCTAssertEqual(defs.map(\.key), [
            "relativeStrength.vsBenchmark20", "relativeStrength.vsBenchmark60",
        ])
        XCTAssertTrue(defs.allSatisfy { def in
            def.parameters.contains { $0.name == "benchmarkListingID" && $0.value == "list_sh000300" }
                && def.parameters.contains { $0.name == "alignment" && $0.value == "independent-tail" }
        })

        // 未指定时 benchmark 参数为空串（显式「无 benchmark」状态）
        let noBenchDefs = RelativeStrengthFactorCalculator(benchmarkListingID: nil).definitions
        XCTAssertTrue(noBenchDefs.allSatisfy { def in
            def.parameters.contains { $0.name == "benchmarkListingID" && $0.value.isEmpty }
        })
    }
}
