import XCTest
@testable import QiemanDashboard

/// DOM-3 单元测试：ProviderIdentifier / IdentityResolutionMethod /
/// InstrumentRelationship 的 V3.1 §12-14 行为。
final class ProviderIdentifierTests: XCTestCase {

    // MARK: - ProviderIdentifier

    func testProviderIdentifier_codableRoundTrip() throws {
        let pid = ProviderIdentifier(
            providerID: .eastmoney,
            identifierScheme: "fund_code",
            identifierValue: "110022",
            canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")),
            resolutionMethod: .exchangeSymbolExact,
            resolvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(pid)
        let decoded = try JSONDecoder().decode(ProviderIdentifier.self, from: data)
        XCTAssertEqual(pid, decoded)
        XCTAssertEqual(decoded.providerID, .eastmoney)
        XCTAssertEqual(decoded.identifierValue, "110022")
    }

    func testProviderIdentifier_differentCanonicalRefs() {
        let toShareClass = ProviderIdentifier(
            providerID: .qieman,
            identifierScheme: "prodCode",
            identifierValue: "SI000192",
            canonical: .fundShareClass(FundShareClassID(rawValue: "sc_x")),
            resolutionMethod: .manualVerified,
            resolvedAt: Date()
        )
        let toListing = ProviderIdentifier(
            providerID: .stooq,
            identifierScheme: "symbol",
            identifierValue: "AAPL",
            canonical: .listing(ListingID(rawValue: "list_aapl")),
            resolutionMethod: .exchangeSymbolExact,
            resolvedAt: Date()
        )
        XCTAssertNotEqual(toShareClass.canonical, toListing.canonical)
    }

    // MARK: - CanonicalRef.stableKey

    func testCanonicalRef_stableKey_hasTypePrefix() {
        let shareClass = CanonicalRef.fundShareClass(FundShareClassID(rawValue: "sc_x"))
        let listing = CanonicalRef.listing(ListingID(rawValue: "list_x"))
        let instrument = CanonicalRef.instrument(InstrumentID(rawValue: "inst_x"))

        // 含类型前缀，即使 rawValue 相同也不会冲突
        XCTAssertEqual(shareClass.stableKey, "fundShareClass:sc_x")
        XCTAssertEqual(listing.stableKey, "listing:list_x")
        XCTAssertEqual(instrument.stableKey, "instrument:inst_x")

        // 即使两个不同类型的 rawValue 都是 "x"，stableKey 仍可区分
        let a = CanonicalRef.instrument(InstrumentID(rawValue: "x"))
        let b = CanonicalRef.listing(ListingID(rawValue: "x"))
        XCTAssertNotEqual(a.stableKey, b.stableKey)
    }

    // MARK: - IdentityResolutionMethod（4 正式路径 + fuzzy）

    func testAuthoritativeMethods_areAuthoritative() {
        XCTAssertTrue(IdentityResolutionMethod.providerAuthoritative.isAuthoritative)
        XCTAssertTrue(IdentityResolutionMethod.exchangeSymbolExact.isAuthoritative)
        XCTAssertTrue(IdentityResolutionMethod.isinOrCik.isAuthoritative)
        XCTAssertTrue(IdentityResolutionMethod.manualVerified.isAuthoritative)
    }

    func testFuzzyCandidate_isNotAuthoritative() {
        // ADR-DATA001 §Decision 3：fuzzy 只产 candidate，必须经 Verification
        XCTAssertFalse(IdentityResolutionMethod.fuzzyCandidate.isAuthoritative)
    }

    func testResolutionMethod_allCases() {
        // 5 个 case（4 正式 + 1 fuzzy）
        let allRaw = IdentityResolutionMethod.allCases.map(\.rawValue)
        XCTAssertEqual(allRaw, [
            "PROVIDER_AUTHORITATIVE",
            "EXCHANGE_SYMBOL_EXACT",
            "ISIN_OR_CIK",
            "MANUAL_VERIFIED",
            "FUZZY_CANDIDATE",
        ])
    }

    // MARK: - InstrumentRelationship

    func testInstrumentRelationship_etfTracksIndex() throws {
        let rel = InstrumentRelationship(
            id: DomainID(rawValue: "rel_1"),
            kind: .tracksIndex,
            fromInstrumentID: InstrumentID(rawValue: "inst_510300_etf"),
            toInstrumentID: InstrumentID(rawValue: "inst_000300_index"),
            strength: 0.999,  // 跟踪紧密度
            provenance: .provider
        )
        let data = try JSONEncoder().encode(rel)
        let decoded = try JSONDecoder().decode(InstrumentRelationship.self, from: data)
        XCTAssertEqual(rel, decoded)
        XCTAssertEqual(decoded.kind, .tracksIndex)
        XCTAssertEqual(decoded.strength, 0.999)
    }

    func testInstrumentRelationship_shareClassOf() {
        let rel = InstrumentRelationship(
            id: DomainID(rawValue: "rel_2"),
            kind: .shareClassOf,
            fromInstrumentID: InstrumentID(rawValue: "inst_110022_A"),
            toInstrumentID: InstrumentID(rawValue: "inst_110022_product"),
            provenance: .manual
        )
        XCTAssertNil(rel.strength)  // 归属关系无强度
        XCTAssertEqual(rel.kind, .shareClassOf)
    }

    func testInstrumentRelationship_adrUnderlying() {
        let rel = InstrumentRelationship(
            id: DomainID(rawValue: "rel_3"),
            kind: .adrUnderlying,
            fromInstrumentID: InstrumentID(rawValue: "inst_baba_adr_us"),
            toInstrumentID: InstrumentID(rawValue: "inst_baba_hk"),
            provenance: .provider
        )
        XCTAssertEqual(rel.kind, .adrUnderlying)
    }

    func testRelationshipKind_allCases() {
        let allRaw = InstrumentRelationship.RelationshipKind.allCases.map(\.rawValue)
        XCTAssertEqual(allRaw, [
            "TRACKS_INDEX",
            "SHARE_CLASS_OF",
            "SAME_ISSUER",
            "ADR_UNDERLYING",
        ])
    }

    // MARK: - 跨 Provider 映射到同一 Canonical（M2 场景 1 预演）

    func testMultipleProviders_sameCanonicalRef() {
        // 同一只基金在天天基金和且慢代码不同，但都映射到同一 FundShareClass
        let shareClassID = FundShareClassID(rawValue: "sc_110022_A")

        let eastmoneyPID = ProviderIdentifier(
            providerID: .eastmoney,
            identifierScheme: "fund_code",
            identifierValue: "110022",
            canonical: .fundShareClass(shareClassID),
            resolutionMethod: .manualVerified,
            resolvedAt: Date()
        )
        let qiemanPID = ProviderIdentifier(
            providerID: .qieman,
            identifierScheme: "prodCode",
            identifierValue: "CONSUMER_STOCK",
            canonical: .fundShareClass(shareClassID),
            resolutionMethod: .manualVerified,
            resolvedAt: Date()
        )

        // Provider 代码不同
        XCTAssertNotEqual(eastmoneyPID.identifierValue, qiemanPID.identifierValue)
        XCTAssertNotEqual(eastmoneyPID.providerID, qiemanPID.providerID)
        // 但映射到同一 Canonical
        XCTAssertEqual(eastmoneyPID.canonical, qiemanPID.canonical)
    }
}

// MARK: - IdentityResolutionMethod allCases（需 CaseIterable 才能跑上面的 test）

