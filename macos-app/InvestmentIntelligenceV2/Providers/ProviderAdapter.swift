import Foundation

// MARK: - ProviderRecord（REPO-5a 拥有；REPO-6/7 Adapter 产、ObservationFactory 消费，ADR-DATA003 raw + adjustment）
//
// Provider Adapter 只产 ProviderRecord，不写 Canonical。
// ProviderRecord = raw 字段 + Provider 给的时间戳 + Provider 原始代码。
// Canonical 化在 Pipeline commit 路径上完成（TemporalNormalizer →
// IdentityResolver → SchemaValidator → Canonical Commit）。

/// Provider 抓取的单条原始记录。
///
/// 不含 availableAt（由 TemporalNormalizer 基于 AvailabilityPolicy 推导）。
/// 不含 Canonical ID（由 IdentityResolver 从 providerCode 解析）。
/// 只含 Provider 视角的 raw 数据 + 时间戳 + 原始代码。
struct ProviderRecord: Sendable, Codable, Hashable {
    /// 哪个 Provider 产的
    let providerID: DataProviderID
    /// Provider 原始代码（如 "110022"、"600519"）+ scheme（如 "fund_code"、"stock_symbol"）
    let providerCode: ProviderCode
    /// Provider 给的时间戳：事件时间 + 公布时间
    let effectiveAt: Date
    let publishedAt: Date
    /// 本系统抓取入库时间（ADR-DATA002 §4：与 availableAt 不建立全序，
    /// Provider 故障时可能远晚于客观可知时间）
    let ingestedAt: Date
    /// 数据类型（决定走哪个 AvailabilityPolicy）
    let kind: ProviderRecordKind
    /// raw payload（Provider 原始字段，JSON 编码）
    /// - DailyBar：OHLCV + adjustmentFactor + currency
    /// - NAV：unitNAV + accumulatedNAV + cumulativeDividend + currency
    /// - FundHolding：positions[]（每个含 providerCode + weight + shares + marketValue）
    /// - Macro：value + unit + frequency + seasonalAdj + basePeriod
    /// - CorporateAction：kind + exDate + recordDate + payDate + ratio + currency
    let rawPayload: Data
    /// 该 Provider 此条记录的可靠性档位（ADR-DATA006）
    let reliabilityClass: ProviderReliabilityClass
    /// 标的法域（用于 AvailabilityPolicy 推导交易日历；Listing 类从 exchange 推导，
    /// 基金类默认 CN）
    let jurisdiction: Jurisdiction

    init(
        providerID: DataProviderID,
        providerCode: ProviderCode,
        effectiveAt: Date,
        publishedAt: Date,
        ingestedAt: Date,
        kind: ProviderRecordKind,
        rawPayload: Data,
        reliabilityClass: ProviderReliabilityClass,
        jurisdiction: Jurisdiction
    ) {
        self.providerID = providerID
        self.providerCode = providerCode
        self.effectiveAt = effectiveAt
        self.publishedAt = publishedAt
        self.ingestedAt = ingestedAt
        self.kind = kind
        self.rawPayload = rawPayload
        self.reliabilityClass = reliabilityClass
        self.jurisdiction = jurisdiction
    }
}

/// Provider 原始代码标识。
struct ProviderCode: Sendable, Codable, Hashable {
    /// 代码体系（如 "fund_code"、"stock_symbol"、"prodCode"）
    let scheme: String
    /// 实际值（如 "110022"、"600519"、"LONG_WIN"）
    let value: String
}

/// Provider 记录的数据类型（决定走哪个 AvailabilityPolicy + 哪个 Canonical 化路径）。
enum ProviderRecordKind: String, Sendable, Codable, Hashable {
    case dailyBar = "DAILY_BAR"
    case navObservation = "NAV_OBSERVATION"
    case fundHoldingSnapshot = "FUND_HOLDING_SNAPSHOT"
    case macroObservation = "MACRO_OBSERVATION"
    case corporateAction = "CORPORATE_ACTION"
}

// MARK: - Provider Adapter 协议（REPO-6/7）
//
// Adapter 只负责「把 Provider 协议解析成 ProviderRecord」。
// 不做业务转换（复权 / 单位换算 / 归一化）——那在 Canonical Pipeline。
// 这样 Adapter 可独立测试、独立替换（ADR-DATA003 §Decision 5）。

