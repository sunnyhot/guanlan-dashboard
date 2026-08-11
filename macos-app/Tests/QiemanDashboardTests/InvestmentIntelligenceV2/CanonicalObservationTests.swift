import XCTest
@testable import QiemanDashboard

/// DOM-5 单元测试：CanonicalObservation 各具体类型（DailyBar / NAV /
/// FundHoldingSnapshot / MacroObservation / CorporateAction /
/// EvidenceObservation）的 ADR-DATA003 行为。
///
/// 重点验证：raw + adjustment 分离、Codable round-trip、强类型单位、
/// 协议多态（CanonicalObservation 容器）。
final class CanonicalObservationTests: XCTestCase {

    private let envelope = TemporalEnvelope(
        effectiveAt: Date(timeIntervalSince1970: 1_720_000_000),
        publishedAt: Date(timeIntervalSince1970: 1_720_086_400),
        availableAt: Date(timeIntervalSince1970: 1_720_172_800),
        ingestedAt: Date(timeIntervalSince1970: 1_720_259_200)
    )
    private let prov = AvailabilityProvenance(
        policyID: "market_close", policyVersion: "v1",
        derivedAt: Date(timeIntervalSince1970: 1_720_172_800)
    )
    private let vintage1 = Vintage(
        announcementDate: Date(timeIntervalSince1970: 1_720_086_400),
        publisherVersion: 1
    )

    // MARK: - DailyBar（raw + adjustment 分离）

    func testDailyBar_codableRoundTrip() throws {
        let bar = DailyBar(
            id: ObservationID(rawValue: "obs_bar_1"),
            listingID: ListingID(rawValue: "list_600519"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .officialStable),
            vintage: vintage1,
            rawOpen: Price(value: 1700, currency: .cny),
            rawHigh: Price(value: 1720, currency: .cny),
            rawLow: Price(value: 1695, currency: .cny),
            rawClose: Price(value: 1710, currency: .cny),
            volume: 1_200_000,
            adjustmentFactor: 1.0,
            fxRate: nil
        )
        let data = try JSONEncoder().encode(bar)
        let decoded = try JSONDecoder().decode(DailyBar.self, from: data)
        XCTAssertEqual(bar, decoded)
        XCTAssertEqual(decoded.rawClose.currency, .cny)
        XCTAssertEqual(decoded.adjustmentFactor, 1.0)
    }

    func testDailyBar_adjustmentFactorForSplits() {
        // 1:10 拆股后 adjustmentFactor = 0.1（raw 价 / 10 = 复权价）
        let bar = DailyBar(
            id: ObservationID(rawValue: "obs_bar_split"),
            listingID: ListingID(rawValue: "list_aapl"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .documentFreeAPI),
            vintage: vintage1,
            rawOpen: Price(value: 5000, currency: .usd),
            rawHigh: Price(value: 5050, currency: .usd),
            rawLow: Price(value: 4980, currency: .usd),
            rawClose: Price(value: 5020, currency: .usd),
            volume: nil,
            adjustmentFactor: Decimal(string: "0.1")!,
            fxRate: nil
        )
        // raw 价 5020 / 10 = 502 复权价
        XCTAssertEqual(
            bar.rawClose.value * bar.adjustmentFactor,
            Decimal(string: "502")!
        )
    }

    // MARK: - NAVObservation

    func testNAVObservation_codableRoundTrip() throws {
        let nav = NAVObservation(
            id: ObservationID(rawValue: "obs_nav_1"),
            shareClassID: FundShareClassID(rawValue: "sc_110022_A"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .communityAggregated),
            vintage: vintage1,
            unitNAV: Price(value: 3.5, currency: .cny),
            accumulatedNAV: Price(value: 4.2, currency: .cny),
            cumulativeDividendPerShare: Price(value: 0.7, currency: .cny)
        )
        let data = try JSONEncoder().encode(nav)
        let decoded = try JSONDecoder().decode(NAVObservation.self, from: data)
        XCTAssertEqual(nav, decoded)
        XCTAssertEqual(decoded.unitNAV.value, 3.5)
    }

