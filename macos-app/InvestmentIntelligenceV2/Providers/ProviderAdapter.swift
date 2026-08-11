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
    /// Provider 给的时间戳（事件时间 + 公布时间；ingestedAt 在抓取时填）
    let effectiveAt: Date
    let publishedAt: Date
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
        kind: ProviderRecordKind,
        rawPayload: Data,
        reliabilityClass: ProviderReliabilityClass,
        jurisdiction: Jurisdiction
    ) {
        self.providerID = providerID
        self.providerCode = providerCode
        self.effectiveAt = effectiveAt
        self.publishedAt = publishedAt
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
/// 生产实现：调用现有天天基金抓取逻辑（基金 NAV / 持仓披露）→ ProviderRecord。
/// 此处提供桩实现，真实抓取在 Epic 4 + 集成测试。
struct EastmoneyProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .eastmoney
    let reliabilityClass: ProviderReliabilityClass = .communityAggregated

    let stubRecords: [ProviderRecord]

    init(stubRecords: [ProviderRecord] = []) {
        self.stubRecords = stubRecords
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        return stubRecords.filter { record in
            record.providerCode == code
                && record.effectiveAt >= from
                && record.effectiveAt <= to
        }
    }
}
