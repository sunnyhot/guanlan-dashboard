import XCTest
@testable import QiemanDashboard

final class MarketOpportunityResearchTests: XCTestCase {
    func testEngineSeparatesHeldSectorActionsFromUnheldMarketOpportunities() throws {
        let consumerEvidence = makeEvidence(
            id: "consumer-risk",
            publisher: "news.cn",
            tier: .authoritative,
            sector: "消费"
        )
        let robotEvidence = makeEvidence(
            id: "robot-opportunity",
            publisher: "caixin.com",
            tier: .authoritative,
            sector: "机器人"
        )
        let report = makeReport(
            sectors: [
                makeSector(
                    name: "消费",
                    direction: .neutralNegative,
                    score: 72,
                    evidenceIDs: [consumerEvidence.id]
                )
            ],
            opportunities: [
                makeOpportunity(
                    name: "机器人",
                    category: "sector",
                    direction: .neutralPositive,
                    score: 68,
                    evidenceIDs: [robotEvidence.id]
                )
            ],
            evidence: [consumerEvidence, robotEvidence]
        )

        let analysis = try XCTUnwrap(MarketOpportunityEngine.analyze(report: report))

        XCTAssertEqual(analysis.heldSectors.map(\.name), ["消费"])
        XCTAssertEqual(analysis.heldSectors.first?.recommendation, .considerReduce)
        XCTAssertEqual(analysis.heldSectors.first?.portfolioExposureText, "组合已有暴露")
        XCTAssertEqual(analysis.marketSectorOpportunities.map(\.name), ["机器人"])
        XCTAssertFalse(analysis.marketSectorOpportunities.contains { $0.name == "消费" })
    }

    func testHeldMarketOpportunityIsMergedIntoHeldSectorInsteadOfDuplicated() throws {
        let evidence = makeEvidence(
            id: "semiconductor-positive",
            publisher: "news.cn",
            tier: .authoritative,
            sector: "半导体"
        )
        let report = makeReport(
            sectors: [
                makeSector(
                    name: "半导体",
                    direction: .neutralPositive,
                    score: 70,
                    evidenceIDs: [evidence.id]
                )
            ],
            opportunities: [
                makeOpportunity(
                    name: "半导体",
                    category: "sector",
                    direction: .bullish,
                    score: 80,
                    evidenceIDs: [evidence.id]
                )
            ],
            evidence: [evidence]
        )

        let analysis = try XCTUnwrap(MarketOpportunityEngine.analyze(report: report))

        XCTAssertEqual(analysis.heldSectors.first?.recommendation, .considerAdd)
        XCTAssertTrue(analysis.marketSectorOpportunities.isEmpty)
    }

    func testHighConvictionBuyRequiresTwoIndependentSourcesAndAuthoritativeEvidence() throws {
        let authoritative = makeEvidence(
            id: "robot-authoritative",
            publisher: "news.cn",
            tier: .authoritative,
            sector: "机器人"
        )
        let secondary = makeEvidence(
            id: "robot-secondary",
            publisher: "eastmoney.com",
            tier: .secondary,
            sector: "机器人"
        )
        let opportunity = makeOpportunity(
            name: "机器人",
            category: "sector",
            direction: .bullish,
            score: 82,
            evidenceIDs: [authoritative.id, secondary.id]
        )

        let strong = try XCTUnwrap(
            MarketOpportunityEngine.analyze(
                report: makeReport(
                    opportunities: [opportunity],
                    evidence: [authoritative, secondary]
                )
            )
        )
        let weak = try XCTUnwrap(
            MarketOpportunityEngine.analyze(
                report: makeReport(
                    opportunities: [opportunity],
                    evidence: [authoritative]
                )
            )
        )

        XCTAssertEqual(strong.marketSectorOpportunities.first?.recommendation, .considerBuying)
        XCTAssertEqual(strong.marketSectorOpportunities.first?.independentExternalSourceCount, 2)
        XCTAssertEqual(weak.marketSectorOpportunities.first?.recommendation, .keyOpportunity)
    }