    // MARK: - FundHoldingSnapshot（multi-vintage 必备）

    func testFundHoldingSnapshot_codableRoundTrip() throws {
        let snapshot = FundHoldingSnapshot(
            id: ObservationID(rawValue: "obs_hold_1"),
            productID: FundProductID(rawValue: "prod_110022"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .communityAggregated),
            vintage: vintage1,
            reportPeriod: .q2,
            positions: [
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "list_600519"),
                    weight: Ratio(value: 0.098),
                    shares: 12_000,
                    marketValue: Price(value: 20_500_000, currency: .cny),
                    isDisclosed: true
                ),
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "list_000858"),
                    weight: Ratio(value: 0.075),
                    shares: 9_000,
                    marketValue: Price(value: 15_700_000, currency: .cny),
                    isDisclosed: true
                ),
            ],
            disclosedWeightTotal: Ratio(value: 0.45)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FundHoldingSnapshot.self, from: data)
        XCTAssertEqual(snapshot, decoded)
        XCTAssertEqual(decoded.positions.count, 2)
        XCTAssertEqual(decoded.disclosedWeightTotal.value, 0.45)
    }

    func testFundHoldingSnapshot_v2RevisionSupersedes() {
        // 同一报告期 v1 vs v2（修订后 disclosedWeightTotal 可能调整）
        let v1 = FundHoldingSnapshot(
            id: ObservationID(rawValue: "obs_hold_v1"),
            productID: FundProductID(rawValue: "prod_110022"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .communityAggregated, isRevised: false, isSuperseded: true),
            vintage: vintage1,
            reportPeriod: .q2,
            positions: [],
            disclosedWeightTotal: Ratio(value: 0.45)
        )
        let vintage2 = Vintage(
            announcementDate: Date(timeIntervalSince1970: 1_724_000_000),
            publisherVersion: 1
        )
        let v2 = FundHoldingSnapshot(
            id: ObservationID(rawValue: "obs_hold_v2"),
            productID: FundProductID(rawValue: "prod_110022"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .communityAggregated, isRevised: true, isSuperseded: false),
            vintage: vintage2,
            reportPeriod: .q2,
            positions: [],
            disclosedWeightTotal: Ratio(value: 0.48)
        )
        // v1 被 supersede，v2 是最新
        XCTAssertTrue(v1.dataQuality.isSuperseded)
        XCTAssertFalse(v2.dataQuality.isSuperseded)
        XCTAssertTrue(v2.dataQuality.isRevised)
        XCTAssertLessThan(vintage1, vintage2)
    }

    // MARK: - MacroObservation（FRED vintage 对齐）

    func testMacroObservation_codableRoundTrip() throws {
        let gdp = MacroObservation(
            id: ObservationID(rawValue: "obs_gdp_q2"),
            indicatorID: InstrumentID(rawValue: "ind_gdp_us"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .officialStable),
            vintage: vintage1,
            value: Decimal(string: "2.8")!,
            unit: .percent,
            frequency: .quarterly,
            isSeasonallyAdjusted: true
        )
        let data = try JSONEncoder().encode(gdp)
        let decoded = try JSONDecoder().decode(MacroObservation.self, from: data)
        XCTAssertEqual(gdp, decoded)
        XCTAssertEqual(decoded.unit, .percent)
        XCTAssertEqual(decoded.frequency, .quarterly)
        XCTAssertTrue(decoded.isSeasonallyAdjusted)
    }

    // MARK: - CorporateAction

    func testCorporateAction_cashDividend() throws {
        let div = CorporateAction(
            id: ObservationID(rawValue: "obs_div_1"),
            listingID: ListingID(rawValue: "list_600519"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .officialStable),
            vintage: vintage1,
            kind: .cashDividend,
            exDate: Date(timeIntervalSince1970: 1_720_000_000),
            recordDate: Date(timeIntervalSince1970: 1_720_086_400),
            payDate: Date(timeIntervalSince1970: 1_720_432_000),
            ratio: Decimal(string: "25.91")!,  // 每股分红 25.91 元
            currency: .cny
        )
        let data = try JSONEncoder().encode(div)
        let decoded = try JSONDecoder().decode(CorporateAction.self, from: data)
        XCTAssertEqual(div, decoded)
        XCTAssertEqual(decoded.kind, .cashDividend)
        XCTAssertEqual(decoded.currency, .cny)
    }

    func testCorporateAction_stockSplit() {
        let split = CorporateAction(
            id: ObservationID(rawValue: "obs_split_1"),
            listingID: ListingID(rawValue: "list_aapl"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .officialStable),
            vintage: vintage1,
            kind: .stockSplit,
            exDate: Date(timeIntervalSince1970: 1_720_000_000),
            recordDate: nil,
            payDate: nil,
            ratio: 10,  // 1拆10
            currency: nil
        )
        XCTAssertEqual(split.kind, .stockSplit)
        XCTAssertNil(split.currency)
    }

    // MARK: - EvidenceObservation

    func testEvidenceObservation_codableRoundTrip() throws {
        let ev = EvidenceObservation(
            id: ObservationID(rawValue: "obs_ev_1"),
            evidenceID: EvidenceID(rawValue: "ev_1"),   // Evidence 逻辑身份
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .officialStable),
            vintage: vintage1,
            content: "茅台 Q2 营收同比增长 17%",
            source: .secFiling,
            subjectCanonical: .listing(ListingID(rawValue: "list_600519"))
        )
        let data = try JSONEncoder().encode(ev)
        let decoded = try JSONDecoder().decode(EvidenceObservation.self, from: data)
        XCTAssertEqual(ev, decoded)
        XCTAssertEqual(decoded.source, .secFiling)
        XCTAssertEqual(decoded.evidenceID, EvidenceID(rawValue: "ev_1"))
    }

    // MARK: - 协议多态（[CanonicalObservation] 容器）

    func testCanonicalObservation_polymorphicContainer() throws {
        let bar = DailyBar(
            id: ObservationID(rawValue: "obs_bar_1"),
            listingID: ListingID(rawValue: "list_x"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .documentFreeAPI),
            vintage: vintage1,
            rawOpen: Price(value: 100, currency: .usd),
            rawHigh: Price(value: 105, currency: .usd),
            rawLow: Price(value: 99, currency: .usd),
            rawClose: Price(value: 102, currency: .usd),
            volume: 1000,
            adjustmentFactor: 1.0,
            fxRate: nil
        )
        let nav = NAVObservation(
            id: ObservationID(rawValue: "obs_nav_1"),
            shareClassID: FundShareClassID(rawValue: "sc_x"),
            temporalEnvelope: envelope,
            availabilityProvenance: prov,
            dataQuality: DataQuality(providerReliability: .communityAggregated),
            vintage: vintage1,
            unitNAV: Price(value: 1.5, currency: .cny),
            accumulatedNAV: Price(value: 1.8, currency: .cny),
            cumulativeDividendPerShare: Price(value: 0.3, currency: .cny)
        )
        // 协议容器：两个不同具体类型都满足 CanonicalObservation
        let observations: [any CanonicalObservation] = [bar, nav]
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].id, ObservationID(rawValue: "obs_bar_1"))
        XCTAssertEqual(observations[1].id, ObservationID(rawValue: "obs_nav_1"))
        // 协议保证所有成员都有 temporalEnvelope
        XCTAssertNil(observations[0].temporalEnvelope.validate())
    }

    // MARK: - ProviderReliabilityClass 四档

    func testProviderReliabilityClass_allCases() {
        XCTAssertEqual(ProviderReliabilityClass.allCases, [
            .officialStable,
            .documentFreeAPI,
            .communityAggregated,
            .undocumentedPublicEndpoint,
        ])
    }
}
