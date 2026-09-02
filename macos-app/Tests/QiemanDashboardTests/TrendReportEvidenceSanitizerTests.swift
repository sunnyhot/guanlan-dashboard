import XCTest
@testable import QiemanDashboard

// MARK: - 2026-08-31 终审爆量修复（幻觉 ID 清洗/周期降级/行动剔除/预算缩放）

final class TrendReportEvidenceSanitizerTests: XCTestCase {
    private func evidence(id: String, entityCode: String? = nil, entityName: String? = nil, kind: TrendEvidenceSourceKind = .marketQuote) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: "测试源",
            title: "证据\(id.suffix(6))",
            url: nil, publishedAt: nil, retrievedAt: "2026-08-31 11:30:00",
            summary: "s",
            metadata: TrendEvidenceMetadata(
                sourceKind: kind,
                sourceTier: .primary,
                requestedTopicKeys: ["test"],
                entityCodes: entityCode.map { [$0] } ?? [],
                entityNames: entityName.map { [$0] } ?? [],
                metadataConfidence: .deterministic
            )
        )
    }

    private func horizon(direction: TrendDirection = .bullish, supporting: [String], rationale: String = "偏强", whatWouldChange: String = "", counterSignals: [String] = []) -> TrendHorizonView {
        TrendHorizonView(
            horizon: .medium,
            direction: direction,
            confidence: TrendConfidence(score: 60, label: "中"),
            rationale: rationale,
            whatWouldChange: whatWouldChange,
            counterSignals: counterSignals,
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: supporting)
        )
    }

    func testHallucinatedIDsStrippedAndHorizonDowngraded() {
        // 账本里只有 market:stock:600519:2026-08-31 15:00:00；模型引用了 T 分隔的幻觉变体
        let real = evidence(id: "market:stock:600519:2026-08-31 15:00:00", entityCode: "161725")
        let module = TrendReportAssetBatchModule(assetTrends: [
            TrendAssetView(
                id: "fund:161725", name: "招商中证白酒", code: "161725", sector: "场外基金",
                impactText: "涨跌归因：茅台跌0.10%拖累。",
                horizons: [
                    horizon(supporting: ["market:stock:600519:2026-08-31T11:29:46"]),  // 幻觉：T 分隔
                    horizon(supporting: ["market:stock:600519:2026-08-31 15:00:00"], counterSignals: ["白酒需求证伪"]),  // 健康
                ],
                rationale: "r", counterSignals: ["c"],
                claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: ["vendor:alphavantage:daily:600519.SHH:2026-08-28"])  // 幻觉：AV 不覆盖 A股
            )
        ])
        let (sanitized, removed) = TrendReportEvidenceSanitizer.sanitizedAssetBatch(module, evidence: [real])
        XCTAssertTrue(removed.contains("market:stock:600519:2026-08-31T11:29:46"), "幻觉 ID 被剔除")
        XCTAssertTrue(removed.contains("vendor:alphavantage:daily:600519.SHH:2026-08-28"))
        let asset = sanitized.assetTrends[0]
        XCTAssertEqual(asset.claimEvidence.supportingEvidenceIDs, [], "资产级幻觉 supporting 清空")
        // 周期 1：幻觉 → 降 uncertain + 待观察信号 + whatWouldChange 兜底
        let downgraded = asset.horizons[0]
        XCTAssertEqual(downgraded.direction, .uncertain)
        XCTAssertTrue(downgraded.rationale.contains("待观察信号"))
        XCTAssertFalse(downgraded.whatWouldChange.isEmpty)
        XCTAssertEqual(downgraded.claimEvidence.exemptionReason, "App 降级：缺少与该标的关联的可引用支持证据")
        // 周期 2：健康 → 原样（含 counterSignals 保留）
        XCTAssertEqual(asset.horizons[1].direction, .bullish)
        XCTAssertEqual(asset.horizons[1].claimEvidence.supportingEvidenceIDs, ["market:stock:600519:2026-08-31 15:00:00"])
    }

    func testActionsWithoutLocalFactEvidenceDropped() {
        let localFact = evidence(id: "market:fund-estimate:161725:2026-08-31 11:28:00", entityName: "招商中证白酒指数(LOF)A", kind: .marketQuote)
        let actionOK = TrendActionCandidate(
            id: "a1", kind: .watch, title: "维持白酒观察", detail: "d", targetName: "招商中证白酒指数(LOF)A",
            confidence: TrendConfidence(score: 60, label: "中"),
            whatWouldChange: "w", triggerConditions: ["t"], invalidatingConditions: ["i"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: ["market:fund-estimate:161725:2026-08-31 11:28:00"])
        )
        let actionBad = TrendActionCandidate(
            id: "a2", kind: .considerIncrease, title: "维持A500定投计划", detail: "d", targetName: "华夏中证A500ETF联接A",
            confidence: TrendConfidence(score: 60, label: "中"),
            whatWouldChange: "w", triggerConditions: ["t"], invalidatingConditions: ["i"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: ["market:estimate:022430:2026-08-31"])  // 幻觉前缀
        )
        let module = TrendReportActionsModule(
            keyAssets: [
                TrendAssetView(id: "k1", name: "关键", code: "161725", sector: "s", impactText: "i", horizons: [], rationale: "r", counterSignals: [], claimEvidence: .empty)
            ],
            actions: [actionOK, actionBad],
            warnings: [TrendWarning(id: "w1", title: "t", detail: "d")],
            disclaimer: "仅供参考"
        )
        let (sanitized, dropped, removed) = TrendReportEvidenceSanitizer.sanitizedActions(module, evidence: [localFact])
        XCTAssertEqual(dropped, ["维持A500定投计划"], "无本地事实证据的行动被剔除")
        XCTAssertEqual(sanitized.actions.count, 1)
        XCTAssertEqual(sanitized.actions.first?.title, "维持白酒观察")
        XCTAssertTrue(removed.contains("market:estimate:022430:2026-08-31"))
        XCTAssertEqual(sanitized.keyAssets.first?.counterSignals.count, 1, "keyAssets 空 counterSignals 被补写")
        XCTAssertTrue(sanitized.disclaimer.contains("非投资建议"), "disclaimer 被补写")
    }

    /// 2026-09-02 根治(runID AD2D63F9):keyAsset 周期引底仓股票/组合级证据(与该基金
    /// 无关联)此前只清幻觉 ID 不做关联降级,终审必拒且错误文案触发 prepareRepairs
    /// 清空全部已暂存批次,健康运行与降级组装双双死于此。现在 keyAssets 与
    /// assetTrends 走同一条 sanitizedHorizon 清洗链。
    func testKeyAssetHorizonWithUnassociatedSupportDowngraded() {
        let stockEvidence = evidence(
            id: "vendor:alphavantage:daily:300308.SHZ:2026-09-01",
            entityCode: "300308.SHZ"
        )
        let portfolioEvidence = evidence(id: "portfolio:overview:RUN-1", entityName: "组合")
        let fundEvidence = evidence(
            id: "market:fund-estimate:007346:2026-09-02 11:31:00",
            entityCode: "007346"
        )
        let keyAsset = TrendAssetView(
            id: "k1", name: "易方达科技创新混合A", code: "007346", sector: "场外基金",
            impactText: "涨跌归因：重仓股深调拖累。",
            horizons: [
                horizon(direction: .bearish, supporting: ["vendor:alphavantage:daily:300308.SHZ:2026-09-01"]),
                horizon(direction: .neutralPositive, supporting: ["portfolio:overview:RUN-1"]),
                horizon(direction: .bullish, supporting: ["market:fund-estimate:007346:2026-09-02 11:31:00"]),
            ],
            rationale: "r",
            counterSignals: [],
            claimEvidence: .empty
        )
        let module = TrendReportActionsModule(
            keyAssets: [keyAsset], actions: [], warnings: [], disclaimer: "仅供参考"
        )
        let (sanitized, _, _) = TrendReportEvidenceSanitizer.sanitizedActions(
            module, evidence: [stockEvidence, portfolioEvidence, fundEvidence]
        )
        let horizons = sanitized.keyAssets[0].horizons
        XCTAssertEqual(horizons[0].direction, .uncertain, "底仓股票证据与基金无关联 → 降级")
        XCTAssertEqual(
            horizons[0].claimEvidence.exemptionReason,
            "App 降级：缺少与该标的关联的可引用支持证据"
        )
        XCTAssertTrue(horizons[0].rationale.contains("待观察信号"))
        XCTAssertEqual(horizons[1].direction, .uncertain, "组合级证据与基金无关联 → 降级")
        XCTAssertEqual(horizons[2].direction, .bullish, "基金自身行情证据关联 → 保留原方向")
        XCTAssertEqual(
            horizons[2].claimEvidence.supportingEvidenceIDs,
            ["market:fund-estimate:007346:2026-09-02 11:31:00"]
        )
    }

    func testWarningDecodesImpactFallback() throws {
        let json = #"{"id":"w1","title":"红利高估值风险","impact":"若利率转向可能补跌。"}"#
        let warning = try JSONDecoder().decode(TrendWarning.self, from: Data(json.utf8))
        XCTAssertEqual(warning.detail, "若利率转向可能补跌。", "impact 字段回退到 detail")
        let normal = try JSONDecoder().decode(TrendWarning.self, from: Data(#"{"id":"w2","title":"t","detail":"d"}"#.utf8))
        XCTAssertEqual(normal.detail, "d")
    }

    func testInvalidSubmissionBudgetScalesWithFundCount() {
        XCTAssertEqual(TrendResearchAgent.effectiveInvalidSubmissionBudget(fundCount: 8, base: 4), 5)
        XCTAssertEqual(TrendResearchAgent.effectiveInvalidSubmissionBudget(fundCount: 24, base: 4), 7, "24 只基金 → 4+3")
        XCTAssertEqual(TrendResearchAgent.effectiveInvalidSubmissionBudget(fundCount: 0, base: 4), 4, "空快照保持基线")
    }

    func testEvidenceIndexToolRegistered() {
        let registry = TrendResearchToolRegistry()
        XCTAssertTrue(registry.tools.keys.contains("get_evidence_index"))
        XCTAssertNotNil(registry.definitions.first { $0.function.name == "get_evidence_index" })
    }
}
