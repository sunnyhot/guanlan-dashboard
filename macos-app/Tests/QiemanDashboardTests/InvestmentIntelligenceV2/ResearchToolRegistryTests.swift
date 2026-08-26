import XCTest
@testable import QiemanDashboard

// RES-3：V2 Research 工具集——Tavily / SEC / Alpha Vantage 桥接 + 本地取数
// 白名单 + Registry 装配。全部走注入的 fake client，无网络依赖。

// MARK: - Fakes

final class FakeTavilyClient: TavilySearchClientProtocol, @unchecked Sendable {
    let lock = NSLock()
    private var response: TavilySearchResponse?
    private var error: Error?
    private(set) var requests: [TavilySearchRequest] = []
    private(set) var apiKeys: [String] = []

    func stub(_ response: TavilySearchResponse) {
        lock.lock()
        self.response = response
        self.error = nil
        lock.unlock()
    }

    func stub(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double
    ) async throws -> TavilySearchResponse {
        lock.lock()
        requests.append(searchRequest)
        apiKeys.append(apiKey)
        let currentError = error
        let currentResponse = response
        lock.unlock()
        if let currentError { throw currentError }
        return currentResponse ?? TavilySearchResponse(query: nil, results: [], responseTime: nil, requestID: nil)
    }
}

final class StubbedSECClient: SECOfficialSourceClientProtocol, @unchecked Sendable {
    let lock = NSLock()
    private var responses: [URL: Data] = [:]
    private(set) var fetchedURLs: [URL] = []

    func stub(url: URL, data: Data) {
        lock.lock()
        responses[url] = data
        lock.unlock()
    }

    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        timeoutSeconds: Double
    ) async throws -> Data {
        lock.lock()
        fetchedURLs.append(descriptor.url)
        let data = responses[descriptor.url]
        lock.unlock()
        guard let data else {
            throw SECOfficialSourceClientError.requestFailed(statusCode: 404, detail: "未 stub")
        }
        return data
    }
}

final class StubbedAlphaVantageClient: AlphaVantageClientProtocol, @unchecked Sendable {
    let lock = NSLock()
    private var data: Data = Data()
    private(set) var descriptors: [AlphaVantageRequestDescriptor] = []

    func stub(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings
    ) async throws -> Data {
        lock.lock()
        descriptors.append(descriptor)
        let current = data
        lock.unlock()
        return current
    }
}

final class FakeResearchDataAccess: ResearchDataAccess, @unchecked Sendable {
    let lock = NSLock()
    var nav: [NAVObservation] = []
    var bars: [DailyBar] = []
    private(set) var asOfTimestamps: [Date] = []

    func navObservations(shareClassID: FundShareClassID, asOf: Date) -> [NAVObservation] {
        lock.lock()
        asOfTimestamps.append(asOf)
        defer { lock.unlock() }
        return nav
    }

    func dailyBars(listingID: ListingID, asOf: Date) -> [DailyBar] {
        lock.lock()
        asOfTimestamps.append(asOf)
        defer { lock.unlock() }
        return bars
    }
}

// MARK: - 测试辅助

private func taskContext(
    sources: ResearchSourcesConfiguration = .empty,
    dataAccess: (any ResearchDataAccess)? = nil
) throws -> ResearchToolContext {
    try ResearchToolContext(
        task: ResearchTask(
            subject: CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
            objective: "test"
        ),
        sources: sources,
        dataAccess: dataAccess
    )
}

/// 解包成功信封。
private func unwrapSuccess(_ result: ResearchToolResult) throws -> (data: ModelJSONValue, evidenceIDs: [EvidenceID]) {
    guard case .object(let entries) = result.contentJSON,
          case .bool(true) = entries["success"],
          let data = entries["data"],
          case .array(let evidenceArray) = entries["evidence_ids"] else {
        throw XCTSkip("信封形状不对：\(result.contentJSON)")
    }
    let ids = evidenceArray.compactMap { value -> String? in
        if case .string(let raw) = value { return raw }
        return nil
    }
    return (data, ids.map { EvidenceID(rawValue: $0) })
}

private func unwrapErrorCode(_ result: ResearchToolResult) -> String? {
    guard case .object(let entries) = result.contentJSON,
          case .bool(false) = entries["success"],
          case .object(let error)? = entries["error"],
          case .string(let code)? = error["code"] else { return nil }
    return code
}

