import XCTest
@testable import QiemanDashboard

// PRES-1：Presentation Layer 测试。
//
// 锁定：DecisionNarrator 只解释不重决（确定性、覆盖 singlePreferred 与
// unresolvedTradeoff 两分支）、ResearchNarrator 故事线拼接、
// ArtifactQueryService 统一读面（latest 降序 / 点查 / kind 隔离 / limit）。

private let presDay = Date(timeIntervalSince1970: 1_860_000_000)

/// 与 WF-1 测试同款的决策材料（A 方案 cost 更低 → singlePreferred A）。
private struct PresMaterialsProvider: PortfolioDecisionMaterialsProviding {
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio, higherIsBetter: false
        )
        let band = IndifferenceBand(
            policyID: "pres-band", version: "v1",
            defaultBand: d("0.01"), rationale: "PRES 测试带"
        )
        let portfolio = PortfolioSnapshot(asOf: presDay, positions: [
            PortfolioPosition(
                subjectKey: "listing|A", assetClass: .equity,
                weight: Ratio(value: d("0.5"))
            ),
        ])
        func run(delta: String, directiveID: String) -> DecisionReplayer.PlannerRun {
            DecisionReplayer.PlannerRun(
                portfolio: portfolio, target: nil, remediationTargets: [],
                userDirectives: [
                    UserDirectiveInput(
                        subjectKey: "listing|A", deltaWeight: Ratio(value: d(delta)),
                        directiveID: directiveID, note: nil
                    )
                ],
                actionDomain: ActionDomain(
                    perSubjectBounds: [
                        "listing|A": .init(
                            lower: Ratio(value: d("-1")), upper: Ratio(value: d("1"))
                        )
                    ],
                    eligibleNewSubjects: [:], builderVersion: "pres-test",
                    newSubjectBuyUpper: Ratio(value: d("1"))
                ),
                plannerParameters: TargetRebalancePlanner.Parameters()
            )
        }
        return PortfolioDecisionMaterials(
            replayerMaterials: DecisionReplayer.ReplayMaterials(
                criterionDefinitions: [definition.fingerprint: definition],
                factorSnapshots: [:], observations: [:], band: band
            ),
            plannerRuns: [
                "A": run(delta: "0.05", directiveID: "u-A"),
                "B": run(delta: "-0.15", directiveID: "u-B"),
            ],
            target: nil,
            knowledgeContextSummary: "PRES"
        )
    }
}

/// 两方案同 cost（同 delta 绝对值）→ 互不支配 → unresolvedTradeoff。
private struct PresUnresolvedMaterialsProvider: PortfolioDecisionMaterialsProviding {
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        var base = try PresMaterialsProvider().materials(asOf: asOf)
        base = PortfolioDecisionMaterials(
            replayerMaterials: base.replayerMaterials,
            plannerRuns: [
                "A": DecisionReplayer.PlannerRun(
                    portfolio: base.plannerRuns["A"]!.portfolio,
                    target: nil, remediationTargets: [],
                    userDirectives: [
                        UserDirectiveInput(
                            subjectKey: "listing|A",
                            deltaWeight: Ratio(value: d("0.05")),
                            directiveID: "u-A", note: nil
                        )
                    ],
                    actionDomain: base.plannerRuns["A"]!.actionDomain,
                    plannerParameters: TargetRebalancePlanner.Parameters()
                ),
                "B": DecisionReplayer.PlannerRun(
                    portfolio: base.plannerRuns["B"]!.portfolio,
                    target: nil, remediationTargets: [],
                    userDirectives: [
                        UserDirectiveInput(
                            subjectKey: "listing|A",
                            deltaWeight: Ratio(value: d("-0.05")),
                            directiveID: "u-B", note: nil
                        )
                    ],
                    actionDomain: base.plannerRuns["B"]!.actionDomain,
                    plannerParameters: TargetRebalancePlanner.Parameters()
                ),
            ],
            target: nil,
            knowledgeContextSummary: "PRES-unresolved"
        )
        return base
    }
}

final class PresentationLayerTests: XCTestCase {

