import Foundation

// MARK: - ProviderRecord（PROV-1 / REPO-6/7 共用，ADR-DATA003 raw + adjustment）
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
    private let ingestedAt: () -> Date

    init(fetcher: any ResponseFetcher, ingestedAt: @escaping () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        guard code.scheme == "fund_code" else {
            // 非 fund_code scheme 留 Epic 4（stock_symbol 走不同上游）
            return []
        }
        // 取 pingzhongdata（NAV 历史）+ lsjz（近期官方净值）
        let pingzhongBody = try await fetcher.fetch(.pingzhongdata(fundCode: code.value))
        let lsjzBody = try await fetcher.fetch(.lsjz(fundCode: code.value))

        let pingzhongHistory = try parser.parsePingzhongdata(pingzhongBody, fundCode: code.value)
        let lsjzHistory = try parser.parseLSJZ(lsjzBody, fundCode: code.value)

        // 合并 + 去重（lsjz 与 pingzhongdata 末段重叠，按 date 取并集，pingzhongdata 优先）
        var mergedByDate: [Date: EastmoneyNAVHistory.Entry] = [:]
        for e in pingzhongHistory.entries { mergedByDate[e.date] = e }
        for e in lsjzHistory.entries where mergedByDate[e.date] == nil { mergedByDate[e.date] = e }

        let merged = EastmoneyNAVHistory(
            fundCode: code.value,
            fundName: pingzhongHistory.fundName,
            entries: mergedByDate.values.sorted { $0.date < $1.date }
        )
        let allRecords = parser.toProviderRecords(
            merged,
            providerID: providerID,
            reliabilityClass: reliabilityClass,
            jurisdiction: .chinaMainland,
            ingestedAt: ingestedAt()
        )
        // 时间段过滤
        return allRecords.filter { $0.effectiveAt >= from && $0.effectiveAt <= to }
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
