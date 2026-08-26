import Foundation

// MARK: - V2 开放研究工具：Tavily / SEC EDGAR / Alpha Vantage（RES-3）
//
// 与 Slice 0-7 的同名工具（TavilyWebSearchTool / SECOfficialResearchTool /
// AlphaVantageResearchTool）刻意不共用实现（rollout RES-3：新建 V2 版）：
// - 协议层是 ResearchTool（evidence 进运行登记簿，供提交校验与 RES-8 匹配）
// - 配置来自 ResearchSourcesConfiguration（V2 值类型），桥接 Core settings
// - 复用 Core/Clients 传输与缓存（SECOfficialSourceCache /
//   AlphaVantageResponseCache 单例），不重复造轮子
// - evidence ID 内容寻址（同输入同 ID；落 EvidenceObservation 时沿用）

/// 工具信封统一形状（成功 / 失败）。
enum ResearchToolEnvelope {
    static func success(_ data: ModelJSONValue, evidenceIDs: [EvidenceID]) -> ModelJSONValue {
        [
            "success": true,
            "data": data,
            "evidence_ids": .array(evidenceIDs.map { .string($0.rawValue) })
        ]
    }

    static func error(code: String, message: String) -> ModelJSONValue {
        [
            "success": false,
            "error": ["code": .string(code), "message": .string(message)]
        ]
    }
}


/// 工具侧来源时间解析（"yyyy-MM-dd" 与 ISO8601；UTC，解析失败返回 nil
/// ——不猜时间，落库回退执行时刻）。
enum ResearchSourceDateParser {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = dayFormatter.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

// MARK: - Tavily 网络搜索

struct V2WebSearchTool: ResearchTool {
    let name = "web_search"
    let description = "联网搜索公开信息（新闻 / 资料）。每条结果登记为一条 evidence。"
    let parameters: ModelJSONValue = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "搜索词（2-400 字符）。"],
            "topic": ["type": "string", "enum": ["general", "news", "finance"], "description": "可选，默认 news。"],
            "time_range": ["type": "string", "enum": ["day", "week", "month", "year"], "description": "可选，默认 month。"],
            "max_results": ["type": "integer", "description": "可选 1-8，默认 5。"]
        ],
        "required": ["query"]
    ]

    private let client: any TavilySearchClientProtocol

    init(client: any TavilySearchClientProtocol = TavilySearchClient()) {
        self.client = client
    }

    private struct Params: Decodable {
        let query: String
        let topic: String?
        let time_range: String?
        let max_results: Int?
    }

    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult {
        guard context.sources.isWebSearchConfigured else {
            return .errorEnvelope(code: "web_search_not_configured", message: "未配置 Tavily API Key，联网搜索不可用。")
        }
        guard let params = Self.decodeParams(Params.self, argumentsJSON) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...400).contains(query.count) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let topic = params.topic ?? "news"
        guard ["general", "news", "finance"].contains(topic) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let timeRange = params.time_range ?? "month"
        guard ["day", "week", "month", "year"].contains(timeRange) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let maxResults = params.max_results ?? 5
        guard (1...8).contains(maxResults) else {
            return .content(Self.invalidArguments, isError: true)
        }

        let request = TavilySearchRequest(
            query: query,
            topic: topic,
            searchDepth: "basic",
            maxResults: maxResults,
            timeRange: timeRange,
            includeDomains: nil,
            includeAnswer: false,
            includeRawContent: false,
            includeImages: false
        )
        do {
            let response = try await client.search(
                request,
                apiKey: context.sources.tavilyAPIKey,
                timeoutSeconds: 30
            )
            var evidenceIDs: [EvidenceID] = []
            var seenEvidenceIDs: Set<String> = []
            var sourceDates: [String: Date] = [:]
            var rows: [ModelJSONValue] = []
            for result in response.results {
                guard !result.title.isEmpty, !result.content.isEmpty else { continue }
                let id = "web:tavily:\(StableDigest.digest("\(result.url)|\(result.title)").prefix(20))"
                // 同 url+title 的重复结果只登记一次（审查 P3-6）
                guard seenEvidenceIDs.insert(id).inserted else { continue }
                evidenceIDs.append(EvidenceID(rawValue: id))
                if let published = result.publishedDate,
                   let date = ResearchSourceDateParser.parse(published) {
                    sourceDates[id] = date
                }
                rows.append([
                    "title": .string(result.title),
                    "url": .string(result.url),
                    "content": .string(String(result.content.prefix(600))),
                    "published_date": result.publishedDate.map { ModelJSONValue.string($0) } ?? .null
                ])
            }
            let data: ModelJSONValue = [
                "query": .string(query),
                "results": .array(rows),
                "count": .number(Double(rows.count))
            ]
            if rows.isEmpty {
                return .content(ResearchToolEnvelope.success(data, evidenceIDs: []),
                                isError: false)
            }
            return .content(
                ResearchToolEnvelope.success(data, evidenceIDs: evidenceIDs),
                evidenceIDs: evidenceIDs,
                sourceDates: sourceDates
            )
        } catch let error as TavilySearchClientError {
            return .errorEnvelope(code: "web_search_failed", message: error.userFacingToolMessage)
        } catch is CancellationError {
            return .errorEnvelope(code: "web_search_cancelled", message: "搜索已取消。")
        } catch {
            return .errorEnvelope(code: "web_search_failed", message: error.localizedDescription)
        }
    }
}

