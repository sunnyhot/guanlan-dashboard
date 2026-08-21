import CryptoKit
import Foundation

// MARK: - M2MarketEvidenceSource（REPO-8 / ASH-11，M2 live gate 共享抓取）
//
// 按 2026-08-14 Architect 方案落地：
// 1. 一整套 M2LiveAcceptanceTests 只对每个上游打一次真实请求——用 actor 缓存
//    天天基金 Q2/Q1 抓取与行情 Provider 抓取，四场景复用同一批 live evidence，
//    避免重复请求触发天天基金 HTTP 限流。
// 2. 跨 Provider identity 样本换成真实 QDII 持仓（天天基金 513100 中的 AAPL），
//    不再拿 A 股 600519 当 Stooq 主样本（Stooq 在方案中定位是美股源）。
// 3. 行情 Provider 走候选链 Stooq primary → Alpha Vantage secondary（DATA006
//    可替换 Provider 降级设计的真实验证）。Stooq challenge / 429 映射
//    .unavailable；Alpha Vantage 额度问题映射 .quotaExhausted。两个都失败
//    → M2 blocked，绝不使用 fixture 冒充 live pass。
// 4. live gate 不 XCTSkip；失败分类为 transportUnavailable / quotaExhausted /
//    semanticMismatch 保留可复现证据。
// 5. 每次抓取输出 evidence manifest（Provider、endpoint、抓取时间、raw SHA-256、
//    published/available/ingested、两端 symbol 与 ListingID），作为 M2 放行证据。
//
// 注：Alpha Vantage 需要真实 apikey（Keychain `trend.alphaVantage.apiKey` 或
// ALPHAVANTAGE_API_KEY 环境变量，不进仓库）。无 key 时 secondary 不可用是
//「配置缺口」而非 fixture 替身，由 M2MarketEvidenceError.keyMissing 显式报告。
// 2026-08-21 实测：免费层只覆盖最近 100 个交易日（full / date-range / 
// DAILY_ADJUSTED 均 premium，date-range 参数被静默忽略），历史窗口需 Stooq
// 恢复或引入第三候选源（见 marketWindow 注释与 rollout §4.1 修订记录）。

/// M2 live gate 的失败分类（不 XCTSkip，失败必须保留原因）。
enum M2MarketEvidenceError: Error, Equatable, Sendable {
    /// 网络或上游反爬（Stooq JS challenge、天天基金限流）
    case transportUnavailable(detail: String)
    /// 额度耗尽（Alpha Vantage 25/天）
    case quotaExhausted(detail: String)
    /// Provider 返回的数据与契约不符（schema 漂移 / 语义错）
    case semanticMismatch(detail: String)
    /// Alpha Vantage apikey 未配置（配置缺口，非网络问题）
    case keyMissing(detail: String)
    /// 候选链上所有 Provider 都失败
    case allProvidersExhausted(details: [String])
}

/// 单次真实抓取的 evidence 条目（进 manifest）。
struct M2EvidenceEntry: Sendable, Hashable {
    let providerID: String
    let endpoint: String
    /// 抓取时刻（墙钟）
    let fetchedAt: Date
    /// raw body 的 SHA-256（hex）
    let rawSHA256: String
    let recordSummary: String

