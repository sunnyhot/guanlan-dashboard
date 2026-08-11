import XCTest
@testable import QiemanDashboard

final class TrendAssetDailyAttributionPolicyTests: XCTestCase {
    func testLegacyStaticDescriptionIsNotShownAsDailyCause() {
        let text = TrendAssetDailyAttributionPolicy.displayText(
            from: "组合核心持仓，市值较高，穿透集中于半导体方向。",
            hasDailyChange: true
        )

        XCTAssertTrue(text?.hasPrefix("原因待确认：") == true)
        XCTAssertFalse(text?.contains("市值较高") == true)
    }

    func testCausalAttributionRequiresCausalEvidence() {
        let invalid = asset(
            impactText: "涨跌归因：底层半导体股票上涨可能构成主要贡献。",
            supportingEvidenceIDs: ["portfolio:asset:000001"]
        )
        XCTAssertNotNil(TrendAssetDailyAttributionPolicy.validationMessage(for: invalid))

        let valid = asset(
            impactText: "涨跌归因：底层半导体股票上涨可能构成主要贡献。",
            supportingEvidenceIDs: ["market:stock:688041:2026-08-10 15:00:00"]
        )
        XCTAssertNil(TrendAssetDailyAttributionPolicy.validationMessage(for: valid))
    }

    func testExplicitUnavailableReasonPassesWithoutInventedEvidence() {
        let value = asset(
            impactText: "原因待确认：仅确认基金净值上涨，但缺少底层证券当日行情。",
            supportingEvidenceIDs: []
        )

        XCTAssertNil(TrendAssetDailyAttributionPolicy.validationMessage(for: value))
    }

    func testUnavailablePrefixCannotHideAnotherStaticDescription() {
        let value = asset(
            impactText: "原因待确认：组合市值较高，穿透持仓集中于半导体方向。",
            supportingEvidenceIDs: []
        )

        XCTAssertNotNil(TrendAssetDailyAttributionPolicy.validationMessage(for: value))
    }

    func testUnderlyingQuoteSelectionTakesTopThreeStocksPerFundAndDeduplicates() {
        let snapshot = PortfolioLookThroughSnapshot(
            expectedFundCount: 2,
            coveredFundCount: 2,
            fundDataCoveragePct: 100,
            disclosedSecurityCoveragePct: 20,
            unknownPortfolioWeightPct: 80,
            topPositions: [],
            industries: [],
            assetClasses: [],
            funds: [],
            disclosures: [
                "000001": disclosure(
                    code: "000001",
                    holdings: [
                        holding("A", weight: 9),
                        holding("B", weight: 8),
                        holding("C", weight: 7),
                        holding("D", weight: 6),
                    ]
                ),
                "000002": disclosure(
                    code: "000002",
                    holdings: [
                        holding("A", weight: 10),
                        holding("E", weight: 9),
                        holding("F", weight: 8),
                    ]
                ),
            ],
            warnings: []
        )

        XCTAssertEqual(
            TrendAssetDailyAttributionPolicy.underlyingQuoteCodes(in: snapshot),
            ["A", "B", "C", "E", "F"]
        )
    }

    private func asset(
        impactText: String,
        supportingEvidenceIDs: [String]
    ) -> TrendAssetView {
        TrendAssetView(
            id: "000001",
            name: "测试基金",
            code: "000001",
            sector: "半导体",
            impactText: impactText,
            horizons: [],
            rationale: impactText,
            counterSignals: ["若底层行情反转则重新评估。"],
            claimEvidence: TrendClaimEvidence(
                supportingEvidenceIDs: supportingEvidenceIDs
            )
        )
    }

    private func holding(_ code: String, weight: Double) -> FundUnderlyingHolding {
        FundUnderlyingHolding(
            code: code,
            name: "股票\(code)",
            kind: .stock,
            weightPct: weight,
            disclosureDate: "2026-06-30"
        )
    }

    private func disclosure(
        code: String,
        holdings: [FundUnderlyingHolding]
    ) -> FundLookThroughDisclosure {
        FundLookThroughDisclosure(
            fundCode: code,
            fundName: "基金\(code)",
            asOf: "2026-06-30",
            holdings: holdings,
            industries: [],
            assetAllocation: nil,
            sourceLabel: "测试披露",
            sourceURL: "https://example.com/\(code)",
            warnings: []
        )
    }
}
