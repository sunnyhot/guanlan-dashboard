import XCTest
@testable import QiemanDashboard

/// PROV-4 单元测试：SEC XBRL companyfacts 解析 + ProviderAdapter 链路。
///
/// 全部离线（FakeSECClient 注入预录 wire 格式样本，复用 SECOfficialSourceCache
/// 真实缓存行为）。覆盖：多 vintage 事实行、PIT 时间语义（end→effectiveAt /
/// filed→publishedAt）、extractionMethod=.xbrlFact（验收项）、schema 校验、
/// staging round-trip、错误映射（403/429→unavailable、目录 notFound、缺 us-gaap
/// →schemaMismatch）。fundamentalFact → FundamentalObservation 的 Canonical
/// 转换链自 REPO-1b 起在 FundamentalRepositoryTests 覆盖。
final class SECAdapterTests: XCTestCase {

    private let ingested = Date(timeIntervalSince1970: 1_724_000_000)

    // MARK: - 测试样本（真实 wire 格式结构）

    private let directoryJSON = """
    {"fields":["cik","name","ticker","exchange"],
     "data":[[320193,"Apple Inc","AAPL","Nasdaq"],
             [789019,"MICROSOFT CORP","MSFT","Nasdaq"]]}
    """

    private func companyFactsJSON(rows: String) -> String {
        """
        {"cik":320193,"entityName":"Apple Inc","facts":{
          "dei":{"EntityCommonStockSharesOutstanding":{"units":{"shares":[]}}},
          "us-gaap":{
            "RevenueFromContractWithCustomerExcludingAssessedTax":{"units":{"USD":[\(rows)]}},
            "NetIncomeLoss":{"units":{"USD":[
              {"start":"2023-04-01","end":"2023-06-30","val":19881000000,
               "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-Q","filed":"2023-08-04"}
            ]}}
          }
        }}
        """
    }

    /// 同一 concept 同一 period 两次申报（10-Q 初报 + 10-K 修订）→ multi-vintage。
    private var revenueRows: String {
        """
        {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
         "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-Q",
         "filed":"2023-08-04","frame":"CY2023Q2"},
        {"start":"2023-04-01","end":"2023-06-30","val":81497000000,
         "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-K","filed":"2023-11-03"}
        """
    }

    private func makeAdapter(
        responses: [String: Data],
        settings: OfficialSourceSettings = OfficialSourceSettings(secContactEmail: "test@example.com")
    ) -> SECProviderAdapter {
        SECProviderAdapter(
            client: FakeSECClient(responses: responses),
            settings: settings,
            cache: SECOfficialSourceCache(),
            ingestedAt: { [self] in ingested }
        )
    }

    private var defaultResponses: [String: Data] {
        [
            "https://www.sec.gov/files/company_tickers_exchange.json": directoryJSON.data(using: .utf8)!,
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json":
                companyFactsJSON(rows: revenueRows).data(using: .utf8)!
        ]
    }

    private let code = ProviderCode(scheme: "stock_symbol", value: "aapl")

    // MARK: - 解析：多 vintage + PIT 语义

    func testParse_multiVintageSamePeriod() throws {
        let parser = SECResponseParser()
        let facts = try parser.parseCompanyFacts(
            companyFactsJSON(rows: revenueRows).data(using: .utf8)!
        )
        XCTAssertEqual(facts.cik, 320193)
        XCTAssertEqual(facts.entityName, "Apple Inc")
        // revenue 2 行（10-Q 初报 + 10-K 修订）+ netIncome 1 行
        XCTAssertEqual(facts.facts.count, 3)
        let revenues = facts.facts.filter { $0.metricKey == "revenue" }
        XCTAssertEqual(revenues.count, 2)
        // 初报 81.418B，修订 81.497B（保留两 vintage 不互相覆盖）
        let values = Set(revenues.map { $0.value })
        XCTAssertTrue(values.contains(Decimal(string: "81418000000")!))
        XCTAssertTrue(values.contains(Decimal(string: "81497000000")!))
        XCTAssertEqual(facts.droppedMalformedCount, 0)
    }

