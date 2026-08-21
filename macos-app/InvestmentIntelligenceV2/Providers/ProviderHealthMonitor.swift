import Foundation

// MARK: - ProviderHealthMonitor（PROV-8，ADR-DATA006 §Decision 2 监控）
//
// 每个 Provider 持续跟踪成功/失败比、剩余 quota、风控/限流次数、schema 漂移，
// 输出 ProviderHealth 快照供 SYNC-7 三档降级决策。运行时状态，不入 GRDB
// （与 ProviderHealth 注释一致：只保留当前 + 最近窗口，不持久化历史 health）。
//
// 阈值是版本化 HealthDegradationPolicy（DOM-7 AvailabilityPolicy 同款形态）：
// 数据化的 policy（id/version/规则），不是散落在方法体里的魔法数，可审计、
// 修订走新 version。调用方（Adapter / Sync）在成功/失败/quota 变化时上报，
// monitor 只做聚合与状态推导，不发网络请求。

/// Provider 健康降级阈值（版本化，PROV-8）。
///
/// 状态推导规则（按优先级，先命中先停）：
/// 1. quota 剩余 = 0 → unavailable
/// 2. 连续失败 ≥ unavailableConsecutiveFailures → unavailable（持续故障）
/// 3. rateLimited 冷却期内 → degraded（瞬时限流；冷却过期自动恢复，不累计
///    连续失败——避免连续频控把 Provider 拖进无恢复路径的 unavailable）
/// 4. quota 剩余比例 < degradedQuotaRemainingRatio → degraded（额度接近耗尽）
/// 5. 连续失败 ≥ degradedConsecutiveFailures → degraded（偶发失败容忍上限）
/// 6. 窗口成功率 < degradedSuccessRate 且样本 ≥ minimumCallsForRateRule → degraded
/// 7. 其余 → healthy
struct HealthDegradationPolicy: Sendable, Codable, Hashable {
    let policyID: String
    let version: String
    /// 最近 N 次调用统计窗口（RecentStatistics 由此窗口聚合）
    let statisticsWindow: Int
    /// 成功率规则的最小样本数（不足时不按成功率判 degraded——小样本失败率无意义）
    let minimumCallsForRateRule: Int
    /// 窗口成功率低于此值 → degraded
    let degradedSuccessRate: Double
    /// 连续失败达到此数 → degraded
    let degradedConsecutiveFailures: Int
    /// 连续失败达到此数 → unavailable
    let unavailableConsecutiveFailures: Int
    /// quota 剩余比例低于此值 → degraded
    let degradedQuotaRemainingRatio: Double
    /// rateLimited 的默认冷却时长（上游未给 retryAfter 时）
    let defaultRateLimitCooldownSeconds: TimeInterval

    /// V1 保守规则集（2026-08 PROV-8 签收基线）。
    static let v1 = HealthDegradationPolicy(
        policyID: "provider_health_degradation",
        version: "v1",
        statisticsWindow: 20,
        minimumCallsForRateRule: 5,
        degradedSuccessRate: 0.5,
        degradedConsecutiveFailures: 2,
        unavailableConsecutiveFailures: 5,
        degradedQuotaRemainingRatio: 0.2,
        defaultRateLimitCooldownSeconds: 60
    )
}

/// quota 配置（注册时声明，如 Alpha Vantage 25/天、Tavily 月度 credits）。
struct QuotaConfig: Sendable, Codable, Hashable {
    let period: QuotaSnapshot.QuotaPeriod
    let total: Int

    init(period: QuotaSnapshot.QuotaPeriod, total: Int) {
        self.period = period
        self.total = total
    }
}

