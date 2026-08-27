import XCTest
@testable import QiemanDashboard

/// PROV-5 测试：FRED 宏观指标 JSON 解析链 → ProviderRecord → ObservationFactory → MacroObservation。
///
/// 验证 FRED 真实 wire 格式（observations JSON + realtime_start vintage）的端到端解析，
/// 以及 MacroRelease availability policy（发布日 +1 交易日）。JSON 样本基于 FRED 真实响应
/// 格式（非 live 录制，手工构造的代表性 wire 格式）。
final class FREDAdapterTests: XCTestCase {

    /// 与 FREDProviderAdapter 默认参数一致的 endpoint（realtime 全窗口 + key）。
    /// 默认 realtimeStart = 1776-07-04（FRED 官方完整实时区间下界，P2 修复）。
    private static let gdpEndpoint = ProviderEndpoint.fredObservations(
        seriesID: "GDP",
        realtimeStart: "1776-07-04",
        realtimeEnd: nil,
        apiKey: "test-key",
        offset: 0
    )

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let w = cal.component(.weekday, from: date)
            return w >= 2 && w <= 6
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            var current = date; var remaining = max(offset, 0); var safety = 0
            while remaining > 0 && safety < 14 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
                safety += 1
            }
            return current
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            return cal.startOfDay(for: date)
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    /// GDP series config（季度、季节调整、%）。
    private var gdpConfig: FREDSeriesConfig {
        FREDSeriesConfig(seriesID: "GDP", unit: .percent, frequency: .quarterly,
                         isSeasonallyAdjusted: true, basePeriod: nil)
    }

    /// 真实 FRED observations JSON 样本（GDP 三期，含一期修订 vintage）。
    private let sampleJSON = """
    {"observations":[
      {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25","realtime_end":"2024-07-24"},
      {"date":"2024-01-01","value":"2.6","realtime_start":"2024-07-25","realtime_end":"9999-12-31"},
      {"date":"2024-04-01","value":"3.0","realtime_start":"2024-07-25","realtime_end":"9999-12-31"}
    ]}
    """

    // MARK: - JSON 解析

    func testParse_realJSONFormat_producesObservations() throws {
        let history = try FREDResponseParser().parse(sampleJSON, seriesID: "GDP")
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.droppedMalformedCount, 0)
        // 第一条：Q1 GDP，观测期 2024-01-01，发布日 2024-04-25
        XCTAssertEqual(history.entries[0].date, date(2024, 1, 1))
        XCTAssertEqual(history.entries[0].value, Decimal(string: "2.5"))
        XCTAssertEqual(history.entries[0].realtimeStart, date(2024, 4, 25))
    }

    func testParse_missingValueDotDropped() throws {
        // FRED 用 "." 表示缺失值 → 丢弃 + 计数，合法行保留
        let json = """
        {"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2024-04-01","value":".","realtime_start":"2024-07-25"}
        ]}
        """
        let history = try FREDResponseParser().parse(json, seriesID: "GDP")
        XCTAssertEqual(history.entries.count, 1, "缺值行应丢弃")
        XCTAssertEqual(history.droppedMalformedCount, 1)
    }

    func testParse_allMissing_throws() {
        let json = """
        {"observations":[
          {"date":"2024-01-01","value":".","realtime_start":"2024-04-25"}
        ]}
        """
        XCTAssertThrowsError(try FREDResponseParser().parse(json, seriesID: "GDP")) { err in
            guard case .noValidEntries(let total) = err as? FREDParseError else {
                XCTFail("expected noValidEntries, got \(err)"); return
            }
            XCTAssertEqual(total, 1)
        }
    }

    func testParse_emptyBody_throws() {
        XCTAssertThrowsError(try FREDResponseParser().parse("", seriesID: "GDP")) { err in
            XCTAssertEqual(err as? FREDParseError, .emptyBody)
        }
    }

    func testParse_malformedJSON_throws() {
        XCTAssertThrowsError(try FREDResponseParser().parse("{not json", seriesID: "GDP")) { err in
            guard case .malformedJSON = err as? FREDParseError else {
                XCTFail("expected malformedJSON, got \(err)"); return
            }
        }
    }

    // MARK: - Adapter → ProviderRecord

    func testAdapter_jsonToProviderRecords() async throws {
        let ingested = date(2024, 8, 1)
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: sampleJSON]),
            ingestedAt: { ingested },
            apiKey: "test-key"
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 3)
        for record in records {
            XCTAssertEqual(record.providerID, .fred)
            XCTAssertEqual(record.kind, .macroObservation)
            XCTAssertEqual(record.reliabilityClass, .officialStable)
            XCTAssertEqual(record.jurisdiction, .unitedStates)
            XCTAssertEqual(record.ingestedAt, ingested)
        }
        // realtime_start → publishedAt（PIT 锚点），date → effectiveAt
        XCTAssertEqual(records[0].effectiveAt, date(2024, 1, 1))
        XCTAssertEqual(records[0].publishedAt, date(2024, 4, 25),
                       "realtime_start 应映射为 publishedAt（发布日）")
        // MacroPayload 字段
        let payload = try JSONDecoder().decode(MacroPayload.self, from: records[0].rawPayload)
        XCTAssertEqual(payload.value, Decimal(string: "2.5"))
        XCTAssertEqual(payload.unit, .percent)
        XCTAssertEqual(payload.frequency, .quarterly)
        XCTAssertTrue(payload.isSeasonallyAdjusted)
    }

    func testAdapter_diagnosticsSurfaceDroppedCount() async throws {
        let json = """
        {"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2024-04-01","value":".","realtime_start":"2024-07-25"}
        ]}
        """
        let ingested = date(2024, 8, 1)
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: json]),
            ingestedAt: { ingested },
            apiKey: "test-key"
        )
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.completeness, .complete)
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["fred_observations"], 1)
        XCTAssertEqual(result.records.count, 1)
    }

    // MARK: - P1 修复：realtime 窗口与 api key

    func testMissingAPIKeyFailsClosed() async {
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([:]),
            apiKey: ""   // 缺 key
        )
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("缺 key 应拒绝抓取")
        } catch let error as ProviderError {
            guard case .unavailable(_, let underlying) = error else {
                return XCTFail("期望 unavailable：\(error)")
            }
            XCTAssertTrue(underlying.contains("FRED API key"), "报错应指向缺失的 key：\(underlying)")
        } catch {
            XCTFail("期望 ProviderError：\(error)")
        }
    }

    func testRealtimeWindowFlowsToEndpoint() async throws {
        // 自定义窗口的 endpoint 命中 → 证明 realtimeStart/End 从 adapter 传到了 fetcher
        let customEndpoint = ProviderEndpoint.fredObservations(
            seriesID: "GDP",
            realtimeStart: "2020-01-01",
            realtimeEnd: "2024-12-31",
            apiKey: "test-key",
            offset: 0
        )
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([customEndpoint: sampleJSON]),
            ingestedAt: { self.date(2024, 8, 1) },
            apiKey: "test-key",
            realtimeStart: "2020-01-01",
            realtimeEnd: "2024-12-31"
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 3, "自定义 realtime 窗口的 endpoint 被命中")
    }

    // MARK: - 二轮 P1/P2 修复

    func testPaginationFetchesAllPages() async throws {
        // 两页响应（count=4、每页 2 条）：adapter 必须循环抓完
        let page1 = """
        {"count":4,"offset":0,"limit":2,"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2023-10-01","value":"2.9","realtime_start":"2024-01-25"}
        ]}
        """
        let page2 = """
        {"count":4,"offset":2,"limit":2,"observations":[
          {"date":"2023-07-01","value":"2.2","realtime_start":"2023-10-26"},
          {"date":"2023-04-01","value":"2.0","realtime_start":"2023-07-27"}
        ]}
        """
        let fetcher = StaticResponseFetcher([
            Self.gdpEndpoint: page1,
            .fredObservations(
                seriesID: "GDP", realtimeStart: "1776-07-04", realtimeEnd: nil,
                apiKey: "test-key", offset: 2
            ): page2,
        ])
        let adapter = FREDProviderAdapter(
            config: gdpConfig, fetcher: fetcher,
            ingestedAt: { self.date(2024, 8, 1) }, apiKey: "test-key"
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 4, "两页共 4 条全部取回（单页截断会只剩 2）")
    }

    func testSinglePageResponseWithoutPaginationFieldsStops() async throws {
        // 旧 fixture 形态（无 count/offset）：按单页处理，不额外请求
        let single = """
        {"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"}
        ]}
        """
        let counting = CountingFetcher(base: StaticResponseFetcher([Self.gdpEndpoint: single]))
        let adapter = FREDProviderAdapter(
            config: gdpConfig, fetcher: counting,
            ingestedAt: { self.date(2024, 8, 1) }, apiKey: "test-key"
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(counting.fetchCount, 1, "无分页字段不追页")
    }

    func testDefaultRealtimeStartUsesOfficialLowerBound() async throws {
        // P2 修复锁定：默认起点必须是 FRED 官方完整实时区间下界 1776-07-04
        //（endpoint 精确匹配 = 参数逐字节一致，1900-01-01 的 key 不会命中）
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: sampleJSON]),
            ingestedAt: { self.date(2024, 8, 1) },
            apiKey: "test-key"
            // 不传 realtimeStart → 默认
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertFalse(records.isEmpty, "默认 1776-07-04 的 endpoint 被命中")
    }

    func testErrorURLRedactionStripsAPIKey() {
        // P1 修复锁定：错误文本用的 URL 描述剥离 query（api_key 在查询参数）
        let url = URL(string: "https://api.stlouisfed.org/fred/series/observations?series_id=GDP&api_key=SECRET_KEY&offset=0")!
        let redacted = URLSessionResponseFetcher.redactedDescription(of: url)
        XCTAssertFalse(redacted.contains("SECRET_KEY"), "脱敏后不含 api_key：\(redacted)")
        XCTAssertTrue(redacted.contains("api.stlouisfed.org/fred/series/observations"))
        XCTAssertFalse(redacted.contains("series_id"), "查询参数整体剥离：\(redacted)")
        // 无 query 的 URL 不受影响
        let plain = URL(string: "https://stooq.com/q/d/l/?s=aapl")!
        XCTAssertTrue(URLSessionResponseFetcher.redactedDescription(of: plain).contains("stooq.com"))
    }

    // MARK: - 三轮 P1 修复

    func testTransportErrorRedactsAPIKey() async {
        // P1 修复（三轮）锁定：URLSession 传输失败（URLError userInfo 含
        // NSErrorFailingURLStringKey = 带 api_key 的完整 URL）时，错误文本
        // 仍不得泄露凭据——整体插值底层错误会把它带出来。
        let fullURL = "https://api.stlouisfed.org/fred/series/observations"
            + "?series_id=GDP&api_key=SECRET_TRANSPORT_KEY&offset=0"
        let failure = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLStringErrorKey: fullURL]
        )
        LeakingTransportURLProtocol.failure = failure
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LeakingTransportURLProtocol.self]
        let fetcher = URLSessionResponseFetcher(session: URLSession(configuration: config))

        do {
            _ = try await fetcher.fetch(.fredObservations(
                seriesID: "GDP", realtimeStart: "1776-07-04", realtimeEnd: nil,
                apiKey: "SECRET_TRANSPORT_KEY", offset: 0
            ))
            XCTFail("传输失败应抛错")
        } catch let error as ProviderError {
            guard case .unavailable(_, let underlying) = error else {
                return XCTFail("期望 unavailable：\(error)")
            }
            XCTAssertFalse(underlying.contains("SECRET_TRANSPORT_KEY"),
                           "传输错误不得泄露 api_key：\(underlying)")
            XCTAssertFalse(underlying.contains("series_id"), "不得泄露任何查询参数：\(underlying)")
            XCTAssertTrue(underlying.contains("transport error"), "保留错误域信息：\(underlying)")
            XCTAssertTrue(underlying.contains("api.stlouisfed.org"), "保留脱敏 host/path：\(underlying)")
        } catch {
            XCTFail("期望 ProviderError：\(error)")
        }
        LeakingTransportURLProtocol.failure = nil
    }

    func testPaginationResponseOffsetForwardJumpRejected() async throws {
        // P1 修复（三轮）：请求 offset=0、响应却自称 offset=2 且「已到末页」
        // ——必须拒收（旧行为直接 break，静默漏掉前两条）
        let jumped = """
        {"count":4,"offset":2,"limit":2,"observations":[
          {"date":"2023-07-01","value":"2.2","realtime_start":"2023-10-26"},
          {"date":"2023-04-01","value":"2.0","realtime_start":"2023-07-27"}
        ]}
        """
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: jumped]),
            ingestedAt: { self.date(2024, 8, 1) }, apiKey: "test-key"
        )
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("响应 offset 前跳应拒收")
        } catch let error as ProviderError {
            guard case .schemaMismatch(_, let detail) = error else {
                return XCTFail("期望 schemaMismatch：\(error)")
            }
            XCTAssertTrue(detail.contains("offset"), "拒收原因指向 offset 错配：\(detail)")
        }
    }

    func testPaginationResponseOffsetBackwardJumpRejected() async throws {
        // 第二页请求 offset=2、响应却回退到 offset=0 —— 拒收
        let page1 = """
        {"count":4,"offset":0,"limit":2,"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2023-10-01","value":"2.9","realtime_start":"2024-01-25"}
        ]}
        """
        let regressed = """
        {"count":4,"offset":0,"limit":2,"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2023-10-01","value":"2.9","realtime_start":"2024-01-25"}
        ]}
        """
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([
                Self.gdpEndpoint: page1,
                .fredObservations(
                    seriesID: "GDP", realtimeStart: "1776-07-04", realtimeEnd: nil,
                    apiKey: "test-key", offset: 2
                ): regressed,
            ]),
            ingestedAt: { self.date(2024, 8, 1) }, apiKey: "test-key"
        )
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("响应 offset 后退应拒收")
        } catch let error as ProviderError {
            guard case .schemaMismatch = error else {
                return XCTFail("期望 schemaMismatch：\(error)")
            }
        }
    }

    func testPaginationInconsistentCountRejected() async throws {
        // offset + received > count（响应自相矛盾）—— 拒收
        let inconsistent = """
        {"count":2,"offset":0,"limit":2,"observations":[
          {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25"},
          {"date":"2023-10-01","value":"2.9","realtime_start":"2024-01-25"},
          {"date":"2023-07-01","value":"2.2","realtime_start":"2023-10-26"}
        ]}
        """
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: inconsistent]),
            ingestedAt: { self.date(2024, 8, 1) }, apiKey: "test-key"
        )
        do {
            _ = try await adapter.fetch(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTFail("count 不一致应拒收")
        } catch let error as ProviderError {
            guard case .schemaMismatch(_, let detail) = error else {
                return XCTFail("期望 schemaMismatch：\(error)")
            }
            XCTAssertTrue(detail.contains("count"), "拒收原因指向 count：\(detail)")
        }
    }

    /// 注入传输失败的 URLProtocol（测试用）。
    private final class LeakingTransportURLProtocol: URLProtocol {
        nonisolated(unsafe) static var failure: Error?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: Self.failure ?? URLError(.badServerResponse))
        }

        override func stopLoading() {}
    }

    /// 计数 fetcher（验证分页循环的请求次数）。
    private final class CountingFetcher: ResponseFetcher, @unchecked Sendable {
        private let base: any ResponseFetcher
        private let lock = NSLock()
        private(set) var fetchCount = 0
        init(base: any ResponseFetcher) { self.base = base }
        func fetch(_ endpoint: ProviderEndpoint) async throws -> String {
            lock.lock(); fetchCount += 1; lock.unlock()
            return try await base.fetch(endpoint)
        }
    }

    // MARK: - ProviderRecord → ObservationFactory → MacroObservation（PIT）

    func testProviderRecordToMacroObservation_macroReleaseAvailability() async throws {
        // 验证 MacroRelease policy：availableAt 基于 publishedAt（realtime_start）
        let ingested = date(2024, 8, 1)
        let adapter = FREDProviderAdapter(
            config: gdpConfig,
            fetcher: StaticResponseFetcher([Self.gdpEndpoint: sampleJSON]),
            ingestedAt: { ingested },
            apiKey: "test-key"
        )
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .fred, identifierScheme: "fred_series", identifierValue: "GDP",
                canonical: .instrument(InstrumentID(rawValue: "inst_gdp")),
                resolutionMethod: .providerAuthoritative, resolvedAt: date(2024, 1, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        // 取第一条：Q1 GDP，effectiveAt=2024-01-01，publishedAt=realtime_start=2024-04-25（周四）
        let result = try factory.makeObservation(
            from: records[0],
            observationID: ObservationID(rawValue: "macro_1"),
            vintage: Vintage(announcementDate: records[0].publishedAt, publisherVersion: 1)
        )
        guard case .macroObservation(let macro) = result else {
            XCTFail("expected .macroObservation"); return
        }
        XCTAssertEqual(macro.indicatorID, InstrumentID(rawValue: "inst_gdp"))
        XCTAssertEqual(macro.value, Decimal(string: "2.5"))
        // MacroRelease：base=publishedAt=2024-04-25（周四）→ availableAt=2024-04-26（周五）
        XCTAssertEqual(macro.temporalEnvelope.availableAt, date(2024, 4, 26),
                       "availableAt 应基于发布日 realtime_start +1 交易日")
        XCTAssertEqual(macro.availabilityProvenance.policyID, "macro_release")
        // economicKnowledge(asOf: 4-25) 看不到（次日才可知）；asOf: 4-26 看到
        XCTAssertFalse(DataQueryMode.economicKnowledge(asOf: date(2024, 4, 25))
            .includes(envelope: macro.temporalEnvelope))
        XCTAssertTrue(DataQueryMode.economicKnowledge(asOf: date(2024, 4, 26))
            .includes(envelope: macro.temporalEnvelope))
    }
}