    static func sha256Hex(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 行情 Provider 候选链返回的真实美股日线证据。
struct M2MarketDailyEvidence: Sendable, Hashable {
    /// 实际返回数据的 Provider（.stooq 或 .alphaVantage）
    let providerID: DataProviderID
    /// 该 Provider 眼中的 symbol（如 "aapl.us" / "AAPL"）
    let providerSymbol: String
    /// 解析出的 ProviderRecord（kind = .dailyBar，已过滤近期窗口）
    let records: [ProviderRecord]
    /// 各候选的尝试记录（成功 + 失败都要留痕）
    let attempts: [String]
}

extension M2EvidenceEntry {
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()
}

/// M2 live gate 共享 evidence 源：串行抓取 + 缓存 + Provider 候选链。
///
/// actor 语义天然把并发抓取串行化；每个 case 只抓一次，四场景复用。
actor M2MarketEvidenceSource {

    static let shared = M2MarketEvidenceSource()

    // 天天基金 QDII 样本：513100（国泰纳斯达克100）2024 Q2 持仓含 AAPL。
    static let qdiiFundCode = "513100"
    // PIT 主样本仍是 110022（Q2 07-18 公告 + Q1 04-20 周六公告）。
    static let pitFundCode = "110022"

    /// 行情窗口（2026-08-21 二次修订）：随 now 滑动的近期窗口。
    ///
    /// 原固定 2024-07 窗口隐含依赖 Alpha Vantage `outputsize=full` 取历史——
    /// 2026-08-21 实测免费层 full 与 DAILY_ADJUSTED 均为 premium，date-range
    /// 参数被**静默忽略**（仍返回最新 100 条）；Stooq 持续反爬。免费候选链
    /// 实际只能覆盖最近 100 个交易日（≈140 日历日），窗口取 now-20d..now 稳落
    /// compact 覆盖内。场景 1 验证的是跨 Provider identity（同一标的经两个
    /// Provider 的 symbol 解析到同一 Listing），与行情期无关；持仓样本仍锚定
    /// 真实 2024 Q2 归档（见 M2LiveAcceptanceTests 头注释）。
    static func marketWindow(now: Date = .now) -> (from: Date, to: Date) {
        (from: now.addingTimeInterval(-20 * 24 * 60 * 60), to: now)
    }

    private var marketWindowDates: (from: Date, to: Date) {
        Self.marketWindow()
    }

    private var fundHoldings: [String: Result<ProviderRecord, Error>] = [:]
    private var marketDaily: Result<M2MarketDailyEvidence, Error>?
    private(set) var evidenceLog: [M2EvidenceEntry] = []

    private init() {}

    // MARK: - 天天基金历史持仓（每 fundCode+reportDate 只抓一次）

    func liveHoldingRecord(
        fundCode: String,
        reportDate: Date,
        ingestedAt: Date
    ) async throws -> ProviderRecord {
        let key = "\(fundCode)@\(M2Dates.dateText(reportDate))"
        // 缓存命中：真实抓取只做一次；按本次请求的 ingestedAt 重建 record
        // （ProviderRecord 无 setter，构造拷贝保持其余字段不变）。
        if let cached = fundHoldings[key], case .success(let fetched) = cached {
            return ProviderRecord(
                providerID: fetched.providerID,
                providerCode: fetched.providerCode,
                effectiveAt: fetched.effectiveAt,
                publishedAt: fetched.publishedAt,
                ingestedAt: ingestedAt,
                kind: fetched.kind,
                rawPayload: fetched.rawPayload,
                reliabilityClass: fetched.reliabilityClass,
                jurisdiction: fetched.jurisdiction
            )
        }
        if let cached = fundHoldings[key], case .failure(let error) = cached {
            throw error
        }
        let adapter = EastmoneyHistoricalHoldingProviderAdapter(
            fetcher: URLSessionResponseFetcher(),
            reportDate: reportDate,
            ingestedAt: { ingestedAt }
        )
        do {
            let records = try await adapter.fetch(
                code: ProviderCode(scheme: "fund_code", value: fundCode),
                from: reportDate,
                to: reportDate
            )
            guard let record = records.first else {
                let error = M2MarketEvidenceError.semanticMismatch(
                    detail: "天天基金 \(key) 归档无持仓记录"
                )
                fundHoldings[key] = .failure(error)
                throw error
            }
            fundHoldings[key] = .success(record)
            appendEvidence(
                providerID: "eastmoney",
                endpoint: "FundArchivesDatas.aspx + JJGG (fund \(fundCode), report \(key))",
                body: String(data: record.rawPayload, encoding: .utf8) ?? "",
                summary: "publishedAt=\(M2Dates.dateText(record.publishedAt)) "
                    + "ingestedAt=\(M2Dates.dateText(record.ingestedAt)) "
                    + "positions=\(positionCount(of: record))"
            )
            return record
        } catch {
            fundHoldings[key] = .failure(error)
            throw error
        }
    }

    // MARK: - 行情 Provider 候选链：Stooq primary → Alpha Vantage secondary

    /// 抓一份真实美股日线（AAPL，随 now 滑动的近期窗口，见 `marketWindow`）。
    /// Stooq challenge → .unavailable → 尝试 Alpha Vantage；两个都失败才抛
    /// allProvidersExhausted。绝不退回 fixture。
    static func fetchVerifiedDaily() async throws -> M2MarketDailyEvidence {
        try await fetchVerifiedDaily(symbol: "AAPL")
    }

    static func fetchVerifiedDaily(symbol: String) async throws -> M2MarketDailyEvidence {
        try await shared.loadMarketDaily(symbol: symbol)
    }

    private func loadMarketDaily(symbol: String) async throws -> M2MarketDailyEvidence {
        if let cached = marketDaily {
            return try cached.get()
        }
        var attempts: [String] = []

        // 1) Stooq primary（美股 CSV；无 key）
        do {
            let evidence = try await fetchFromStooq(symbol: symbol, attempts: &attempts)
            marketDaily = .success(evidence)
            return evidence
        } catch {
            attempts.append("stooq: \(classify(error))")
        }

        // 2) Alpha Vantage secondary（需真实 apikey；DATA006 降级路径）
        do {
            let evidence = try await fetchFromAlphaVantage(symbol: symbol, attempts: &attempts)
            marketDaily = .success(evidence)
            return evidence
        } catch {
            attempts.append("alpha-vantage: \(classify(error))")
        }

        let failure = M2MarketEvidenceError.allProvidersExhausted(details: attempts)
        marketDaily = .failure(failure)
        throw failure
    }

    private func fetchFromStooq(
        symbol: String,
        attempts: inout [String]
    ) async throws -> M2MarketDailyEvidence {
        let stooqSymbol = "\(symbol.lowercased()).us"
        let adapter = StooqProviderAdapter(fetcher: URLSessionResponseFetcher())
        let body: String
        let records: [ProviderRecord]
        do {
            body = try await URLSessionResponseFetcher().fetch(.stooqHistory(symbol: stooqSymbol))
            records = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: stooqSymbol),
                from: marketWindowDates.from,
                to: marketWindowDates.to
            )
        } catch let error as ProviderError {
            // challenge / 429 已被 URLSessionResponseFetcher 折叠为 .unavailable
            throw error
        }
        guard !records.isEmpty else {
            throw M2MarketEvidenceError.semanticMismatch(
                detail: "Stooq \(stooqSymbol) 返回 0 条近期日线"
            )
        }
        attempts.append("stooq: success (\(records.count) bars)")
        appendEvidence(
            providerID: "stooq",
            endpoint: "stooq.com/q/d/l/?s=\(stooqSymbol)&i=d",
            body: body,
            summary: "bars=\(records.count) window=recent-20d"
        )
        return M2MarketDailyEvidence(
            providerID: .stooq,
            providerSymbol: stooqSymbol,
            records: records,
            attempts: attempts
        )
    }