// MARK: - SEC EDGAR 官方源

struct V2SECOfficialTool: ResearchTool {
    let name = "official_sec_research"
    let description = "查询 SEC EDGAR 官方数据：近期申报列表或公司财务事实（XBRL）。"
    let parameters: ModelJSONValue = [
        "type": "object",
        "properties": [
            "ticker": ["type": "string", "description": "美股 ticker（如 AAPL）。"],
            "mode": ["type": "string", "enum": ["recent_filings", "company_facts"],
                     "description": "近期申报列表 / 公司 XBRL 财务事实。"],
            "max_results": ["type": "integer", "description": "可选 1-20，默认 10。"]
        ],
        "required": ["ticker", "mode"]
    ]

    private let client: any SECOfficialSourceClientProtocol
    private let cache: SECOfficialSourceCache

    init(
        client: any SECOfficialSourceClientProtocol = SECOfficialSourceClient(),
        cache: SECOfficialSourceCache = .shared
    ) {
        self.client = client
        self.cache = cache
    }

    private struct Params: Decodable {
        let ticker: String
        let mode: String
        let max_results: Int?
    }

    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult {
        guard context.sources.isSECConfigured else {
            return .errorEnvelope(code: "official_sec_not_configured", message: "未配置 SEC 联系邮箱，EDGAR 查询不可用。")
        }
        guard let params = Self.decodeParams(Params.self, argumentsJSON) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let ticker = params.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (1...8).contains(ticker.count), ticker.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return .content(Self.invalidArguments, isError: true)
        }
        guard ["recent_filings", "company_facts"].contains(params.mode) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let maxResults = params.max_results ?? 10
        guard (1...20).contains(maxResults) else {
            return .content(Self.invalidArguments, isError: true)
        }

