import Foundation

// MARK: - StooqResponseParser（PROV-2 真实 Provider 解析链：美股日线 CSV）
//
// 解析 Stooq 历史日线 CSV 响应 → ProviderRecord（kind = .dailyBar）。
// Stooq 是美股 primary 行情源（documentFreeAPI，personal-use，FREE001 合规：免费、无 key）。
//
// 真实 wire 格式（`https://stooq.com/q/d/l/?s={symbol}&i=d`）：
// ```
// Date,Open,High,Low,Close,Volume
// 2024-07-01,210.34,212.50,209.80,211.20,52000000
// 2024-07-02,211.20,213.00,210.90,212.80,49800000
// ```
//
// **复权语义**（ADR-DATA003 raw + adjustment 分离）：Stooq 基础下载是不复权 raw 价。
// adjustmentFactor 默认 1.0；真实复权因子需单独通道（Stooq 的 adjusted 端点或外部源），
// 不在此伪造——业务层按 raw + adjustment 分离消费。
//
// 不修改现有 client（无现有 Stooq 接入），让 Provider Adapter 层可独立测试。

/// Stooq 日线 CSV 解析结果。
struct StooqDailyBarHistory: Sendable, Hashable {
    let symbol: String
    let entries: [Entry]
    /// 解析过程中因格式异常被丢弃的行数（schema 漂移可审计出口）
    let droppedMalformedCount: Int

    struct Entry: Sendable, Hashable {
        /// 交易日（归一化到 unitedStates 日界 00:00，CSV 已是 YYYY-MM-DD 零点）
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        /// 成交量（Stooq 个别行可能缺，为 nil）
        let volume: Int64?
    }
}

enum StooqParseError: Error, Equatable, Sendable {
    case emptyBody
    /// CSV 全部行都异常（整体 schema 失败）
    case noValidEntries(totalRows: Int)
    /// CSV 结构异常（如无法识别的表头）
    case malformedCSV(detail: String)
}

/// Stooq CSV 响应解析器。
struct StooqResponseParser: Sendable {

    /// 美东日历（用于日期解析；CSV 日期是 YYYY-MM-DD，按 America/New_York 解析到日界）。
    private static var usCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 解析 Stooq 日线 CSV 响应。
    ///
    /// - Parameter symbol: 标的 symbol（如 "aapl.us"），用于 providerCode 与 symbol 字段。
    func parse(_ body: String, symbol: String) throws -> StooqDailyBarHistory {
        guard !body.isEmpty else { throw StooqParseError.emptyBody }

        let lines = body.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw StooqParseError.emptyBody }

        // 第一行是表头：Date,Open,High,Low,Close,Volume
        // 不强校验表头字节（Stooq 偶尔调整列序），但确认含 Date 列再按列名分派
        let header = lines[0].lowercased()
        guard header.contains("date"), header.contains("close") else {
            throw StooqParseError.malformedCSV(detail: "unexpected header: \(lines[0])")
        }
        let columns = lines[0].lowercased().components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        func colIndex(_ name: String) -> Int? {
            columns.firstIndex(of: name)
        }
        guard let dateIdx = colIndex("date"),
              let openIdx = colIndex("open"),
              let highIdx = colIndex("high"),
              let lowIdx = colIndex("low"),
              let closeIdx = colIndex("close")
        else {
            throw StooqParseError.malformedCSV(detail: "missing required OHLC columns in header: \(lines[0])")
        }
        let volumeIdx = colIndex("volume")   // volume 可缺

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "America/New_York")

        var entries: [StooqDailyBarHistory.Entry] = []
        var dropped = 0
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: ",")
            // 字段数不足 → 丢弃
            guard fields.count > max(dateIdx, openIdx, highIdx, lowIdx, closeIdx) else {
                dropped += 1; continue
            }
            guard let date = dateFormatter.date(from: fields[dateIdx].trimmingCharacters(in: .whitespaces)) else {
                dropped += 1; continue
            }
            // OHLC 必须是有限正数（NAV/价格 ≥ 0；非有限数丢弃，避免 Decimal trap）
            guard let o = Double(fields[openIdx]), o.isFinite,
                  let h = Double(fields[highIdx]), h.isFinite,
                  let l = Double(fields[lowIdx]), l.isFinite,
                  let c = Double(fields[closeIdx]), c.isFinite
            else {
                dropped += 1; continue
            }
            // volume 可缺/空 → nil
            var volume: Int64?
            if let vIdx = volumeIdx, vIdx < fields.count {
                let vStr = fields[vIdx].trimmingCharacters(in: .whitespaces)
                if !vStr.isEmpty, let v = Int64(vStr) {
                    volume = v
                }
            }
            entries.append(StooqDailyBarHistory.Entry(
                date: Self.usCalendar.startOfDay(for: date),
                open: o, high: h, low: l, close: c, volume: volume
            ))
        }
        if entries.isEmpty {
            throw StooqParseError.noValidEntries(totalRows: lines.count - 1)
        }
        return StooqDailyBarHistory(symbol: symbol, entries: entries, droppedMalformedCount: dropped)
    }

    /// 把解析出的日线历史转换为 ProviderRecord 流（kind = .dailyBar）。
    ///
    /// ADR-DATA003 raw + adjustment 分离：rawOpen/High/Low/Close 是不复权原始价，
    /// adjustmentFactor = 1.0（真实复权因子另行获取，不伪造）。
    func toProviderRecords(
        _ history: StooqDailyBarHistory,
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
                adjustmentFactor: 1.0,   // 不复权 raw；复权因子单独通道
                fxRate: nil              // USD 标的，base USD
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            // 美股日线：effectiveAt = publishedAt = 交易日（收盘后次日才可知，由 MarketClose policy 推导）
            return ProviderRecord(
                providerID: .stooq,
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

// MARK: - StooqProviderAdapter（PROV-2）

/// Stooq Provider Adapter（PROV-2，美股历史日线 primary）。
///
/// 真实解析链：通过 fetcher 取 Stooq CSV → StooqResponseParser 解析 → ProviderRecord 流。
/// 生产用 `URLSessionResponseFetcher`（GET Stooq CSV 端点）；测试注入 `StaticResponseFetcher`。
///
/// **合规标注**（FREE001）：Stooq 是免费、无 key、personal-use 的历史数据源，
/// 适合个人投资研究；非商业 redistribution 受 Stooq 服务条款约束（不在本系统范围）。
struct StooqProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .stooq
    let reliabilityClass: ProviderReliabilityClass = .documentFreeAPI

    private let parser = StooqResponseParser()
    private let fetcher: any ResponseFetcher
    private let ingestedAt: @Sendable () -> Date

    init(fetcher: any ResponseFetcher, ingestedAt: @escaping @Sendable () -> Date = { .now }) {
        self.fetcher = fetcher
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    /// 真实主实现：fetch + 诊断（透传 CSV 解析 droppedMalformedCount）。
    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        guard code.scheme == "stock_symbol" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }
        let body = try await fetcher.fetch(.stooqHistory(symbol: code.value))
        let history = try parser.parse(body, symbol: code.value)
        let allRecords = parser.toProviderRecords(
            history, reliabilityClass: reliabilityClass, ingestedAt: ingestedAt()
        )
        let filtered = allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
        let diagnostics = ProviderFetchDiagnostics(droppedMalformedBySource: [
            "stooq_csv": history.droppedMalformedCount
        ])
        return ProviderFetchResult(records: filtered, diagnostics: diagnostics)
    }
}
