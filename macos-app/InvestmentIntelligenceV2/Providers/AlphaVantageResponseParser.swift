import Foundation

// MARK: - AlphaVantageResponseParser（PROV-6：TIME_SERIES_DAILY JSON → DailyBar）
//
// 复用现有 `AlphaVantageClient`（Core/Clients/）取 raw Data——URL 构造 / apikey 鉴权 /
// 上游 service message（Information/Note/Error Message）检测 / HTTP 错误都已封装，
// 本解析器不重复这些。它只负责 OHLC 全字段解析 → ProviderRecord。
//
// 现有 `AlphaVantageResearchTool.dailyAnalytics`（Core/TrendResearch/）只读 close+volume、
// 丢弃 open/high/low；V2 `DailyBarPayload` 需 OHLCV 全字段，故新写本解析器（参照
// StooqResponseParser 的 raw + adjustment 分离模式）。
//
// 真实 wire 格式（`function=TIME_SERIES_DAILY&datatype=json`）：
// ```
// {"Time Series (Daily)": {
//   "2024-07-01": {"1. open":"210.34","2. high":"212.50","3. low":"209.80",
//                  "4. close":"211.20","5. volume":"52000000"},
//   "2024-07-02": {...}
// }}
// ```
// 所有数值字段都是字符串；日期 key "YYYY-MM-DD"（按 America/New_York 解析到日界）。
//
// **复权语义**（ADR-DATA003 raw + adjustment 分离）：TIME_SERIES_DAILY 返回不复权 raw 价，
// adjustmentFactor = 1.0（真实复权因子需 TIME_SERIES_DAILY_ADJUSTED 端点，不在此伪造）。

/// Alpha Vantage TIME_SERIES_DAILY 解析结果。
struct AlphaVantageDailyHistory: Sendable, Hashable {
    let symbol: String
    let entries: [Entry]
    /// 解析过程中因格式异常被丢弃的行数（schema 漂移可审计出口）
    let droppedMalformedCount: Int

    struct Entry: Sendable, Hashable {
        /// 交易日（归一化到 unitedStates 日界 00:00）
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        /// 成交量（个别行可能缺，为 nil）
        let volume: Int64?
    }
}

enum AlphaVantageParseError: Error, Equatable, Sendable {
    case emptyBody
    /// JSON 根结构异常
    case malformedJSON(detail: String)
    /// 缺 "Time Series (Daily)" key（上游 service message 已由 AlphaVantageClient 拦截；
    /// 到此处说明 Data 结构异常）
    case missingTimeSeries
    /// 全部行都异常（整体 schema 失败）
    case noValidEntries(totalRows: Int)
}

/// Alpha Vantage TIME_SERIES_DAILY JSON 响应解析器。
struct AlphaVantageResponseParser: Sendable {

    /// 美东日历（日期归一化到 America/New_York 日界）。
    private static var usCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 解析 TIME_SERIES_DAILY JSON（Data）→ AlphaVantageDailyHistory。
    func parse(_ data: Data, symbol: String) throws -> AlphaVantageDailyHistory {
        guard !data.isEmpty else { throw AlphaVantageParseError.emptyBody }

        // key 含空格/括号/点（"Time Series (Daily)"、"1. open"），用 JSONSerialization
        // 比 Codable keyDecodingStrategy 更直接
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AlphaVantageParseError.malformedJSON(detail: "root not a JSON object")
        }
        guard let series = root["Time Series (Daily)"] as? [String: [String: Any]] else {
            throw AlphaVantageParseError.missingTimeSeries
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "America/New_York")