        do {
            // ticker → CIK 映射（公司目录，TTL 24h）
            let cik = try await resolveCIK(ticker: ticker, sources: context.sources)
            switch params.mode {
            case "recent_filings":
                return try await recentFilingsResult(
                    ticker: ticker, cik: cik, maxResults: maxResults, sources: context.sources
                )
            default:
                return try await companyFactsResult(
                    ticker: ticker, cik: cik, maxResultCount: maxResults, sources: context.sources
                )
            }
        } catch is CancellationError {
            return .errorEnvelope(code: "official_sec_cancelled", message: "SEC EDGAR 查询已取消。")
        } catch {
            return .errorEnvelope(code: "official_sec_failed", message: error.localizedDescription)
        }
    }

    private func resolveCIK(ticker: String, sources: ResearchSourcesConfiguration) async throws -> String {
        let url = URL(string: "https://www.sec.gov/files/company_tickers.json")!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 24 * 3600),
            settings: sources.officialSourceSettings,
            client: client
        )
        guard let json = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            throw SECOfficialSourceClientError.invalidResponse("company_tickers 不是 JSON 对象")
        }
        for entry in json.values {
            guard let dict = entry as? [String: Any],
                  let entryTicker = dict["ticker"] as? String,
                  entryTicker.uppercased() == ticker,
                  let cikNumber = dict["cik_str"] as? Int else { continue }
            return String(format: "%010d", cikNumber)
        }
        throw SECOfficialSourceClientError.invalidResponse("ticker \(ticker) 未在 SEC 公司目录中找到")
    }

    private func recentFilingsResult(
        ticker: String, cik: String, maxResults: Int, sources: ResearchSourcesConfiguration
    ) async throws -> ResearchToolResult {
        let url = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json")!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 15 * 60),
            settings: sources.officialSourceSettings,
            client: client
        )
        guard let json = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let recent = json["filings"] as? [String: Any],
              let forms = recent["form"] as? [Any],
              let accessionNumbers = recent["accessionNumber"] as? [Any],
              let filingDates = recent["filingDate"] as? [Any] else {
            throw SECOfficialSourceClientError.invalidResponse("submissions 结构不符合预期")
        }
        var rows: [ModelJSONValue] = []
        var evidenceIDs: [EvidenceID] = []
        let name = (json["name"] as? String) ?? ticker
        // 上界取三数组与 maxResults 的最小值——上游字段长度不齐时安全跳过，
        // 不做无条件下标（越界是 crash，不是可恢复错误）。
        let rowCount = min(maxResults, forms.count, accessionNumbers.count, filingDates.count)
        var sourceDates: [String: Date] = [:]
        for index in 0..<rowCount {
            guard let form = forms[index] as? String,
                  let accession = accessionNumbers[index] as? String,
                  let date = filingDates[index] as? String else { continue }
            let evidenceID = EvidenceID(rawValue: "official:sec:filing:\(accession)")
            evidenceIDs.append(evidenceID)
            if let filedAt = ResearchSourceDateParser.parse(date) {
                sourceDates[evidenceID.rawValue] = filedAt
            }
            rows.append([
                "form": .string(form),
                "filed_at": .string(date),
                "accession_number": .string(accession),
                "interpretation_boundary": .string("官方申报事实；文件内容需另行研读，不含解读。")
            ])
        }
        let data: ModelJSONValue = [
            "company": .string(name),
            "ticker": .string(ticker),
            "cik": .string(cik),
            "filings": .array(rows),
            "cache_hit": .bool(outcome.cacheHit)
        ]
        return .content(
            ResearchToolEnvelope.success(data, evidenceIDs: evidenceIDs),
            evidenceIDs: evidenceIDs,
            sourceDates: sourceDates
        )
    }

    private func companyFactsResult(
        ticker: String, cik: String, maxResultCount: Int, sources: ResearchSourcesConfiguration
    ) async throws -> ResearchToolResult {
        let url = URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(cik).json")!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 6 * 3600),
            settings: sources.officialSourceSettings,
            client: client
        )
        guard let json = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let facts = json["facts"] as? [String: Any],
              let gaap = facts["us-gaap"] as? [String: Any] else {
            throw SECOfficialSourceClientError.invalidResponse("companyfacts 结构不符合预期")
        }
        // 精选常用财务事实（年度最近值），其余留给后续需要时扩展。
        let interestingKeys = ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax",
                               "NetIncomeLoss", "EarningsPerShareDiluted", "Assets", "StockholdersEquity"]
        var rows: [ModelJSONValue] = []
        for key in interestingKeys where gaap[key] != nil {
            guard let concept = gaap[key] as? [String: Any],
                  let units = concept["units"] as? [String: Any] else { continue }
            // unit 选择必须跨进程确定（审查 P3：units.values.first 依赖
            // Dictionary 迭代序，EPS 等概念同时有 USD 与 USD/shares 时不同
            // 进程可能选中不同 unit → evidence 内容漂移 → 内容寻址 ID 漂移）。
            // 优先级：USD 最常用，其余按 unit 名排序取最小。
            let unitName = units.keys.first(where: { $0 == "USD" })
                ?? units.keys.sorted().first
            guard let unitName,
                  let unitValues = units[unitName] as? [[String: Any]] else { continue }
            // 取年度（fy 数据）最近一条
            let annual = unitValues
                .filter { ($0["fp"] as? String) == "FY" }
                .compactMap { entry -> (String, Any)? in
                    guard let end = entry["end"] as? String else { return nil }
                    return (end, entry["val"] ?? 0)
                }
                .sorted { $0.0 > $1.0 }
                .prefix(1)
            guard let latest = annual.first else { continue }
            let value = latest.1
            let numeric: ModelJSONValue
            if let double = value as? Double { numeric = .number(double) }
            else if let int = value as? Int { numeric = .number(Double(int)) }
            else { numeric = .string(String(describing: value)) }
            rows.append([
                "concept": .string(key),
                "period_end": .string(latest.0),
                "value": numeric,
                "basis": .string("XBRL us-gaap 年度（FY）最近披露值")
            ])
            if rows.count >= maxResultCount { break }
        }
        let digest = StableDigest.digest("\(cik)|\(rows.count)")
        let evidenceID = EvidenceID(rawValue: "official:sec:facts:\(cik):\(digest.prefix(12))")
        let data: ModelJSONValue = [
            "ticker": .string(ticker),
            "cik": .string(cik),
            "facts": .array(rows),
            "cache_hit": .bool(outcome.cacheHit),
            "interpretation_boundary": .string("XBRL 机器可读事实（extractionMethod = xbrlFact 口径）；跨期比较需自行对齐会计期间。")
        ]
        return .content(
            ResearchToolEnvelope.success(data, evidenceIDs: [evidenceID]),
            evidenceIDs: [evidenceID]
        )
    }
}

