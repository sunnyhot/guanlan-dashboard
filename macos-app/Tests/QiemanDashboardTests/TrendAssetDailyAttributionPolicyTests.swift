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

    // MARK: - v4.6.1 待确认边界 App 兜底(2026-08-28 真实运行拒批死循环修复)

    func testAppendantFixesRealWorldUnavailableWithoutBoundaryWord() {
        // 真实运行最后一轮的实际提交:语义已说清"什么没确认",但没命中
        // 六词硬词表(缺少/未取得/未提供/无法/不足/没有),被拒到预算耗尽。
        let realWorld = "原因待确认：盘中估值+0.26%，跟踪创业板指+0.18%上行，重仓股宁德时代-0.93%逆势走弱，但基金涨幅高于指数0.08个百分点，超额收益具体来源原因待确认。"
        let patched = TrendAssetDailyAttributionPolicy.appendingMissingEvidenceBoundaryIfNeeded(realWorld)
        XCTAssertTrue(patched.contains("缺少可佐证"), "App 应补写缺失证据说明")
        XCTAssertTrue(patched.hasPrefix("原因待确认："), "前缀不得被改写")
        XCTAssertNil(
            TrendAssetDailyAttributionPolicy.validationMessage(
                for: asset(impactText: patched, supportingEvidenceIDs: [])
            ),
            "补写后必须通过校验"
        )
    }

    func testAppendantLeavesBoundaryWordedAndAttributionTextsUntouched() {
        let worded = "原因待确认：仅确认净值变化，但缺少底层证券当日行情。"
        XCTAssertEqual(
            TrendAssetDailyAttributionPolicy.appendingMissingEvidenceBoundaryIfNeeded(worded),
            worded,
            "已含边界词的不动"
        )
        let attribution = "涨跌归因：底层上涨构成主要贡献。"
        XCTAssertEqual(
            TrendAssetDailyAttributionPolicy.appendingMissingEvidenceBoundaryIfNeeded(attribution),
            attribution,
            "归因文本不在兜底范围"
        )
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

// MARK: - 2026-08-28 死循环修复：无因果证据的归因自动降级

final class AttributionDowngradeTests: XCTestCase {
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

    func testAttributionWithoutCausalEvidenceDowngradesToUnavailable() {
        let noEvidence = asset(
            impactText: "涨跌归因：当日盘中估值跌0.31%，跟随港股科技回调。",
            supportingEvidenceIDs: ["manager:forumHit:86149"]
        )
        let downgraded = TrendAssetDailyAttributionPolicy.downgradedAttributionText(noEvidence)
        XCTAssertNotNil(downgraded, "非因果证据（manager 帖子）也要降级")
        XCTAssertTrue(downgraded?.hasPrefix("原因待确认：") ?? false)
        XCTAssertTrue(downgraded?.contains("缺少可佐证的底层证券当日行情或外部研究证据") ?? false)
        XCTAssertTrue(downgraded?.contains("跟随港股科技回调") ?? false, "原文保留为线索")
        // 降级后的文本通过校验（含边界词「缺少」）
        let patched = asset(
            impactText: downgraded ?? "",
            supportingEvidenceIDs: ["manager:forumHit:86149"]
        )
        XCTAssertNil(TrendAssetDailyAttributionPolicy.validationMessage(for: patched))
    }

    func testAttributionWithCausalEvidenceUntouched() {
        let evidenced = asset(
            impactText: "涨跌归因：重仓的贵州茅台涨0.39%带动估值。",
            supportingEvidenceIDs: ["market:stock:600519:2026-08-28 15:00:00"]
        )
        XCTAssertNil(TrendAssetDailyAttributionPolicy.downgradedAttributionText(evidenced), "有行情证据不降级")
    }

    func testNonAttributionPrefixNotDowngraded() {
        let malformed = asset(
            impactText: "组合核心持仓，市值较高。",
            supportingEvidenceIDs: []
        )
        XCTAssertNil(TrendAssetDailyAttributionPolicy.downgradedAttributionText(malformed), "错前缀仍走原校验拒绝")
    }
}
