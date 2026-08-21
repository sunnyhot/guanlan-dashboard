import Foundation

// MARK: - SECResponseParser（PROV-4：XBRL companyfacts → fundamental fact ProviderRecord）
//
// 复用现有 `SECOfficialSourceClient`（Core/Clients/）取 raw Data——公平访问限流器
// （5 req/s）、User-Agent 规范、HTTP 错误都已封装，本解析器不重复。它只负责
// companyfacts JSON → FundamentalFactPayload ProviderRecord（kind = .fundamentalFact）。
//
// 真实 wire 格式（`data.sec.gov/api/xbrl/companyfacts/CIK{padded}.json`）：
// ```
// {"cik":320193,"entityName":"Apple Inc","facts":{
//   "dei":{...},
//   "us-gaap":{
//     "Revenues":{"label":"...","units":{
//       "USD":[
//         {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
//          "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-Q",
//          "filed":"2023-08-04","frame":"CY2023Q2"},
//         ...]
//     }}
//   }
// }}
// ```
//
// **PIT 语义**（ADR-DATA005 + DATA008）：一条记录 = 一个 (concept, unit, start/end,
// filed) 事实行。同一 concept 同一 period 的多次申报（10-Q 初报 → 10-K 修订）是
// publishedAt 不同的多条记录，保留完整 vintage 历史；effectiveAt = 期间结束/时点日，
// publishedAt = filed。Canonical 化经 ObservationFactory 产 FundamentalObservation
//（REPO-1b，providerCode `sec_cik` 需先登记 LegalEntity 映射）。
//
// **提取方式**（PROV-4 验收）：XBRL fact 是申报的机器可读字段，payload 携带
// `extractionMethod = .xbrlFact`，与 LLM extracted fact（Epic 11）在类型层区分。

/// 标准化财务指标规格（concept → metricKey 的稳定映射）。
///
/// 与现有 `SECOfficialResearchTool` 的 spec 集对齐（revenue / netIncome / assets /
/// liabilities / operatingCashFlow）；概念候选按顺序取第一个命中的。
struct SECXBRLMetricSpec: Sendable, Hashable {
    let key: String
    let label: String
    let concepts: [String]

    static let standard: [SECXBRLMetricSpec] = [
        SECXBRLMetricSpec(
            key: "revenue", label: "营业收入",
            concepts: [
                "RevenueFromContractWithCustomerExcludingAssessedTax",
                "Revenues",
                "SalesRevenueNet"
            ]
        ),
        SECXBRLMetricSpec(key: "netIncome", label: "净利润", concepts: ["NetIncomeLoss", "ProfitLoss"]),
        SECXBRLMetricSpec(key: "assets", label: "总资产", concepts: ["Assets"]),
        SECXBRLMetricSpec(key: "liabilities", label: "总负债", concepts: ["Liabilities"]),
        SECXBRLMetricSpec(
            key: "operatingCashFlow", label: "经营现金流",
            concepts: ["NetCashProvidedByUsedInOperatingActivities"]
        )
    ]
}

/// 公司身份（company_tickers_exchange.json 目录解析结果）。
struct SECCompanyIdentity: Sendable, Hashable {
    let cik: Int
    let ticker: String
    let name: String

    var paddedCIK: String {
        String(format: "%010d", cik)
    }
}

/// 单条 XBRL 事实（companyfacts 一个 units 行）。
struct SECXBRLFact: Sendable, Hashable {
    let concept: String
    let metricKey: String
    let unit: String
    let value: Decimal
    let start: Date?
    let end: Date
    let form: String
    let filed: Date
    let frame: String?
}

/// companyfacts 解析结果。
struct SECCompanyFacts: Sendable, Hashable {
    let cik: Int
    let entityName: String
    let facts: [SECXBRLFact]
    /// 因格式异常（val 非数 / 日期非法 / form 不在范围）被丢弃的行数
    let droppedMalformedCount: Int
}

enum SECResponseParseError: Error, Equatable, Sendable {
    case emptyBody
    case malformedJSON(detail: String)
    /// companyfacts 缺 facts/us-gaap 结构（schema 漂移）
    case missingFacts
    /// 目录里找不到 ticker
    case companyNotFound(ticker: String)
    /// 目录结构不完整（fields/data 缺失）
    case malformedDirectory(detail: String)
    /// 配置的标准概念一条有效事实都没有（不一定是错——部分公司不用 US-GAAP 标签，
    /// 调用方按空结果降级，不崩）
    case noValidFacts
}

