import Foundation

// MARK: - FREDResponseParser（PROV-5 真实 Provider 解析链：宏观指标观测）
//
// 解析 FRED（圣路易斯联储）series/observations JSON → ProviderRecord（kind=.macroObservation）。
// FRED 是 officialStable 宏观源（DATA006 最高档），免费 API（需 api_key，FREE001 合规）。
//
// 真实 wire 格式（`api.stlouisfed.org/fred/series/observations?series_id=GDP&file_type=json`）：
// ```
// {"observations":[
//   {"date":"2024-01-01","value":"2.5","realtime_start":"2024-04-25","realtime_end":"9999-12-31"},
//   {"date":"2024-04-01","value":"3.0","realtime_start":"2024-07-25","realtime_end":"9999-12-31"}
// ]}
// ```
//
// **PIT 语义**（ADR-DATA005 + DATA008）：
// - `date`：观测期（→ effectiveAt，如 GDP Q1 = 2024-01-01）
// - `value`：指标值（"." 表示缺失，丢弃）
// - `realtime_start`：FRED 发布该值的日期（→ publishedAt；这是「客观可知」锚点）
// - `realtime_end`：被修订替代的日期（9999-12-31 = 当前 vintage）
// availableAt 由 MacroRelease policy 基于 publishedAt 推导（发布日 +1 交易日）。
// 修订（advance/second/third）天然是多 vintage：同一 date 的不同 realtime_start 是不同 vintage。

/// FRED series 元数据配置（observations 响应不含 unit/frequency，需外部提供）。
struct FREDSeriesConfig: Sendable, Hashable {
    let seriesID: String
    /// providerCode 的 value（如 "GDP"、"CPIAUCSL"），通常等于 seriesID
    let providerSymbol: String
    let unit: MacroObservation.MacroUnit
    let frequency: MacroObservation.MacroFrequency
    let isSeasonallyAdjusted: Bool
    let basePeriod: MacroObservation.MacroBasePeriod?

    init(
        seriesID: String,
        providerSymbol: String? = nil,
        unit: MacroObservation.MacroUnit,
        frequency: MacroObservation.MacroFrequency,
        isSeasonallyAdjusted: Bool,
        basePeriod: MacroObservation.MacroBasePeriod? = nil
    ) {
        self.seriesID = seriesID
        self.providerSymbol = providerSymbol ?? seriesID
        self.unit = unit
        self.frequency = frequency
        self.isSeasonallyAdjusted = isSeasonallyAdjusted
        self.basePeriod = basePeriod
    }
}

/// FRED 观测序列解析结果。
struct FREDObservationHistory: Sendable, Hashable {
    let seriesID: String
    let entries: [Entry]
    /// 解析过程中因缺失值（"."）/格式异常被丢弃的行数
    let droppedMalformedCount: Int

    struct Entry: Sendable, Hashable {
        /// 观测期（→ effectiveAt）
        let date: Date
        let value: Decimal
        /// FRED 发布日 realtime_start（→ publishedAt，PIT 锚点）
        let realtimeStart: Date
    }
}

enum FREDParseError: Error, Equatable, Sendable {
    case emptyBody
    /// observations JSON 解析失败（schema 漂移）
    case malformedJSON(detail: String)
    /// 全部观测都异常（缺值 / 解析失败）
    case noValidEntries(totalRows: Int)
}

