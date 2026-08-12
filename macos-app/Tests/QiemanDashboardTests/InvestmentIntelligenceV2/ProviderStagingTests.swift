import XCTest
@testable import QiemanDashboard

/// PROV-1 测试：ProviderStaging JSONL 读写 + ProviderRecordSchemaValidator。
///
/// 验收对齐 ADR-DATA003 Compliance：ProviderRecord + ProviderStaging JSONL 格式 +
/// SchemaValidator 拒收非法字段。
final class ProviderStagingTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    /// 构造一条合法 NAV ProviderRecord（可指定 providerID / kind 便于覆盖边界用例）。
    private func makeRecord(
        id: String = "r1",
        providerID: DataProviderID = .eastmoney,
        kind: ProviderRecordKind = .navObservation,
        effectiveAt: Date? = nil,
        publishedAt: Date? = nil,
        payload: Data? = nil
    ) throws -> ProviderRecord {
        let eff = effectiveAt ?? date(2024, 7, 18)
        let pub = publishedAt ?? eff
        let rawPayload = try payload ?? JSONEncoder().encode(NAVPayload(
            unitNAV: Price(value: 3.5, currency: .cny), accumulatedNAV: nil, cumulativeDividendPerShare: nil
        ))
        return ProviderRecord(
            providerID: providerID,
            providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: eff, publishedAt: pub, ingestedAt: date(2024, 7, 19),
            kind: kind, rawPayload: rawPayload,
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
    }

    // MARK: - JSONL 读写 round-trip

    func testStaging_writeReadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov1-staging-roundtrip-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try [
            makeRecord(id: "r1"),
            makeRecord(id: "r2"),
            makeRecord(id: "r3")
        ]
        try ProviderStagingWriter().write(records, to: url)

        let read = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(read.count, 3)
        // 逐字段等价（ProviderRecord: Hashable + Equatable）
        XCTAssertEqual(read, records)
    }

    func testStaging_appendGrowsSpool() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov1-staging-append-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let batch1 = try [makeRecord(id: "r1"), makeRecord(id: "r2")]
        let batch2 = try [makeRecord(id: "r3")]
        // 追加到不存在的文件 → 先创建
        try ProviderStagingWriter().append(batch1, to: url)
        try ProviderStagingWriter().append(batch2, to: url)

        let read = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(read.count, 3, "两批追加后应共 3 条")
    }

    func testStaging_skipsBlankLines() throws {
        // 空行（含文件末尾换行产生的尾空行）应跳过，不计为损坏
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov1-staging-blank-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try makeRecord()
        try ProviderStagingWriter().write([record], to: url)
        // 人为在中间插入空行
        let original = try String(contentsOf: url, encoding: .utf8)
        let withBlankLines = original + "\n\n"
        try withBlankLines.write(to: url, atomically: true, encoding: .utf8)

        let read = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(read.count, 1, "空行应跳过")
    }

    func testStaging_malformedLineThrowsWithLineNumber() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov1-staging-bad-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try makeRecord()
        let encoded = try ProviderStaging.defaultEncoder.encode(record)
        let goodLine = String(data: encoded, encoding: .utf8)!
        // 第 2 行是损坏 JSON
        let content = goodLine + "\n{not valid json\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProviderStagingReader().read(from: url)) { err in
            guard case .malformedLine(let lineNo, _) = err as? ProviderStagingError else {
                XCTFail("expected malformedLine, got \(err)"); return
            }
            XCTAssertEqual(lineNo, 2, "第 2 行损坏应报告行号 2")
        }
    }

    func testStaging_readMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov1-staging-missing-\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try ProviderStagingReader().read(from: url)) { err in
            guard case .readFailed = err as? ProviderStagingError else {
                XCTFail("expected readFailed, got \(err)"); return
            }
        }
    }
}

