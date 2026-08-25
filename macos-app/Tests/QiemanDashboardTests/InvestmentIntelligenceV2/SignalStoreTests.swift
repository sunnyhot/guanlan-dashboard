import XCTest
@testable import QiemanDashboard

// RES-6：Signal Store——幂等写 / 跨运行查询（subject / evidence 溯源）/
// 形态门禁。GRDB 与 InMemory 双实现同套断言（parity）。

private func makeSignal(
    id: String = "sig_test1",
    direction: SignalDirection = .bullish,
    strength: SignalStrength = .strong,
    evidence: [EvidenceID] = [EvidenceID(rawValue: "EV-1"), EvidenceID(rawValue: "EV-2")],
    effectiveAt: Date = Date(timeIntervalSince1970: 1000),
    rationale: String? = "测试信号｜policy=research-signal-extraction@v1"
) throws -> InvestmentSignal {
    InvestmentSignal(
        id: SignalID(rawValue: id),
        subjectCanonical: try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
        dimension: .momentum,
        direction: direction,
        strength: strength,
        derivedFromEvidenceIDs: evidence,
        effectiveAt: effectiveAt,
        producer: SignalProducer(kind: .llm, modelIdentifier: "test-model"),
        rationale: rationale
    )
}

final class SignalStoreTests: XCTestCase {

    private func makeStores() throws -> [(name: String, store: any SignalStore)] {
        let grdb = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: TestWeekdayCalendar()
        )
        return [("grdb", grdb), ("inMemory", InMemorySignalStore())]
    }

    func testWriteFetchRoundTripAndCrossRunQueries() throws {
        for (name, store) in try makeStores() {
            let signal = try makeSignal()
            let otherSubject = try makeSignal(
                id: "sig_other",
                evidence: [EvidenceID(rawValue: "EV-2")],
                effectiveAt: Date(timeIntervalSince1970: 500)
            )

            try store.write(signal)
            try store.write(otherSubject)

            // 点查 round-trip
            let fetched = try store.signal(id: SignalID(rawValue: "sig_test1"))
            XCTAssertEqual(fetched, signal, "[\(name)] GRDB 列编解码 round-trip")

            // subject 查询：跨运行可查 + effectiveAt 降序
            let subject = try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100")
            let bySubject = try store.signals(subject: subject)
            XCTAssertEqual(bySubject.map(\.id.rawValue), ["sig_test1", "sig_other"], "[\(name)] 按主体查，时间降序")

            // evidence 溯源：EV-2 被两个信号引用，EV-1 只有一个
            let viaEV2 = try store.signals(derivedFromEvidence: EvidenceID(rawValue: "EV-2"))
            XCTAssertEqual(Set(viaEV2.map(\.id.rawValue)), ["sig_test1", "sig_other"], "[\(name)] 溯源查（json_each 精确匹配）")
            let viaEV1 = try store.signals(derivedFromEvidence: EvidenceID(rawValue: "EV-1"))
            XCTAssertEqual(viaEV1.map(\.id.rawValue), ["sig_test1"], "[\(name)] EV-1 只被一个信号引用")
            // 前缀不误配（EV-1 ≠ EV-10）
            let viaEV10 = try store.signals(derivedFromEvidence: EvidenceID(rawValue: "EV-10"))
            XCTAssertTrue(viaEV10.isEmpty, "[\(name)] 前缀相似不误配")
        }
    }

    func testIdempotentWriteKeepsFirstEffectiveAt() throws {
        for (name, store) in try makeStores() {
            let first = try makeSignal(effectiveAt: Date(timeIntervalSince1970: 1000))
            try store.write(first)
            // 同 ID 同语义、稍晚 effectiveAt → no-op，保留首条时间
            let later = try makeSignal(effectiveAt: Date(timeIntervalSince1970: 9999))
            try store.write(later)
            let fetched = try store.signal(id: SignalID(rawValue: "sig_test1"))
            XCTAssertEqual(fetched?.effectiveAt, Date(timeIntervalSince1970: 1000), "[\(name)] 幂等保留首条 effectiveAt")

            // evidence 顺序不同仍是同语义（集合语义）
            let reordered = try makeSignal(
                evidence: [EvidenceID(rawValue: "EV-2"), EvidenceID(rawValue: "EV-1")]
            )
            XCTAssertNoThrow(try store.write(reordered), "[\(name)] evidence 顺序无关")
        }
    }

    func testConflictingRewriteIsRejected() throws {
        for (name, store) in try makeStores() {
            try store.write(try makeSignal())
            // 同 ID 不同 direction → conflict
            let tampered = try makeSignal(direction: .bearish)
            XCTAssertThrowsError(try store.write(tampered)) { error in
                guard case SignalStoreError.conflict(let signalID, let field)? = error as? SignalStoreError else {
                    return XCTFail("[\(name)] 错误类型不对: \(error)")
                }
                XCTAssertEqual(signalID, "sig_test1")
                XCTAssertEqual(field, "direction")
            }
            // rationale 变化同样是冲突
            let reRationale = try makeSignal(rationale: "改写理由")
            XCTAssertThrowsError(try store.write(reRationale), "[\(name)] rationale 篡改拒绝")
        }
    }

    func testMalformedSignalsRejectedAtWrite() throws {
        for (name, store) in try makeStores() {
            // 无证据
            let noEvidence = try makeSignal(evidence: [])
            XCTAssertThrowsError(try store.write(noEvidence)) { error in
                guard case SignalStoreError.malformed? = error as? SignalStoreError else {
                    return XCTFail("[\(name)] 应 malformed: \(error)")
                }
            }
            // rationale 缺失
            let noRationale = try makeSignal(rationale: nil)
            XCTAssertThrowsError(try store.write(noRationale), "[\(name)] rationale 缺失拒绝")
            // 确认没写入
            XCTAssertTrue(try store.signals(subject: try CanonicalRef(
                entityType: "fundShareClass", entityIDRawValue: "sc_513100"
            )).isEmpty, "[\(name)] 拒绝的信号不落库")
        }
    }

    func testPersistenceAcrossDatabaseReopen() throws {
        // 跨运行可查（验收语义）：文件库重开后信号仍在。
        let path = NSTemporaryDirectory() + "signal-store-\(UUID().uuidString).sqlite3"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let signal = try makeSignal()
        let first = GRDBRepository(database: try CanonicalDatabase(path: path), calendarBackend: TestWeekdayCalendar())
        try first.write(signal)

        let reopened = GRDBRepository(database: try CanonicalDatabase(path: path), calendarBackend: TestWeekdayCalendar())
        let fetched = try reopened.signal(id: SignalID(rawValue: "sig_test1"))
        XCTAssertEqual(fetched, signal, "重开库后信号仍可查")
        XCTAssertEqual(
            try reopened.signals(derivedFromEvidence: EvidenceID(rawValue: "EV-1")).map(\.id.rawValue),
            ["sig_test1"]
        )
    }
}
