import Foundation
import XCTest
@testable import QiemanDashboard

// Evidence Intelligence Slice 4 测试。
// 验证独立性分组、时效衰减、Claim Assessment 的综合判定。
final class EvidenceIntelligenceTests: XCTestCase {

    // MARK: - EvidenceIndependencePolicy

    func testIndependentCountGroupsByPublisherKey() {
        // 3 条外部证据,2 个不同 publisher → 2 个独立来源
        let evidence = [
            makeEvidence(id: "web:1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary),
            makeEvidence(id: "web:2", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary),  // 同 publisher → 合并
            makeEvidence(id: "web:3", sourceKind: .webSearch, publisherKey: "news.cn", tier: .authoritative)
        ]
        XCTAssertEqual(EvidenceIndependencePolicy.independentCount(for: evidence), 2)
    }

    func testIndependentCountExcludesUnknownPublisher() {
        let evidence = [
            makeEvidence(id: "web:1", sourceKind: .webSearch, publisherKey: "unknown", tier: .unknown),
            makeEvidence(id: "web:2", sourceKind: .webSearch, publisherKey: nil, tier: .unknown),
            makeEvidence(id: "web:3", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary)
        ]
        // 只有 gov.cn 算,unknown/nil 被排除
        XCTAssertEqual(EvidenceIndependencePolicy.independentCount(for: evidence), 1)
    }

    func testIndependentCountSeparatesFactualAndExternal() {
        // 2 个外部(gov.cn + news.cn)+ 1 个事实(portfolioSnapshot)
        let evidence = [
            makeEvidence(id: "ext:1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary),
            makeEvidence(id: "ext:2", sourceKind: .webSearch, publisherKey: "news.cn", tier: .authoritative),
            makeEvidence(id: "fact:1", sourceKind: .portfolioSnapshot, publisherKey: nil, tier: .primary)
        ]
        // 2 个外部独立组 + 1 个事实组 = 3
        XCTAssertEqual(EvidenceIndependencePolicy.independentCount(for: evidence), 3)
    }

    func testIndependentCountRespectsTierThreshold() {
        // community tier 不达 secondary 门槛 → 不计入
        let evidence = [
            makeEvidence(id: "web:1", sourceKind: .webSearch, publisherKey: "xueqiu.com", tier: .community),
            makeEvidence(id: "web:2", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary)
        ]
        // community 不达标(minTier=.secondary),只有 gov.cn 算
        XCTAssertEqual(EvidenceIndependencePolicy.independentCount(for: evidence, minTier: .secondary), 1)
    }

    // MARK: - EvidenceFreshnessPolicy

    func testFreshnessWebSearchRecent() {
        let recent = makeEvidence(id: "web:1", sourceKind: .webSearch, publishedAt: daysAgo(3))
        XCTAssertEqual(EvidenceFreshnessPolicy.assess(recent), .fresh)
    }

    func testFreshnessWebSearchStale() {
        let stale = makeEvidence(id: "web:1", sourceKind: .webSearch, publishedAt: daysAgo(45))
        XCTAssertEqual(EvidenceFreshnessPolicy.assess(stale), .stale)
    }

    func testFreshnessFilingLongValidity() {
        // SEC filing 90 天内 fresh(有效期比 web 长)
        let filing = makeEvidence(id: "sec:1", sourceKind: .officialFiling, publishedAt: daysAgo(60))
        XCTAssertEqual(EvidenceFreshnessPolicy.assess(filing), .fresh)
    }

    func testFreshnessNoPublishedAt() {
        let noDate = makeEvidence(id: "fact:1", sourceKind: .portfolioSnapshot, publishedAt: nil)
        // portfolioSnapshot 走 freshnessStatus 兜底(这里 nil → unknown)
        XCTAssertEqual(EvidenceFreshnessPolicy.assess(noDate), .unknown)
    }

    // MARK: - ClaimAssessmentEngine

    func testClaimAssessmentSupportedWhenTwoIndependentPlusStrongTier() {
        let supporting = [
            makeEvidence(id: "web:1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary, publishedAt: daysAgo(2)),
            makeEvidence(id: "web:2", sourceKind: .webSearch, publisherKey: "news.cn", tier: .authoritative, publishedAt: daysAgo(3))
        ]
        let assessment = ClaimAssessmentEngine.assess(
            supportingEvidence: supporting,
            counterEvidence: []
        )
        XCTAssertEqual(assessment.disposition, .supported)
        XCTAssertGreaterThanOrEqual(assessment.independentSourceGroupCount, 2)
        XCTAssertGreaterThanOrEqual(assessment.strongTierCount, 1)
    }

    func testClaimAssessmentContradictedWhenCounterOverwhelms() {
        let supporting = [
            makeEvidence(id: "web:1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary)
        ]
        let counter = [
            makeEvidence(id: "web:c1", sourceKind: .webSearch, publisherKey: "news.cn", tier: .authoritative),
            makeEvidence(id: "web:c2", sourceKind: .webSearch, publisherKey: "caixin.com", tier: .authoritative)
        ]
        let assessment = ClaimAssessmentEngine.assess(
            supportingEvidence: supporting,
            counterEvidence: counter
        )
        XCTAssertEqual(assessment.disposition, .contradicted)
        XCTAssertGreaterThanOrEqual(assessment.counterIndependentGroupCount, 2)
    }

    func testClaimAssessmentInsufficientWhenNoSupport() {
        let assessment = ClaimAssessmentEngine.assess(
            supportingEvidence: [],
            counterEvidence: []
        )
        XCTAssertEqual(assessment.disposition, .insufficient)
    }

    func testExitReviewThresholdMetWithTwoIndependentCounters() {
        let counter = [
            makeEvidence(id: "web:c1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary),
            makeEvidence(id: "web:c2", sourceKind: .webSearch, publisherKey: "news.cn", tier: .authoritative)
        ]
        let assessment = ClaimAssessmentEngine.assess(
            supportingEvidence: [],
            counterEvidence: counter
        )
        XCTAssertTrue(assessment.meetsExitReviewThreshold, "≥2 独立反向来源应满足 exitReview 门槛")
    }

    func testExitReviewThresholdNotMetWithSamePublisher() {
        let counter = [
            makeEvidence(id: "web:c1", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary),
            makeEvidence(id: "web:c2", sourceKind: .webSearch, publisherKey: "gov.cn", tier: .primary)  // 同 publisher
        ]
        let assessment = ClaimAssessmentEngine.assess(
            supportingEvidence: [],
            counterEvidence: counter
        )
        XCTAssertFalse(assessment.meetsExitReviewThreshold, "同 publisher 的反证不应满足独立性门槛")
    }

    // MARK: - 辅助

    private func makeEvidence(
        id: String,
        sourceKind: TrendEvidenceSourceKind,
        publisherKey: String? = nil,
        tier: TrendEvidenceSourceTier = .unknown,
        publishedAt: String? = "2026-08-01 10:00:00"
    ) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: publisherKey ?? "测试来源",
            title: "测试证据",
            url: publisherKey.map { "https://\($0)/article" },
            publishedAt: publishedAt,
            retrievedAt: "2026-08-05 10:00:00",
            summary: "测试",
            metadata: TrendEvidenceMetadata(
                sourceKind: sourceKind,
                sourceTier: tier,
                publisherKey: publisherKey,
                metadataConfidence: .ruleDerived
            )
        )
    }

    private func daysAgo(_ days: Int) -> String {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}
