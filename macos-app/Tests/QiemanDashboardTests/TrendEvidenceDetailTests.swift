import XCTest
@testable import QiemanDashboard

final class TrendEvidenceDetailTests: XCTestCase {
    func testResolvesClaimRolesAndLegacyReferencesWithoutDuplicates() {
        let supporting = evidence(id: "support")
        let counter = evidence(id: "counter")
        let context = evidence(id: "context")
        let referenced = evidence(id: "referenced")
        let detail = TrendEvidenceDetailModel(
            claimEvidence: TrendClaimEvidence(
                supportingEvidenceIDs: [supporting.id],
                counterEvidenceIDs: [counter.id],
                contextEvidenceIDs: [context.id]
            ),
            referencedEvidenceIDs: [
                supporting.id,
                referenced.id,
                "missing"
            ],
            evidenceLedger: [supporting, counter, context, referenced]
        )

        XCTAssertEqual(detail.items.map(\.role), [
            .supporting,
            .counter,
            .context,
            .referenced
        ])
        XCTAssertEqual(detail.items.map(\.evidence.id), [
            "support",
            "counter",
            "context",
            "referenced"
        ])
        XCTAssertEqual(detail.missingEvidenceIDs, ["missing"])
    }

    func testKeepsStructuredExemptionWhenNoEvidenceExists() {
        let detail = TrendEvidenceDetailModel(
            claimEvidence: TrendClaimEvidence(
                exemptionReason: "当前数据不足，方向已降为不确定。"
            ),
            referencedEvidenceIDs: [],
            evidenceLedger: []
        )

        XCTAssertTrue(detail.items.isEmpty)
        XCTAssertEqual(detail.exemptionReason, "当前数据不足，方向已降为不确定。")
    }

    private func evidence(id: String) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: "测试来源",
            title: id,
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-07-29 15:00:00",
            summary: "测试数据"
        )
    }
}