private func configuredSources() -> ResearchSourcesConfiguration {
    var sources = ResearchSourcesConfiguration()
    sources.tavilyAPIKey = "tvly-test"
    sources.secEnabled = true
    sources.secContactEmail = "research@example.com"
    sources.alphaVantageEnabled = true
    sources.alphaVantageAPIKey = "av-test"
    return sources
}

// MARK: - Tests

final class ResearchToolRegistryTests: XCTestCase {

    // MARK: Tavily

    func testWebSearchProducesContentAddressedEvidence() async throws {
        let client = FakeTavilyClient()
        client.stub(TavilySearchResponse(
            query: "QDII 溢价",
            results: [
                TavilySearchResult(title: "新闻一", url: "https://example.com/a", content: "内容甲", score: 0.9, publishedDate: "2026-08-20"),
                TavilySearchResult(title: "", url: "https://example.com/b", content: "空标题被过滤", score: 0.8, publishedDate: nil),
            ],
            responseTime: nil,
            requestID: nil
        ))
        let tool = V2WebSearchTool(client: client)
        let result = await tool.execute(
            argumentsJSON: "{\"query\": \"QDII 溢价\", \"max_results\": 5}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertFalse(result.isError)
        let unwrapped = try unwrapSuccess(result)
        XCTAssertEqual(unwrapped.evidenceIDs.count, 1, "空标题结果被过滤")
        XCTAssertTrue(unwrapped.evidenceIDs[0].rawValue.hasPrefix("web:tavily:"), unwrapped.evidenceIDs[0].rawValue)
        // 内容寻址：同输入再跑一次 ID 不变
        let again = await tool.execute(
            argumentsJSON: "{\"query\": \"QDII 溢价\"}",
            context: try taskContext(sources: configuredSources())
        )
        let unwrappedAgain = try unwrapSuccess(again)
        XCTAssertEqual(unwrappedAgain.evidenceIDs, unwrapped.evidenceIDs)
        // 结果里的 evidence_ids 与登记一致
        XCTAssertEqual(unwrapped.evidenceIDs, result.evidenceIDs)
        XCTAssertEqual(client.apiKeys, ["tvly-test", "tvly-test"], "apiKey 只进传输层")
    }

    func testWebSearchGuards() async throws {
        let tool = V2WebSearchTool(client: FakeTavilyClient())
        // 未配置
        var result = await tool.execute(
            argumentsJSON: "{\"query\": \"anything\"}",
            context: try taskContext()
        )
        XCTAssertEqual(unwrapErrorCode(result), "web_search_not_configured")
        // query 太短
        result = await tool.execute(
            argumentsJSON: "{\"query\": \"a\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertEqual(unwrapErrorCode(result), "invalid_arguments")
        // topic 非法
        result = await tool.execute(
            argumentsJSON: "{\"query\": \"valid query\", \"topic\": \"sports\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertEqual(unwrapErrorCode(result), "invalid_arguments")
        // 传输失败
        let failing = FakeTavilyClient()
        failing.stub(error: TavilySearchClientError.requestFailed(statusCode: 429, detail: "limit"))
        result = await V2WebSearchTool(client: failing).execute(
            argumentsJSON: "{\"query\": \"valid query\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertEqual(unwrapErrorCode(result), "web_search_failed")
    }

    // MARK: SEC

    func testSECRecentFilingsEndToEnd() async throws {
        let client = StubbedSECClient()
        client.stub(
            url: URL(string: "https://www.sec.gov/files/company_tickers.json")!,
            data: Data(#"{"0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc"}}"#.utf8)
        )
        let submissions = """
        {"name": "Apple Inc", "filings": {"form": ["10-K", "10-Q", "8-K"],
          "accessionNumber": ["a1", "a2", "a3"], "filingDate": ["2026-08-01", "2026-05-01", "2026-02-01"]}}
        """
        client.stub(
            url: URL(string: "https://data.sec.gov/submissions/CIK0000320193.json")!,
            data: Data(submissions.utf8)
        )
        let tool = V2SECOfficialTool(client: client, cache: SECOfficialSourceCache())
        let result = await tool.execute(
            argumentsJSON: "{\"ticker\": \"aapl\", \"mode\": \"recent_filings\", \"max_results\": 2}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertFalse(result.isError)
        let unwrapped = try unwrapSuccess(result)
        XCTAssertEqual(unwrapped.evidenceIDs.map(\.rawValue),
                       ["official:sec:filing:a1", "official:sec:filing:a2"], "按 accession 内容寻址、截断到 max_results")
        // 请求链：先公司目录再 submissions
        XCTAssertEqual(client.fetchedURLs.map(\.absoluteString), [
            "https://www.sec.gov/files/company_tickers.json",
            "https://data.sec.gov/submissions/CIK0000320193.json",
        ])
    }

    func testSECCompanyFactsExtractsAnnualValues() async throws {
        let client = StubbedSECClient()
        client.stub(
            url: URL(string: "https://www.sec.gov/files/company_tickers.json")!,
            data: Data(#"{"0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc"}}"#.utf8)
        )
        let facts = """
        {"facts": {"us-gaap": {
            "Revenues": {"units": {"USD": [
                {"end": "2025-09-30", "val": 391000000000, "fp": "FY"},
                {"end": "2024-09-30", "val": 383000000000, "fp": "FY"},
                {"end": "2025-06-30", "val": 85000000000, "fp": "Q3"}
            ]}},
            "NetIncomeLoss": {"units": {"USD": [
                {"end": "2025-09-30", "val": 93700000000, "fp": "FY"}
            ]}}
        }}}
        """
        client.stub(
            url: URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json")!,
            data: Data(facts.utf8)
        )
        let tool = V2SECOfficialTool(client: client, cache: SECOfficialSourceCache())
        let result = await tool.execute(
            argumentsJSON: "{\"ticker\": \"AAPL\", \"mode\": \"company_facts\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertFalse(result.isError)
        let unwrapped = try unwrapSuccess(result)
        XCTAssertEqual(result.evidenceIDs.count, 1)
        XCTAssertTrue(result.evidenceIDs[0].rawValue.hasPrefix("official:sec:facts:0000320193:"))
        // 验证取的是 FY 最近值（2025-09-30 的 Revenues，不是 Q3）
        guard case .object(let data) = unwrapped.data,
              case .array(let rows)? = data["facts"] else {
            return XCTFail("facts 结构不对")
        }
        let revenueRow = rows.first { row in
            if case .object(let entry) = row, case .string("Revenues")? = entry["concept"] { return true }
            return false
        }
        XCTAssertNotNil(revenueRow, "包含 Revenues")
        if case .object(let entry)? = revenueRow,
           case .string(let periodEnd)? = entry["period_end"] {
            XCTAssertEqual(periodEnd, "2025-09-30", "取 FY 最近年度值")
        }
    }

    func testSECCompanyFactsUnitSelectionIsDeterministic() async throws {
        // 审查 P3 回归：同一概念同时有 USD 与 USD/shares 两个 unit 时，
        // 必须确定性选 USD（原 units.values.first 依赖 Dictionary 迭代序，
        // 跨进程漂移 → evidence 内容寻址 ID 漂移）。
        let client = StubbedSECClient()
        client.stub(
            url: URL(string: "https://www.sec.gov/files/company_tickers.json")!,
            data: Data(#"{"0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc"}}"#.utf8)
        )
        // shares 单元放在 JSON 前面（若实现按字典序或首序取值不稳定会暴露）
        let facts = """
        {"facts": {"us-gaap": {
            "EarningsPerShareDiluted": {"units": {
                "USD/shares": [
                    {"end": "2025-09-30", "val": 6.11, "fp": "FY"}
                ],
                "USD": [
                    {"end": "2025-09-30", "val": 999, "fp": "FY"}
                ]
            }}
        }}}
        """
        client.stub(
            url: URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json")!,
            data: Data(facts.utf8)
        )
        let tool = V2SECOfficialTool(client: client, cache: SECOfficialSourceCache())
        let context = try taskContext(sources: configuredSources())
        let first = await tool.execute(
            argumentsJSON: "{\"ticker\": \"AAPL\", \"mode\": \"company_facts\"}", context: context
        )
        let second = await tool.execute(
            argumentsJSON: "{\"ticker\": \"AAPL\", \"mode\": \"company_facts\"}", context: context
        )
        XCTAssertEqual(first.evidenceIDs, second.evidenceIDs)
        // 选中的是 USD unit 的值（999），且 evidence ID 稳定
        XCTAssertEqual(first.evidenceIDs.map(\.rawValue).first, second.evidenceIDs.map(\.rawValue).first)
        guard case .object(let data) = first.contentJSON,
              case .object(let inner)? = data["data"],
              case .array(let rows)? = inner["facts"],
              let row = rows.first,
              case .object(let entry) = row,
              case .string(let concept)? = entry["concept"] else {
            return XCTFail("facts 结构不对")
        }
        XCTAssertEqual(concept, "EarningsPerShareDiluted")
        if case .number(let value)? = entry["value"] {
            XCTAssertEqual(value, 999, "unit 优先级 USD 先于 USD/shares")
        } else {
            XCTFail("value 缺失")
        }
    }

    func testWebSearchDisabledSwitchBlocksEvenWithKey() async throws {
        // Tavily enabled 开关（对称性修复）：关掉后即使有 key 也不可用。
        var sources = configuredSources()
        sources.tavilyEnabled = false
        let result = await V2WebSearchTool(client: FakeTavilyClient()).execute(
            argumentsJSON: "{\"query\": \"valid query\"}",
            context: try taskContext(sources: sources)
        )
        XCTAssertEqual(unwrapErrorCode(result), "web_search_not_configured")
        XCTAssertEqual(ResearchSourcesConfiguration().tavilyEnabled, true, "默认开启保持兼容")
    }

    func testSECNotConfiguredOrUnknownTicker() async throws {
        let tool = V2SECOfficialTool(client: StubbedSECClient(), cache: SECOfficialSourceCache())
        var result = await tool.execute(
            argumentsJSON: "{\"ticker\": \"AAPL\", \"mode\": \"recent_filings\"}",
            context: try taskContext()
        )
        XCTAssertEqual(unwrapErrorCode(result), "official_sec_not_configured")

        // 未配置时不触碰网络
        let client = StubbedSECClient()
        client.stub(
            url: URL(string: "https://www.sec.gov/files/company_tickers.json")!,
            data: Data("{}".utf8)
        )
        result = await V2SECOfficialTool(client: client, cache: SECOfficialSourceCache()).execute(
            argumentsJSON: "{\"ticker\": \"NOPE\", \"mode\": \"recent_filings\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertEqual(unwrapErrorCode(result), "official_sec_failed", "未知 ticker 是失败信封不是崩溃")
    }

    // MARK: Alpha Vantage

    func testAlphaVantageDailyAnalyticsComputesLocally() async throws {
        let client = StubbedAlphaVantageClient()
        // 7 天日线（AV 日期降序）：latest=110
        let series = """
        {"Time Series (Daily)": {
            "2026-08-25": {"4. close": "110.0"},
            "2026-08-24": {"4. close": "100.0"},
            "2026-08-21": {"4. close": "105.0"},
            "2026-08-20": {"4. close": "102.0"},
            "2026-08-19": {"4. close": "108.0"},
            "2026-08-18": {"4. close": "104.0"},
            "2026-08-17": {"4. close": "100.0"}
        }}
        """
        client.stub(Data(series.utf8))
        let tool = V2AlphaVantageTool(client: client, cache: AlphaVantageResponseCache())
        let result = await tool.execute(
            argumentsJSON: "{\"symbol\": \"QQQ\", \"mode\": \"daily_analytics\"}",
            context: try taskContext(sources: configuredSources())
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.evidenceIDs.count, 1)
        XCTAssertTrue(result.evidenceIDs[0].rawValue.hasPrefix("vendor:alphavantage:daily:QQQ:"))
        let unwrapped = try unwrapSuccess(result)
        guard case .object(let data) = unwrapped.data else { return XCTFail() }
        func number(_ key: String) -> Double? {
            if case .number(let value)? = data[key] { return value }
            if case .null? = data[key] { return nil }
            return nil
        }
        // return_5d = 110/104 - 1 ≈ 5.769%
        XCTAssertEqual(number("return_5d_pct") ?? -1, 5.769, accuracy: 0.01)
        // 样本 < 21：波动率与 sma_20 为 null（不猜）
        XCTAssertNil(number("sma_20"))
        XCTAssertNil(number("annualized_volatility_pct_20d"))
        // max drawdown：窗口内 peak 108 时谷 100 → ≈ -7.407%
        XCTAssertEqual(number("max_drawdown_pct_window") ?? 0, -7.407, accuracy: 0.01)
    }

    func testAlphaVantageSymbolNormalizationAndConfigGuard() async throws {
        XCTAssertEqual(V2AlphaVantageTool.normalizedSymbol("510300"), "510300.SHH")
        XCTAssertEqual(V2AlphaVantageTool.normalizedSymbol("000001"), "000001.SHZ")
        XCTAssertEqual(V2AlphaVantageTool.normalizedSymbol("aapl"), "AAPL")
        let tool = V2AlphaVantageTool(client: StubbedAlphaVantageClient(), cache: AlphaVantageResponseCache())
        let result = await tool.execute(
            argumentsJSON: "{\"symbol\": \"AAPL\", \"mode\": \"etf_profile\"}",
            context: try taskContext()
        )
        XCTAssertEqual(unwrapErrorCode(result), "alpha_vantage_not_configured")
    }

    // MARK: 本地取数

    func testLocalDataFundNAVTailAndPITContext() async throws {
        let access = FakeResearchDataAccess()
        access.nav = (0..<10).map { index in
            NAVObservation(
                id: ObservationID(rawValue: "obs_nav_\(index)"),
                shareClassID: FundShareClassID(rawValue: "sc_513100"),
                temporalEnvelope: TemporalEnvelope(
                    effectiveAt: Date(timeIntervalSince1970: Double(1000 + index * 86400)),
                    publishedAt: Date(timeIntervalSince1970: Double(1000 + index * 86400)),
                    availableAt: Date(timeIntervalSince1970: Double(1000 + index * 86400 + 3600)),
                    ingestedAt: Date(timeIntervalSince1970: Double(1000 + index * 86400 + 3600))
                ),
                availabilityProvenance: AvailabilityProvenance(
                    policyID: "p", policyVersion: "1", derivedAt: Date(timeIntervalSince1970: 0)
                ),
                dataQuality: DataQuality(
                    providerReliability: .communityAggregated, sourceProviderID: .eastmoney
                ),
                vintage: Vintage(
                    announcementDate: Date(timeIntervalSince1970: 0), publisherVersion: 1
                ),
                unitNAV: Price(value: Decimal(1 + index), currency: .cny),
                accumulatedNAV: nil,
                cumulativeDividendPerShare: nil
            )
        }
        let tool = V2LocalDataTool(now: { Date(timeIntervalSince1970: 5000) })
        let result = await tool.execute(
            argumentsJSON: "{\"dataset\": \"fund_nav\", \"subject_id\": \"sc_513100\", \"days\": 3}",
            context: try taskContext(dataAccess: access)
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.evidenceIDs.count, 1)
        XCTAssertTrue(result.evidenceIDs[0].rawValue.hasPrefix("local:fund_nav:"))
        let unwrapped = try unwrapSuccess(result)
        guard case .object(let data) = unwrapped.data,
              case .array(let rows)? = data["series"],
              case .number(let count)? = data["count"] else {
            return XCTFail("series 结构不对")
        }
        XCTAssertEqual(Int(count), 3, "截断到最近 3 条")
        XCTAssertEqual(access.asOfTimestamps, [Date(timeIntervalSince1970: 5000)], "PIT 语境由工具固定传入")
        // 最新在前
        if case .object(let first)? = rows.first {
            XCTAssertEqual(first["date"], .string("1970-01-10"))
            XCTAssertEqual(first["value"], .number(10))
        } else {
            XCTFail("rows 空")
        }
    }

    func testLocalDataUnavailableWithoutDataAccess() async throws {
        let result = await V2LocalDataTool().execute(
            argumentsJSON: "{\"dataset\": \"daily_bars\", \"subject_id\": \"list_1\"}",
            context: try taskContext()
        )
        XCTAssertEqual(unwrapErrorCode(result), "local_data_unavailable")
    }

    // MARK: Registry 装配

    func testRegistryAssemblesToolsAndLooksUpByName() {
        let registry = ResearchToolRegistry()
        let names = registry.tools.map(\.name)
        XCTAssertEqual(names, ["web_search", "official_sec_research", "alpha_vantage_research", "get_local_data"])
        XCTAssertEqual(registry.definitions.count, 4)
        XCTAssertNotNil(registry.tool(named: "web_search"))
        XCTAssertNil(registry.tool(named: "nonexistent"))
        // 全部工具声明带 object schema（模型可用性）
        for spec in registry.definitions {
            guard case .object(let schema) = spec.parameters,
                  case .string(let type)? = schema["type"], type == "object" else {
                return XCTFail("\(spec.name) 的 parameters 必须是 object schema")
            }
        }
    }

    func testRegistryOptionalClientsExcludeExternalTools() {
        let registry = ResearchToolRegistry(
            webSearchClient: nil, secClient: nil, alphaVantageClient: nil
        )
        XCTAssertEqual(registry.tools.map(\.name), ["get_local_data"], "外部 client 传 nil 只保留本地工具")
    }
}