        var entries: [AlphaVantageDailyHistory.Entry] = []
        var dropped = 0
        for (dateStr, row) in series {
            guard let date = dateFormatter.date(from: dateStr) else {
                dropped += 1; continue
            }
            // OHLC 必须有限（字符串→Double，非有限丢弃避免 Decimal trap）
            guard let o = Self.number(row["1. open"]), o.isFinite,
                  let h = Self.number(row["2. high"]), h.isFinite,
                  let l = Self.number(row["3. low"]), l.isFinite,
                  let c = Self.number(row["4. close"]), c.isFinite
            else {
                dropped += 1; continue
            }
            // volume 可缺/空 → nil
            var volume: Int64?
            if let vStr = row["5. volume"] as? String, !vStr.isEmpty, let v = Int64(vStr) {
                volume = v
            } else if let vNum = row["5. volume"] as? NSNumber {
                volume = Int64(exactly: vNum.int64Value)
            }
            entries.append(AlphaVantageDailyHistory.Entry(
                date: Self.usCalendar.startOfDay(for: date),
                open: o, high: h, low: l, close: c, volume: volume
            ))
        }
        if entries.isEmpty {
            throw AlphaVantageParseError.noValidEntries(totalRows: series.count)
        }
        // API 不保证顺序，按日期升序排（便于时间序列消费）
        entries.sort { $0.date < $1.date }
        return AlphaVantageDailyHistory(symbol: symbol, entries: entries, droppedMalformedCount: dropped)
    }

    /// 字符串 / 数字 → Double（Alpha Vantage 字段都是字符串，兼容个别 NSNumber）。
    private static func number(_ raw: Any?) -> Double? {
        if let s = raw as? String { return Double(s) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    /// 把解析出的日线历史转换为 ProviderRecord 流（kind = .dailyBar）。
    ///
    /// ADR-DATA003 raw + adjustment 分离：rawOpen/High/Low/Close 是不复权原始价，
    /// adjustmentFactor = 1.0（真实复权因子另行获取，不伪造）。
    func toProviderRecords(
        _ history: AlphaVantageDailyHistory,
        reliabilityClass: ProviderReliabilityClass,
        ingestedAt: Date
    ) -> [ProviderRecord] {
        history.entries.map { entry in
            let payload = DailyBarPayload(
                rawOpen: Price(value: Decimal(entry.open), currency: .usd),
                rawHigh: Price(value: Decimal(entry.high), currency: .usd),
                rawLow: Price(value: Decimal(entry.low), currency: .usd),
                rawClose: Price(value: Decimal(entry.close), currency: .usd),
                volume: entry.volume,
                adjustmentFactor: 1.0,   // TIME_SERIES_DAILY 不复权 raw；复权因子单独通道
                fxRate: nil              // USD 标的，base USD
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            // 美股日线：effectiveAt = publishedAt = 交易日（收盘后可知，由 MarketClose policy 推导）
            return ProviderRecord(
                providerID: .alphaVantage,
                providerCode: ProviderCode(scheme: "stock_symbol", value: history.symbol),
                effectiveAt: entry.date,
                publishedAt: entry.date,
                ingestedAt: ingestedAt,
                kind: .dailyBar,
                rawPayload: payloadData,
                reliabilityClass: reliabilityClass,
                jurisdiction: .unitedStates
            )
        }
    }
}

// MARK: - AlphaVantageProviderAdapter（PROV-6）

/// Alpha Vantage Provider Adapter（PROV-6，美股日线 supplemental 降级源）。
///
/// **复用现有 `AlphaVantageClient`**（Core/Clients/）取 raw Data：URL 构造、apikey 鉴权、
/// HTTP 错误、上游 service message（Information/Note/Error Message）检测都已封装，不重复。
/// 本 adapter 只负责：构造 descriptor → client.fetch → parser 解析 OHLCV → ProviderRecord，
/// 并把 `AlphaVantageClientError` 映射到 `ProviderError`（三档降级，ADR-DATA006）。
///
/// **降级定位**（rollout PROV-6）：Stooq 是美股日线 primary，Alpha Vantage 是 supplemental
/// （documentFreeAPI，25/天 free tier）。quota 耗尽时抛 `ProviderError.quotaExhausted`，
/// 调用方降级到其他源或 unavailable，不阻塞。
///
/// 生产用 `AlphaVantageClient(session:)` + 真实 `AlphaVantageSettings`（apiKey）；
/// 测试注入 `FakeAlphaVantageClient`（返回预录 Data 或抛特定 error）。
struct AlphaVantageProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .alphaVantage
    let reliabilityClass: ProviderReliabilityClass = .documentFreeAPI

    private let parser = AlphaVantageResponseParser()
    private let client: AlphaVantageClientProtocol
    private let settings: AlphaVantageSettings
    private let ingestedAt: @Sendable () -> Date

    init(
        client: AlphaVantageClientProtocol,
        settings: AlphaVantageSettings,
        ingestedAt: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.settings = settings
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    /// 真实主实现：client.fetch → parser → ProviderRecord + 诊断（透传 droppedMalformedCount）。
    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        guard code.scheme == "stock_symbol" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }
        let descriptor = AlphaVantageRequestDescriptor(
            function: .timeSeriesDaily,
            symbol: code.value,
            parameters: ["outputsize": "compact", "datatype": "json"],
            cacheTTL: 6 * 60 * 60   // 与现有 AlphaVantageResearchTool 一致
        )
        do {
            // 复用 AlphaVantageClient（URL/鉴权/上游信号检测已封装）
            let data = try await client.fetch(descriptor, settings: settings)
            let history = try parser.parse(data, symbol: code.value)
            let allRecords = parser.toProviderRecords(
                history, reliabilityClass: reliabilityClass, ingestedAt: ingestedAt()
            )
            let filtered = allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
            let diagnostics = ProviderFetchDiagnostics(droppedMalformedBySource: [
                "alphavantage_daily": history.droppedMalformedCount
            ])
            return ProviderFetchResult(records: filtered, diagnostics: diagnostics)
        } catch let e as AlphaVantageClientError {
            throw Self.mapClientError(e)
        } catch {
            // AlphaVantageParseError（missingTimeSeries / malformedJSON / noValidEntries）→ schema
            throw ProviderError.schemaMismatch(providerID: .alphaVantage, detail: "\(error)")
        }
    }

    /// AlphaVantageClientError → ProviderError（ADR-DATA006 三档降级）。
    ///
    /// - dailyBudgetExceeded：本地 25/天预算耗尽 → quotaExhausted（若上层用了 budget）
    /// - serviceMessage：上游 Information/Note（"...25 requests per day..."、"API call frequency"）
    ///   → quotaExhausted；Error Message（invalid symbol 等）→ schemaMismatch
    /// - invalidURL / invalidHTTPStatus / invalidResponse：网络/服务端 → unavailable
    static func mapClientError(_ error: AlphaVantageClientError) -> ProviderError {
        switch error {
        case .dailyBudgetExceeded:
            return .quotaExhausted(providerID: .alphaVantage)
        case .serviceMessage(let msg):
            // Information/Note 通常是 rate limit / 额度提示 → quota 降级不阻塞；
            // Error Message 通常是 invalid symbol / 参数错 → schema
            let lower = msg.lowercased()
            if lower.contains("25 requests") || lower.contains("frequency")
                || lower.contains("rate limit") || lower.contains("premium") {
                return .quotaExhausted(providerID: .alphaVantage)
            }
            return .schemaMismatch(providerID: .alphaVantage, detail: msg)
        case .invalidURL, .invalidHTTPStatus, .invalidResponse:
            return .unavailable(providerID: .alphaVantage, underlying: error.errorDescription ?? "\(error)")
        }
    }
}
