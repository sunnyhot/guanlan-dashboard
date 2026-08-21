import Foundation

// MARK: - Tavily 月额度感知（PROV-7，ADR-DATA006 §Decision 5）
//
// Tavily 在 V2 中的定位是 Research 子系统（Epic 11 RES-3）的 web 搜索工具，
// 不产 ProviderRecord（搜索结果是 Evidence，不是 5+1 个 ProviderRecordKind）。
// 本文件交付 PROV-7 的验收面：月额度感知——
// 1. `TavilySearchClientError` → `ProviderError` 映射（401→auth 不可用、
//    432/433→quotaExhausted 月额度耗尽、429→rateLimited 瞬时频控独立冷却）
// 2. `TavilyQuotaPolicy`：免费层 1000 credits/月，额度感知的三档决策
//    （available / lowQuota 保守 / exhausted 降级「无 web 搜索」模式，DATA006 §5）
// 3. 与 ProviderHealthMonitor 的对接：Research 调用层记录失败/用量，
//    monitor 按 monthly QuotaConfig 聚合，SYNC-7 读 health 决策降级
//
// 复用现有 `TavilySearchClient`（Core/Clients/）取数——URL/鉴权/HTTP/解码
// 错误都已封装，本层只做额度与错误语义映射，不重复实现客户端。

/// Tavily 搜索对 Research 子系统的可用性档位。
enum TavilySearchAvailability: Sendable, Hashable {
    /// 额度充足，正常搜索
    case available
    /// 额度接近耗尽（剩 < lowQuotaRemainingThreshold）——仍可用，调用方应保守
    /// （减少搜索次数 / 收紧 query），Research 层自行决定策略
    case lowQuota(remaining: Int)
    /// 月额度用尽 → Research 降级「无 web 搜索」模式（DATA006 §Decision 5），
    /// 不阻塞其余研究工具
    case exhausted(resetsAt: Date)
    /// Provider 本身不可用（未配置 / 认证失败 / 网络故障）
    case providerUnavailable(detail: String)
}

/// Tavily 月额度策略（版本化阈值，PROV-7）。
struct TavilyQuotaPolicy: Sendable, Codable, Hashable {
    /// 每月 credits 总额（Tavily 免费层 1000）
    let monthlyCredits: Int
    /// 剩余低于此值 → lowQuota（保守档）
    let lowQuotaRemainingThreshold: Int

    /// 免费层默认策略（2026-08 PROV-7 签收基线）。
    static let freeTier = TavilyQuotaPolicy(
        monthlyCredits: 1000,
        lowQuotaRemainingThreshold: 100
    )

    /// 额度决策（纯函数，Research 调用前判断）。
    ///
    /// - Parameters:
    ///   - used: 本周期已用 credits（由调用方记账，Tavily 响应不带余量）
    ///   - resetsAt: 周期重置时间（月度，UTC 次月 1 日，见 ProviderHealthMonitor.nextReset）
    ///   - now: 当前时间
    func availability(used: Int, resetsAt: Date, now: Date) -> TavilySearchAvailability {
        // 周期已滚动：额度视作恢复（调用方应同时重置记账，这里不猜已用量）
        if now >= resetsAt {
            return .available
        }
        let remaining = max(0, monthlyCredits - used)
        if remaining == 0 {
            return .exhausted(resetsAt: resetsAt)
        }
        if remaining < lowQuotaRemainingThreshold {
            return .lowQuota(remaining: remaining)
        }
        return .available
    }

    /// 注册到 ProviderHealthMonitor 的 monthly quota 配置（SYNC-7 聚合口径）。
    var quotaConfig: QuotaConfig {
        QuotaConfig(period: .monthly, total: monthlyCredits)
    }
}

/// `TavilySearchClientError` → `ProviderError` 映射（ADR-DATA006 三档降级）。
///
/// 三种「被拒」语义不同：**432/433 是套餐/月额度耗尽**（持久，周期重置才恢复）
/// → quotaExhausted（ProviderHealthMonitor 会推满月 quota）；**429 是请求频率限流**
/// （transient）→ rateLimited（独立冷却、自动恢复，既不推满月 quota，也避免连续
/// 频控累计成 unavailable 的无恢复路径，审查 P2）；**401 是认证失败** → unavailable。
enum TavilyProviderErrorMapper {

    static func map(_ error: TavilySearchClientError) -> ProviderError {
        switch error {
        case .missingAPIKey:
            // 未配置属本地配置缺失，不是 Provider 故障——unavailable 语义最贴近
            // （调用方提示配置），不冒充 quota
            return .unavailable(providerID: .tavily, underlying: "api key not configured")
        case .requestFailed(let statusCode, let detail):
            if statusCode == 401 {
                return .unavailable(providerID: .tavily, underlying: "auth failed\(detail.map { " \($0)" } ?? "")")
            }
            if statusCode == 432 || statusCode == 433 {
                return .quotaExhausted(providerID: .tavily)
            }
            if statusCode == 429 {
                return .rateLimited(providerID: .tavily, retryAfter: nil)
            }
            // 其它（含 5xx）：服务端问题 → unavailable
            return .unavailable(providerID: .tavily, underlying: "http \(statusCode)")
        case .invalidResponse:
            return .schemaMismatch(providerID: .tavily, detail: error.errorDescription ?? "\(error)")
        case .timedOut:
            return .unavailable(providerID: .tavily, underlying: "timed out")
        }
    }
}