/// Provider Adapter：从外部数据源抓取 → ProviderRecord 流。
///
/// 实现类：
/// - QiemanProviderAdapter（REPO-6）：调用现有 QiemanPlatformNativeClient
/// - EastmoneyProviderAdapter（REPO-7）：调用现有天天基金抓取逻辑
/// - StooqProviderAdapter / SECProviderAdapter / FREDProviderAdapter / ...（Epic 4）
///
/// 真实 Adapter 调用现有 client 取数，**不修改现有 client**。
/// 桩实现（StubXXXProviderAdapter）用于 M2 阶段离线测试。
protocol ProviderAdapter: Sendable {
    /// Provider 标识
    var providerID: DataProviderID { get }
    /// 该 Provider 的可靠性档位（ADR-DATA006）
    var reliabilityClass: ProviderReliabilityClass { get }

    /// 抓取指定 Provider 代码 + 时间段的记录。
    /// 返回 ProviderRecord 流（可能跨多次网络调用）。
    /// 失败时抛 ProviderError（调用方按三档降级处理，ADR-DATA006 §Decision 3）。
    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord]

    /// 抓取 + 诊断（审查 P2：让生产调用方能观察部分数据丢失，如 LSJZ 异常行计数）。
    /// 默认实现调 fetch 返回 `.unsupported` 诊断；EastmoneyProviderAdapter 等真实 Adapter 覆写。
    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult
}

extension ProviderAdapter {
    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        let records = try await fetch(code: code, from: from, to: to)
        // 默认实现不产诊断：completeness = .unsupported，totalDropped == 0
        // **不代表**「确认零丢弃」，只代表该 Adapter 未实现诊断出口（审查 P2）。
        return ProviderFetchResult(
            records: records,
            diagnostics: ProviderFetchDiagnostics(completeness: .unsupported)
        )
    }
}

/// Provider 抓取结果（records + 诊断）。
struct ProviderFetchResult: Sendable {
    let records: [ProviderRecord]
    let diagnostics: ProviderFetchDiagnostics
}

/// 诊断覆盖度（审查 P2：区分「确认零丢弃」与「Adapter 未实现诊断」）。
enum DiagnosticCompleteness: Sendable, Equatable {
    /// Adapter 实现了诊断出口：totalDropped 可信，0 即确认零丢弃。
    case complete
    /// Adapter 走默认实现，未覆盖诊断：totalDropped 恒为 0 但不代表无丢弃。
    /// ProviderHealth 不应据此判定该 Provider「无数据丢失」。
    case unsupported
}

/// Provider 抓取诊断（审查 P2：部分数据丢失的可审计出口）。
/// 生产调用方（Sync / Pipeline）可据此更新 ProviderHealth 或决定降级。
struct ProviderFetchDiagnostics: Sendable, Equatable {
    /// 诊断覆盖度：真实 Adapter 标 .complete，桩/默认实现标 .unsupported。
    /// 调用方（ProviderHealth）必须先看此字段再决定是否信任 totalDropped。
    var completeness: DiagnosticCompleteness
    /// 解析过程中因格式异常被丢弃的行数（按上游来源分桶）
    var droppedMalformedBySource: [String: Int] = [:]
    /// 合并阶段因日期未对齐等被丢弃的条目数
    var droppedOnMerge: Int = 0

    /// 总丢弃数（仅当 completeness == .complete 时可信；用于快速判断是否触发告警阈值）。
    var totalDropped: Int {
        droppedMalformedBySource.values.reduce(0, +) + droppedOnMerge
    }

    /// - Parameters:
    ///   - completeness: 真实 Adapter 默认 .complete（含丢弃计数即确认覆盖）；
    ///     默认 extension 构造时显式传 .unsupported。
    init(
        completeness: DiagnosticCompleteness = .complete,
        droppedMalformedBySource: [String: Int] = [:],
        droppedOnMerge: Int = 0
    ) {
        self.completeness = completeness
        self.droppedMalformedBySource = droppedMalformedBySource
        self.droppedOnMerge = droppedOnMerge
    }
}

