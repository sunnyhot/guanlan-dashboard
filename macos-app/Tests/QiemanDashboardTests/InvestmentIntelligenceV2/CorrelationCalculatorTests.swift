import XCTest
@testable import QiemanDashboard

/// RISK-2 单元测试：CorrelationCalculator——Pearson 数学 + 不足→unknown 不猜。
final class CorrelationCalculatorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// 交替 ±10% 收益序列（returns 根 bar）
    private func alternatingSeries(listing: String, returns: Int, invert: Bool = false) -> [AdjustedClosePoint] {
        var closes: [Decimal] = [100]
        let up = Decimal(string: "1.1")!
        let down = Decimal(string: "0.9")!
        for i in 0..<returns {
            let gain = i % 2 == 0
            let factor = invert ? (gain ? down : up) : (gain ? up : down)
            closes.append(closes.last! * factor)
        }
        return closes.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "\(listing)\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: c
            )
        }
    }

    private func compute(
        _ series: [ListingID: [AdjustedClosePoint]],
        pairs: [(ListingID, ListingID)],
        parameters: CorrelationCalculator.Parameters = .init()
    ) -> [CorrelationPair] {
        CorrelationCalculator(parameters: parameters).compute(series: series, pairs: pairs)
    }

    // MARK: - golden(交替 ±10% 序列)

    func testPerfectPositiveCorrelation() {
        let a = alternatingSeries(listing: "A", returns: 40)
        // B = A × 2 → 同收益率 → r = +1
        let b = a.map { point in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "bm\(point.observationID.rawValue)"),
                effectiveAt: point.effectiveAt,
                adjustedClose: point.adjustedClose * 2
            )
        }
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertEqual(result[0].pearson?.value, 1)
        XCTAssertEqual(result[0].sampleCount, 40)
        XCTAssertNil(result[0].insufficiency)
    }

    func testPerfectNegativeCorrelation() {
        let a = alternatingSeries(listing: "A", returns: 40)
        let b = alternatingSeries(listing: "B", returns: 40, invert: true)
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertEqual(result[0].pearson?.value, Decimal(string: "-1"))
        XCTAssertEqual(result[0].sampleCount, 40)
    }

    // MARK: - 不足 → unknown(不猜)三态

    func testInsufficientSamplesReportsUnknown() {
        // 默认 minSampleCount = 30:只给 29 个配对收益率 → unknown,不以 0 填充
        let a = alternatingSeries(listing: "A", returns: 29)
        let b = alternatingSeries(listing: "B", returns: 29, invert: true)
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertNil(result[0].pearson, "样本不足不猜方向")
        XCTAssertEqual(result[0].sampleCount, 29)
        XCTAssertEqual(result[0].insufficiency?.reason, .insufficientSamples)
        XCTAssertEqual(result[0].insufficiency?.requiredSamples, 30)
    }

    func testNoOverlappingDatesReportsUnknown() {
        let a = alternatingSeries(listing: "A", returns: 40)
        // B 整体平移 200 天:同日无配对
        let b = alternatingSeries(listing: "B", returns: 40).map { point in
            AdjustedClosePoint(
                observationID: point.observationID,
                effectiveAt: point.effectiveAt.addingTimeInterval(200 * 86400),
                adjustedClose: point.adjustedClose
            )
        }
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertNil(result[0].pearson)
        XCTAssertEqual(result[0].sampleCount, 0)
        XCTAssertEqual(result[0].insufficiency?.reason, .noOverlappingDates)
    }

    func testZeroVarianceReportsUnknown() {
        // A 恒定(收益率全 0,零方差):数学无定义,不猜
        let flat = (0..<40).map { i in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "f\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: 100
            )
        }
        let b = alternatingSeries(listing: "B", returns: 40)
        let result = compute([ListingID(rawValue: "A"): flat, ListingID(rawValue: "B"): b],
                             pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertNil(result[0].pearson)
        XCTAssertEqual(result[0].sampleCount, 39)
        XCTAssertEqual(result[0].insufficiency?.reason, .zeroVariance)
    }

    // MARK: - 窗口与参数

    func testWindowTruncatesTail() {
        // 100 个收益率,windowReturns=60 → 只用尾部 60 个
        let a = alternatingSeries(listing: "A", returns: 100)
        let b = a.map { point in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "s\(point.observationID.rawValue)"),
                effectiveAt: point.effectiveAt,
                adjustedClose: point.adjustedClose * 3
            )
        }
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))])
        XCTAssertEqual(result[0].sampleCount, 60)
        XCTAssertEqual(result[0].pearson?.value, 1)
    }

    func testMinSampleCountIsVersionedParameter() {
        // 阈值降到 20:29 个样本即可计算
        let a = alternatingSeries(listing: "A", returns: 29)
        let b = alternatingSeries(listing: "B", returns: 29, invert: true)
        let result = compute(
            [ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b],
            pairs: [(ListingID(rawValue: "A"), ListingID(rawValue: "B"))],
            parameters: .init(windowReturns: 60, minSampleCount: 20)
        )
        XCTAssertNotNil(result[0].pearson)
        XCTAssertEqual(result[0].pearson?.value, Decimal(string: "-1"))
    }

    func testPairsOrderPreservedAndCodable() throws {
        let a = alternatingSeries(listing: "A", returns: 40)
        let b = alternatingSeries(listing: "B", returns: 40, invert: true)
        let pairDefs: [(ListingID, ListingID)] = [
            (ListingID(rawValue: "A"), ListingID(rawValue: "B")),
            (ListingID(rawValue: "B"), ListingID(rawValue: "A")),
        ]
        let result = compute([ListingID(rawValue: "A"): a, ListingID(rawValue: "B"): b], pairs: pairDefs)
        XCTAssertEqual(result.map { "\($0.listingA.rawValue)|\($0.listingB.rawValue)" }, ["A|B", "B|A"])

        let data = try JSONEncoder().encode(result[0])
        let decoded = try JSONDecoder().decode(CorrelationPair.self, from: data)
        XCTAssertEqual(decoded, result[0])
    }
}
