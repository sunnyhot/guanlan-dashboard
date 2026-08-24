import XCTest
@testable import QiemanDashboard

/// RISK-1 单元测试：ConcentrationCalculator——重复持股识别 + HHI 数学。
final class ConcentrationCalculatorTests: XCTestCase {

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

    private func compute(
        positions: [LookthroughPositionInput],
        disclosures: [FundDisclosureInput],
        sectors: [ListingID: SectorClassification] = [:]
    ) -> ConcentrationAssessment {
        let lookthrough = PortfolioLookthroughCalculator(parameters: .init(sectorClassifications: sectors))
            .compute(positions: positions, disclosures: disclosures,
                     asOf: Self.date(2024, 7, 20), producedAt: Self.date(2024, 7, 20))!
        return ConcentrationCalculator().compute(lookthrough: lookthrough)
    }

    // MARK: - 核心验收:多基金重复持股识别

    func testDuplicateHoldingAcrossFundsIdentified() {
        // 基金 A(50%)持 X 40% + Y 60%;基金 B(50%)持 X 50% + Z 50%
        // 基金层:各 50%,largest fund = 50%(分散假象)
        // 穿透层:X = 0.5×0.4 + 0.5×0.5 = 45%(重复持股暴露)
        let a = compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "B")),
            ],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", positions: [("X", "0.4"), ("Y", "0.6")]),
                      allocation: nil),
                .init(productID: FundProductID(rawValue: "B"),
                      holding: holding(id: "hB", product: "B", positions: [("X", "0.5"), ("Z", "0.5")]),
                      allocation: nil),
            ]
        )

        XCTAssertEqual(a.largestSingleFund?.productID, FundProductID(rawValue: "A"), "同权重按 key 序")
        XCTAssertEqual(a.largestSingleFund?.weight.value, Decimal(string: "0.5"))
        XCTAssertEqual(a.fundHHI.value, Decimal(string: "0.5"))

        XCTAssertEqual(a.largestUnderlyingSecurity?.listingID, ListingID(rawValue: "X"))
        XCTAssertEqual(a.largestUnderlyingSecurity?.weight.value, Decimal(string: "0.45"),
                       "穿透层反映合并权重,穿透是重复持股的识别通道")
        // HHI = 0.45² + 0.3² + 0.25² = 0.2025 + 0.09 + 0.0625 = 0.355
        XCTAssertEqual(a.securityHHI.value, Decimal(string: "0.355"))
    }

    // MARK: - HHI 数学

    func testHHIMath_edgeShapes() {
        // 单标的 100%(直接持股):HHI = 1
        let single = compute(
            positions: [.init(weight: Ratio(value: 1), directListingID: ListingID(rawValue: "L1"))],
            disclosures: []
        )
        XCTAssertEqual(single.securityHHI.value, 1)
        XCTAssertEqual(single.largestUnderlyingSecurity?.weight.value, 1)
        XCTAssertNil(single.largestSingleFund)
        XCTAssertEqual(single.fundHHI.value, 0)
        XCTAssertEqual(single.top5UnderlyingWeight.value, 1)
        // unknown = 0 → 上界 = 下界
        XCTAssertEqual(single.securityHHIUpperBound.value, single.securityHHI.value)

        // 等权 4 标的:HHI = 4 × 0.25² = 0.25
        let equal = compute(
            positions: [
                .init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A")),
            ],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A",
                                       positions: [("L1", "0.25"), ("L2", "0.25"), ("L3", "0.25"), ("L4", "0.25")]),
                      allocation: nil),
            ]
        )
        XCTAssertEqual(equal.securityHHI.value, Decimal(string: "0.25"))
        XCTAssertEqual(equal.top5UnderlyingWeight.value, 1)
        XCTAssertEqual(equal.underlyingCount, 4)
    }

    func testHHIUpperBound_formula() {
        // 披露 60%:{X: 60%};unknown = 40%
        // HHI = 0.36;上界 = 0.36 + 2×0.6×0.4 + 0.16 = 0.36 + 0.48 + 0.16 = 1.0
        // (最坏:unknown 全是 X → X = 100%)
        let a = compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", positions: [("X", "0.6")]),
                      allocation: nil),
            ]
        )
        XCTAssertEqual(a.unknownPortfolioWeight.value, Decimal(string: "0.4"))
        XCTAssertEqual(a.securityHHI.value, Decimal(string: "0.36"))
        XCTAssertEqual(a.securityHHIUpperBound.value, 1)
    }

    // MARK: - 行业层

    func testSectorLayer_whenInputPresent() {
        let a = compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A",
                                       positions: [("X", "0.6"), ("Y", "0.4")]),
                      allocation: nil),
            ],
            sectors: [
                ListingID(rawValue: "X"): .init(label: "制造业"),
                ListingID(rawValue: "Y"): .init(label: "制造业"),
            ]
        )
        XCTAssertEqual(a.largestSector?.label, "制造业")
        XCTAssertEqual(a.largestSector?.weight.value, Decimal(string: "1.0"))
        XCTAssertEqual(a.sectorHHI?.value, 1)
    }

    func testSectorLayer_nilWithoutInput() {
        let a = compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", positions: [("X", "1.0")]),
                      allocation: nil),
            ]
        )
        XCTAssertNil(a.largestSector)
        XCTAssertNil(a.sectorHHI)
    }

    func testCodableRoundTrip() throws {
        let a = compute(
            positions: [.init(weight: Ratio(value: 1), directListingID: ListingID(rawValue: "L1"))],
            disclosures: []
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(ConcentrationAssessment.self, from: data)
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(decoded.calculatorVersion, "v1")
    }
}
