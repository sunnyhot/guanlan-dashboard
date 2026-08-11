import XCTest
@testable import QiemanDashboard

/// DOM-1 单元测试：基础 ID 类型的 Sendable + Codable + Hashable 行为。
///
/// M1 验收要求每个 DOM-* 类型 Codable round-trip + Sendable 检查通过
///（rollout §4.0）。
final class CanonicalIDTests: XCTestCase {

    // MARK: - Codable round-trip

    func testDomainID_codableRoundTrip() throws {
        let original = DomainID(rawValue: "inst_01J8Z3F9K0P2Q4R6S8T0V1W2X4")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DomainID.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(original.rawValue, "inst_01J8Z3F9K0P2Q4R6S8T0V1W2X4")
    }

    func testInstrumentID_codableRoundTrip() throws {
        let original = InstrumentID(rawValue: "inst_01J8Z3F9K0P2Q4R6S8T0V1W2X4")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InstrumentID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testListingID_codableRoundTrip() throws {
        let original = ListingID(rawValue: "list_sh600519")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ListingID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testLegalEntityID_codableRoundTrip() throws {
        let original = LegalEntityID(rawValue: "ent_kweichow")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LegalEntityID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testFundProductID_codableRoundTrip() throws {
        let original = FundProductID(rawValue: "prod_110022")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FundProductID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testFundShareClassID_codableRoundTrip() throws {
        let original = FundShareClassID(rawValue: "sc_110022_A")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FundShareClassID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDataProviderID_codableRoundTrip() throws {
        let original = DataProviderID.qieman
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DataProviderID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testInvestmentTargetID_codableRoundTrip() throws {
        // ADR-D000 Target 的稳定标识，Decision 层通过它引用 Target
        let original = InvestmentTargetID(rawValue: "target_user_001")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InvestmentTargetID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testEvidenceID_codableRoundTrip() throws {
        // EvidenceID 与 ObservationID 类型独立，编译期不可互换
        let original = EvidenceID(rawValue: "ev_01J8Z3F9")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EvidenceID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Hashable（可作 Dictionary key / Set 元素）

    func testIDTypes_hashableAsDictionaryKey() {
        var dict: [InstrumentID: String] = [:]
        let id1 = InstrumentID(rawValue: "inst_a")
        let id2 = InstrumentID(rawValue: "inst_b")
        dict[id1] = "A"
        dict[id2] = "B"
        XCTAssertEqual(dict[id1], "A")
        XCTAssertEqual(dict[id2], "B")
        XCTAssertEqual(dict.count, 2)
    }

    func testIDTypes_hashableAsSetElement_dedup() {
        let id1 = ListingID(rawValue: "list_sh600519")
        let id2 = ListingID(rawValue: "list_sh600519")  // 相同 rawValue
        let id3 = ListingID(rawValue: "list_sz000001")
        let set: Set<ListingID> = [id1, id2, id3]
        XCTAssertEqual(set.count, 2)  // id1 == id2 去重
    }

    // MARK: - 相等性

    func testSameRawValue_equal() {
        XCTAssertEqual(InstrumentID(rawValue: "x"), InstrumentID(rawValue: "x"))
    }

    func testDifferentRawValue_notEqual() {
        XCTAssertNotEqual(InstrumentID(rawValue: "x"), InstrumentID(rawValue: "y"))
    }

    // MARK: - Provider 常量集中声明

    func testKnownProviderIDs() {
        XCTAssertEqual(DataProviderID.qieman.rawValue, "qieman")
        XCTAssertEqual(DataProviderID.eastmoney.rawValue, "eastmoney")
        XCTAssertEqual(DataProviderID.sec.rawValue, "sec")
        XCTAssertEqual(DataProviderID.fred.rawValue, "fred")
        XCTAssertEqual(DataProviderID.stooq.rawValue, "stooq")
        XCTAssertEqual(DataProviderID.alphaVantage.rawValue, "alpha-vantage")
        XCTAssertEqual(DataProviderID.akshare.rawValue, "akshare")
        XCTAssertEqual(DataProviderID.tavily.rawValue, "tavily")
    }

    // MARK: - Sendable 检查
    //
    // Sendable 是编译期约束，这里通过把 ID 跨 actor 传递来 runtime 验证
    // （如果类型 non-Sendable 会编译失败，测试本身主要保证 round-trip 不退化）。
    private actor IDReceiver {
        func receive(_ id: InstrumentID) -> InstrumentID { id }
    }

    func testIDTypes_sendableAcrossActor() async {
        let receiver = IDReceiver()
        let id = InstrumentID(rawValue: "inst_sendable_test")
        let received = await receiver.receive(id)
        XCTAssertEqual(id, received)
    }

    // MARK: - CustomStringConvertible

    func testDomainID_description() {
        let id = DomainID(rawValue: "ent_test")
        XCTAssertEqual(id.description, "ent_test")
    }
}
