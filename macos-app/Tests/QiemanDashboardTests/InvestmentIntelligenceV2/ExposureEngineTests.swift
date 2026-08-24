import XCTest
@testable import QiemanDashboard

/// EXP-2 单元测试：ExposureEngine 的四维暴露估计 + 基金重叠。
final class ExposureEngineTests: XCTestCase {

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

    private func holding(
        id: String, product: String, effective: Date,
        positions: [(String, String)]
    ) -> FundHoldingSnapshot {
        let resolved = positions.map { ($0.0, Decimal(string: $0.1) ?? 0) }
        return FundHoldingSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: product),
            temporalEnvelope: envelope(effective),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.communityAggregated, providerID: .eastmoney),
            vintage: Vintage(announcementDate: effective, publisherVersion: 1),
            reportPeriod: .q2,
            positions: resolved.map {
                FundHoldingPosition(listingID: ListingID(rawValue: $0.0),
                                    weight: Ratio(value: $0.1), shares: nil,
                                    marketValue: nil, isDisclosed: true)
            },
            disclosedWeightTotal: Ratio(value: resolved.map(\.1).reduce(0, +))
        )
    }

    /// 最小 lookthrough:两基金(A 60% B 40%)+ 直接持股,用于三维转换验证。
    private func makeLookthrough() -> LookthroughSnapshot {
        let eff = Self.date(2024, 6, 30)
        let lookthrough = PortfolioLookthroughCalculator().compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.6")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.4")!), fundProductID: FundProductID(rawValue: "B")),
                .init(weight: Ratio(value: Decimal(string: "0.2")!),
                      directListingID: ListingID(rawValue: "L1"), directAssetClass: .equity),
            ],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", effective: eff,
                                       positions: [("X", "0.5"), ("Y", "0.5")]),
                      allocation: nil),
                .init(productID: FundProductID(rawValue: "B"),
                      holding: holding(id: "hB", product: "B", effective: eff,
                                       positions: [("X", "0.5")]),
                      allocation: nil),
            ],
            asOf: Self.date(2024, 7, 20), producedAt: Self.date(2024, 7, 20)
        )
        return lookthrough!
    }

    // MARK: - 三维转换（bounds 保持,unknown 进上下界）

    func testThreeDimensionsPreserveBoundsAndUnknown() {
        let lookthrough = makeLookthrough()
        // 组合权重归一:A=0.5 B=1/3 direct=1/6
        // X = 0.5×0.5 + (1/3)×0.5 = 0.416666666667;Y = 0.25;L1 = 0.166666666667
        let report = ExposureEngine().compute(
            lookthrough: lookthrough, holdings: [:], producedAt: Self.date(2024, 7, 20)
        )

        let securities = report.estimates.filter { $0.dimension == .singleSecurity }
        XCTAssertEqual(securities.map(\.key), ["X", "Y", "L1"], "lowerBound 降序")
        let x = securities.first { $0.key == "X" }!
        // X = 0.5×0.5 + (1/3)×0.5 = 5/12(独立分数算式,EXP-1 的 Ratio 全精度不舍入)
        XCTAssertEqual(x.lowerBound.value, Decimal(5) / Decimal(12))
        // unknown = (1/3)×0.5(基金 B 披露缺口)+ 0(基金 A)→ 0.166666666667
        // 上界 = 0.416666666667 + 0.166666666667 = 0.583333333333(先加后舍,容差比较)
        XCTAssertEqual(x.upperBound.value, lookthrough.underlyingPositions
            .first { $0.listingID.rawValue == "X" }!.upperBound.value, "上界语义从 EXP-1 原样保持")

        XCTAssertEqual(report.unknownPortfolioWeight, lookthrough.unknownPortfolioWeight)
    }

    func testAssetClassAndSectorDimensionsPresent() {
        let lookthrough = makeLookthrough()
        let report = ExposureEngine().compute(
            lookthrough: lookthrough, holdings: [:], producedAt: Self.date(2024, 7, 20)
        )
        // 资产大类:lookthrough 无 allocation → 全进 AC 维 unknown,estimates 无
        // assetClass 条目(直接持股 L1 有 .equity → equity 一条)
        let assetClasses = report.estimates.filter { $0.dimension == .assetClass }
        XCTAssertEqual(assetClasses.map(\.key), ["EQUITY"])
        XCTAssertEqual(assetClasses[0].lowerBound.value, Decimal(1) / Decimal(6))

        // 行业:无分类输入 → 空
        XCTAssertTrue(report.estimates.filter { $0.dimension == .sector }.isEmpty)
    }

    // MARK: - fund overlap(核心新维度)

    func testFundOverlap_disclosedAndUpperBound() {
        // A:{X: 40%, Y: 30%, Z: 30%}(披露全量)
        // B:{X: 50%, W: 50%}(披露全量)
        // overlap = min(0.4, 0.5) = 0.4;双方 unknown=0 → 上界=0.4
        let eff = Self.date(2024, 6, 30)
        let holdings: [FundProductID: FundHoldingSnapshot] = [
            FundProductID(rawValue: "A"): holding(id: "hA", product: "A", effective: eff,
                                                  positions: [("X", "0.4"), ("Y", "0.3"), ("Z", "0.3")]),
            FundProductID(rawValue: "B"): holding(id: "hB", product: "B", effective: eff,
                                                  positions: [("X", "0.5"), ("W", "0.5")]),
        ]
        let report = ExposureEngine().compute(
            lookthrough: makeLookthrough(), holdings: holdings, producedAt: Self.date(2024, 7, 20)
        )

        XCTAssertEqual(report.fundOverlaps.count, 1)
        let overlap = report.fundOverlaps[0]
        XCTAssertEqual(overlap.fundA, FundProductID(rawValue: "A"))
        XCTAssertEqual(overlap.fundB, FundProductID(rawValue: "B"))
        XCTAssertEqual(overlap.disclosedOverlap.value, Decimal(string: "0.4"))
        XCTAssertEqual(overlap.upperBound.value, Decimal(string: "0.4"), "双方披露全量时上界=披露重叠")
        XCTAssertEqual(overlap.commonListings, [ListingID(rawValue: "X")])

        // 统一 estimates 里也有 fundOverlap 维度(key "A|B")
        let overlapEstimates = report.estimates.filter { $0.dimension == .fundOverlap }
        XCTAssertEqual(overlapEstimates.map(\.key), ["A|B"])
        XCTAssertEqual(overlapEstimates[0].sourceObservationIDs.map(\.rawValue).sorted(), ["hA", "hB"])
    }

    func testFundOverlap_unknownEntersUpperBound() {
        // A:{X: 30%}(披露 30%,unknown 70%)
        // B:{X: 60%}(披露 60%,unknown 40%)
        // disclosed overlap = min(0.3, 0.6) = 0.3;上界 += min(0.7, 0.4) = 0.7
        let eff = Self.date(2024, 6, 30)
        let holdings: [FundProductID: FundHoldingSnapshot] = [
            FundProductID(rawValue: "A"): holding(id: "hA", product: "A", effective: eff,
                                                  positions: [("X", "0.3")]),
            FundProductID(rawValue: "B"): holding(id: "hB", product: "B", effective: eff,
                                                  positions: [("X", "0.6")]),
        ]
        let report = ExposureEngine().compute(
            lookthrough: makeLookthrough(), holdings: holdings, producedAt: Self.date(2024, 7, 20)
        )
        let overlap = report.fundOverlaps[0]
        XCTAssertEqual(overlap.disclosedOverlap.value, Decimal(string: "0.3"))
        XCTAssertEqual(overlap.upperBound.value, Decimal(string: "0.7"), "unknown 较小方进入上界")
    }

    func testFundOverlap_disjointHoldingsIsZero() {
        let eff = Self.date(2024, 6, 30)
        let holdings: [FundProductID: FundHoldingSnapshot] = [
            FundProductID(rawValue: "A"): holding(id: "hA", product: "A", effective: eff,
                                                  positions: [("X", "1.0")]),
            FundProductID(rawValue: "B"): holding(id: "hB", product: "B", effective: eff,
                                                  positions: [("Y", "1.0")]),
        ]
        let report = ExposureEngine().compute(
            lookthrough: makeLookthrough(), holdings: holdings, producedAt: Self.date(2024, 7, 20)
        )
        XCTAssertEqual(report.fundOverlaps[0].disclosedOverlap.value, 0)
        XCTAssertTrue(report.fundOverlaps[0].commonListings.isEmpty)
    }

    func testFundOverlap_topNTruncationAndOrdering() {
        // 4 只基金 → 6 对;overlapTopN=3 截断,按重叠度降序
        let eff = Self.date(2024, 6, 30)
        let holdings: [FundProductID: FundHoldingSnapshot] = [
            FundProductID(rawValue: "A"): holding(id: "hA", product: "A", effective: eff,
                                                  positions: [("X", "1.0")]),
            FundProductID(rawValue: "B"): holding(id: "hB", product: "B", effective: eff,
                                                  positions: [("X", "1.0"), ("Y", "0.0")]),
            FundProductID(rawValue: "C"): holding(id: "hC", product: "C", effective: eff,
                                                  positions: [("X", "0.5")]),
            FundProductID(rawValue: "D"): holding(id: "hD", product: "D", effective: eff,
                                                  positions: [("Z", "1.0")]),
        ]
        let report = ExposureEngine(parameters: .init(overlapTopN: 3)).compute(
            lookthrough: makeLookthrough(), holdings: holdings, producedAt: Self.date(2024, 7, 20)
        )
        XCTAssertEqual(report.fundOverlaps.count, 3)
        // 重叠度:A-B=1.0 > A-C=0.5 = B-C=0.5(同值按 key 序 B-C < C? B|C vs A|C:
        // ("B","C") < ("A","C")?字符串 "A" < "B",A|C 排前)→ [A|B, A|C, B|C]
        XCTAssertEqual(report.fundOverlaps.map { "\($0.fundA.rawValue)|\($0.fundB.rawValue)" },
                       ["A|B", "A|C", "B|C"])
        XCTAssertEqual(report.fundOverlaps[0].disclosedOverlap.value, Decimal(string: "1.0"))
        XCTAssertEqual(report.fundOverlaps[1].disclosedOverlap.value, Decimal(string: "0.5"))
    }

    // MARK: - Artifact / 确定性 / Codable

    func testNoHoldingsYieldsEmptyOverlaps() {
        let report = ExposureEngine().compute(
            lookthrough: makeLookthrough(), holdings: [:], producedAt: Self.date(2024, 7, 20)
        )
        XCTAssertTrue(report.fundOverlaps.isEmpty)
        XCTAssertTrue(report.estimates.filter { $0.dimension == .fundOverlap }.isEmpty)
    }

    func testArtifactConformanceAndDeterministicId() {
        let lookthrough = makeLookthrough()
        let eff = Self.date(2024, 6, 30)
        let holdings: [FundProductID: FundHoldingSnapshot] = [
            FundProductID(rawValue: "A"): holding(id: "hA", product: "A", effective: eff,
                                                  positions: [("X", "1.0")]),
            FundProductID(rawValue: "B"): holding(id: "hB", product: "B", effective: eff,
                                                  positions: [("X", "1.0")]),
        ]
        let a = ExposureEngine().compute(lookthrough: lookthrough, holdings: holdings, producedAt: Self.date(2024, 7, 20))
        let b = ExposureEngine().compute(lookthrough: lookthrough, holdings: holdings, producedAt: Self.date(2024, 7, 20))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.validityPolicy, .untilDependencyChanges)
        XCTAssertEqual(a.engineVersion, "v1")

        // dependencies 覆盖 lookthrough 源 + holdings(去重排序)
        XCTAssertEqual(
            Set(a.dependencies.map(\.referenceID)),
            Set(lookthrough.sourceObservationIDs.map(\.rawValue) + ["hA", "hB"])
        )
        XCTAssertTrue(a.dependencies.allSatisfy { $0.kind == .observation })
    }

    func testCodableRoundTrip() throws {
        let lookthrough = makeLookthrough()
        let report = ExposureEngine().compute(
            lookthrough: lookthrough, holdings: [:], producedAt: Self.date(2024, 7, 20)
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ExposureReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