    private func makeDecisionArtifact(
        provider: PortfolioDecisionMaterialsProviding = PresMaterialsProvider()
    ) throws -> PortfolioDecisionArtifact {
        let materials = try provider.materials(asOf: presDay)
        let outcome = try DecisionReplayer().compute(
            materials: materials.replayerMaterials,
            plannerInputs: materials.plannerRuns,
            frozenNowByPlan: [:]
        )
        return PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig_pres_1")],
            criterionDefinitions: Array(materials.replayerMaterials.criterionDefinitions.values),
            factorSnapshotIDs: [],
            target: nil,
            band: materials.replayerMaterials.band,
            knowledgeContextSummary: materials.knowledgeContextSummary,
            decision: outcome.decision,
            comparison: outcome.comparison,
            plans: outcome.plans,
            plannerRuns: materials.plannerRuns,
            producedAt: presDay
        )
    }

    // MARK: - DecisionNarrator

    func testNarratesSinglePreferredWinner() throws {
        let artifact = try makeDecisionArtifact()
        XCTAssertEqual(artifact.decision.status, .singlePreferred)
        let narrative = DecisionNarrator().narrate(artifact)

        XCTAssertEqual(narrative.artifactID, artifact.id.rawValue)
        XCTAssertTrue(narrative.headline.contains("方案 A 胜出"))
        XCTAssertTrue(
            narrative.whyWinner.contains { $0.contains("方案 A 支配方案 B") }
        )
        XCTAssertTrue(narrative.tradeoffs.isEmpty)
        XCTAssertTrue(narrative.unknownBlockers.isEmpty)
        XCTAssertTrue(narrative.researchContext.contains("1 条研究信号"))

        // 确定性（只解释不重决：同 artifact 同叙述）
        XCTAssertEqual(DecisionNarrator().narrate(artifact), narrative)
    }

    func testNarratesUnresolvedTradeoff() throws {
        let artifact = try makeDecisionArtifact(
            provider: PresUnresolvedMaterialsProvider()
        )
        XCTAssertEqual(artifact.decision.status, .unresolvedTradeoff)
        let narrative = DecisionNarrator().narrate(artifact)

        XCTAssertTrue(narrative.headline.contains("互不支配"))
        XCTAssertTrue(narrative.headline.contains("A、B"))
        XCTAssertTrue(narrative.whyWinner.isEmpty)
        XCTAssertFalse(narrative.tradeoffs.isEmpty)
        XCTAssertTrue(
            narrative.tradeoffs.contains { $0.contains("可采纳方案 A：1 条动作") }
        )
    }

    // MARK: - ResearchNarrator

    func testNarratesResearchStory() throws {
        let assetSubject = try CanonicalRef(
            entityType: "listing", entityIDRawValue: "lst_story"
        )
        let portfolioSubject = try CanonicalRef(
            entityType: "fundShareClass", entityIDRawValue: "sc_story"
        )
        let signals = [
            InvestmentSignal(
                id: SignalID(rawValue: "sig_s1"),
                subjectCanonical: assetSubject,
                dimension: .momentum, direction: .bullish, strength: .strong,
                derivedFromEvidenceIDs: [EvidenceID(rawValue: "EV-S1")],
                effectiveAt: presDay, producer: .llmDefault,
                rationale: "动量强"
            ),
            InvestmentSignal(
                id: SignalID(rawValue: "sig_s2"),
                subjectCanonical: assetSubject,
                dimension: .value, direction: .neutral, strength: .moderate,
                derivedFromEvidenceIDs: [EvidenceID(rawValue: "EV-S2")],
                effectiveAt: presDay, producer: .llmDefault,
                rationale: "估值中性"
            ),
        ]
        let assetThesis = ResearchThesis(
            id: "thesis_s1", kind: .asset, subject: assetSubject,
            statement: "动量改善，估值中性。",
            supportingEvidenceIDs: signals.flatMap { $0.derivedFromEvidenceIDs },
            linkedSignalIDs: signals.map(\.id),
            createdAt: presDay, revisedAt: nil,
            sourceNotesFingerprints: ["fp-s1"]
        )
        let portfolioThesis = ResearchThesis(
            id: "thesis_s2", kind: .portfolio, subject: portfolioSubject,
            statement: "组合研究聚合。",
            supportingEvidenceIDs: signals.flatMap { $0.derivedFromEvidenceIDs },
            linkedSignalIDs: signals.map(\.id),
            createdAt: presDay, revisedAt: nil,
            sourceNotesFingerprints: ["fp-s1"]
        )
        let narrative = ResearchNarrator().narrate(
            theses: [assetThesis, portfolioThesis], signals: signals
        )

        XCTAssertTrue(narrative.headline.contains("1 份资产论点"))
        XCTAssertTrue(narrative.headline.contains("2 条信号"))
        XCTAssertEqual(narrative.portfolioStatement, "组合研究聚合。")
        XCTAssertEqual(narrative.assetStories.count, 1)
        XCTAssertTrue(
            narrative.assetStories[0].contains("MOMENTUM BULLISH、VALUE NEUTRAL")
        )
        XCTAssertEqual(narrative.signalDigest.count, 2)
        XCTAssertTrue(
            narrative.signalDigest[0].contains("MOMENTUM：BULLISH（STRONG，1 条证据）")
        )
    }

    func testNarratorDegradesWithoutPortfolioThesis() {
        let narrative = ResearchNarrator().narrate(theses: [], signals: [])
        XCTAssertTrue(narrative.headline.contains("尚无组合级论点"))
        XCTAssertTrue(narrative.assetStories.isEmpty)
        XCTAssertTrue(narrative.signalDigest.isEmpty)
    }

    // MARK: - ArtifactQueryService

    func testQueryServiceListsAndPointQueries() throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let service = ArtifactQueryService(repository: repository)

        // 落两个语义不同的决策 artifact（singlePreferred + unresolved）
        let earlier = try makeDecisionArtifact()
        try repository.writeArtifact(earlier)
        let different = try makeDecisionArtifact(
            provider: PresUnresolvedMaterialsProvider()
        )
        try repository.writeArtifact(different)

        // 列表：完整返回 + limit
        let list = try service.latestPortfolioDecisions(limit: 10)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(
            Set(list.map(\.artifactID)),
            Set([earlier.id.rawValue, different.id.rawValue])
        )
        let limited = try service.latestPortfolioDecisions(limit: 1)
        XCTAssertEqual(limited.count, 1)

        // 点查 + 概要字段
        let summary = try XCTUnwrap(
            list.first { $0.artifactID == earlier.id.rawValue }
        )
        XCTAssertEqual(summary.status, "singlePreferred")
        XCTAssertEqual(summary.admissiblePlans, ["A"])
        XCTAssertEqual(summary.signalCount, 1)

        let point = try service.portfolioDecision(id: earlier.id.rawValue)
        XCTAssertEqual(point, earlier)
        XCTAssertNil(try service.portfolioDecision(id: "dec_nonexistent"))

        // kind 隔离：决策 artifact 不出现在 discovery / intraday 列表
        XCTAssertTrue(try service.latestMarketDiscoveryReports().isEmpty)
        XCTAssertTrue(try service.latestIntradayReports().isEmpty)
    }

    func testQueryServiceAcrossKinds() throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let service = ArtifactQueryService(repository: repository)

        // discovery：直接组装最小报告落库（workflow 全链在 WF-2 测试已覆盖）
        let report = MarketDiscoveryReport(
            id: ArtifactID(rawValue: "mkt_pres"),
            producedAt: presDay,
            validityPolicy: .untilDependencyChanges,
            dependencies: [],
            asOf: presDay,
            universeVersion: 1,
            rankingPolicy: DiscoveryRankingPolicy(),
            candidates: [],
            coverageGaps: []
        )
        try repository.writeMarketDiscoveryReport(report)

        // intraday：手工组装最小报告
        let intraday = IntradayExecutionReport(
            id: ArtifactID(rawValue: "itd_pres"),
            producedAt: presDay,
            validityPolicy: .tradingSession(exchange: .nasdaq, sessionDate: presDay),
            dependencies: [],
            asOf: presDay,
            decision: .hold,
            eligibility: IntradayEligibilityPolicy(),
            plan: nil,
            gateVerdict: nil,
            holdReasons: ["测试 hold"],
            referencedSignalIDs: [],
            target: nil
        )
        try repository.database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(intraday), into: db)
        }

        XCTAssertEqual(
            try service.latestMarketDiscoveryReports().map(\.id),
            [report.id]
        )
        // 十六轮 P2:默认只返回当前时段仍有效的报告——测试报告是固定过去/
        // 未来时段,走 includeInvalid 拿全量断言
        XCTAssertEqual(
            try service.latestIntradayReports(includeInvalid: true).map(\.id),
            [intraday.id]
        )
        XCTAssertEqual(
            try service.marketDiscoveryReport(id: "mkt_pres")?.candidates.count,
            0
        )
        XCTAssertEqual(
            try service.intradayExecutionReport(id: "itd_pres")?.holdReasons,
            ["测试 hold"]
        )
        // 决策列表不被其他 kind 污染
        XCTAssertTrue(try service.latestPortfolioDecisions().isEmpty)
    }
}