/// SEC XBRL companyfacts / 公司目录解析器。
struct SECResponseParser: Sendable {

    /// 只取定期报告的事实（与现有 SECOfficialResearchTool 口径一致）。
    private static let acceptedForms: Set<String> = ["10-Q", "10-K", "20-F", "40-F"]

    /// SEC 日期是纯日历日（无时间分量），按 UTC 00:00 解析保证确定性；
    /// availableAt 由 AvailabilityPolicy 按 US 交易日历另行推导。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 公司目录（ticker → CIK）

    /// 解析 `company_tickers_exchange.json`，按 ticker 找公司身份。
    func parseCompanyDirectory(_ data: Data, ticker: String) throws -> SECCompanyIdentity {
        guard !data.isEmpty else { throw SECResponseParseError.emptyBody }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String],
              let rows = root["data"] as? [[Any]] else {
            throw SECResponseParseError.malformedDirectory(detail: "fields/data 缺失")
        }
        guard let cikIndex = fields.firstIndex(of: "cik"),
              let nameIndex = fields.firstIndex(of: "name"),
              let tickerIndex = fields.firstIndex(of: "ticker") else {
            throw SECResponseParseError.malformedDirectory(detail: "fields 不含 cik/name/ticker")
        }
        let normalized = Self.normalizedTicker(ticker)
        guard let row = rows.first(where: {
            guard $0.indices.contains(tickerIndex) else { return false }
            return Self.normalizedTicker(Self.string($0[tickerIndex])) == normalized
        }), row.indices.contains(cikIndex), row.indices.contains(nameIndex),
        let cik = Self.integer(row[cikIndex]) else {
            throw SECResponseParseError.companyNotFound(ticker: normalized)
        }
        return SECCompanyIdentity(cik: cik, ticker: normalized, name: Self.string(row[nameIndex]))
    }

    // MARK: - companyfacts

    /// 解析 companyfacts JSON → SECCompanyFacts（配置的全部 metric spec、全部 vintage 行）。
    func parseCompanyFacts(
        _ data: Data,
        specs: [SECXBRLMetricSpec] = SECXBRLMetricSpec.standard
    ) throws -> SECCompanyFacts {
        guard !data.isEmpty else { throw SECResponseParseError.emptyBody }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SECResponseParseError.malformedJSON(detail: "root not a JSON object")
        }
        guard let cik = Self.integer(root["cik"]) else {
            throw SECResponseParseError.malformedJSON(detail: "missing cik")
        }
        let entityName = Self.string(root["entityName"])
        guard let factsContainer = root["facts"] as? [String: Any],
              let usGAAP = factsContainer["us-gaap"] as? [String: Any] else {
            throw SECResponseParseError.missingFacts
        }

        var facts: [SECXBRLFact] = []
        var dropped = 0
        for spec in specs {
            // 逐事实选优先 concept（审查 P2）：收集 spec 全部候选概念的行（带优先级），
            // 按 (unit, start/end, filed) 分组、组内取最高优先级概念——
            // - 同一 (期间, unit, filed) 被多个概念披露（如新标签与旧标签并存）→ 只留
            //   优先级最高的，不重复；
            // - 公司近年用新标签、早年只有旧标签 → 两组不同 (start/end, filed)，
            //   各自保留，历史不整段消失（全局只选一个 concept 的旧做法会吞掉早年数据）
            struct GroupKey: Hashable {
                let unit: String
                let start: Date?
                let end: Date
                let filed: Date
            }
            var chosen: [GroupKey: (priority: Int, fact: SECXBRLFact)] = [:]
            for (priority, concept) in spec.concepts.enumerated() {
                guard let fact = usGAAP[concept] as? [String: Any],
                      let units = fact["units"] as? [String: Any] else {
                    continue   // 该概念此公司未披露（正常，不算 malformed）
                }
                for (unit, rawRows) in units {
                    guard let rows = rawRows as? [[String: Any]] else {
                        dropped += 1
                        continue
                    }
                    for row in rows {
                        guard let value = Self.decimal(row["val"]),
                              let end = Self.dayFormatter.date(from: Self.string(row["end"])),
                              let filed = Self.dayFormatter.date(from: Self.string(row["filed"])),
                              let form = Self.string(row["form"]).nilIfEmpty,
                              Self.acceptedForms.contains(form) else {
                            dropped += 1
                            continue
                        }
                        let startStr = Self.string(row["start"])
                        let candidate = SECXBRLFact(
                            concept: concept,
                            metricKey: spec.key,
                            unit: unit,
                            value: value,
                            start: startStr.nilIfEmpty.flatMap { Self.dayFormatter.date(from: $0) },
                            end: end,
                            form: form,
                            filed: filed,
                            frame: Self.string(row["frame"]).nilIfEmpty
                        )
                        let key = GroupKey(unit: unit, start: candidate.start, end: end, filed: filed)
                        if let existing = chosen[key] {
                            if priority < existing.priority {
                                chosen[key] = (priority, candidate)
                            }
                        } else {
                            chosen[key] = (priority, candidate)
                        }
                    }
                }
            }
            facts.append(contentsOf: chosen.values.map(\.fact))
        }
        if facts.isEmpty {
            throw SECResponseParseError.noValidFacts
        }
        facts.sort { ($0.filed, $0.end, $0.concept) < ($1.filed, $1.end, $1.concept) }
        return SECCompanyFacts(
            cik: cik, entityName: entityName, facts: facts, droppedMalformedCount: dropped
        )
    }

    // MARK: - ProviderRecord 转换

    /// 事实流 → ProviderRecord（kind = .fundamentalFact）。
    ///
    /// effectiveAt = 期间结束/时点日；publishedAt = filed（申报提交日）；
    /// availableAt 由 policy 基于 publishedAt 推导（FilingRelease v1，US 交易日，REPO-1b）。
    /// providerCode 用 `sec_cik`（SEC 权威键，**统一 10 位补零**，与 SEC 官方
    /// padded CIK URL 及目录口径一致——避免补零/未补零两套键混用，审查 P2），
    /// canonical 解析待 Identity Sync（SYNC-8）建立映射。
    func toProviderRecords(
        _ facts: SECCompanyFacts,
        reliabilityClass: ProviderReliabilityClass,
        ingestedAt: Date
    ) -> [ProviderRecord] {
        let paddedCIK = String(format: "%010d", facts.cik)
        return facts.facts.map { fact in
            let payload = FundamentalFactPayload(
                concept: fact.concept,
                metricKey: fact.metricKey,
                value: fact.value,
                unit: fact.unit,
                start: fact.start,
                end: fact.end,
                form: fact.form,
                frame: fact.frame,
                extractionMethod: .xbrlFact   // PROV-4 验收：XBRL 机器可读字段
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            return ProviderRecord(
                providerID: .sec,
                providerCode: ProviderCode(scheme: "sec_cik", value: paddedCIK),
                effectiveAt: fact.end,
                publishedAt: fact.filed,
                ingestedAt: ingestedAt,
                kind: .fundamentalFact,
                rawPayload: payloadData,
                reliabilityClass: reliabilityClass,
                jurisdiction: .unitedStates
            )
        }
    }

    // MARK: - Helpers

    static func normalizedTicker(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private static func integer(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// JSON 数值 → Decimal（经 stringValue 中转避免 Double 精度损失）。
    private static func decimal(_ value: Any?) -> Decimal? {
        if let n = value as? NSNumber { return Decimal(string: n.stringValue) }
        if let s = value as? String { return Decimal(string: s) }
        return nil
    }
}

// MARK: - SECProviderAdapter（PROV-4）

/// SEC Provider Adapter（PROV-4，XBRL 官方财务事实）。
///
/// **复用现有 `SECOfficialSourceClient` + `SECOfficialSourceCache`**（Core/Clients/）：
/// 公平访问限流（5 req/s 共享节流）、User-Agent 联系邮箱规范、HTTP 错误、
/// 目录/事实缓存（24h / 6h，与现有 SECOfficialResearchTool 一致）都不重复实现。
/// 本 adapter 只负责：目录解析 ticker→CIK → companyfacts 解析 → ProviderRecord，
/// 并把 `SECOfficialSourceClientError` 映射到 `ProviderError`（ADR-DATA006 降级）。
///
/// 输入 code：scheme = `stock_symbol`（如 AAPL）；产出记录 providerCode = `sec_cik`。
/// 生产用真实 `OfficialSourceSettings`（联系邮箱）；测试注入 FakeSECClient。
struct SECProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .sec
    let reliabilityClass: ProviderReliabilityClass = .officialStable

    private let parser = SECResponseParser()
    private let client: any SECOfficialSourceClientProtocol
    private let cache: SECOfficialSourceCache
    private let settings: OfficialSourceSettings
    private let metricSpecs: [SECXBRLMetricSpec]
    private let ingestedAt: @Sendable () -> Date

    init(
        client: any SECOfficialSourceClientProtocol,
        settings: OfficialSourceSettings,
        cache: SECOfficialSourceCache = SECOfficialSourceCache(),
        metricSpecs: [SECXBRLMetricSpec] = SECXBRLMetricSpec.standard,
        ingestedAt: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.settings = settings
        self.cache = cache
        self.metricSpecs = metricSpecs
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        guard code.scheme == "stock_symbol" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }
        let ticker = SECResponseParser.normalizedTicker(code.value)
        do {
            let identity = try await resolveCompany(ticker: ticker)
            let outcome = try await cache.fetch(
                SECRequestDescriptor(
                    url: URL(
                        string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(identity.paddedCIK).json"
                    )!,
                    cacheTTL: 6 * 60 * 60
                ),
                settings: settings,
                client: client
            )
            let facts = try parser.parseCompanyFacts(outcome.data, specs: metricSpecs)
            let allRecords = parser.toProviderRecords(
                facts, reliabilityClass: reliabilityClass, ingestedAt: ingestedAt()
            )
            let filtered = allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
            let diagnostics = ProviderFetchDiagnostics(droppedMalformedBySource: [
                "sec_companyfacts": facts.droppedMalformedCount
            ])
            return ProviderFetchResult(records: filtered, diagnostics: diagnostics)
        } catch let e as SECOfficialSourceClientError {
            throw Self.mapClientError(e)
        } catch let e as SECResponseParseError {
            throw Self.mapParseError(e)
        }
    }

    /// ticker → CIK（company_tickers_exchange.json，24h 缓存）。
    private func resolveCompany(ticker: String) async throws -> SECCompanyIdentity {
        let outcome = try await cache.fetch(
            SECRequestDescriptor(
                url: URL(string: "https://www.sec.gov/files/company_tickers_exchange.json")!,
                cacheTTL: 24 * 60 * 60
            ),
            settings: settings,
            client: client
        )
        return try parser.parseCompanyDirectory(outcome.data, ticker: ticker)
    }

    /// SECOfficialSourceClientError → ProviderError（ADR-DATA006 三档降级）。
    ///
    /// SEC 无配额概念：432/433 类月额度语义不存在，quotaExhausted 不适用；
    /// **429 是公平访问限流（transient）→ rateLimited**（独立冷却自动恢复，
    /// 不累计连续失败，审查 P2）；403（拒自动访问）→ unavailable。
    static func mapClientError(_ error: SECOfficialSourceClientError) -> ProviderError {
        switch error {
        case .missingContact, .timedOut:
            return .unavailable(providerID: .sec, underlying: error.errorDescription ?? "\(error)")
        case .invalidResponse:
            return .schemaMismatch(providerID: .sec, detail: error.errorDescription ?? "\(error)")
        case .requestFailed(let statusCode, let detail):
            if statusCode == 429 {
                return .rateLimited(providerID: .sec, retryAfter: nil)
            }
            return .unavailable(
                providerID: .sec,
                underlying: "http \(statusCode)\(detail.isEmpty ? "" : " \(detail)")"
            )
        }
    }

    /// SECResponseParseError → ProviderError。
    static func mapParseError(_ error: SECResponseParseError) -> ProviderError {
        switch error {
        case .companyNotFound(let ticker):
            return .notFound(code: ProviderCode(scheme: "stock_symbol", value: ticker))
        case .emptyBody, .missingFacts, .noValidFacts:
            return .schemaMismatch(providerID: .sec, detail: "\(error)")
        case .malformedJSON(let detail), .malformedDirectory(let detail):
            return .schemaMismatch(providerID: .sec, detail: detail)
        }
    }
}