    func testEngineKeepsBroadMarketAndAssetClassIndependentFromLongTermViews() throws {
        let report = makeReport(
            opportunities: [
                makeOpportunity(name: "黄金", category: "assetClass"),
                makeOpportunity(name: "中证1000", category: "index")
            ]
        )

        let analysis = try XCTUnwrap(MarketOpportunityEngine.analyze(report: report))

        XCTAssertEqual(analysis.assetClasses.map(\.name), ["黄金"])
        XCTAssertEqual(analysis.markets.map(\.name), ["中证1000"])
        XCTAssertFalse(analysis.markets.contains { $0.name == "沪深300" })
    }

    func testEngineHidesLegacyPortfolioRelatedOpportunityFromMarketPool() throws {
        let evidence = makeEvidence(
            id: "held-consumer",
            publisher: "news.cn",
            tier: .authoritative,
            sector: "消费"
        )
        let report = makeReport(
            sectors: [
                makeSector(
                    name: "消费",
                    direction: .neutral,
                    score: 52,
                    evidenceIDs: [evidence.id]
                )
            ],
            opportunities: [
                makeOpportunity(
                    name: "当前持仓补仓方向",
                    category: "sector",
                    scope: .portfolioRelated
                )
            ],
            evidence: [evidence]
        )

        let analysis = try XCTUnwrap(MarketOpportunityEngine.analyze(report: report))

        XCTAssertEqual(analysis.heldSectors.map(\.name), ["消费"])
        XCTAssertTrue(analysis.marketSectorOpportunities.isEmpty)
        XCTAssertFalse(analysis.marketScanCompleted)
    }

    func testEngineDoesNotCreateDefaultHeldCardsWithoutEvidence() {
        let report = makeReport(
            sectors: [makeSector(name: "制造业", direction: .uncertain, score: 25)]
        )

        XCTAssertNil(MarketOpportunityEngine.analyze(report: report))
    }

