import Foundation

// MARK: - ProviderHealth（ADR-DATA006 §Decision 2 监控，PROV-8 用）
//
// DataQuality / ProviderReliabilityClass 已在 DOM-5 定义。
// 这里补充 ProviderHealth：每个 Provider 持续跟踪成功/失败比、剩余 quota、
// 风控/限流、schema 漂移，供 SYNC-7 三档降级决策用。

/// 单个 Provider 的健康状态快照（ADR-DATA006 §Decision 2）。
///
/// 由 ProviderHealthMonitor（Epic 4 PROV-8）维护，SYNC-7 降级路径读取。
/// 这是运行时状态，不入 GRDB（不持久化历史 health 记录，只保留当前 + 最近窗口）。
struct ProviderHealth: Sendable, Codable, Hashable {
    let providerID: DataProviderID
    /// 该 Provider 的可靠性档位（ADR-DATA006 四档，固定）
    let reliabilityClass: ProviderReliabilityClass
    /// 当前状态
    let status: ProviderStatus
    /// 最近 N 次调用统计
    let recentStatistics: RecentStatistics
    /// 剩余 quota（如 Alpha Vantage 25/天），无配额限制的 Provider 为 nil
    let remainingQuota: QuotaSnapshot?
    /// 最近一次 schema 漂移时间（Provider 改字段时记录，提醒维护者）
    let lastSchemaDrift: Date?
    /// 状态更新时间
    let updatedAt: Date

    init(
        providerID: DataProviderID,
        reliabilityClass: ProviderReliabilityClass,
        status: ProviderStatus,
        recentStatistics: RecentStatistics,
        remainingQuota: QuotaSnapshot? = nil,
        lastSchemaDrift: Date? = nil,
        updatedAt: Date
    ) {
        self.providerID = providerID
        self.reliabilityClass = reliabilityClass
        self.status = status
        self.recentStatistics = recentStatistics
        self.remainingQuota = remainingQuota
        self.lastSchemaDrift = lastSchemaDrift
        self.updatedAt = updatedAt
    }
}

/// Provider 当前运行状态（ADR-DATA006 §Decision 3 三档降级）。
enum ProviderStatus: String, Sendable, Codable, Hashable {
    /// 健康，可正常使用
    case healthy = "HEALTHY"
    /// 降级中（quota 接近耗尽 / 偶发失败率上升），仍可用但优先 secondary
    case degraded = "DEGRADED"
    /// quota 耗尽或持续失败，本次不可用，走 local 兜底或 secondary
    case unavailable = "UNAVAILABLE"

    /// 是否仍可调用（degraded 仍可，unavailable 不可）。
    var isCallable: Bool {
        switch self {
        case .healthy, .degraded: return true
        case .unavailable: return false
        }
    }
}

/// 最近 N 次调用统计（用于判断 degraded 阈值）。
struct RecentStatistics: Sendable, Codable, Hashable {
    let totalCalls: Int
    let successCount: Int
    let failureCount: Int
    let rateLimitedCount: Int   // 429 / 风控次数
    /// 成功率（0-1），total=0 时返回 nil
    var successRate: Double? {
        guard totalCalls > 0 else { return nil }
        return Double(successCount) / Double(totalCalls)
    }

    init(totalCalls: Int, successCount: Int, failureCount: Int, rateLimitedCount: Int) {
        self.totalCalls = totalCalls
        self.successCount = successCount
        self.failureCount = failureCount
        self.rateLimitedCount = rateLimitedCount
    }
}

/// Provider 配额快照（如 Alpha Vantage 25/天）。
struct QuotaSnapshot: Sendable, Codable, Hashable {
    /// 配额周期（daily / monthly）
    let period: QuotaPeriod
    /// 周期内总额度
    let total: Int
    /// 已用
    let used: Int
    /// 周期重置时间
    let resetsAt: Date
    /// 剩余 = total - used
    var remaining: Int { max(0, total - used) }
    /// 剩余比例（0-1），total=0 时 nil
    var remainingRatio: Double? {
        guard total > 0 else { return nil }
        return Double(remaining) / Double(total)
    }

    enum QuotaPeriod: String, Sendable, Codable, Hashable {
        case daily = "DAILY"
        case monthly = "MONTHLY"
        case hourly = "HOURLY"
    }
}

// MARK: - DataQuality 补充方法（与 ProviderHealth 联动）
//
// DOM-5 已定义 DataQuality struct，这里加便捷构造与判断方法。

extension DataQuality {
    /// 基于 Provider 的 reliabilityClass + providerID 构造（REPO-2b：注入来源 Provider）。
    /// isRevised / isSuperseded 默认 false。
    static func from(_ cls: ProviderReliabilityClass, providerID: DataProviderID) -> DataQuality {
        DataQuality(providerReliability: cls, sourceProviderID: providerID)
    }

    /// 该观测是否可信（用于业务层决定是否消费）。
    /// undocumentedPublicEndpoint 的观测标记为「需 secondary 验证」。
    var requiresSecondaryValidation: Bool {
        providerReliability == .undocumentedPublicEndpoint
    }
}