// MARK: - Alpha Vantage 供应商数据

struct V2AlphaVantageTool: ResearchTool {
    let name = "alpha_vantage_research"
    let description = "查询 Alpha Vantage 供应商数据：ETF 档案或日线分析（本地计算指标）。"
    let parameters: ModelJSONValue = [
        "type": "object",
        "properties": [
            "symbol": ["type": "string", "description": "标的 symbol（美股 / A 股 6 位代码自动映射 .SHH/.SHZ）。"],
            "mode": ["type": "string", "enum": ["etf_profile", "daily_analytics"],
                     "description": "ETF 档案 / 日线技术分析。"]
        ],
        "required": ["symbol", "mode"]
    ]

    private let client: any AlphaVantageClientProtocol
    private let cache: AlphaVantageResponseCache

    init(
        client: any AlphaVantageClientProtocol = AlphaVantageClient(),
        cache: AlphaVantageResponseCache = .shared
    ) {
        self.client = client
        self.cache = cache
    }

    private struct Params: Decodable {
        let symbol: String
        let mode: String
    }

    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult {
        guard context.sources.isAlphaVantageConfigured else {
            return .errorEnvelope(code: "alpha_vantage_not_configured", message: "未启用或未配置 Alpha Vantage API Key。")
        }
        guard let params = Self.decodeParams(Params.self, argumentsJSON),
              ["etf_profile", "daily_analytics"].contains(params.mode) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let symbol = Self.normalizedSymbol(params.symbol)
        guard !symbol.isEmpty else {
            return .content(Self.invalidArguments, isError: true)
        }

        do {
            switch params.mode {
            case "etf_profile":
                return try await etfProfileResult(symbol: symbol, sources: context.sources)
            default:
                return try await dailyAnalyticsResult(symbol: symbol, sources: context.sources)
            }
        } catch is CancellationError {
            return .errorEnvelope(code: "alpha_vantage_cancelled", message: "查询已取消。")
        } catch {
            return .errorEnvelope(code: "alpha_vantage_request_failed", message: error.localizedDescription)
        }
    }

