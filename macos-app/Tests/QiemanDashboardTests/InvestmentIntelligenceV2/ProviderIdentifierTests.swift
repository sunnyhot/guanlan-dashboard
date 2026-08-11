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

    // MARK: - InstrumentRelationship（端点类型化，ADR-DATA001 §14）

    func testInstrumentRelationship_tracksIndex() throws {
        let rel = InstrumentRelationship.tracksIndex(
            .init(
                id: DomainID(rawValue: "rel_1"),
                etf: InstrumentID(rawValue: "inst_510300_etf"),
                index: InstrumentID(rawValue: "inst_000300_index"),
                strength: 0.999,
                provenance: .provider
            )
        )
        let data = try JSONEncoder().encode(rel)
        let decoded = try JSONDecoder().decode(InstrumentRelationship.self, from: data)
        XCTAssertEqual(rel, decoded)
        XCTAssertEqual(rel.id, DomainID(rawValue: "rel_1"))
        XCTAssertEqual(rel.provenance, .provider)
        if case .tracksIndex(let r) = rel {
            XCTAssertEqual(r.strength, 0.999)
            XCTAssertEqual(r.etf, InstrumentID(rawValue: "inst_510300_etf"))
        } else {
            XCTFail("expected .tracksIndex")
        }
    }

    func testInstrumentRelationship_shareClassOf_typedEndpoints() throws {
        // ShareClass → Product：源是 FundShareClassID，目标是 FundProductID。
        // 编译期保证不混（审查 P1 修复点）。
        let rel = InstrumentRelationship.shareClassOf(
            .init(
                id: DomainID(rawValue: "rel_2"),
                shareClass: FundShareClassID(rawValue: "sc_110022_A"),
                product: FundProductID(rawValue: "prod_110022"),
                provenance: .manual
            )
        )
        let data = try JSONEncoder().encode(rel)
        let decoded = try JSONDecoder().decode(InstrumentRelationship.self, from: data)
        XCTAssertEqual(rel, decoded)
        XCTAssertEqual(rel.provenance, .manual)
        guard case .shareClassOf(let r) = rel else {
            XCTFail("expected .shareClassOf"); return
        }
        XCTAssertEqual(r.shareClass, FundShareClassID(rawValue: "sc_110022_A"))
        XCTAssertEqual(r.product, FundProductID(rawValue: "prod_110022"))
    }

    func testInstrumentRelationship_issuedBy_typedEndpoints() throws {
        // Instrument → LegalEntity（ADR-DATA001 §14 Stock→Entity）：
        // 目标端是 LegalEntityID 而非 InstrumentID。
        let rel = InstrumentRelationship.issuedBy(
            .init(
                id: DomainID(rawValue: "rel_3"),
                instrument: InstrumentID(rawValue: "inst_600519"),
                issuer: LegalEntityID(rawValue: "ent_kweichow"),
                provenance: .derived
            )
        )
        let data = try JSONEncoder().encode(rel)
        let decoded = try JSONDecoder().decode(InstrumentRelationship.self, from: data)
        XCTAssertEqual(rel, decoded)
        guard case .issuedBy(let r) = rel else {
            XCTFail("expected .issuedBy"); return
        }
        XCTAssertEqual(r.instrument, InstrumentID(rawValue: "inst_600519"))
        XCTAssertEqual(r.issuer, LegalEntityID(rawValue: "ent_kweichow"))
    }

    func testInstrumentRelationship_adrUnderlying() throws {
        let rel = InstrumentRelationship.adrUnderlying(
            .init(
                id: DomainID(rawValue: "rel_4"),
                adr: InstrumentID(rawValue: "inst_baba_adr_us"),
                underlying: InstrumentID(rawValue: "inst_baba_hk"),
                provenance: .provider
            )
        )
        let data = try JSONEncoder().encode(rel)
        let decoded = try JSONDecoder().decode(InstrumentRelationship.self, from: data)
        XCTAssertEqual(rel, decoded)
        XCTAssertEqual(rel.id, DomainID(rawValue: "rel_4"))
    }

    func testInstrumentRelationship_idAccessor_worksForAllCases() {
        // id 访问器在 4 种 case 上都返回各自内部的 id
        let r1 = InstrumentRelationship.tracksIndex(
            .init(id: DomainID(rawValue: "a"), etf: InstrumentID(rawValue: "e"),
                  index: InstrumentID(rawValue: "i"), strength: nil, provenance: .provider))
        let r2 = InstrumentRelationship.shareClassOf(
            .init(id: DomainID(rawValue: "b"), shareClass: FundShareClassID(rawValue: "s"),
                  product: FundProductID(rawValue: "p"), provenance: .manual))
        let r3 = InstrumentRelationship.issuedBy(
            .init(id: DomainID(rawValue: "c"), instrument: InstrumentID(rawValue: "i"),
                  issuer: LegalEntityID(rawValue: "l"), provenance: .derived))
        let r4 = InstrumentRelationship.adrUnderlying(
            .init(id: DomainID(rawValue: "d"), adr: InstrumentID(rawValue: "a"),
                  underlying: InstrumentID(rawValue: "u"), provenance: .provider))
        XCTAssertEqual(r1.id, DomainID(rawValue: "a"))
        XCTAssertEqual(r2.id, DomainID(rawValue: "b"))
        XCTAssertEqual(r3.id, DomainID(rawValue: "c"))
        XCTAssertEqual(r4.id, DomainID(rawValue: "d"))
        XCTAssertEqual(Set([r1.provenance, r2.provenance, r3.provenance, r4.provenance]).count, 3)
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

