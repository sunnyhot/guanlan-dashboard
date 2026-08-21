import XCTest
@testable import QiemanDashboard

/// PROV-8 单元测试：ProviderHealthMonitor 状态推导（ADR-DATA006 §Decision 2/3）。
///
/// 覆盖 HealthDegradationPolicy 六条规则的优先级、quota 周期滚动、
/// ProviderError 归类上报（quotaExhausted→rateLimited+推满 / schemaMismatch→drift）、
/// 未注册上报忽略语义。
final class ProviderHealthMonitorTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_724_000_000)

    private func makeMonitor(
        policy: HealthDegradationPolicy = .v1
    ) -> ProviderHealthMonitor {
        ProviderHealthMonitor(policy: policy, now: { [weak self] in self?.now ?? .distantPast })
    }

    // MARK: - 注册 + 基础上报

    func testRegister_thenHealthy() async {
        let monitor = makeMonitor()
        await monitor.register(.fred, reliabilityClass: .officialStable)
        let health = await monitor.health(for: .fred)
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertEqual(health?.reliabilityClass, .officialStable)
        XCTAssertNil(health?.remainingQuota)   // FRED 无配额
    }

    func testRecordSuccess_updatesStatistics() async {
        let monitor = makeMonitor()
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        await monitor.recordSuccess(.stooq)
        await monitor.recordSuccess(.stooq)
        let health = await monitor.health(for: .stooq)
        XCTAssertEqual(health?.recentStatistics.totalCalls, 2)
        XCTAssertEqual(health?.recentStatistics.successCount, 2)
        XCTAssertEqual(health?.recentStatistics.failureCount, 0)
        XCTAssertEqual(health?.status, .healthy)
    }

    func testUnregisteredProvider_reportsIgnored() async {
        let monitor = makeMonitor()
        let afterSuccess = await monitor.recordSuccess(.alphaVantage)
        let afterFailure = await monitor.recordFailure(
            .alphaVantage, error: .unavailable(providerID: .alphaVantage, underlying: "x")
        )
        XCTAssertNil(afterSuccess)
        XCTAssertNil(afterFailure)
        let snapshot = await monitor.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: - 规则 1：quota 耗尽 → unavailable

    func testQuotaExhausted_unavailable() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.status, .unavailable)
        XCTAssertFalse(health!.status.isCallable)
        let callable = await monitor.isCallable(.alphaVantage)
        XCTAssertFalse(callable)
    }

    // MARK: - 规则 3：quota 接近耗尽 → degraded

    func testQuotaLow_degraded() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        // 21/25 用掉，剩 4/25 = 0.16 < 0.2 → degraded（仍可调用）
        await monitor.recordQuota(.alphaVantage, used: 21)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.status, .degraded)
        XCTAssertEqual(health?.remainingQuota?.remaining, 4)
        XCTAssertTrue(health!.status.isCallable)
    }

    func testQuotaComfortable_healthy() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 10)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.status, .healthy)
    }

    // MARK: - 规则 1 优先于规则 2（quota 耗尽 + 大量成功仍 unavailable）

    func testQuotaExhausted_beatsSuccesses() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        for _ in 0..<10 { await monitor.recordSuccess(.alphaVantage) }
        await monitor.recordQuota(.alphaVantage, used: 25)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.status, .unavailable)
    }

    // MARK: - 规则 2/4：连续失败 → degraded / unavailable

    func testConsecutiveFailures_degradedThenUnavailable() async {
        let monitor = makeMonitor()
        await monitor.register(.eastmoney, reliabilityClass: .communityAggregated)
        // 1 次失败：仅偶发，仍 healthy
        await monitor.recordFailure(.eastmoney, error: .unavailable(providerID: .eastmoney, underlying: "timeout"))
        var health = await monitor.health(for: .eastmoney)
        XCTAssertEqual(health?.status, .healthy)
        // 2 次连续 → degraded
        await monitor.recordFailure(.eastmoney, error: .unavailable(providerID: .eastmoney, underlying: "timeout"))
        health = await monitor.health(for: .eastmoney)
        XCTAssertEqual(health?.status, .degraded)
        // 5 次连续 → unavailable
        for _ in 0..<3 {
            await monitor.recordFailure(.eastmoney, error: .unavailable(providerID: .eastmoney, underlying: "403"))
        }
        health = await monitor.health(for: .eastmoney)
        XCTAssertEqual(health?.status, .unavailable)
    }

    func testSuccessResetsConsecutiveFailures() async {
        let monitor = makeMonitor()
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        await monitor.recordFailure(.stooq, error: .unavailable(providerID: .stooq, underlying: "x"))
        await monitor.recordFailure(.stooq, error: .unavailable(providerID: .stooq, underlying: "x"))
        var health = await monitor.health(for: .stooq)
        XCTAssertEqual(health?.status, .degraded)
        await monitor.recordSuccess(.stooq)
        health = await monitor.health(for: .stooq)
        XCTAssertEqual(health?.status, .healthy)
    }

    // MARK: - 规则 5：窗口成功率（需 ≥ minimumCallsForRateRule 样本）

    func testWindowSuccessRate_degraded() async {
        let monitor = makeMonitor()
        await monitor.register(.fred, reliabilityClass: .officialStable)
        // 交错排列（无连续失败，不触发规则 2/4）：F S F S F S F = 3/7 ≈ 0.43 < 0.5，
        // 样本 7 ≥ 5 → 仅由成功率规则（规则 5）触发 degraded
        for i in 0..<7 {
            if i % 2 == 0 {
                await monitor.recordFailure(.fred, error: .timedOutLike)
            } else {
                await monitor.recordSuccess(.fred)
            }
        }
        let health = await monitor.health(for: .fred)
        XCTAssertEqual(health?.recentStatistics.totalCalls, 7)
        XCTAssertEqual(health?.status, .degraded)
    }

    func testSmallSample_rateRuleNotApplied() async {
        let monitor = makeMonitor()
        await monitor.register(.fred, reliabilityClass: .officialStable)
        // 2 次调用 1 成功：样本 < 5，成功率规则不触发；连续失败 1 < 2 → healthy
        await monitor.recordSuccess(.fred)
        await monitor.recordFailure(.fred, error: .timedOutLike)
        let health = await monitor.health(for: .fred)
        XCTAssertEqual(health?.status, .healthy)
    }

    // MARK: - 统计窗口裁剪

    func testStatisticsWindowTruncated() async {
        let monitor = makeMonitor()
        await monitor.register(.fred, reliabilityClass: .officialStable)
        // 窗口 20：写 30 次，统计只保留最近 20
        for _ in 0..<30 { await monitor.recordSuccess(.fred) }
        let health = await monitor.health(for: .fred)
        XCTAssertEqual(health?.recentStatistics.totalCalls, 20)
    }

    // MARK: - ProviderError 归类

    func testQuotaExhaustedFailure_marksRateLimitedAndFillsQuota() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordFailure(.alphaVantage, error: .quotaExhausted(providerID: .alphaVantage))
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.recentStatistics.rateLimitedCount, 1)
        XCTAssertEqual(health?.remainingQuota?.remaining, 0)   // quota 推满
        XCTAssertEqual(health?.status, .unavailable)
    }

    func testSchemaMismatchFailure_recordsDrift() async {
        let monitor = makeMonitor()
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        await monitor.recordFailure(
            .stooq, error: .schemaMismatch(providerID: .stooq, detail: "csv columns changed")
        )
        let health = await monitor.health(for: .stooq)
        XCTAssertNotNil(health?.lastSchemaDrift)
        XCTAssertEqual(health?.status, .healthy)   // 单次漂移不降级，只提醒维护者
    }

    func testExplicitSchemaDriftRecording() async {
        let monitor = makeMonitor()
        await monitor.register(.eastmoney, reliabilityClass: .communityAggregated)
        await monitor.recordSchemaDrift(.eastmoney)
        let health = await monitor.health(for: .eastmoney)
        XCTAssertNotNil(health?.lastSchemaDrift)
    }

    // MARK: - quota 周期滚动

    func testDailyQuotaResets_afterPeriodPasses() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)
        var health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.status, .unavailable)
        // 跨过 resetsAt（nextReset 按 UTC 次日 00:00）
        now = now.addingTimeInterval(2 * 86_400)
        health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.remainingQuota?.used, 0)
        XCTAssertEqual(health?.status, .healthy)
        // resetsAt 也推进到新的未来时点
        XCTAssertGreaterThan(health!.remainingQuota!.resetsAt, now)
    }

    func testMonthlyQuota_nextResetIsFirstOfNextMonth() {
        // 2024-08-12 UTC → 2024-09-01 00:00 UTC
        let date = Date(timeIntervalSince1970: 1_723_429_824)
        let next = ProviderHealthMonitor.nextReset(after: date, period: .monthly)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 0)
    }

    func testDailyQuota_nextResetIsNextUtcMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2024, month: 8, day: 12, hour: 15
        ))!
        let next = ProviderHealthMonitor.nextReset(after: date, period: .daily)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(comps.day, 13)
        XCTAssertEqual(comps.hour, 0)
    }

    // MARK: - notFound 不污染服务健康（审查 P2）

    func testNotFound_doesNotCountAsFailure() async {
        let monitor = makeMonitor()
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        // 连续查 5 个 Provider 未覆盖的代码：不是服务故障，不进统计、不触发降级
        for _ in 0..<5 {
            await monitor.recordFailure(
                .stooq, error: .notFound(code: ProviderCode(scheme: "stock_symbol", value: "XXXX"))
            )
        }
        let health = await monitor.health(for: .stooq)
        XCTAssertEqual(health?.recentStatistics.totalCalls, 0)
        XCTAssertEqual(health?.status, .healthy)
    }

    // MARK: - quota 跨周期后首记不丢（审查 P1：先滚动再写）

    func testQuotaRolloverBeforeRecord_recordQuota() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)
        // 跨周期后首次对齐用量：必须先滚动清零再写入，新周期用量不能被读取时
        // 的二次滚动抹掉
        now = now.addingTimeInterval(2 * 86_400)
        await monitor.recordQuota(.alphaVantage, used: 3)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.remainingQuota?.used, 3)
        XCTAssertEqual(health?.status, .healthy)
    }

    func testQuotaRolloverBeforeRecord_incrementQuota() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)
        now = now.addingTimeInterval(86_400)
        await monitor.incrementQuota(.alphaVantage)
        let health = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(health?.remainingQuota?.used, 1)
        XCTAssertEqual(health?.status, .healthy)
    }

    func testQuotaExhaustedAfterRollover_fillsNewPeriod() async {
        let monitor = makeMonitor()
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)
        now = now.addingTimeInterval(86_400)
        // 新周期里报 quotaExhausted：推满的是新周期（25），resetsAt 也是新周期的
        let health = await monitor.recordFailure(
            .alphaVantage, error: .quotaExhausted(providerID: .alphaVantage)
        )
        XCTAssertEqual(health?.remainingQuota?.used, 25)
        XCTAssertEqual(health?.status, .unavailable)
        XCTAssertGreaterThan(health!.remainingQuota!.resetsAt, now)
    }

    // MARK: - rateLimited 独立冷却（审查 P2：连续频控不得无恢复路径）

    func testRateLimited_repeatedNeverBecomesUnavailable() async {
        let monitor = makeMonitor()
        await monitor.register(.tavily, reliabilityClass: .documentFreeAPI)
        // 连续 7 次 429（超过 unavailableConsecutiveFailures=5）：瞬时限流不是
        // 服务故障，不累计连续失败 → 只处于 degraded（冷却中），仍可调用
        for _ in 0..<7 {
            await monitor.recordFailure(
                .tavily, error: .rateLimited(providerID: .tavily, retryAfter: 60)
            )
        }
        let health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.status, .degraded)
        XCTAssertEqual(health?.recentStatistics.rateLimitedCount, 7)
        let callable = await monitor.isCallable(.tavily)
        XCTAssertTrue(callable)
    }

    func testRateLimited_cooldownAutoRecovers() async {
        let monitor = makeMonitor()
        await monitor.register(.tavily, reliabilityClass: .documentFreeAPI)
        await monitor.recordFailure(
            .tavily, error: .rateLimited(providerID: .tavily, retryAfter: 120)
        )
        var health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.status, .degraded)   // 冷却期内
        now = now.addingTimeInterval(121)
        health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.status, .healthy)    // 冷却过期自动恢复，无需人工干预
    }

    func testRateLimited_defaultCooldownWhenNoRetryAfter() async {
        let monitor = makeMonitor()
        await monitor.register(.sec, reliabilityClass: .officialStable)
        await monitor.recordFailure(
            .sec, error: .rateLimited(providerID: .sec, retryAfter: nil)
        )
        var health = await monitor.health(for: .sec)
        XCTAssertEqual(health?.status, .degraded)               // 默认 60s 冷却生效
        now = now.addingTimeInterval(30)
        health = await monitor.health(for: .sec)
        XCTAssertEqual(health?.status, .degraded)               // 仍在冷却
        now = now.addingTimeInterval(31)
        health = await monitor.health(for: .sec)
        XCTAssertEqual(health?.status, .healthy)
    }

    func testRateLimited_doesNotFillQuota() async {
        let monitor = makeMonitor()
        await monitor.register(
            .tavily, reliabilityClass: .documentFreeAPI,
            quota: TavilyQuotaPolicy.freeTier.quotaConfig
        )
        await monitor.recordFailure(
            .tavily, error: .rateLimited(providerID: .tavily, retryAfter: nil)
        )
        let health = await monitor.health(for: .tavily)
        // 瞬时频控不消耗月额度（与 quotaExhausted 的核心区别）
        XCTAssertEqual(health?.remainingQuota?.used, 0)
        XCTAssertEqual(health?.status, .degraded)   // 因冷却而 degraded，非 quota
    }

    func testRateLimited_afterCooldownRecoversEvenWithFullWindow() async {
        // 审查 P2 组合场景：连续 7 次 429 填满统计窗口后冷却过期——限流调用
        // 不进成功率分母（否则 0/7 的成功率会让规则 6 把 degraded 锁死，
        // 永远无法自动恢复）
        let monitor = makeMonitor()
        await monitor.register(.tavily, reliabilityClass: .documentFreeAPI)
        for _ in 0..<7 {
            await monitor.recordFailure(
                .tavily, error: .rateLimited(providerID: .tavily, retryAfter: 60)
            )
        }
        var health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.status, .degraded)           // 冷却期内
        XCTAssertEqual(health?.recentStatistics.rateLimitedCount, 7)
        XCTAssertNil(health?.recentStatistics.successRate)  // 无非限流样本
        now = now.addingTimeInterval(61)
        health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.status, .healthy)            // 冷却过期即恢复
    }

    // MARK: - snapshot + register 更新

    func testSnapshot_includesAllRegistered() async {
        let monitor = makeMonitor()
        await monitor.register(.fred, reliabilityClass: .officialStable)
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        await monitor.register(.sec, reliabilityClass: .officialStable)
        let snapshot = await monitor.snapshot()
        XCTAssertEqual(Set(snapshot.keys), Set([.fred, .stooq, .sec]))
    }

    func testReRegister_keepsStatistics() async {
        let monitor = makeMonitor()
        await monitor.register(.stooq, reliabilityClass: .documentFreeAPI)
        for _ in 0..<3 { await monitor.recordSuccess(.stooq) }
        // 声明更新（如接入 quota）不清统计
        await monitor.register(
            .stooq, reliabilityClass: .documentFreeAPI,
            quota: QuotaConfig(period: .daily, total: 100)
        )
        let health = await monitor.health(for: .stooq)
        XCTAssertEqual(health?.recentStatistics.totalCalls, 3)
        XCTAssertEqual(health?.remainingQuota?.total, 100)
        XCTAssertEqual(health?.remainingQuota?.used, 0)
    }

    func testRecordQuota_ignoredWithoutQuotaConfig() async {
        let monitor = makeMonitor()
        await monitor.register(.sec, reliabilityClass: .officialStable)
        let result = await monitor.recordQuota(.sec, used: 5)
        XCTAssertNil(result)
        let health = await monitor.health(for: .sec)
        XCTAssertNil(health?.remainingQuota)
    }
}

private extension ProviderError {
    /// 测试用 timeout 语义（unavailable 桶，非 rateLimited / 非 schema）。
    static var timedOutLike: ProviderError {
        .unavailable(providerID: DataProviderID(rawValue: "test"), underlying: "timed out")
    }
}