    func testParse_conceptPriority_deduplicatesSameMetric() throws {
        // 公司同时披露高优先级标签（RevenueFromContract…）与回退标签（Revenues）：
        // 同一 metricKey 只取首个命中概念，不得产出重复事实（审查 P2）
        let json = """
        {"cik":320193,"entityName":"Apple Inc","facts":{"us-gaap":{
          "RevenueFromContractWithCustomerExcludingAssessedTax":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
             "form":"10-Q","filed":"2023-08-04"}
          ]}},
          "Revenues":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
             "form":"10-Q","filed":"2023-08-04"}
          ]}}
        }}}
        """
        let parser = SECResponseParser()
        let facts = try parser.parseCompanyFacts(json.data(using: .utf8)!)
        XCTAssertEqual(facts.facts.count, 1)   // 只有首个命中概念
        XCTAssertEqual(facts.facts[0].concept, "RevenueFromContractWithCustomerExcludingAssessedTax")
    }

    func testParse_conceptFallbackWhenPrimaryAbsent() throws {
        // 高优先级标签缺失/无有效行时回退到 Revenues
        let json = """
        {"cik":320193,"entityName":"Apple Inc","facts":{"us-gaap":{
          "RevenueFromContractWithCustomerExcludingAssessedTax":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":"garbage",
             "form":"10-Q","filed":"2023-08-04"}
          ]}},
          "Revenues":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
             "form":"10-Q","filed":"2023-08-04"}
          ]}}
        }}}
        """
        let parser = SECResponseParser()
        let facts = try parser.parseCompanyFacts(json.data(using: .utf8)!)
        XCTAssertEqual(facts.facts.count, 1)
        XCTAssertEqual(facts.facts[0].concept, "Revenues")
    }