    private func etfProfileResult(symbol: String, sources: ResearchSourcesConfiguration) async throws -> ResearchToolResult {
        let descriptor = AlphaVantageRequestDescriptor(
            function: .etfProfile, symbol: symbol, parameters: [:], cacheTTL: 24 * 3600
        )
        let outcome = try await cache.fetch(descriptor, settings: sources.alphaVantageSettings, client: client)
        guard let json = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            throw AlphaVantageClientError.invalidResponse("ETF_PROFILE 不是 JSON 对象")
        }
        let stringField: (String) -> String? = { key in (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let data: ModelJSONValue = [
            "symbol": .string(symbol),
            "name": stringField("name").map { ModelJSONValue.string($0) } ?? .null,
            "asset_benchmark": stringField("asset_benchmark").map { ModelJSONValue.string($0) } ?? .null,
            "asset_class": stringField("asset_class").map { ModelJSONValue.string($0) } ?? .null,
            "sector": stringField("sector").map { ModelJSONValue.string($0) } ?? .null,
            "annual_holdings_turnover": (json["annual_holdings_turnover"] as? String).map { ModelJSONValue.string($0) } ?? .null,
            "cache_hit": .bool(outcome.cacheHit),
            "evidence_boundary": .string("第三方供应商（authoritative vendor）数据；与官方申报口径可能有差异。")
        ]
        let evidenceID = EvidenceID(rawValue: "vendor:alphavantage:etf:\(symbol):\(StableDigest.digest(symbol).prefix(10))")
        return .content(
            ResearchToolEnvelope.success(data, evidenceIDs: [evidenceID]),
            evidenceIDs: [evidenceID]
        )
    }

    private func dailyAnalyticsResult(symbol: String, sources: ResearchSourcesConfiguration) async throws -> ResearchToolResult {
        let descriptor = AlphaVantageRequestDescriptor(
            function: .timeSeriesDaily, symbol: symbol,
            parameters: ["outputsize": "compact", "datatype": "json"],
            cacheTTL: 6 * 3600
        )
        let outcome = try await cache.fetch(descriptor, settings: sources.alphaVantageSettings, client: client)
        guard let json = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let series = json["Time Series (Daily)"] as? [String: [String: String]] else {
            throw AlphaVantageClientError.invalidResponse("TIME_SERIES_DAILY 结构不符合预期")
        }
        // 日期降序的 (date, close)
        let closes: [(date: String, close: Double)] = series.compactMap { date, values in
            guard let close = values["4. close"], let value = Double(close) else { return nil }
            return (date, value)
        }
        .sorted { $0.date > $1.date }
        guard closes.count >= 2 else {
            throw AlphaVantageClientError.invalidResponse("日线数据不足（<2 条）")
        }
        let latest = closes[0].close
        func trailingReturn(_ days: Int) -> ModelJSONValue {
            guard closes.count > days else { return .null }
            let base = closes[days].close
            guard base != 0 else { return .null }
            return .number((latest / base - 1) * 100)
        }
        func sma(_ days: Int) -> ModelJSONValue {
            guard closes.count >= days else { return .null }
            let window = closes.prefix(days).map(\.close)
            return .number(window.reduce(0, +) / Double(window.count))
        }
        // 年化波动率（日收益标准差 × √252）
        let vol: ModelJSONValue
        if closes.count >= 21 {
            let logReturns = zip(closes.prefix(20), closes.dropFirst().prefix(20)).compactMap { newer, older -> Double? in
                guard older.close > 0 else { return nil }
                return log(newer.close / older.close)
            }
            let mean = logReturns.reduce(0, +) / Double(logReturns.count)
            let variance = logReturns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, logReturns.count - 1))
            vol = .number(sqrt(variance) * sqrt(252) * 100)
        } else {
            vol = .null
        }
        // 最大回撤（窗口内）
        var peak = closes.last!.close
        var maxDrawdown = 0.0
        for entry in closes.reversed() {
            peak = max(peak, entry.close)
            if peak > 0 {
                maxDrawdown = min(maxDrawdown, entry.close / peak - 1)
            }
        }
        let digest = StableDigest.digest("\(symbol)|\(closes.first?.date ?? "")|\(closes.count)")
        let evidenceID = EvidenceID(rawValue: "vendor:alphavantage:daily:\(symbol):\(digest.prefix(12))")
        // 来源时间 = 日线最新交易日（数据描述的最后事件时刻）
        let dailySourceDates: [String: Date] = [
            evidenceID.rawValue: ResearchSourceDateParser.parse(closes[0].date)
        ].compactMapValues { $0 }
        let data: ModelJSONValue = [
            "symbol": .string(symbol),
            "latest_date": .string(closes[0].date),
            "latest_close": .number(latest),
            "return_5d_pct": trailingReturn(5),
            "return_20d_pct": trailingReturn(20),
            "return_60d_pct": trailingReturn(60),
            "sma_20": sma(20),
            "annualized_volatility_pct_20d": vol,
            "max_drawdown_pct_window": .number(maxDrawdown * 100),
            "observations": .number(Double(closes.count)),
            "cache_hit": .bool(outcome.cacheHit),
            "evidence_boundary": .string("供应商日线 + 本地确定性计算；指标窗口固定，不含预测。")
        ]
        return .content(
            ResearchToolEnvelope.success(data, evidenceIDs: [evidenceID]),
            evidenceIDs: [evidenceID],
            sourceDates: dailySourceDates
        )
    }

    /// A 股 6 位数字代码映射 AV 后缀（与旧 AlphaVantageResearchTool 同规则：
    /// 5/6/9 开头沪市 .SHH，0/1/2/3 开头深市 .SHZ，其余如北交所原样）；其他 symbol 原样大写。
    static func normalizedSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return trimmed }
        let first = String(trimmed.prefix(1))
        if ["5", "6", "9"].contains(first) {
            return trimmed + ".SHH"
        }
        if ["0", "1", "2", "3"].contains(first) {
            return trimmed + ".SHZ"
        }
        return trimmed
    }
}

// MARK: - 共享辅助

extension ResearchTool {
    /// 参数解码（Codable；失败统一 invalid_arguments 信封）。
    static func decodeParams<P: Decodable>(_ type: P.Type, _ argumentsJSON: String) -> P? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(P.self, from: data)
    }

    static var invalidArguments: ModelJSONValue {
        ResearchToolEnvelope.error(code: "invalid_arguments", message: "参数不符合声明。")
    }
}