    private func fetchFromAlphaVantage(
        symbol: String,
        attempts: inout [String]
    ) async throws -> M2MarketDailyEvidence {
        guard let apiKey = Self.alphaVantageAPIKey(), !apiKey.isEmpty else {
            throw M2MarketEvidenceError.keyMissing(
                detail: "Alpha Vantage apikey 未配置（真实 key 见 Keychain/环境变量，不进仓库）"
            )
        }
        let settings = AlphaVantageSettings(enabled: true, apiKey: apiKey)
        let adapter = AlphaVantageProviderAdapter(client: AlphaVantageClient(), settings: settings)
        let records: [ProviderRecord]
        do {
            records = try await adapter.fetch(
                code: ProviderCode(scheme: "stock_symbol", value: symbol),
                from: marketWindowDates.from,
                to: marketWindowDates.to
            )
        } catch let error as ProviderError {
            // AlphaVantageProviderAdapter 已把 serviceMessage/额度映射为
            // .quotaExhausted / .schemaMismatch / .unavailable
            throw error
        }
        guard !records.isEmpty else {
            throw M2MarketEvidenceError.semanticMismatch(
                detail: "Alpha Vantage \(symbol) 返回 0 条近期日线（免费层只覆盖最近 100 个交易日；"
                    + "full/date-range 均 premium，历史窗口需 Stooq 恢复或引入第三候选源）"
            )
        }
        attempts.append("alpha-vantage: success (\(records.count) bars)")
        appendEvidence(
            providerID: "alpha-vantage",
            endpoint: "alphavantage.co TIME_SERIES_DAILY symbol=\(symbol)",
            body: records.map { "\($0.effectiveAt)" }.joined(separator: ","),
            summary: "bars=\(records.count) window=recent-20d"
        )
        return M2MarketDailyEvidence(
            providerID: .alphaVantage,
            providerSymbol: symbol,
            records: records,
            attempts: attempts
        )
    }

