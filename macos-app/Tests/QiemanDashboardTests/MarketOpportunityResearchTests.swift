import XCTest
@testable import QiemanDashboard

final class MarketOpportunityResearchTests: XCTestCase {
    func testEngineIgnoresPortfolioSectorsAndKeepsWholeMarketOpportunities() throws {
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

        XCTAssertEqual(analysis.marketSectorOpportunities.map(\.name), ["机器人"])
        XCTAssertEqual(analysis.marketSignalCount, 1)
    }

    func testPortfolioEvidenceExcludesWholeMarketResearch() throws {
        let portfolioEvidence = makeEvidence(
            id: "portfolio-only",
            publisher: "portfolio.local",
            tier: .primary,
            sector: "组合"
        )
        let marketEvidence = makeEvidence(
            id: "market-only",
            publisher: "market.example",
            tier: .authoritative,
            sector: "机器人"
        )
        let base = makeReport(evidence: [portfolioEvidence, marketEvidence])
        let report = TrendAnalysisReport(
            id: base.id,
            generatedAt: base.generatedAt,
            dataAsOf: base.dataAsOf,
            privacyMode: base.privacyMode,
            externalSignalStatus: base.externalSignalStatus,
            portfolio: TrendPortfolioSummary(
                headline: base.portfolio.headline,
                riskLevel: base.portfolio.riskLevel,
                summary: base.portfolio.summary,
                claimEvidence: TrendClaimEvidence(
                    supportingEvidenceIDs: [portfolioEvidence.id]
                )
            ),
            horizons: base.horizons,
            marketOutlook: [
                TrendMarketOutlook(
                    id: "whole-market",
                    name: "全市场",
                    category: "index",
                    direction: .neutralPositive,
                    confidence: TrendConfidence(score: 65, label: "中"),
                    rationale: "全市场研究结论。",
                    evidenceIDs: [marketEvidence.id],
                    counterSignals: [],
                    claimEvidence: TrendClaimEvidence(
                        supportingEvidenceIDs: [marketEvidence.id]
                    )
                )
            ],
            sectors: base.sectors,
            opportunities: base.opportunities,
            keyAssets: base.keyAssets,
            assetTrends: base.assetTrends,
            actions: base.actions,
            evidence: base.evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: base.schemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
        )

        XCTAssertEqual(report.portfolioReferencedEvidenceIDs, [portfolioEvidence.id])
        XCTAssertEqual(report.portfolioEvidence.map(\.id), [portfolioEvidence.id])
        XCTAssertTrue(report.referencedEvidenceIDs.contains(marketEvidence.id))
    }

    func testMarketOpportunityRemainsVisibleWhenPortfolioOwnsSameSector() throws {
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

        XCTAssertEqual(analysis.marketSectorOpportunities.map(\.name), ["半导体"])
        XCTAssertEqual(analysis.marketSectorOpportunities.first?.recommendation, .keyOpportunity)
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

        XCTAssertNil(MarketOpportunityEngine.analyze(report: report))
    }

    func testEngineDoesNotProjectPortfolioSectorsIntoMarketRadar() {
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
        XCTAssertTrue(prompt.contains("assetTrends.impactText 是「当日涨跌归因」"))
        XCTAssertTrue(prompt.contains("原因待确认："))
        XCTAssertTrue(prompt.contains("market:stock:*"))
        XCTAssertTrue(prompt.contains("\"scope\":\"marketWide\""))
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