/// FRED observations 响应解析器。
struct FREDResponseParser: Sendable {

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f
    }()

    /// 解析 FRED observations JSON。
    func parse(_ body: String, seriesID: String) throws -> FREDObservationHistory {
        guard !body.isEmpty else { throw FREDParseError.emptyBody }
        guard let data = body.data(using: .utf8) else {
            throw FREDParseError.malformedJSON(detail: "body not utf8")
        }

        struct FREDResponse: Decodable {
            struct Obs: Decodable {
                let date: String
                let value: String
                let realtime_start: String
            }
            let observations: [Obs]
        }
        let resp: FREDResponse
        do {
            resp = try JSONDecoder().decode(FREDResponse.self, from: data)
        } catch {
            throw FREDParseError.malformedJSON(detail: "\(error)")
        }

        let fmt = Self.dayFormatter
        var entries: [FREDObservationHistory.Entry] = []
        var dropped = 0
        for obs in resp.observations {
            // FRED 用 "." 表示缺失值（非数）→ 丢弃 + 计数
            let valueStr = obs.value.trimmingCharacters(in: .whitespaces)
            guard valueStr != ".", let value = Decimal(string: valueStr) else {
                dropped += 1; continue
            }
            guard let date = fmt.date(from: obs.date),
                  let realtimeStart = fmt.date(from: obs.realtime_start) else {
                dropped += 1; continue
            }
            entries.append(FREDObservationHistory.Entry(
                date: date, value: value, realtimeStart: realtimeStart
            ))
        }
        if entries.isEmpty {
            throw FREDParseError.noValidEntries(totalRows: resp.observations.count)
        }
        return FREDObservationHistory(seriesID: seriesID, entries: entries, droppedMalformedCount: dropped)
    }

    /// 把解析出的观测序列转换为 ProviderRecord 流（kind = .macroObservation）。
    ///
    /// effectiveAt = 观测期 date；publishedAt = realtime_start（FRED 发布日，PIT 锚点）；
    /// availableAt 由 MacroRelease policy 基于 publishedAt 推导。
    func toProviderRecords(
        _ history: FREDObservationHistory,
        config: FREDSeriesConfig,
        reliabilityClass: ProviderReliabilityClass,
        ingestedAt: Date
    ) -> [ProviderRecord] {
        history.entries.map { entry in
            let payload = MacroPayload(
                value: entry.value,
                unit: config.unit,
                frequency: config.frequency,
                isSeasonallyAdjusted: config.isSeasonallyAdjusted,
                basePeriod: config.basePeriod
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            return ProviderRecord(
                providerID: .fred,
                providerCode: ProviderCode(scheme: "fred_series", value: config.providerSymbol),
                effectiveAt: entry.date,
                publishedAt: entry.realtimeStart,
                ingestedAt: ingestedAt,
                kind: .macroObservation,
                rawPayload: payloadData,
                reliabilityClass: reliabilityClass,
                jurisdiction: .unitedStates
            )
        }
    }
}

// MARK: - FREDProviderAdapter（PROV-5）

/// FRED Provider Adapter（PROV-5，宏观指标 primary）。
///
/// 单 series 配置驱动：一个 adapter 实例对应一个 FRED series（unit/frequency/seasonalAdj
/// 等 metadata 不在 observations 响应里，由 config 提供）。多 series 场景由 Sync（Epic 6）
/// 组合多个 adapter。生产用 URLSessionResponseFetcher；测试注入 StaticResponseFetcher。
///
/// **合规标注**（FREE001）：FRED API 免费、需注册 api_key（用户自备，不进代码库）；
/// DATA006 最高档 officialStable（联储官方）。
struct FREDProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .fred
    let reliabilityClass: ProviderReliabilityClass = .officialStable

    let config: FREDSeriesConfig
    private let parser = FREDResponseParser()
    private let fetcher: any ResponseFetcher
    private let ingestedAt: @Sendable () -> Date
    /// FRED API key（免费申请）。**必填**——缺失直接拒绝抓取（fail-closed，
    /// 不再用 PLACEHOLDER 静默发出注定失败的请求）
    private let apiKey: String
    /// real-time 窗口起点（默认 1900-01-01，早于一切 FRED 序列——请求全量
    /// vintage 历史；FRED 缺省=当天快照会伪造 publishedAt，P1 修复）
    private let realtimeStart: String
    /// real-time 窗口终点（nil = 今天，FRED 缺省）
    private let realtimeEnd: String?

    init(
        config: FREDSeriesConfig,
        fetcher: any ResponseFetcher,
        ingestedAt: @escaping @Sendable () -> Date = { .now },
        apiKey: String = "",
        realtimeStart: String = "1900-01-01",
        realtimeEnd: String? = nil
    ) {
        self.config = config
        self.fetcher = fetcher
        self.ingestedAt = ingestedAt
        self.apiKey = apiKey
        self.realtimeStart = realtimeStart
        self.realtimeEnd = realtimeEnd
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        guard code.scheme == "fred_series" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }
        // fail-closed：没有 key 的请求必然 403，显式拒绝优于静默坏请求
        guard !apiKey.isEmpty else {
            throw ProviderError.unavailable(
                providerID: .fred,
                underlying: "缺少 FRED API key（fred.stlouisfed.org 免费申请，注入 FREDProviderAdapter apiKey）"
            )
        }
        let body = try await fetcher.fetch(.fredObservations(
            seriesID: config.seriesID,
            realtimeStart: realtimeStart,
            realtimeEnd: realtimeEnd,
            apiKey: apiKey
        ))
        let history = try parser.parse(body, seriesID: config.seriesID)
        let allRecords = parser.toProviderRecords(
            history, config: config, reliabilityClass: reliabilityClass, ingestedAt: ingestedAt()
        )
        let filtered = allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
        let diagnostics = ProviderFetchDiagnostics(droppedMalformedBySource: [
            "fred_observations": history.droppedMalformedCount
        ])
        return ProviderFetchResult(records: filtered, diagnostics: diagnostics)
    }
}