/// ProviderRecordSchemaValidator 测试（ADR-DATA003 Compliance：拒收非法字段）。
final class ProviderRecordSchemaValidatorTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private let validator = ProviderRecordSchemaValidator()

    private func navPayloadData() throws -> Data {
        try JSONEncoder().encode(NAVPayload(
            unitNAV: Price(value: 3.5, currency: .cny), accumulatedNAV: nil, cumulativeDividendPerShare: nil
        ))
    }

    private func makeRecord(
        providerID: DataProviderID = .eastmoney,
        scheme: String = "fund_code", value: String = "110022",
        effectiveAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        kind: ProviderRecordKind = .navObservation,
        payload: Data? = nil
    ) throws -> ProviderRecord {
        ProviderRecord(
            providerID: providerID,
            providerCode: ProviderCode(scheme: scheme, value: value),
            effectiveAt: effectiveAt, publishedAt: publishedAt, ingestedAt: publishedAt,
            kind: kind, rawPayload: try payload ?? navPayloadData(),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
    }

    // MARK: - 合法记录通过

    func testValidate_acceptsWellFormedRecord() throws {
        let record = try makeRecord()
        XCTAssertNoThrow(try validator.validate(record))
    }

    func testValidate_acceptsAllFiveKinds() throws {
        // 每个 kind 用其对应 payload schema，都应通过
        let payloads: [(ProviderRecordKind, Codable)] = [
            (.dailyBar, DailyBarPayload(rawOpen: Price(value: 1, currency: .cny),
                rawHigh: Price(value: 1, currency: .cny), rawLow: Price(value: 1, currency: .cny),
                rawClose: Price(value: 1, currency: .cny), volume: 1, adjustmentFactor: 1, fxRate: nil)),
            (.navObservation, NAVPayload(unitNAV: Price(value: 1, currency: .cny),
                accumulatedNAV: nil, cumulativeDividendPerShare: nil)),
            (.fundHoldingSnapshot, FundHoldingPayload(reportPeriod: .q2, positions: [],
                disclosedWeightTotal: Ratio(value: 0))),
            (.macroObservation, MacroPayload(value: 1, unit: .percent, frequency: .monthly,
                isSeasonallyAdjusted: false, basePeriod: nil)),
            (.corporateAction, CorporateActionPayload(kind: .cashDividend,
                exDate: Date(timeIntervalSince1970: 0), recordDate: nil, payDate: nil,
                ratio: 1, currency: nil))
        ]
        for (kind, payload) in payloads {
            let data = try JSONEncoder().encode(payload)
            let record = try makeRecord(kind: kind, payload: data)
            XCTAssertNoThrow(try validator.validate(record), "kind \(kind) 应通过 schema 校验")
        }
    }

    // MARK: - 拒收非法字段（ADR-DATA003 Compliance）

    func testValidate_rejectsEmptyProviderID() throws {
        let record = try makeRecord(providerID: DataProviderID(rawValue: ""))
        XCTAssertThrowsError(try validator.validate(record)) { err in
            XCTAssertEqual(err as? ProviderRecordSchemaError, .emptyProviderID)
        }
    }

    func testValidate_rejectsEmptyProviderCode() throws {
        let record = try makeRecord(scheme: "", value: "110022")
        XCTAssertThrowsError(try validator.validate(record)) { err in
            XCTAssertEqual(err as? ProviderRecordSchemaError, .emptyProviderCode)
        }
    }

    func testValidate_rejectsEmptyPayload() throws {
        let record = try makeRecord(payload: Data())
        XCTAssertThrowsError(try validator.validate(record)) { err in
            XCTAssertEqual(err as? ProviderRecordSchemaError, .emptyPayload)
        }
    }

    func testValidate_rejectsInvalidTimestampOrder() throws {
        // effectiveAt 晚于 publishedAt（事件在公布之后 = lookahead，非法）
        let record = try makeRecord(
            effectiveAt: date(2024, 7, 20),
            publishedAt: date(2024, 7, 18)
        )
        XCTAssertThrowsError(try validator.validate(record)) { err in
            XCTAssertEqual(err as? ProviderRecordSchemaError, .invalidTimestampOrder)
        }
    }

    func testValidate_rejectsPayloadSchemaMismatch() throws {
        // kind=dailyBar 但 payload 是 NAVPayload → schema 不匹配
        let record = try makeRecord(kind: .dailyBar, payload: navPayloadData())
        XCTAssertThrowsError(try validator.validate(record)) { err in
            guard case .payloadSchemaMismatch(let kind, _) = err as? ProviderRecordSchemaError else {
                XCTFail("expected payloadSchemaMismatch, got \(err)"); return
            }
            XCTAssertEqual(kind, .dailyBar)
        }
    }

    func testValidate_rejectsCorruptPayload() throws {
        // payload 不是合法 JSON
        let record = try makeRecord(payload: Data("not json".utf8))
        XCTAssertThrowsError(try validator.validate(record)) { err in
            guard case .payloadSchemaMismatch = err as? ProviderRecordSchemaError else {
                XCTFail("expected payloadSchemaMismatch, got \(err)"); return
            }
        }
    }

    // MARK: - 批量 partition（部分失败不连累整批）

    func testPartition_separatesValidAndInvalid() throws {
        let good = try makeRecord()
        let badID = try makeRecord(providerID: DataProviderID(rawValue: ""))
        let badPayload = try makeRecord(payload: Data("x".utf8))
        let (valid, invalid) = validator.partition([good, badID, badPayload])
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(invalid.count, 2)
        XCTAssertTrue(invalid.contains { $0.error == .emptyProviderID })
    }
}