    func testLegacyOpportunityWithoutScopeDecodesAsPortfolioRelated() throws {
        let data = Data(
            """
            {
              "id":"legacy","name":"消费","category":"sector",
              "direction":"neutral","confidence":{"score":50,"label":"中"},
              "rationale":"旧报告","triggerConditions":[],"invalidatingConditions":[],
              "evidenceIDs":[],"counterSignals":[]
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(TrendOpportunity.self, from: data)

        XCTAssertEqual(decoded.scope, .portfolioRelated)
    }

    func testHarnessRequiresEverySectorGroupBeforeSubmission() throws {
        var harness = TrendResearchHarnessState(snapshot: .placeholder)
        _ = harness.process(
            toolName: "get_portfolio_overview",
            result: .content(TrendResearchToolEnvelope.success(["portfolio": [:]]))
        )
        _ = harness.process(
            toolName: "web_search",
            result: webResult(kind: .assetClass, key: "黄金")
        )
        _ = harness.process(
            toolName: "web_search",
            result: webResult(kind: .index, key: "沪深300")
        )

        for group in MarketOpportunityUniverse.sectorGroups.dropLast() {
            _ = harness.process(
                toolName: "web_search",
                result: webResult(kind: .sector, key: group.key)
            )
        }

        XCTAssertFalse(harness.opportunitySearchCoverageComplete)
        XCTAssertFalse(harness.readyForSubmission(webSearchConfigured: true))
        XCTAssertFalse(
            harness.readyForSubmission(
                webSearchConfigured: true,
                allowInsufficientWebEvidence: true
            )
        )
        XCTAssertEqual(
            harness.missingOpportunitySearchSectorGroups,
            [try XCTUnwrap(MarketOpportunityUniverse.sectorGroups.last?.key)]
        )
        XCTAssertTrue(
            harness.nextStepHint(webSearchConfigured: true, remainingWebSearches: 3)
                .contains("板块分组")
        )

        if let lastGroup = MarketOpportunityUniverse.sectorGroups.last {
            _ = harness.process(
                toolName: "web_search",
                result: webResult(kind: .sector, key: lastGroup.key)
            )
        }

        XCTAssertTrue(harness.opportunitySearchCoverageComplete)
        XCTAssertTrue(harness.readyForSubmission(webSearchConfigured: true))
    }

    func testPromptRequiresGroupedWholeMarketScan() throws {
        let messages = TrendResearchPromptBuilder().initialMessages(snapshot: .placeholder)
        let prompt = try XCTUnwrap(messages.first?.content)

        XCTAssertTrue(prompt.contains("全市场机会发现"))
        XCTAssertTrue(prompt.contains("独立于用户当前持仓"))
        XCTAssertTrue(prompt.contains("六个 sector 分组"))
        XCTAssertTrue(prompt.contains("科技成长"))
        XCTAssertTrue(prompt.contains("防御价值"))
        XCTAssertTrue(prompt.contains("跨组比较"))
        XCTAssertTrue(prompt.contains("statistical_industries"))
        XCTAssertTrue(prompt.contains("不得直接输出为 sectors"))
        XCTAssertTrue(prompt.contains("\"scope\":\"marketWide\""))
    }

    private func webResult(
        kind: TrendResearchTargetKind,
        key: String
    ) -> TrendResearchToolResult {
        let id = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "query": "测试查询",
                    "research_target": [
                        "kind": kind.rawValue,
                        "key": key,
                    ],
                    "results": [[
                        "evidence_id": "web:tavily:\(id)",
                        "title": "测试证据",
                        "url": "https://example.com/\(id)",
                    ]],
                    "count": 1,
                ],
                evidenceIDs: ["web:tavily:\(id)"]
            )
        )
    }

    private func makeOpportunity(
        name: String,
        category: String,
        scope: TrendOpportunityScope = .marketWide,
        direction: TrendDirection = .neutralPositive,
        score: Int = 68,
        evidenceIDs: [String] = []
    ) -> TrendOpportunity {
        TrendOpportunity(
            id: "\(category)-\(name)",
            name: name,
            category: category,
            scope: scope,
            direction: direction,
            confidence: TrendConfidence(score: score, label: TrendConfidence.label(for: score)),
            rationale: "来自全市场搜索的独立研究结论。",
            triggerConditions: ["基本面与价格趋势同时确认。"],
            invalidatingConditions: ["核心逻辑被新数据否定。"],
            evidenceIDs: evidenceIDs,
            counterSignals: ["短期仍可能反复。"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: evidenceIDs)
        )
    }

    private func makeSector(
        name: String,
        direction: TrendDirection,
        score: Int,
        evidenceIDs: [String] = []
    ) -> TrendSectorView {
        TrendSectorView(
            id: "held-\(name)",
            name: name,
            exposureText: "组合已有暴露",
            direction: direction,
            confidence: TrendConfidence(score: score, label: TrendConfidence.label(for: score)),
            rationale: "组合穿透后的板块判断。",
            evidenceIDs: evidenceIDs,
            counterSignals: ["基本面变化时重新评估。"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: evidenceIDs)
        )
    }

    private func makeEvidence(
        id: String,
        publisher: String,
        tier: TrendEvidenceSourceTier,
        sector: String
    ) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: publisher,
            title: "\(sector)研究依据",
            url: "https://\(publisher)/\(id)",
            publishedAt: "2026-08-07",
            retrievedAt: "2026-08-07T10:00:00Z",
            summary: "与\(sector)方向直接相关的研究内容。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .webSearch,
                sourceTier: tier,
                publisherKey: publisher,
                sectorKeys: [sector],
                metadataConfidence: .ruleDerived
            )
        )
    }

    private func makeReport(
        sectors: [TrendSectorView] = [],
        opportunities: [TrendOpportunity] = [],
        evidence: [TrendEvidence] = []
    ) -> TrendAnalysisReport {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-08-07 10:00:00",
            externalSignalStatus: .partial
        )
        return TrendAnalysisReport(
            id: base.id,
            generatedAt: base.generatedAt,
            dataAsOf: base.dataAsOf,
            privacyMode: base.privacyMode,
            externalSignalStatus: base.externalSignalStatus,
            portfolio: base.portfolio,
            horizons: base.horizons,
            marketOutlook: [
                TrendMarketOutlook(
                    id: "held-market",
                    name: "沪深300",
                    category: "index",
                    direction: .neutral,
                    confidence: TrendConfidence(score: 55, label: "中"),
                    rationale: "组合长期研判里的市场观点。",
                    evidenceIDs: [],
                    counterSignals: ["行情变化时重新评估。"]
                )
            ],
            sectors: sectors,
            opportunities: opportunities,
            keyAssets: base.keyAssets,
            assetTrends: base.assetTrends,
            actions: base.actions,
            evidence: evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: base.schemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
        )
    }
}
