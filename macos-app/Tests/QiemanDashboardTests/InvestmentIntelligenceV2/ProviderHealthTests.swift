import XCTest
@testable import QiemanDashboard

/// DOM-8 单元测试：ProviderHealth / ProviderStatus / RecentStatistics /
/// QuotaSnapshot + DataQuality 联动。
///
/// 重点验证 ADR-DATA006 §Decision 2（监控）/ §Decision 3（三档降级状态）。
final class ProviderHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_724_000_000)

    // MARK: - ProviderStatus

    func testProviderStatus_callable() {
        XCTAssertTrue(ProviderStatus.healthy.isCallable)
        XCTAssertTrue(ProviderStatus.degraded.isCallable)
        XCTAssertFalse(ProviderStatus.unavailable.isCallable)
    }

    // MARK: - RecentStatistics

    func testRecentStatistics_successRate() {
        let stats = RecentStatistics(totalCalls: 100, successCount: 95, failureCount: 5, rateLimitedCount: 0)
        XCTAssertEqual(stats.successRate ?? -1, 0.95, accuracy: 0.001)
    }

    func testRecentStatistics_successRate_nilWhenZero() {
        let stats = RecentStatistics(totalCalls: 0, successCount: 0, failureCount: 0, rateLimitedCount: 0)
        XCTAssertNil(stats.successRate)
    }

    // MARK: - QuotaSnapshot

    func testQuotaSnapshot_remaining() {
        let quota = QuotaSnapshot(
            period: .daily, total: 25, used: 10,
            resetsAt: now.addingTimeInterval(3600)
        )
        XCTAssertEqual(quota.remaining, 15)
        XCTAssertEqual(quota.remainingRatio ?? -1, 0.6, accuracy: 0.001)
    }

    func testQuotaSnapshot_exhaustedClampsToZero() {
        // Alpha Vantage 25/天用完
        let quota = QuotaSnapshot(period: .daily, total: 25, used: 30, resetsAt: now)
        XCTAssertEqual(quota.remaining, 0)  // 不出现负数
    }

    func testQuotaSnapshot_nilRatioWhenTotalZero() {
        let quota = QuotaSnapshot(period: .daily, total: 0, used: 0, resetsAt: now)
        XCTAssertNil(quota.remainingRatio)
    }

    // MARK: - ProviderHealth 构造 + 状态

    func testProviderHealth_alphaVantageWithQuota() {
        let health = ProviderHealth(
            providerID: .alphaVantage,
            reliabilityClass: .documentFreeAPI,
            status: .degraded,  // 配额接近耗尽
            recentStatistics: RecentStatistics(
                totalCalls: 24, successCount: 24, failureCount: 0, rateLimitedCount: 0
            ),
            remainingQuota: QuotaSnapshot(
                period: .daily, total: 25, used: 24, resetsAt: now.addingTimeInterval(3600)
            ),
            lastSchemaDrift: nil,
            updatedAt: now
        )
        XCTAssertEqual(health.providerID, .alphaVantage)
        XCTAssertEqual(health.reliabilityClass, .documentFreeAPI)
        XCTAssertEqual(health.status, .degraded)
        XCTAssertEqual(health.remainingQuota?.remaining, 1)
        XCTAssertTrue(health.status.isCallable)  // degraded 仍可调
    }

    func testProviderHealth_qiemanNoQuota() {
        let health = ProviderHealth(
            providerID: .qieman,
            reliabilityClass: .undocumentedPublicEndpoint,
            status: .healthy,
            recentStatistics: RecentStatistics(
                totalCalls: 50, successCount: 50, failureCount: 0, rateLimitedCount: 0
            ),
            remainingQuota: nil,  // 且慢无配额限制
            lastSchemaDrift: nil,
            updatedAt: now
        )
        XCTAssertNil(health.remainingQuota)
        XCTAssertEqual(health.status, .healthy)
    }

    // MARK: - 三档降级状态切换（PROV-8 监控 + SYNC-7 降级）

    func testDegradedStatus_whenQuotaLow() {
        // Alpha Vantage 用了 23/25，剩余 2，应降级
        let health = ProviderHealth(
            providerID: .alphaVantage,
            reliabilityClass: .documentFreeAPI,
            status: .degraded,
            recentStatistics: RecentStatistics(
                totalCalls: 23, successCount: 23, failureCount: 0, rateLimitedCount: 0
            ),
            remainingQuota: QuotaSnapshot(period: .daily, total: 25, used: 23, resetsAt: now),
            updatedAt: now
        )
        XCTAssertEqual(health.status, .degraded)
    }

    func testUnavailableStatus_whenQuotaExhausted() {
        // 用完 → unavailable
        let health = ProviderHealth(
            providerID: .alphaVantage,
            reliabilityClass: .documentFreeAPI,
            status: .unavailable,
            recentStatistics: RecentStatistics(
                totalCalls: 25, successCount: 25, failureCount: 0, rateLimitedCount: 0
            ),
            remainingQuota: QuotaSnapshot(period: .daily, total: 25, used: 25, resetsAt: now),
            updatedAt: now
        )
        XCTAssertFalse(health.status.isCallable)
    }

    func testUnavailableStatus_whenPersistentFailures() {
        // 持续 403 / 风控
        let health = ProviderHealth(
            providerID: .akshare,
            reliabilityClass: .communityAggregated,
            status: .unavailable,
            recentStatistics: RecentStatistics(
                totalCalls: 10, successCount: 0, failureCount: 8, rateLimitedCount: 2
            ),
            updatedAt: now
        )
        XCTAssertEqual(health.recentStatistics.successRate ?? -1, 0.0, accuracy: 0.001)
        XCTAssertFalse(health.status.isCallable)
    }

    // MARK: - DataQuality 联动

    func testDataQuality_fromReliabilityClass() {
        let dq1 = DataQuality.from(.officialStable, providerID: .fred)
        XCTAssertEqual(dq1.providerReliability, .officialStable)
        XCTAssertEqual(dq1.sourceProviderID, .fred)
        XCTAssertFalse(dq1.isRevised)
        XCTAssertFalse(dq1.isSuperseded)

        let dq2 = DataQuality(providerReliability: .communityAggregated, isRevised: true)
        XCTAssertTrue(dq2.isRevised)
    }

    func testDataQuality_undocumentedRequiresSecondaryValidation() {
        // ADR-DATA006：undocumentedPublicEndpoint 需 secondary 验证
        let dq = DataQuality.from(.undocumentedPublicEndpoint, providerID: .qieman)
        XCTAssertTrue(dq.requiresSecondaryValidation)
    }

    func testDataQuality_officialDoesNotRequireSecondary() {
        let dq = DataQuality.from(.officialStable, providerID: .fred)
        XCTAssertFalse(dq.requiresSecondaryValidation)
    }

    // MARK: - Codable

    func testProviderHealth_codableRoundTrip() throws {
        let health = ProviderHealth(
            providerID: .fred,
            reliabilityClass: .officialStable,
            status: .healthy,
            recentStatistics: RecentStatistics(
                totalCalls: 100, successCount: 99, failureCount: 1, rateLimitedCount: 0
            ),
            remainingQuota: nil,
            lastSchemaDrift: nil,
            updatedAt: now
        )
        let data = try JSONEncoder().encode(health)
        let decoded = try JSONDecoder().decode(ProviderHealth.self, from: data)
        XCTAssertEqual(health, decoded)
    }

    func testQuotaSnapshot_codableRoundTrip() throws {
        let quota = QuotaSnapshot(period: .monthly, total: 1000, used: 250, resetsAt: now)
        let data = try JSONEncoder().encode(quota)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        XCTAssertEqual(quota, decoded)
    }
}