    // MARK: - Evidence manifest

    private func appendEvidence(
        providerID: String,
        endpoint: String,
        body: String,
        summary: String
    ) {
        evidenceLog.append(M2EvidenceEntry(
            providerID: providerID,
            endpoint: endpoint,
            fetchedAt: Date(),
            rawSHA256: M2EvidenceEntry.sha256Hex(body),
            recordSummary: summary
        ))
    }

    /// 输出 evidence manifest（M2 放行证据）。
    func manifestText() -> String {
        evidenceLog.map { entry in
            let fetched = M2EvidenceEntry.timestampFormatter.string(from: entry.fetchedAt)
            return "[\(entry.providerID)] \(entry.endpoint) fetchedAt=\(fetched) "
                + "sha256=\(entry.rawSHA256.prefix(16))… \(entry.recordSummary)"
        }
        .joined(separator: "\n")
    }

    // MARK: - 错误分类（live gate 失败原因保留）

    nonisolated static func classify(_ error: Error) -> String {
        if case let M2MarketEvidenceError.transportUnavailable(detail) = error {
            return "transportUnavailable(\(detail))"
        }
        if case let M2MarketEvidenceError.quotaExhausted(detail) = error {
            return "quotaExhausted(\(detail))"
        }
        if case let M2MarketEvidenceError.semanticMismatch(detail) = error {
            return "semanticMismatch(\(detail))"
        }
        if case let M2MarketEvidenceError.keyMissing(detail) = error {
            return "keyMissing(\(detail))"
        }
        if case let ProviderError.unavailable(_, underlying) = error {
            return "transportUnavailable(\(underlying))"
        }
        if case ProviderError.quotaExhausted = error {
            return "quotaExhausted(alpha-vantage daily budget)"
        }
        if case let ProviderError.schemaMismatch(_, detail) = error {
            return "semanticMismatch(\(detail))"
        }
        if case let M2MarketEvidenceError.allProvidersExhausted(details) = error {
            return "allProvidersExhausted(\(details.joined(separator: "; ")))"
        }
        return "unclassified(\(error))"
    }

    private func classify(_ error: Error) -> String {
        Self.classify(error)
    }

    // MARK: - Alpha Vantage key 发现（Keychain → 环境变量；不进仓库）

    nonisolated static func alphaVantageAPIKey() -> String? {
        // 1) App 自己的 Keychain account（与 TrendAnalysisStore 同一存储）
        if let key = KeychainHelper.get(account: KeychainHelper.Account.alphaVantageKey),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key
        }
        // 2) CI / 本机环境变量
        for name in ["ALPHAVANTAGE_API_KEY", "ALPHA_VANTAGE_API_KEY"] {
            if let value = ProcessInfo.processInfo.environment[name],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func positionCount(of record: ProviderRecord) -> Int {
        (try? JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload))?
            .positions.count ?? -1
    }
}

// MARK: - M2 日期工具（上海日界）

enum M2Dates {
    static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        shanghaiCalendar.startOfDay(
            for: shanghaiCalendar.date(from: DateComponents(year: year, month: month, day: day))!
        )
    }

    static func dateText(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
