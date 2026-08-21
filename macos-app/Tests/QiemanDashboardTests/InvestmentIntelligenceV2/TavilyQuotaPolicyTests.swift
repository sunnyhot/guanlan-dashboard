import XCTest
@testable import QiemanDashboard

/// PROV-7 单元测试：Tavily 月额度感知。
///
/// 覆盖：错误映射（432/433→quotaExhausted 月额度耗尽、429→rateLimited 瞬时频控
/// 独立冷却、401→unavailable、invalidResponse→schemaMismatch）、免费层额度三档
/// （available/lowQuota/exhausted）、周期滚动恢复、与 ProviderHealthMonitor 的
/// monthly quota 对接（DATA006 §5：月额度用完 Research 降级「无 web 搜索」模式）。
final class TavilyQuotaPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_724_000_000)
    private var resetsAt: Date {
        ProviderHealthMonitor.nextReset(after: now, period: .monthly)
    }

    private let policy = TavilyQuotaPolicy.freeTier

    // MARK: - 额度三档

    func testAvailability_comfortableQuota() {
        let availability = policy.availability(used: 300, resetsAt: resetsAt, now: now)
        XCTAssertEqual(availability, .available)
    }

    func testAvailability_lowQuota() {
        // 免费层 1000，用到 905 剩 95 < 100 → lowQuota（保守档，仍可用）
        let availability = policy.availability(used: 905, resetsAt: resetsAt, now: now)
        XCTAssertEqual(availability, .lowQuota(remaining: 95))
    }

    func testAvailability_exhausted() {
        let availability = policy.availability(used: 1000, resetsAt: resetsAt, now: now)
        XCTAssertEqual(availability, .exhausted(resetsAt: resetsAt))
        // 超用（记账延迟）仍 clamp 到 exhausted
        let over = policy.availability(used: 1200, resetsAt: resetsAt, now: now)
        XCTAssertEqual(over, .exhausted(resetsAt: resetsAt))
    }

    func testAvailability_boundaryJustAboveThreshold() {
        // 剩 100 = 阈值，不小于 → 仍 available（阈值是「低于」语义）
        let availability = policy.availability(used: 900, resetsAt: resetsAt, now: now)
        XCTAssertEqual(availability, .available)
    }

    func testAvailability_resetsAfterPeriodPasses() {
        // 跨过 resetsAt → 周期恢复 available（调用方重置记账）
        let availability = policy.availability(
            used: 1000, resetsAt: resetsAt, now: resetsAt.addingTimeInterval(60)
        )
        XCTAssertEqual(availability, .available)
    }

    // MARK: - 错误映射

    func testMap_planLimitStatusesToQuotaExhausted() {
        // 432/433 = 套餐/月额度耗尽（持久）→ quotaExhausted
        for status in [432, 433] {
            let error = TavilySearchClientError.requestFailed(statusCode: status, detail: nil)
            guard case .quotaExhausted(let providerID) = TavilyProviderErrorMapper.map(error) else {
                return XCTFail("HTTP \(status) 应映射 quotaExhausted")
            }
            XCTAssertEqual(providerID, .tavily)
        }
    }

    func testMap_429RateLimitedTransient_notQuotaExhausted() {
        // 429 = 瞬时频控（审查 P2）：映射 rateLimited（独立冷却自动恢复）——
        // 不推满月 quota、不累计成无恢复路径的 unavailable
        let error = TavilySearchClientError.requestFailed(statusCode: 429, detail: nil)
        guard case .rateLimited(let providerID, _) = TavilyProviderErrorMapper.map(error) else {
            return XCTFail("429 瞬时频控应映射 rateLimited，got \(TavilyProviderErrorMapper.map(error))")
        }
        XCTAssertEqual(providerID, .tavily)
    }

    func testMonitorIntegration_rateLimitedDoesNotFillMonthlyQuota() async {
        let clockNow = now
        let monitor = ProviderHealthMonitor(policy: .v1, now: { clockNow })
        await monitor.register(
            .tavily,
            reliabilityClass: .documentFreeAPI,
            quota: TavilyQuotaPolicy.freeTier.quotaConfig
        )
        // 连续 429 上报：月额度不受污染，状态只是 degraded（冷却），可自动恢复
        for _ in 0..<6 {
            await monitor.recordFailure(
                .tavily, error: TavilyProviderErrorMapper.map(
                    .requestFailed(statusCode: 429, detail: nil)
                )
            )
        }
        let health = await monitor.health(for: .tavily)
        XCTAssertEqual(health?.remainingQuota?.used, 0)
        XCTAssertEqual(health?.status, .degraded)
        let callable = await monitor.isCallable(.tavily)
        XCTAssertTrue(callable)
    }

    func testMap_auth401ToUnavailable() {
        let error = TavilySearchClientError.requestFailed(statusCode: 401, detail: "bad key")
        guard case .unavailable(let providerID, _) = TavilyProviderErrorMapper.map(error) else {
            return XCTFail("401 应映射 unavailable（认证失败不是额度）")
        }
        XCTAssertEqual(providerID, .tavily)
    }

    func testMap_missingKeyToUnavailable() {
        let error = TavilySearchClientError.missingAPIKey
        guard case .unavailable = TavilyProviderErrorMapper.map(error) else {
            return XCTFail("missingAPIKey 应映射 unavailable")
        }
    }

    func testMap_invalidResponseToSchemaMismatch() {
        let error = TavilySearchClientError.invalidResponse("broken json")
        guard case .schemaMismatch(let providerID, _) = TavilyProviderErrorMapper.map(error) else {
            return XCTFail("invalidResponse 应映射 schemaMismatch")
        }
        XCTAssertEqual(providerID, .tavily)
    }

    func testMap_timedOutToUnavailable() {
        let error = TavilySearchClientError.timedOut(30)
        guard case .unavailable = TavilyProviderErrorMapper.map(error) else {
            return XCTFail("timedOut 应映射 unavailable")
        }
    }

    // MARK: - 与 ProviderHealthMonitor 对接（monthly quota 聚合）

    func testMonitorIntegration_monthlyQuotaDrivesStatus() async {
        let clockNow = now
        let monitor = ProviderHealthMonitor(policy: .v1, now: { clockNow })
        await monitor.register(
            .tavily,
            reliabilityClass: .documentFreeAPI,
            quota: TavilyQuotaPolicy.freeTier.quotaConfig
        )
        // 用掉 950/1000 → 剩 50/1000 = 0.05 < 0.2 → degraded
        var health = await monitor.recordQuota(.tavily, used: 950)
        XCTAssertEqual(health?.remainingQuota?.period, .monthly)
        XCTAssertEqual(health?.status, .degraded)

        // 月额度耗尽（432/433 语义）上报 → quota 推满 → unavailable
        // （Research 降级「无 web 搜索」模式）
        health = await monitor.recordFailure(
            .tavily, error: .quotaExhausted(providerID: .tavily)
        )
        XCTAssertEqual(health?.status, .unavailable)
        let callable = await monitor.isCallable(.tavily)
        XCTAssertFalse(callable)
    }

    // MARK: - Codable（策略可持久化 / 审计）

    func testPolicy_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(TavilyQuotaPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }
}
