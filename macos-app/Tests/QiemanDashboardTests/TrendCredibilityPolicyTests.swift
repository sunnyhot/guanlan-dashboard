import XCTest
@testable import QiemanDashboard

final class TrendCredibilityPolicyTests: XCTestCase {
    func testIntradayQuoteRequiresMinuteFreshness() {
        let fresh = TrendSourceFreshnessPolicy.assess(
            quoteType: .lastTrade,
            asOf: "2026-07-27 10:05:00",
            receivedAt: "2026-07-27 10:15:00"
        )
        let stale = TrendSourceFreshnessPolicy.assess(
            quoteType: .lastTrade,
            asOf: "2026-07-27 09:45:00",
            receivedAt: "2026-07-27 10:15:00"
        )

        XCTAssertEqual(fresh.freshnessStatus, .fresh)
        XCTAssertTrue(fresh.isFreshForExecution)
        XCTAssertEqual(stale.freshnessStatus, .stale)
        XCTAssertFalse(stale.isFreshForExecution)
    }

    func testClosedMarketQuoteIsPreviousCloseNotLiveExecutionPrice() {
        let assessment = TrendSourceFreshnessPolicy.assess(
            quoteType: .lastTrade,
            asOf: "2026-07-27 15:00:00",
            receivedAt: "2026-07-27 20:00:00"
        )

        XCTAssertEqual(assessment.freshnessStatus, .previousSessionClose)
        XCTAssertFalse(assessment.isFreshForExecution)
    }

    func testOfficialNAVUsesDailyFreshnessButCannotExecuteAfterHours() {
        let assessment = TrendSourceFreshnessPolicy.assess(
            quoteType: .officialNAV,
            asOf: "2026-07-24",
            receivedAt: "2026-07-27 20:00:00"
        )

        XCTAssertEqual(assessment.freshnessStatus, .fresh)
        XCTAssertFalse(assessment.isFreshForExecution)
    }

    func testRequestedTopicCannotMasqueradeAsContentAssociation() {
        let metadata = TrendEvidenceMetadata(
            sourceKind: .webSearch,
            sourceTier: .authoritative,
            requestedTopicKeys: ["沪深300", "000300"],
            metadataConfidence: .unknown
        )

        XCTAssertFalse(
            metadata.isAssociated(entityCode: "000300", entityName: "沪深300")
        )
    }

    func testUnknownDomainDoesNotReceiveAuthorityByDefault() {
        let classification = TrendSourceAuthorityRegistry().classify(
            urlString: "https://unregistered.example/article"
        )

        XCTAssertEqual(classification.tier, .unknown)
        XCTAssertEqual(classification.publisherKey, "unregistered.example")
    }

    func testInformationalActionStillRequiresLocalTargetEvidence() {
        let action = TrendActionCandidate(
            id: "watch-policy",
            kind: .watch,
            title: "观察政策",
            detail: "等待后续信号确认。",
            targetName: "沪深300",
            confidence: TrendConfidence(score: 50, label: "中"),
            triggerConditions: ["指数放量"],
            invalidatingConditions: ["指数转弱"],
            claimEvidence: TrendClaimEvidence(
                supportingEvidenceIDs: ["web:policy"]
            )
        )
        let webEvidence = TrendEvidence(
            id: "web:policy",
            sourceName: "测试网页",
            title: "政策",
            url: "https://www.gov.cn/policy",
            publishedAt: "2026-07-27",
            retrievedAt: "2026-07-27 10:00:00",
            summary: "沪深300相关政策。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .webSearch,
                sourceTier: .primary,
                entityNames: ["沪深300"],
                metadataConfidence: .ruleDerived
            )
        )

        let messages = TrendClaimEvidencePolicy().validateAction(
            action,
            evidenceByID: [webEvidence.id: webEvidence]
        )

        XCTAssertTrue(messages.contains { $0.contains("持仓") || $0.contains("行情事实") })
    }

    func testAuditRedactorKeepsSecurityCodeButRemovesCurrencyAmount() {
        let query = "分析 512000，用户投入人民币 100000 元，比较证券行业消息"
        let redacted = TrendAgentAuditRedactor.redactedSensitiveText(query)

        XCTAssertTrue(redacted.contains("512000"))
        XCTAssertFalse(redacted.contains("100000 元"))
        XCTAssertTrue(redacted.contains("[redacted]"))
    }
}