    func testParse_conceptsCoveringDifferentYears_bothKept() throws {
        // 审查 P2 场景：公司近年用新标签（RevenueFromContract…），早年只有旧标签
        // （Revenues）——逐事实按 (unit, start/end, filed) 选优先概念后，两段历史
        // 都保留，早年数据不因全局只选一个 concept 而消失
        let json = """
        {"cik":320193,"entityName":"Apple Inc","facts":{"us-gaap":{
          "RevenueFromContractWithCustomerExcludingAssessedTax":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
             "form":"10-Q","filed":"2023-08-04"}
          ]}},
          "Revenues":{"units":{"USD":[
            {"start":"2019-09-29","end":"2020-09-26","val":274515000000,
             "form":"10-K","filed":"2020-10-30"}
          ]}}
        }}}
        """
        let parser = SECResponseParser()
        let facts = try parser.parseCompanyFacts(json.data(using: .utf8)!)
        XCTAssertEqual(facts.facts.count, 2)
        let byConcept = Dictionary(facts.facts.map { ($0.concept, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byConcept["RevenueFromContractWithCustomerExcludingAssessedTax"], Decimal(string: "81418000000"))
        XCTAssertEqual(byConcept["Revenues"], Decimal(string: "274515000000"))
    }

    func testToProviderRecords_pitSemanticsAndExtractionMethod() throws {
        let parser = SECResponseParser()
        let facts = try parser.parseCompanyFacts(
            companyFactsJSON(rows: revenueRows).data(using: .utf8)!
        )
        let records = parser.toProviderRecords(
            facts, reliabilityClass: .officialStable, ingestedAt: ingested
        )
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertEqual(record.providerID, .sec)
            XCTAssertEqual(record.kind, .fundamentalFact)
            XCTAssertEqual(record.providerCode.scheme, "sec_cik")
            XCTAssertEqual(record.providerCode.value, "0000320193")   // 10 位补零（审查 P2）
            XCTAssertEqual(record.reliabilityClass, .officialStable)
            XCTAssertEqual(record.jurisdiction, .unitedStates)
            // PIT：事件时间（period end）≤ 公布时间（filed）
            XCTAssertLessThanOrEqual(record.effectiveAt, record.publishedAt)
        }
        // payload：extractionMethod = .xbrlFact（PROV-4 验收）+ 数值精度
        let revenueRecords = records.filter {
            $0.effectiveAt == utcDay("2023-06-30")
        }
        let payloads = try revenueRecords.map {
            try JSONDecoder().decode(FundamentalFactPayload.self, from: $0.rawPayload)
        }
        XCTAssertEqual(Set(payloads.map(\.extractionMethod)), [.xbrlFact])
        XCTAssertTrue(payloads.contains { $0.concept == "RevenueFromContractWithCustomerExcludingAssessedTax" })
        XCTAssertTrue(payloads.contains { $0.concept == "NetIncomeLoss" })
        XCTAssertTrue(payloads.contains { $0.value == Decimal(string: "19881000000")! })
        XCTAssertTrue(payloads.contains { $0.frame == "CY2023Q2" })
    }

    // MARK: - Adapter 链路

    func testFetch_fullChain() async throws {
        let adapter = makeAdapter(responses: defaultResponses)
        let result = try await adapter.fetchWithDiagnostics(
            code: code,
            from: utcDay("2023-01-01"),
            to: utcDay("2024-01-01")
        )
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.diagnostics.completeness, .complete)
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["sec_companyfacts"], 0)
    }

    func testFetch_timeRangeFilters() async throws {
        let adapter = makeAdapter(responses: defaultResponses)
        // 只取 2023-09-01 之后结束的期间：10-K 修订行（end 06-30 在窗口外）全被滤掉
        let result = try await adapter.fetchWithDiagnostics(
            code: code,
            from: utcDay("2023-09-01"),
            to: utcDay("2024-01-01")
        )
        XCTAssertTrue(result.records.isEmpty)
    }

    func testFetch_ignoresNonStockSymbolScheme() async throws {
        let adapter = makeAdapter(responses: defaultResponses)
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: .distantPast, to: .distantFuture
        )
        XCTAssertTrue(result.records.isEmpty)
    }

    func testFetch_malformedRowsCountedNotFatal() async throws {
        // 一行 val 非法 + 一行 form 不在范围（8-K），其余正常 → dropped 计数 2
        let rows = """
        {"start":"2023-04-01","end":"2023-06-30","val":"not-a-number",
         "form":"10-Q","filed":"2023-08-04"},
        {"start":"2023-04-01","end":"2023-06-30","val":100,
         "form":"8-K","filed":"2023-08-04"},
        {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
         "form":"10-Q","filed":"2023-08-04"}
        """
        let responses = [
            "https://www.sec.gov/files/company_tickers_exchange.json": directoryJSON.data(using: .utf8)!,
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json":
                companyFactsJSON(rows: rows).data(using: .utf8)!
        ]
        let adapter = makeAdapter(responses: responses)
        let result = try await adapter.fetchWithDiagnostics(
            code: code, from: .distantPast, to: .distantFuture
        )
        XCTAssertEqual(result.records.count, 2)   // netIncome 1 + 合法 revenue 1
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["sec_companyfacts"], 2)
    }

    // MARK: - Schema 校验 + staging round-trip

    func testRecords_passSchemaValidatorAndStage() async throws {
        let adapter = makeAdapter(responses: defaultResponses)
        let result = try await adapter.fetchWithDiagnostics(
            code: code, from: .distantPast, to: .distantFuture
        )
        let validator = ProviderRecordSchemaValidator()
        let partition = validator.partition(result.records)
        XCTAssertTrue(partition.invalid.isEmpty)
        XCTAssertEqual(partition.valid.count, 3)

        // staging round-trip（PROV-1 Reader/Writer）
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec-prov4-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProviderStagingWriter().write(partition.valid, to: url)
        let reread = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(reread, partition.valid)
    }

    // MARK: - ObservationFactory 转换（REPO-1b 后的完整链路在 FundamentalRepositoryTests）

    // MARK: - 错误映射

    func testMapClientError_429RateLimited_403Unavailable() {
        let forbidden = SECOfficialSourceClientError.requestFailed(statusCode: 403, detail: "blocked")
        let rateLimited = SECOfficialSourceClientError.requestFailed(statusCode: 429, detail: "")
        if case .unavailable = SECProviderAdapter.mapClientError(forbidden) {} else {
            XCTFail("403 应映射 unavailable")
        }
        // 429 是公平访问限流（transient）→ rateLimited（独立冷却自动恢复，审查 P2）
        if case .rateLimited(let providerID, _) = SECProviderAdapter.mapClientError(rateLimited) {
            XCTAssertEqual(providerID, .sec)
        } else {
            XCTFail("429 应映射 rateLimited")
        }
        // SEC 无配额概念：任何情况都不冒充 quotaExhausted
        if case .quotaExhausted = SECProviderAdapter.mapClientError(rateLimited) {
            XCTFail("SEC 429 不是 quota 语义")
        } else {}
    }

    func testMapClientError_invalidResponseSchemaMismatch() {
        let error = SECOfficialSourceClientError.invalidResponse("not json")
        if case .schemaMismatch = SECProviderAdapter.mapClientError(error) {} else {
            XCTFail("invalidResponse 应映射 schemaMismatch")
        }
    }

    func testFetch_companyNotFound() async {
        let responses = [
            "https://www.sec.gov/files/company_tickers_exchange.json": directoryJSON.data(using: .utf8)!,
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json":
                companyFactsJSON(rows: revenueRows).data(using: .utf8)!
        ]
        let adapter = makeAdapter(responses: responses)
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: "TSLA"),
                from: .distantPast, to: .distantFuture
            )
            XCTFail("目录外 ticker 应抛 notFound")
        } catch let error as ProviderError {
            guard case .notFound(let code) = error else {
                return XCTFail("expected notFound, got \(error)")
            }
            XCTAssertEqual(code.value, "TSLA")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetch_missingFactsSchemaMismatch() async {
        let brokenJSON = """
        {"cik":320193,"entityName":"Apple Inc","facts":{"dei":{}}}
        """
        let responses = [
            "https://www.sec.gov/files/company_tickers_exchange.json": directoryJSON.data(using: .utf8)!,
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json":
                brokenJSON.data(using: .utf8)!
        ]
        let adapter = makeAdapter(responses: responses)
        do {
            _ = try await adapter.fetch(code: code, from: .distantPast, to: .distantFuture)
            XCTFail("缺 us-gaap 应抛 schemaMismatch")
        } catch let error as ProviderError {
            guard case .schemaMismatch = error else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetch_missingContactMapsUnavailable() async {
        // 未配置联系邮箱 → SECOfficialSourceClientError.missingContact → unavailable
        let adapter = makeAdapter(
            responses: defaultResponses,
            settings: OfficialSourceSettings(secContactEmail: "")
        )
        do {
            _ = try await adapter.fetch(code: code, from: .distantPast, to: .distantFuture)
            XCTFail("未配置联系邮箱应抛 unavailable")
        } catch let error as ProviderError {
            guard case .unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - 目录解析

    func testParseCompanyDirectory_tickerNormalization() throws {
        let parser = SECResponseParser()
        // 小写 + brk.b 风格 → BRK-B（与现有 SECOfficialResearchTool 归一化一致）
        let identity = try parser.parseCompanyDirectory(
            directoryJSON.data(using: .utf8)!, ticker: "aapl"
        )
        XCTAssertEqual(identity.cik, 320193)
        XCTAssertEqual(identity.ticker, "AAPL")
        XCTAssertEqual(identity.paddedCIK, "0000320193")
    }

    // MARK: - Helpers

    private func utcDay(_ yyyyMMdd: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: yyyyMMdd)!
    }
}

/// 注入预录响应的 SEC client（按 URL 分发）。
private struct FakeSECClient: SECOfficialSourceClientProtocol {
    let responses: [String: Data]

    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        timeoutSeconds: Double
    ) async throws -> Data {
        guard settings.isSECConfigured else {
            throw SECOfficialSourceClientError.missingContact
        }
        guard let data = responses[descriptor.url.absoluteString] else {
            throw SECOfficialSourceClientError.requestFailed(statusCode: 404, detail: "no fixture")
        }
        return data
    }
}

/// 周末非交易日的最小日历（与其他 V2 测试的 WeekdayCalendar 桩一致）。
extension SECAdapterTests {
    struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let weekday = cal.component(.weekday, from: date)
            return weekday != 1 && weekday != 7
        }

        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var current = cal.startOfDay(for: date)
            var remaining = offset
            while remaining > 0 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    remaining -= 1
                }
            }
            return current
        }

        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.startOfDay(for: date)
        }
    }
}