/// Provider 抓取错误。
enum ProviderError: Error, Equatable, Sendable {
    /// Provider 不可用（网络 / 服务端）
    case unavailable(providerID: DataProviderID, underlying: String)
    /// 配额耗尽（如 Alpha Vantage 25/天）
    case quotaExhausted(providerID: DataProviderID)
    /// Provider 返回的数据无法解析（schema 漂移）
    case schemaMismatch(providerID: DataProviderID, detail: String)
    /// 标的不在 Provider 覆盖范围
    case notFound(code: ProviderCode)
}

// MARK: - REPO-6：且慢 Provider Adapter（桩实现）
//
// 真实实现调用 QiemanPlatformNativeClient（不修改现有 client）。
// 桩实现用于 M2 阶段离线验证 identity + PIT 语义。

/// 且慢平台 Provider Adapter（REPO-6）。
///
/// 生产实现：调用 `QiemanPlatformNativeClient` 取基金 NAV / 持仓 → ProviderRecord。
/// 此处提供桩实现（离线返回固定数据），真实 client 接入在 Epic 4 + 集成测试。
struct QiemanProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .qieman
    let reliabilityClass: ProviderReliabilityClass = .undocumentedPublicEndpoint

    /// 桩数据（生产实现删除，改调真实 client）。
    let stubRecords: [ProviderRecord]

    init(stubRecords: [ProviderRecord] = []) {
        self.stubRecords = stubRecords
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        // 桩：返回符合时间段的 stub 数据
        return stubRecords.filter { record in
            record.providerCode == code
                && record.effectiveAt >= from
                && record.effectiveAt <= to
        }
    }
}

// MARK: - REPO-7：天天基金 Provider Adapter（桩实现）

/// 天天基金 Provider Adapter（REPO-7）。
///
/// 真实解析链：通过 fetcher 取天天基金 pingzhongdata / lsjz 真实响应，
/// 用 EastmoneyResponseParser 解析为 ProviderRecord 流。
///
/// 生产用 `URLSessionResponseFetcher`（直接 GET 上游 URL，复用现有 client 的
/// 上游地址）；测试注入 `StaticResponseFetcher`（返回预录真实响应）。
/// 不依赖现有 QiemanPlatformNativeClient 的公共 API（其 NAV 公共接口字段有损），
/// 但解析格式与现有 client 内部一致（见 QiemanPlatformFundQuoteFallbackTests inline mock）。
struct EastmoneyProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .eastmoney
    let reliabilityClass: ProviderReliabilityClass = .communityAggregated

    private let parser = EastmoneyResponseParser()
    private let fetcher: any ResponseFetcher
    private let ingestedAt: @Sendable () -> Date

    init(fetcher: any ResponseFetcher, ingestedAt: @escaping @Sendable () -> Date = { .now }) {
        self.fetcher = fetcher
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        // fetch 是 fetchWithDiagnostics 的便捷包装（丢弃诊断）
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    /// 真实主实现：fetch + 诊断（审查 P2：透传 LSJZ droppedMalformedCount）。
    func fetchWithDiagnostics(
        code: ProviderCode, from: Date, to: Date
    ) async throws -> ProviderFetchResult {
        guard code.scheme == "fund_code" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }
        // 取 pingzhongdata（NAV 历史）+ lsjz（近期官方净值）
        let pingzhongBody = try await fetcher.fetch(.pingzhongdata(fundCode: code.value))
        let lsjzBody = try await fetcher.fetch(.lsjz(fundCode: code.value))

        let pingzhongHistory = try parser.parsePingzhongdata(pingzhongBody, fundCode: code.value)
        let lsjzHistory = try parser.parseLSJZ(lsjzBody, fundCode: code.value)

        // 合并 + 去重。entry.date 已在 parser 归一化到 Asia/Shanghai 交易日界，
        // 所以 pingzhongdata 与 LSJZ 的同一交易日 Date 完全一致。
        //
        // 审查 P1：字段级合并，不能整条丢弃。
        // 先用 pingzhongdata（历史长序列）seed，LSJZ（近期官方净值）覆盖同日：
        //   - LSJZ 的 unitNAV/changePct 是「近期官方」，作为权威覆盖
        //   - accumulatedNAV 优先取 LSJZ 的 LJJZ（若 LSJZ 无则保留 pingzhongdata 的）
        // 这样 pingzhongdata 缺 accumulatedNAV 而 LSJZ 有 LJJZ 时，真实累计净值不丢失。
        var mergedByDay: [Date: EastmoneyNAVHistory.Entry] = [:]
        for e in pingzhongHistory.entries { mergedByDay[e.date] = e }
        for official in lsjzHistory.entries {
            if let historical = mergedByDay[official.date] {
                mergedByDay[official.date] = EastmoneyNAVHistory.Entry(
                    date: official.date,
                    unitNAV: official.unitNAV,
                    changePct: official.changePct ?? historical.changePct,
                    accumulatedNAV: official.accumulatedNAV ?? historical.accumulatedNAV
                )
            } else {
                mergedByDay[official.date] = official
            }
        }

        // 审查 P2：保留两源的 droppedMalformedCount 透传到诊断出口，
        // 不在重新构造 merged 时丢失（之前默认 0 让生产链路无法审计部分丢失）。
        let merged = EastmoneyNAVHistory(
            fundCode: code.value,
            fundName: pingzhongHistory.fundName,
            entries: mergedByDay.values.sorted { $0.date < $1.date },
            droppedMalformedCount: pingzhongHistory.droppedMalformedCount + lsjzHistory.droppedMalformedCount
        )
        let allRecords = parser.toProviderRecords(
            merged,
            providerID: providerID,
            reliabilityClass: reliabilityClass,
            jurisdiction: .chinaMainland,
            ingestedAt: ingestedAt()
        )
        let filtered = allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
        let diagnostics = ProviderFetchDiagnostics(droppedMalformedBySource: [
            "pingzhongdata": pingzhongHistory.droppedMalformedCount,
            "lsjz": lsjzHistory.droppedMalformedCount
        ])
        return ProviderFetchResult(records: filtered, diagnostics: diagnostics)
    }
}

