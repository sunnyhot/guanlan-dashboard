import XCTest
@testable import QiemanDashboard

/// PROV-6 测试：Alpha Vantage TIME_SERIES_DAILY JSON 解析链 → ProviderRecord →
/// staging/schema 校验，以及 quota 降级（核心验收：quota 用完降级不阻塞）。
///
/// 复用现有 `AlphaVantageClient`（Core/Clients/）的 URL/鉴权/上游信号检测，本测试用
/// `FakeAlphaVantageClient` 注入预录 Data 或特定 error。JSON 样本基于 Alpha Vantage
/// TIME_SERIES_DAILY 真实 wire 格式（非 live 录制，手工构造的代表性样本）。
final class AlphaVantageAdapterTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    /// 真实 Alpha Vantage TIME_SERIES_DAILY JSON（含 OHLCV 全字段，3 天）。
    private let sampleJSON = """
    {"Time Series (Daily)": {
      "2024-07-01": {"1. open":"210.34","2. high":"212.50","3. low":"209.80","4. close":"211.20","5. volume":"52000000"},
      "2024-07-02": {"1. open":"211.20","2. high":"213.00","3. low":"210.90","4. close":"212.80","5. volume":"49800000"},
      "2024-07-03": {"1. open":"212.80","2. high":"214.10","3. low":"212.10","4. close":"213.45","5. volume":"45100000"}
    }}
    """

    private func sampleData() -> Data {
        Data(sampleJSON.utf8)
    }

    private func makeAdapter(_ outcome: FakeAlphaVantageClient.Outcome, ingested: Date) -> AlphaVantageProviderAdapter {
        AlphaVantageProviderAdapter(
            client: FakeAlphaVantageClient(outcome),
            settings: AlphaVantageSettings(enabled: true, apiKey: "test-key")
        ) { ingested }
    }

    // MARK: - JSON 解析

    func testParse_realJSONFormat_producesDailyBarEntries() throws {
        let parser = AlphaVantageResponseParser()
        let history = try parser.parse(sampleData(), symbol: "AAPL")
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.droppedMalformedCount, 0)
        // 按日期升序
        XCTAssertEqual(history.entries[0].date, date(2024, 7, 1))
        let first = history.entries[0]
        XCTAssertEqual(first.open, 210.34, accuracy: 1e-9)
        XCTAssertEqual(first.high, 212.50, accuracy: 1e-9)
        XCTAssertEqual(first.low, 209.80, accuracy: 1e-9)
        XCTAssertEqual(first.close, 211.20, accuracy: 1e-9)
        XCTAssertEqual(first.volume, 52_000_000)
    }

    func testParse_missingVolume_treatedAsNil() throws {
        // 个别行缺 "5. volume" → nil，不丢弃整行
        let json = """
        {"Time Series (Daily)": {"2024-07-01": {"1. open":"210.34","2. high":"212.50","3. low":"209.80","4. close":"211.20"}}}
        """
        let history = try AlphaVantageResponseParser().parse(Data(json.utf8), symbol: "AAPL")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(history.entries[0].volume, "缺 volume 应为 nil 而非丢弃")
    }

    func testParse_malformedRowsCountedNotCrash() throws {
        // 第 2 行 OHLC 非有限（"NaN"）→ 丢弃 + 计数；合法行保留
        let json = """
        {"Time Series (Daily)": {
          "2024-07-01": {"1. open":"210.34","2. high":"212.50","3. low":"209.80","4. close":"211.20","5. volume":"52000000"},
          "2024-07-02": {"1. open":"NaN","2. high":"213.00","3. low":"210.90","4. close":"212.80","5. volume":"100"},
          "2024-07-03": {"1. open":"212.80","2. high":"214.10","3. low":"212.10","4. close":"213.45","5. volume":"45100000"}
        }}
        """
        let history = try AlphaVantageResponseParser().parse(Data(json.utf8), symbol: "AAPL")
        XCTAssertEqual(history.entries.count, 2, "NaN 行应丢弃")
        XCTAssertEqual(history.droppedMalformedCount, 1)
    }

    func testParse_allRowsMalformed_throws() {
        let json = """
        {"Time Series (Daily)": {
          "2024-07-01": {"1. open":"bad","2. high":"x","3. low":"y","4. close":"z"},
          "2024-07-02": {"1. open":"NaN","2. high":"NaN","3. low":"NaN","4. close":"NaN"}
        }}
        """
        XCTAssertThrowsError(try AlphaVantageResponseParser().parse(Data(json.utf8), symbol: "AAPL")) { err in
            guard case .noValidEntries(let total) = err as? AlphaVantageParseError else {
                XCTFail("expected noValidEntries, got \(err)"); return
            }
            XCTAssertEqual(total, 2)
        }
    }

    func testParse_emptyBody_throws() {
        XCTAssertThrowsError(try AlphaVantageResponseParser().parse(Data(), symbol: "AAPL")) { err in
            XCTAssertEqual(err as? AlphaVantageParseError, .emptyBody)
        }
    }

    func testParse_missingTimeSeries_throws() {
        // 有 JSON 但缺 "Time Series (Daily)" key
        let json = #"{"Meta Data": {"1. Information": "Daily Prices"}}"#
        XCTAssertThrowsError(try AlphaVantageResponseParser().parse(Data(json.utf8), symbol: "AAPL")) { err in
            XCTAssertEqual(err as? AlphaVantageParseError, .missingTimeSeries)
        }
    }

    // MARK: - Adapter → ProviderRecord

    func testAdapter_jsonToProviderRecords() async throws {
        let ingested = date(2024, 7, 10)
        let adapter = makeAdapter(.data(sampleData()), ingested: ingested)
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertEqual(record.providerID, .alphaVantage)
            XCTAssertEqual(record.kind, .dailyBar)
            XCTAssertEqual(record.reliabilityClass, .documentFreeAPI)
            XCTAssertEqual(record.jurisdiction, .unitedStates)
            XCTAssertEqual(record.providerCode, ProviderCode(scheme: "stock_symbol", value: "AAPL"))
            XCTAssertEqual(record.ingestedAt, ingested)
        }
        // rawPayload 解出来是真实 DailyBarPayload（USD，不复权 raw）
        let payload = try JSONDecoder().decode(DailyBarPayload.self, from: records[0].rawPayload)
        XCTAssertEqual(payload.rawOpen.value, Decimal(string: "210.34"))
        XCTAssertEqual(payload.rawOpen.currency, .usd)
        XCTAssertEqual(payload.adjustmentFactor, 1.0, "TIME_SERIES_DAILY 不复权，factor=1.0 不伪造")
        XCTAssertEqual(payload.volume, 52_000_000)
    }

    func testAdapter_diagnosticsSurfaceDroppedCount() async throws {
        let json = """
        {"Time Series (Daily)": {
          "2024-07-01": {"1. open":"210.34","2. high":"212.50","3. low":"209.80","4. close":"211.20","5. volume":"52000000"},
          "2024-07-02": {"1. open":"bad","2. high":"213.00","3. low":"210.90","4. close":"212.80","5. volume":"100"}
        }}
        """
        let adapter = makeAdapter(.data(Data(json.utf8)), ingested: date(2024, 7, 10))
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.completeness, .complete)
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["alphavantage_daily"], 1)
        XCTAssertEqual(result.records.count, 1)
    }

    func testAdapter_nonStockSymbolScheme_returnsEmpty() async throws {
        let adapter = makeAdapter(.data(sampleData()), ingested: date(2024, 7, 10))
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "AAPL"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(result.records.isEmpty, "非 stock_symbol scheme 应返回空")
    }

    // MARK: - quota 降级（核心验收：quota 用完降级不阻塞）

    func testAdapter_serviceMessageRateLimit_mapsToQuotaExhausted() async {
        // 上游 "Information"（25/day 额度耗尽）→ ProviderError.quotaExhausted，不阻塞
        let adapter = makeAdapter(.error(.serviceMessage(
            "Thank you for using Alpha Vantage! Our standard API call frequency is 25 requests per day. Please subscribe..."
        )), ingested: date(2024, 7, 10))
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("额度耗尽应抛 quotaExhausted")
        } catch {
            XCTAssertEqual(error as? ProviderError, .quotaExhausted(providerID: .alphaVantage))
        }
    }

    func testAdapter_serviceMessageFrequency_mapsToQuotaExhausted() async {
        // 上游 "Note"（API call frequency 提示）→ quotaExhausted
        let adapter = makeAdapter(.error(.serviceMessage(
            "Information. API call frequency is 25 per day."
        )), ingested: date(2024, 7, 10))
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("频率限制应抛 quotaExhausted")
        } catch {
            XCTAssertEqual(error as? ProviderError, .quotaExhausted(providerID: .alphaVantage))
        }
    }

    func testAdapter_dailyBudgetExceeded_mapsToQuotaExhausted() async {
        // 本地预算耗尽（若上层接了 budget）→ quotaExhausted
        let adapter = makeAdapter(.error(.dailyBudgetExceeded(limit: 25)), ingested: date(2024, 7, 10))
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("预算耗尽应抛 quotaExhausted")
        } catch {
            XCTAssertEqual(error as? ProviderError, .quotaExhausted(providerID: .alphaVantage))
        }
    }

    func testAdapter_serviceMessageInvalidSymbol_mapsToSchemaMismatch() async {
        // "Error Message"（invalid symbol 等，非 quota）→ schemaMismatch（不误判为 quota）
        let adapter = makeAdapter(.error(.serviceMessage("Invalid API call. Please retry or visit the documentation.")), ingested: date(2024, 7, 10))
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "BADSYM"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("invalid symbol 应抛 schemaMismatch")
        } catch let e as ProviderError {
            if case .schemaMismatch(let pid, _) = e {
                XCTAssertEqual(pid, .alphaVantage)
            } else {
                XCTFail("expected schemaMismatch, got \(e)")
            }
        } catch {
            XCTFail("expected ProviderError, got \(error)")
        }
    }

    func testAdapter_invalidHTTPStatus_mapsToUnavailable() async {
        let adapter = makeAdapter(.error(.invalidHTTPStatus(503)), ingested: date(2024, 7, 10))
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("HTTP 503 应抛 unavailable")
        } catch let e as ProviderError {
            if case .unavailable(let pid, _) = e {
                XCTAssertEqual(pid, .alphaVantage)
            } else {
                XCTFail("expected unavailable, got \(e)")
            }
        } catch {
            XCTFail("expected ProviderError, got \(error)")
        }
    }

    // MARK: - mapClientError 单元（直接测映射，不走路由）

    func testMapClientError_dailyBudget() {
        XCTAssertEqual(
            AlphaVantageProviderAdapter.mapClientError(.dailyBudgetExceeded(limit: 25)),
            .quotaExhausted(providerID: .alphaVantage)
        )
    }

    // MARK: - PROV-1 集成：staging + schema 校验

    func testIntegration_recordsPassSchemaValidatorAndStagingRoundTrip() async throws {
        let adapter = makeAdapter(.data(sampleData()), ingested: date(2024, 7, 10))
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        // 1. SchemaValidator 全部通过
        let validator = ProviderRecordSchemaValidator()
        let (valid, invalid) = validator.partition(records)
        XCTAssertEqual(valid.count, 3)
        XCTAssertTrue(invalid.isEmpty, "Alpha Vantage 产出的记录应全部通过 schema 校验")

        // 2. Staging JSONL round-trip 等价
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov6-alphavantage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProviderStagingWriter().write(records, to: url)
        let readBack = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(readBack, records, "staging round-trip 应等价")
    }
}

// MARK: - FakeAlphaVantageClient（测试注入：返回预录 Data 或抛特定 error）

private final class FakeAlphaVantageClient: AlphaVantageClientProtocol, @unchecked Sendable {
    enum Outcome {
        case data(Data)
        case error(AlphaVantageClientError)
    }
    private let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }

    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings
    ) async throws -> Data {
        switch outcome {
        case .data(let d): return d
        case .error(let e): throw e
        }
    }
}