/// Provider 健康监控器（PROV-8）。
///
/// 用法（生产调用方 = Adapter 包装层 / Epic 6 Sync）：
/// 1. 启动时 `register` 声明每个 Provider 的 reliabilityClass + 可选 quota
///    （ADR-DATA006 PR checklist：新增 Provider 未声明 reliabilityClass → 拒绝）
/// 2. 每次调用后 `recordSuccess` / `recordFailure(error:)` 上报结果
/// 3. quota 感知的 Adapter（如 Alpha Vantage budget）用 `recordQuota(used:)` 对齐真实用量
/// 4. SYNC-7 降级路径读 `health(for:)` / `isCallable(_:)`
///
/// 未注册的 Provider 上报一律忽略并返回 nil（不猜 reliabilityClass，DATA006）。
actor ProviderHealthMonitor {

    private struct Call: Sendable {
        let succeeded: Bool
        let rateLimited: Bool
    }

    private struct ProviderState {
        var reliabilityClass: ProviderReliabilityClass
        var quota: QuotaConfig?
        var quotaUsed: Int
        var quotaResetsAt: Date
        var recentCalls: [Call]   // ring，容量 = policy.statisticsWindow
        var consecutiveFailures: Int
        var lastSchemaDriftAt: Date?
        /// rateLimited 冷却截止时间（冷却期内 degraded，过期自动恢复）
        var rateLimitCooldownUntil: Date?

        init(
            reliabilityClass: ProviderReliabilityClass,
            quota: QuotaConfig?,
            resetsAt: Date
        ) {
            self.reliabilityClass = reliabilityClass
            self.quota = quota
            self.quotaUsed = 0
            self.quotaResetsAt = resetsAt
            self.recentCalls = []
            self.consecutiveFailures = 0
            self.lastSchemaDriftAt = nil
            self.rateLimitCooldownUntil = nil
        }
    }

    private let policy: HealthDegradationPolicy
    private var states: [DataProviderID: ProviderState] = [:]
    private let now: @Sendable () -> Date

    init(
        policy: HealthDegradationPolicy = .v1,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.policy = policy
        self.now = now
    }

    // MARK: - 注册

    /// 注册 / 更新 Provider 声明。重复 register 保留既有统计（仅更新声明字段）。
    func register(
        _ providerID: DataProviderID,
        reliabilityClass: ProviderReliabilityClass,
        quota: QuotaConfig? = nil
    ) {
        if states[providerID] != nil {
            // 已注册：reliabilityClass/quota 声明以最新为准，统计与 quota 已用量保留
            states[providerID]!.reliabilityClass = reliabilityClass
            states[providerID]!.quota = quota
            return
        }
        let resetsAt = quota.map { Self.nextReset(after: now(), period: $0.period) }
            ?? now()
        states[providerID] = ProviderState(
            reliabilityClass: reliabilityClass,
            quota: quota,
            resetsAt: resetsAt
        )
    }

    /// 已注册的 Provider 集合（诊断 / 测试用）。
    var registeredProviderIDs: [DataProviderID] {
        Array(states.keys)
    }

    // MARK: - 结果上报

    /// 上报一次成功调用。返回更新后的健康快照；未注册返回 nil。
    @discardableResult
    func recordSuccess(_ providerID: DataProviderID) -> ProviderHealth? {
        guard states[providerID] != nil else { return nil }
        appendCall(providerID, call: Call(succeeded: true, rateLimited: false))
        states[providerID]!.consecutiveFailures = 0
        return health(for: providerID)
    }

    /// 上报一次失败调用（按 ProviderError 语义归类）。
    ///
    /// - quotaExhausted：额外标记 rateLimited + 把 quota 已用量推满（保持与
    ///   Provider 上游判定一致，下游 health 立即 unavailable）
    /// - rateLimited：进入**独立冷却**（默认 60s，上游 retryAfter 优先）——计入
    ///   限流统计但不累计 consecutiveFailures；冷却期内 degraded，过期自动恢复
    ///   healthy（审查 P2：连续频控不得把 Provider 拖进无恢复路径的 unavailable）
    /// - schemaMismatch：额外记录 lastSchemaDrift（提醒维护者 Provider 改字段）
    /// - notFound：**不计入**调用统计与连续失败——覆盖缺失（查了 Provider 没有
    ///   的代码）不是服务故障，连续查多个未覆盖代码不应把健康 Provider 拖进
    ///   unavailable（审查 P2）
    @discardableResult
    func recordFailure(
        _ providerID: DataProviderID,
        error: ProviderError
    ) -> ProviderHealth? {
        guard states[providerID] != nil else { return nil }
        switch error {
        case .notFound:
            return health(for: providerID)
        case .quotaExhausted:
            // 先滚动周期再推满（审查 P1：跨周期后的首次记账不能写进旧周期）
            rolloverQuotaIfNeeded(providerID)
            if states[providerID]!.quota != nil {
                states[providerID]!.quotaUsed = states[providerID]!.quota!.total
            }
            appendCall(providerID, call: Call(succeeded: false, rateLimited: true))
            states[providerID]!.consecutiveFailures += 1
        case .rateLimited(_, let retryAfter):
            let cooldown = retryAfter ?? policy.defaultRateLimitCooldownSeconds
            states[providerID]!.rateLimitCooldownUntil = now().addingTimeInterval(cooldown)
            appendCall(providerID, call: Call(succeeded: false, rateLimited: true))
        case .unavailable, .schemaMismatch:
            if case .schemaMismatch = error {
                states[providerID]!.lastSchemaDriftAt = now()
            }
            appendCall(providerID, call: Call(succeeded: false, rateLimited: false))
            states[providerID]!.consecutiveFailures += 1
        }
        return health(for: providerID)
    }

    /// 显式记录一次 schema 漂移（不伴随失败时用，如 SchemaValidator 拒收部分行）。
    @discardableResult
    func recordSchemaDrift(_ providerID: DataProviderID) -> ProviderHealth? {
        guard states[providerID] != nil else { return nil }
        states[providerID]!.lastSchemaDriftAt = now()
        return health(for: providerID)
    }

    /// 对齐真实 quota 已用量（quota 感知 Adapter 的权威上报，如 Alpha Vantage budget）。
    /// 未声明 quota 的 Provider 忽略。先滚动周期再写入（审查 P1：跨周期后的首次
    /// 记账必须落进新周期，不能被随后的读取时滚动清零）。
    @discardableResult
    func recordQuota(_ providerID: DataProviderID, used: Int) -> ProviderHealth? {
        guard states[providerID]?.quota != nil else { return nil }
        rolloverQuotaIfNeeded(providerID)
        states[providerID]!.quotaUsed = max(0, used)
        return health(for: providerID)
    }

    /// quota 已用量 +1（无精确 budget 的 Adapter 按调用次数近似）。
    @discardableResult
    func incrementQuota(_ providerID: DataProviderID) -> ProviderHealth? {
        guard states[providerID]?.quota != nil else { return nil }
        rolloverQuotaIfNeeded(providerID)
        states[providerID]!.quotaUsed += 1
        return health(for: providerID)
    }

    // MARK: - 查询

    /// 某 Provider 当前健康快照（含 quota 周期滚动）。未注册返回 nil。
    func health(for providerID: DataProviderID) -> ProviderHealth? {
        guard let state = rolledState(for: providerID) else { return nil }
        let successCount = state.recentCalls.filter(\.succeeded).count
        // 限流调用（429/quota 拒绝）不算服务失败：不进成功率的分子分母
        // （审查 P2：否则连续频控在冷却过期后仍以 0% 成功率把 Provider 锁在
        // degraded，没有自动恢复路径）
        let failureCount = state.recentCalls.filter { !$0.succeeded && !$0.rateLimited }.count
        let statistics = RecentStatistics(
            totalCalls: state.recentCalls.count,
            successCount: successCount,
            failureCount: failureCount,
            rateLimitedCount: state.recentCalls.filter(\.rateLimited).count
        )
        let remainingQuota: QuotaSnapshot?
        if let quota = state.quota {
            remainingQuota = QuotaSnapshot(
                period: quota.period,
                total: quota.total,
                used: state.quotaUsed,
                resetsAt: state.quotaResetsAt
            )
        } else {
            remainingQuota = nil
        }
        return ProviderHealth(
            providerID: providerID,
            reliabilityClass: state.reliabilityClass,
            status: deriveStatus(state: state),
            recentStatistics: statistics,
            remainingQuota: remainingQuota,
            lastSchemaDrift: state.lastSchemaDriftAt,
            updatedAt: now()
        )
    }

    /// 是否仍可调用（degraded 可，unavailable 不可——SYNC-7 降级入口）。
    func isCallable(_ providerID: DataProviderID) -> Bool {
        health(for: providerID)?.status.isCallable ?? false
    }

    /// 全部已注册 Provider 的健康快照（运维视图 / UI）。
    func snapshot() -> [DataProviderID: ProviderHealth] {
        var result: [DataProviderID: ProviderHealth] = [:]
        for id in states.keys {
            result[id] = health(for: id)
        }
        return result
    }

    // MARK: - 状态推导（HealthDegradationPolicy 规则，按优先级）

    private func deriveStatus(state: ProviderState) -> ProviderStatus {
        // 1. quota 耗尽 → unavailable
        if let quota = state.quota, quota.total > 0,
           max(0, quota.total - state.quotaUsed) == 0 {
            return .unavailable
        }
        // 2. 持续故障 → unavailable
        if state.consecutiveFailures >= policy.unavailableConsecutiveFailures {
            return .unavailable
        }
        // 3. rateLimited 冷却期 → degraded（transient；过期自动恢复，不需要人工干预）
        if let cooldownUntil = state.rateLimitCooldownUntil, now() < cooldownUntil {
            return .degraded
        }
        // 4. quota 接近耗尽 → degraded
        if let quota = state.quota, quota.total > 0 {
            let remainingRatio = Double(max(0, quota.total - state.quotaUsed)) / Double(quota.total)
            if remainingRatio < policy.degradedQuotaRemainingRatio {
                return .degraded
            }
        }
        // 5. 偶发连续失败 → degraded
        if state.consecutiveFailures >= policy.degradedConsecutiveFailures {
            return .degraded
        }
        // 6. 窗口成功率低（样本足够时）→ degraded。样本与比率都只按非限流调用
        //    计算（限流不是服务失败，且冷却过期后不应残留 degraded）
        let effectiveTotal = state.recentCalls.filter { !$0.rateLimited }.count
        if effectiveTotal >= policy.minimumCallsForRateRule {
            let successCount = state.recentCalls.filter { $0.succeeded }.count
            if Double(successCount) / Double(effectiveTotal) < policy.degradedSuccessRate {
                return .degraded
            }
        }
        return .healthy
    }

    // MARK: - Helpers

    private func appendCall(_ providerID: DataProviderID, call: Call) {
        states[providerID]!.recentCalls.append(call)
        if states[providerID]!.recentCalls.count > policy.statisticsWindow {
            states[providerID]!.recentCalls.removeFirst(
                states[providerID]!.recentCalls.count - policy.statisticsWindow
            )
        }
    }

    /// 周期滚动（跨过 resetsAt → 用量清零、周期推进）。所有写 quotaUsed 的路径
    /// （recordQuota / incrementQuota / quotaExhausted 推满）必须先调用本方法，
    /// 否则跨周期后的首次记账会写进旧周期、随后被读取时滚动清零（审查 P1）。
    private func rolloverQuotaIfNeeded(_ providerID: DataProviderID) {
        guard var state = states[providerID], let quota = state.quota else { return }
        var resetsAt = state.quotaResetsAt
        var rolled = false
        while now() >= resetsAt {
            resetsAt = Self.advance(resetsAt, period: quota.period)
            rolled = true
        }
        if rolled {
            state.quotaUsed = 0
            state.quotaResetsAt = resetsAt
            states[providerID] = state
        }
    }

    /// 读取 state 并先做 quota 周期滚动（跨过 resetsAt → 用量清零，周期推进）。
    private func rolledState(for providerID: DataProviderID) -> ProviderState? {
        rolloverQuotaIfNeeded(providerID)
        return states[providerID]
    }

    /// 下一个重置点（UTC 确定性：daily → 次日 00:00；monthly → 次月 1 日；hourly → 次整点）。
    static func nextReset(after date: Date, period: QuotaSnapshot.QuotaPeriod) -> Date {
        advance(date, period: period)
    }

    private static func advance(_ date: Date, period: QuotaSnapshot.QuotaPeriod) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        switch period {
        case .hourly:
            // 当前 UTC 整点 + 1 小时（UTC 无 DST，整点推进稳定）
            let hourComps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            guard let hourStart = calendar.date(from: hourComps) else {
                return date.addingTimeInterval(3600)
            }
            return calendar.date(byAdding: .hour, value: 1, to: hourStart)
                ?? date.addingTimeInterval(3600)
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                ?? date.addingTimeInterval(86_400)
        case .monthly:
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let firstOfMonth = calendar.date(from: comps) else {
                return date.addingTimeInterval(30 * 86_400)
            }
            return calendar.date(byAdding: .month, value: 1, to: firstOfMonth)
                ?? date.addingTimeInterval(30 * 86_400)
        }
    }
}