// MARK: - ResponseFetcher（生产/测试切换）

/// Provider 上游响应获取器（解耦网络层，便于测试注入预录响应）。
protocol ResponseFetcher: Sendable {
    func fetch(_ endpoint: ProviderEndpoint) async throws -> String
}

/// Provider 上游端点（决定 URL 与解析路径）。
enum ProviderEndpoint: Sendable, Hashable {
    /// 天天基金 pingzhongdata：`fund.eastmoney.com/pingzhongdata/{code}.js`
    case pingzhongdata(fundCode: String)
    /// 天天基金 lsjz：`api.fund.eastmoney.com/f10/lsjz?fundCode=...`
    case lsjz(fundCode: String)
}

/// 静态响应 fetcher（测试用：注入预录真实响应文本）。
struct StaticResponseFetcher: ResponseFetcher {
    let responses: [ProviderEndpoint: String]

    init(_ responses: [ProviderEndpoint: String]) {
        self.responses = responses
    }

    func fetch(_ endpoint: ProviderEndpoint) async throws -> String {
        guard let body = responses[endpoint] else {
            throw ProviderError.notFound(code: ProviderCode(scheme: "endpoint", value: String(describing: endpoint)))
        }
        return body
    }
}

/// URLSession fetcher（生产用：构造真实上游 URL，GET 取响应文本）。
/// Epic 4 会补全 URL 构造 + Referer header + 超时；此处占位供集成测试。
struct URLSessionResponseFetcher: ResponseFetcher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ endpoint: ProviderEndpoint) async throws -> String {
        let urlString: String
        switch endpoint {
        case .pingzhongdata(let code):
            urlString = "https://fund.eastmoney.com/pingzhongdata/\(code).js"
        case .lsjz(let code):
            urlString = "https://api.fund.eastmoney.com/f10/lsjz?fundCode=\(code)&pageIndex=1&pageSize=20"
        }
        guard let url = URL(string: urlString) else {
            throw ProviderError.unavailable(providerID: .eastmoney, underlying: "bad url")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ProviderError.unavailable(providerID: .eastmoney, underlying: "http error")
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.unavailable(providerID: .eastmoney, underlying: "\(error)")
        }
    }
}
