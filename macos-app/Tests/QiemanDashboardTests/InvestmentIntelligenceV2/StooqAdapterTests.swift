import XCTest
@testable import QiemanDashboard

/// PROV-2 测试：Stooq 美股日线 CSV 解析链 → ProviderRecord → staging/schema 校验。
///
/// 验证真实 Stooq wire 格式（CSV）的端到端解析，以及与 PROV-1 staging +
/// SchemaValidator 的集成。CSV 样本基于 Stooq 真实下载格式（非 live 录制，
/// 手工构造的代表性 wire 格式）。
final class StooqAdapterTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    /// 真实 Stooq CSV 格式样本（含表头 + 3 行数据）。
    private let sampleCSV = """
    Date,Open,High,Low,Close,Volume
    2024-07-01,210.34,212.50,209.80,211.20,52000000
    2024-07-02,211.20,213.00,210.90,212.80,49800000
    2024-07-03,212.80,214.10,212.10,213.45,45100000
    """

    // MARK: - CSV 解析

    func testParse_realCSVFormat_producesDailyBarEntries() throws {
        let parser = StooqResponseParser()
        let history = try parser.parse(sampleCSV, symbol: "aapl.us")
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.droppedMalformedCount, 0)
        let first = history.entries[0]
        XCTAssertEqual(first.date, date(2024, 7, 1))
        XCTAssertEqual(first.open, 210.34, accuracy: 1e-9)
        XCTAssertEqual(first.high, 212.50, accuracy: 1e-9)
        XCTAssertEqual(first.low, 209.80, accuracy: 1e-9)
        XCTAssertEqual(first.close, 211.20, accuracy: 1e-9)
        XCTAssertEqual(first.volume, 52_000_000)
    }

    func testParse_missingVolumeColumn_treatedAsNil() throws {
        // Stooq 个别标的/日期缺 Volume → nil，不丢弃整行
        let csv = """
        Date,Open,High,Low,Close,Volume
        2024-07-01,210.34,212.50,209.80,211.20,
        """
        let history = try StooqResponseParser().parse(csv, symbol: "x.us")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(history.entries[0].volume, "空 Volume 应为 nil 而非丢弃")
    }

    func testParse_malformedRowsCountedNotCrash() throws {
        // 第 2 行 OHLC 非有限（"NaN"）→ 丢弃 + 计数；合法行保留
        let csv = """
        Date,Open,High,Low,Close,Volume
        2024-07-01,210.34,212.50,209.80,211.20,52000000
        2024-07-02,NaN,213.00,210.90,212.80,100
        2024-07-03,212.80,214.10,212.10,213.45,45100000
        """
        let history = try StooqResponseParser().parse(csv, symbol: "aapl.us")
        XCTAssertEqual(history.entries.count, 2, "NaN 行应丢弃")
        XCTAssertEqual(history.droppedMalformedCount, 1)
    }

    func testParse_allRowsMalformed_throws() {
        let csv = """
        Date,Open,High,Low,Close,Volume
        bad,bad,bad,bad,bad,bad
        also-bad,x,x,x,x,x
        """
        XCTAssertThrowsError(try StooqResponseParser().parse(csv, symbol: "x.us")) { err in
            guard case .noValidEntries(let total) = err as? StooqParseError else {
                XCTFail("expected noValidEntries, got \(err)"); return
            }
            XCTAssertEqual(total, 2)
        }
    }

    func testParse_emptyBody_throws() {
        XCTAssertThrowsError(try StooqResponseParser().parse("", symbol: "x.us")) { err in
            XCTAssertEqual(err as? StooqParseError, .emptyBody)
        }
    }

    func testParse_badHeader_throws() {
        // 表头缺 Date/Close 列 → 结构异常
        let csv = "Foo,Bar\n1,2\n"
        XCTAssertThrowsError(try StooqResponseParser().parse(csv, symbol: "x.us")) { err in
            guard case .malformedCSV = err as? StooqParseError else {
                XCTFail("expected malformedCSV, got \(err)"); return
            }
        }
    }

    // MARK: - Adapter → ProviderRecord

    func testAdapter_csvToProviderRecords() async throws {
        let ingested = date(2024, 7, 10)
        let adapter = StooqProviderAdapter(
            fetcher: StaticResponseFetcher([.stooqHistory(symbol: "aapl.us"): sampleCSV])
        ) { ingested }
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "aapl.us"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertEqual(record.providerID, .stooq)
            XCTAssertEqual(record.kind, .dailyBar)
            XCTAssertEqual(record.reliabilityClass, .documentFreeAPI)
            XCTAssertEqual(record.jurisdiction, .unitedStates)
            XCTAssertEqual(record.providerCode, ProviderCode(scheme: "stock_symbol", value: "aapl.us"))
            XCTAssertEqual(record.ingestedAt, ingested)
        }
        // rawPayload 解出来是真实 DailyBarPayload（USD，不复权 raw）
        let payload = try JSONDecoder().decode(DailyBarPayload.self, from: records[0].rawPayload)
        XCTAssertEqual(payload.rawOpen.value, Decimal(string: "210.34"))
        XCTAssertEqual(payload.rawOpen.currency, .usd)
        XCTAssertEqual(payload.adjustmentFactor, 1.0, "基础下载不复权，factor=1.0 不伪造")
        XCTAssertEqual(payload.volume, 52_000_000)
    }

    func testAdapter_diagnosticsSurfaceDroppedCount() async throws {
        let csv = """
        Date,Open,High,Low,Close,Volume
        2024-07-01,210.34,212.50,209.80,211.20,52000000
        2024-07-02,bad,213.00,210.90,212.80,100
        """
        let ingested = date(2024, 7, 10)
        let adapter = StooqProviderAdapter(
            fetcher: StaticResponseFetcher([.stooqHistory(symbol: "aapl.us"): csv])
        ) { ingested }
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "stock_symbol", value: "aapl.us"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.completeness, .complete)
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["stooq_csv"], 1)
        XCTAssertEqual(result.records.count, 1)
    }

    func testAdapter_nonStockSymbolScheme_returnsEmpty() async throws {
        let ingested = date(2024, 7, 10)
        let adapter = StooqProviderAdapter(
            fetcher: StaticResponseFetcher([.stooqHistory(symbol: "aapl.us"): sampleCSV])
        ) { ingested }
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "aapl.us"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(result.records.isEmpty, "非 stock_symbol scheme 应返回空")
    }

    // MARK: - PROV-1 集成：staging + schema 校验

    func testIntegration_recordsPassSchemaValidatorAndStagingRoundTrip() async throws {
        // Stooq Adapter 产的 ProviderRecord 应能过 SchemaValidator 并 staging round-trip
        let ingested = date(2024, 7, 10)
        let adapter = StooqProviderAdapter(
            fetcher: StaticResponseFetcher([.stooqHistory(symbol: "aapl.us"): sampleCSV])
        ) { ingested }
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "aapl.us"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        // 1. SchemaValidator 全部通过
        let validator = ProviderRecordSchemaValidator()
        let (valid, invalid) = validator.partition(records)
        XCTAssertEqual(valid.count, 3)
        XCTAssertTrue(invalid.isEmpty, "Stooq 产出的记录应全部通过 schema 校验")

        // 2. Staging JSONL round-trip 等价
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov2-stooq-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProviderStagingWriter().write(records, to: url)
        let readBack = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(readBack, records, "staging round-trip 应等价")
    }
}
