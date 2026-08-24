import XCTest
@testable import QiemanDashboard

/// RISK-3 单元测试：PortfolioRiskProfiler——多维聚合 + 不产单一分数。
final class PortfolioRiskProfilerTests: XCTestCase {

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private func envelope(_ effective: Date) -> TemporalEnvelope {
        TemporalEnvelope(effectiveAt: effective, publishedAt: effective,
                         availableAt: effective, ingestedAt: effective)
    }

    private func makeProv() -> AvailabilityProvenance {
        AvailabilityProvenance(policyID: "fund_disclosure", policyVersion: "v1", derivedAt: Self.date(2024, 1, 1))
    }

    private func holding(id: String, product: String, positions: [(String, String)]) -> FundHoldingSnapshot {
        let resolved = positions.map { ($0.0, Decimal(string: $0.1) ?? 0) }
        return FundHoldingSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: product),
            temporalEnvelope: envelope(Self.date(2024, 6, 30)),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.communityAggregated, providerID: .eastmoney),
            vintage: Vintage(announcementDate: Self.date(2024, 6, 30), publisherVersion: 1),
            reportPeriod: .q2,
            positions: resolved.map {
                FundHoldingPosition(listingID: ListingID(rawValue: $0.0),
                                    weight: Ratio(value: $0.1), shares: nil,
                                    marketValue: nil, isDisclosed: true)
            },
            disclosedWeightTotal: Ratio(value: resolved.map(\.1).reduce(0, +))
        )
    }

    /// 三标的 lookthrough(X 50% Y 30% Z 20%,全披露)。
    private func makeLookthrough() -> LookthroughSnapshot {
        PortfolioLookthroughCalculator().compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A",
                                       positions: [("X", "0.5"), ("Y", "0.3"), ("Z", "0.2")]),
                      allocation: nil),
            ],
            asOf: Self.date(2024, 7, 20), producedAt: Self.date(2024, 7, 20)
        )!
    }

    /// 交替 ±10% 序列(returns 根 bar),可反转相位构造 ±1 相关。
    private func alternating(listing: String, returns: Int, invert: Bool = false) -> [AdjustedClosePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var closes: [Decimal] = [100]
        let up = Decimal(string: "1.1")!, down = Decimal(string: "0.9")!
        for i in 0..<returns {
            let gain = i % 2 == 0
            closes.append(closes.last! * (invert == gain ? down : up))
        }
        return closes.enumerated().map { i, c in
            AdjustedClosePoint(
                observationID: ObservationID(rawValue: "\(listing)\(i)"),
                effectiveAt: start.addingTimeInterval(Double(i) * 86400),
                adjustedClose: c
            )
        }
    }

    // MARK: - 聚合正确性

    func testAggregatesConcentrationAndCorrelations() {
        let lookthrough = makeLookthrough()
        // X 与 Y 完全正相关(同相);X 与 Z 完全负相关(反相)
        let series: [ListingID: [AdjustedClosePoint]] = [
            ListingID(rawValue: "X"): alternating(listing: "X", returns: 40),
            ListingID(rawValue: "Y"): alternating(listing: "Y", returns: 40),
            ListingID(rawValue: "Z"): alternating(listing: "Z", returns: 40, invert: true),
        ]
        let profile = PortfolioRiskProfiler().profile(
            lookthrough: lookthrough, series: series, producedAt: Self.date(2024, 7, 20)
        )

        // 集中度维度(RISK-1)
        XCTAssertEqual(profile.concentration.largestUnderlyingSecurity?.listingID, ListingID(rawValue: "X"))
        XCTAssertEqual(profile.concentration.largestUnderlyingSecurity?.weight.value, Decimal(string: "0.5"))

        // 相关性维度(RISK-2):前 3 标的 → 3 对,全部已知
        XCTAssertEqual(profile.correlations.count, 3)
        XCTAssertEqual(profile.dataBasis.knownCorrelationPairs, 3)
        XCTAssertEqual(profile.dataBasis.unknownCorrelationPairs, 0)
        let xy = profile.correlations.first {
            $0.listingA.rawValue == "X" && $0.listingB.rawValue == "Y"
        }!
        XCTAssertEqual(xy.pearson?.value, 1)
        let xz = profile.correlations.first {
            $0.listingA.rawValue == "X" && $0.listingB.rawValue == "Z"
        }!
        XCTAssertEqual(xz.pearson?.value, Decimal(string: "-1"))

        // 数据基础维度
        XCTAssertEqual(profile.dataBasis.disclosedSecurityCoverage.value, 1)
        XCTAssertEqual(profile.dataBasis.unknownPortfolioWeight.value, 0)
    }

    func testCorrelationTopNTruncates() {
        // 5 标的 lookthrough,correlationTopN 默认 5 → 10 对
        let lookthrough = PortfolioLookthroughCalculator().compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A",
                                       positions: [("L1", "0.3"), ("L2", "0.25"), ("L3", "0.2"), ("L4", "0.15"), ("L5", "0.1")]),
                      allocation: nil),
            ],
            asOf: Self.date(2024, 7, 20), producedAt: Self.date(2024, 7, 20)
        )!
        // 不给任何序列:10 对全部 unknown(noOverlappingDates)
        let profile = PortfolioRiskProfiler().profile(
            lookthrough: lookthrough, series: [:], producedAt: Self.date(2024, 7, 20)
        )
        XCTAssertEqual(profile.correlations.count, 10)
        XCTAssertEqual(profile.dataBasis.knownCorrelationPairs, 0)
        XCTAssertEqual(profile.dataBasis.unknownCorrelationPairs, 10)
        XCTAssertTrue(profile.correlations.allSatisfy { $0.pearson == nil })
    }

    func testInsufficientSeriesCountsAsUnknown() {
        let lookthrough = makeLookthrough()
        // 只给 10 根 bar(9 个收益率 < minSample 30)→ insufficientSamples → unknown 对
        let series: [ListingID: [AdjustedClosePoint]] = [
            ListingID(rawValue: "X"): alternating(listing: "X", returns: 9),
            ListingID(rawValue: "Y"): alternating(listing: "Y", returns: 9),
            ListingID(rawValue: "Z"): alternating(listing: "Z", returns: 9),
        ]
        let profile = PortfolioRiskProfiler().profile(
            lookthrough: lookthrough, series: series, producedAt: Self.date(2024, 7, 20)
        )
        XCTAssertEqual(profile.dataBasis.knownCorrelationPairs, 0)
        XCTAssertEqual(profile.dataBasis.unknownCorrelationPairs, 3)
    }

    // MARK: - 不产单一分数(类型保证)

    func testNoAggregateScoreSurface() {
        let profile = PortfolioRiskProfiler().profile(
            lookthrough: makeLookthrough(), series: [:], producedAt: Self.date(2024, 7, 20)
        )
        // 存储属性白名单:没有 score / rating / riskLevel 之类聚合分数字段
        let labels = Mirror(reflecting: profile).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "id", "producedAt", "validityPolicy", "dependencies",
            "asOf", "profileVersion", "concentration", "correlations", "dataBasis",
        ])
        // ConcentrationAssessment 同样无单一分数(RISK-1 已保证,聚合层复核)
        let concentrationLabels = Mirror(reflecting: profile.concentration).children.compactMap(\.label)
        XCTAssertTrue(concentrationLabels.allSatisfy { !$0.lowercased().contains("score") })
    }

    // MARK: - Artifact / 确定性 / Codable

    func testArtifactConformanceAndDeterministicId() {
        let lookthrough = makeLookthrough()
        let series: [ListingID: [AdjustedClosePoint]] = [
            ListingID(rawValue: "X"): alternating(listing: "X", returns: 40),
        ]
        let a = PortfolioRiskProfiler().profile(lookthrough: lookthrough, series: series, producedAt: Self.date(2024, 7, 20))
        let b = PortfolioRiskProfiler().profile(lookthrough: lookthrough, series: series, producedAt: Self.date(2024, 7, 20))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.validityPolicy, .untilDependencyChanges)
        XCTAssertEqual(a.profileVersion, "v1")

        // dependencies 覆盖 lookthrough 源 + series observations(去重)
        XCTAssertEqual(
            Set(a.dependencies.map(\.referenceID)),
            Set(lookthrough.sourceObservationIDs.map(\.rawValue)
                + series.values.flatMap { $0.map(\.observationID).map(\.rawValue) })
        )
        XCTAssertTrue(a.dependencies.allSatisfy { $0.kind == .observation })
    }

    func testCodableRoundTrip() throws {
        let profile = PortfolioRiskProfiler().profile(
            lookthrough: makeLookthrough(), series: [:], producedAt: Self.date(2024, 7, 20)
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PortfolioRiskProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }
}
