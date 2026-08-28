import XCTest
@testable import QiemanDashboard

final class TrendAnalysisStoreTests: XCTestCase {
    func testAgentRunLogStorePersistsOrderedFailureDetailsWithRestrictedPermissions() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-agent.log")
        let store = TrendAgentRunLogStore()

        try store.beginRun(
            at: url,
            trigger: "scheduled",
            model: "glm-5.2",
            startedAt: "2026-07-24 14:30:00"
        )
        try store.append(
            TrendProgressLog(
                timestamp: "2026-07-24 14:30:01",
                message: "正在等待模型响应",
                level: .activity
            ),
            to: url
        )
        try store.append(
            TrendProgressLog(
                timestamp: "2026-07-24 14:30:03",
                message: "Agent 执行失败",
                detail: "HTTP 429",
                level: .error
            ),
            to: url
        )

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("trigger: scheduled"))
        XCTAssertTrue(content.contains("[activity] 正在等待模型响应"))
        XCTAssertTrue(content.contains("[error] Agent 执行失败"))
        XCTAssertTrue(content.contains("    HTTP 429"))
        XCTAssertLessThan(
            try XCTUnwrap(content.range(of: "正在等待模型响应")?.lowerBound),
            try XCTUnwrap(content.range(of: "Agent 执行失败")?.lowerBound)
        )
        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.map(\.message), ["正在等待模型响应", "Agent 执行失败"])
        XCTAssertEqual(loaded.last?.level, .error)
        XCTAssertEqual(loaded.last?.detail, "HTTP 429")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testSettingsStoreReturnsEmptyProviderWhenFileIsMissing() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-settings.json")

        let settings = try isolatedSettingsStore().load(from: url)

        XCTAssertFalse(settings.provider.isConfigured)
        XCTAssertEqual(settings.provider.timeoutSeconds, 300)
        XCTAssertFalse(settings.webSearch.isConfigured)
        XCTAssertTrue(settings.officialSources.enabled)
        XCTAssertFalse(settings.officialSources.isSECConfigured)
        XCTAssertFalse(settings.alphaVantage.enabled)
        XCTAssertEqual(settings.alphaVantage.dailyRequestLimit, 25)
        XCTAssertEqual(settings.defaultPrivacyMode, .sanitized)
        XCTAssertFalse(settings.dailyAutoAnalysisEnabled)
        XCTAssertEqual(settings.dailyAutoAnalysisTimes, ["09:30", "14:30"])
    }

    func testSettingsStoreSavesAndLoadsProviderSettings() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-settings.json")
        let settings = TrendAnalysisSettings(
            provider: TrendAIProviderSettings(
                providerName: "智谱",
                baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
                model: "glm-5.2",
                apiKey: "sk-test-secret",
                timeoutSeconds: 180
            ),
            webSearch: TavilySearchSettings(apiKey: "tvly-test-secret"),
            officialSources: OfficialSourceSettings(
                enabled: true,
                secContactEmail: "research@example.com"
            ),
            alphaVantage: AlphaVantageSettings(
                enabled: true,
                apiKey: "alpha-test-secret",
                dailyRequestLimit: 25
            ),
            defaultPrivacyMode: .fullDetail,
            dailyAutoAnalysisEnabled: true,
            dailyAutoAnalysisTimes: ["15:10", "09:30"],
            lastAutoAnalysisDay: "2026-06-22",
            lastAutoAnalysisSlotKey: "2026-06-22 15:10"
        )

        let store = try isolatedSettingsStore()
        try store.save(settings, to: url)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded.provider.providerName, "智谱")
        XCTAssertEqual(loaded.provider.baseURL, "https://open.bigmodel.cn/api/coding/paas/v4")
        XCTAssertEqual(loaded.provider.model, "glm-5.2")
        XCTAssertEqual(loaded.provider.apiKey, "sk-test-secret")
        XCTAssertEqual(loaded.provider.timeoutSeconds, 180)
        XCTAssertEqual(loaded.webSearch.apiKey, "tvly-test-secret")
        XCTAssertTrue(loaded.officialSources.isSECConfigured)
        XCTAssertEqual(loaded.officialSources.secContactEmail, "research@example.com")
        XCTAssertTrue(loaded.alphaVantage.isConfigured)
        XCTAssertEqual(loaded.alphaVantage.apiKey, "alpha-test-secret")
        XCTAssertEqual(loaded.alphaVantage.dailyRequestLimit, 25)
        XCTAssertEqual(loaded.defaultPrivacyMode, settings.defaultPrivacyMode)
        XCTAssertEqual(loaded.dailyAutoAnalysisEnabled, settings.dailyAutoAnalysisEnabled)
        XCTAssertEqual(loaded.dailyAutoAnalysisTimes, ["09:30", "15:10"])
        XCTAssertEqual(loaded.lastAutoAnalysisDay, settings.lastAutoAnalysisDay)
        XCTAssertEqual(loaded.lastAutoAnalysisSlotKey, "2026-06-22 15:10")
    }

    func testSettingsStoreKeepsLegacyProviderSettingsAndUsesDefaultSchedule() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-settings.json")
        try """
        {
          "dailyAutoAnalysisEnabled": true,
          "defaultPrivacyMode": "完整明细",
          "lastAutoAnalysisDay": "2026-06-22",
          "provider": {
            "baseURL": "https://open.bigmodel.cn/api/coding/paas/v4",
            "model": "glm-5.2",
            "providerName": "智谱",
            "supportsOnlineSearch": true,
            "timeoutSeconds": 60
          }
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try isolatedSettingsStore().load(from: url)

        XCTAssertEqual(loaded.provider.baseURL, "https://open.bigmodel.cn/api/coding/paas/v4")
        XCTAssertEqual(loaded.provider.model, "glm-5.2")
        XCTAssertEqual(loaded.provider.providerName, "智谱")
        XCTAssertEqual(loaded.provider.timeoutSeconds, 60)
        XCTAssertFalse(loaded.webSearch.isConfigured)
        XCTAssertTrue(loaded.officialSources.enabled)
        XCTAssertFalse(loaded.officialSources.isSECConfigured)
        XCTAssertFalse(loaded.alphaVantage.isConfigured)
        XCTAssertEqual(loaded.defaultPrivacyMode, .fullDetail)
        XCTAssertTrue(loaded.dailyAutoAnalysisEnabled)
        XCTAssertEqual(loaded.dailyAutoAnalysisTimes, ["09:30", "14:30"])
        XCTAssertEqual(loaded.lastAutoAnalysisDay, "2026-06-22")
    }

    func testSettingsStoreMigratesSingleLegacyScheduleTime() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-settings.json")
        try """
        {
          "dailyAutoAnalysisEnabled": true,
          "dailyAutoAnalysisTime": "15:10",
          "defaultPrivacyMode": "脱敏摘要",
          "provider": {}
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try isolatedSettingsStore().load(from: url)

        XCTAssertEqual(loaded.dailyAutoAnalysisTimes, ["15:10"])
    }

    func testReportStoreKeepsLatestSuccessfulReport() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("trend-report.json")
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-22 10:00:00",
            externalSignalStatus: .available
        )

        try TrendAnalysisReportStore().save(report, to: url)
        let loaded = try TrendAnalysisReportStore().load(from: url)

        XCTAssertEqual(loaded?.generatedAt, "2026-06-22 10:00:00")
        XCTAssertEqual(loaded?.externalSignalStatus, .available)
    }

    func testReportDecodesExpandedMarketOpportunityAndAssetTrendSections() throws {
        let data = Data(expandedReportJSON.utf8)

        let report = try JSONDecoder().decode(TrendAnalysisReport.self, from: data)

        XCTAssertEqual(report.marketOutlook.map(\.name), ["沪深300", "黄金"])
        XCTAssertEqual(report.marketOutlook.map(\.categoryDisplayName), ["大盘宽基", "商品"])
        XCTAssertEqual(report.opportunities.map(\.name), ["黄金配置窗口"])
        XCTAssertEqual(report.assetTrends.map(\.name), ["消费指数基金"])
        XCTAssertEqual(report.assetTrends.first?.code, "000001")
    }

    func testMarketOutlookLocalizesStructuredCategoryValues() {
        func outlook(category: String) -> TrendMarketOutlook {
            TrendMarketOutlook(
                id: category,
                name: "测试",
                category: category,
                direction: .neutral,
                confidence: TrendConfidence(score: 60, label: "中"),
                rationale: "测试",
                evidenceIDs: [],
                counterSignals: []
            )
        }

        XCTAssertEqual(outlook(category: "index").categoryDisplayName, "指数")
        XCTAssertEqual(outlook(category: "assetClass").categoryDisplayName, "大类资产")
        XCTAssertEqual(outlook(category: "asset_class").categoryDisplayName, "大类资产")
        XCTAssertEqual(outlook(category: "商品").categoryDisplayName, "商品")
    }

    func testLegacyReportDecodesMissingExpandedSectionsAsEmptyArrays() throws {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-22 12:00:00",
            externalSignalStatus: .partial
        )
        let encoded = try JSONEncoder().encode(report)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "marketOutlook")
        legacyObject.removeValue(forKey: "opportunities")
        legacyObject.removeValue(forKey: "assetTrends")
        let data = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(TrendAnalysisReport.self, from: data)

        XCTAssertTrue(decoded.marketOutlook.isEmpty)
        XCTAssertTrue(decoded.opportunities.isEmpty)
        XCTAssertTrue(decoded.assetTrends.isEmpty)
    }

    func testSameDayAutoAnalysisUsesStoredLocalDay() {
        let settings = TrendAnalysisSettings(
            provider: .empty,
            defaultPrivacyMode: .sanitized,
            dailyAutoAnalysisEnabled: true,
            lastAutoAnalysisDay: "2026-06-22",
            lastAutoAnalysisSlotKey: nil
        )

        XCTAssertTrue(settings.hasAutoAnalyzed(on: "2026-06-22"))
        XCTAssertFalse(settings.hasAutoAnalyzed(on: "2026-06-23"))
    }

    private func isolatedSettingsStore() throws -> TrendAnalysisSettingsStore {
        let suiteName = "com.sunnyhot.qieman.dashboard.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var secrets: [String: String] = [:]
        return TrendAnalysisSettingsStore(
            readSecret: { secrets[$0] },
            writeSecret: { value, account in secrets[account] = value },
            userDefaults: defaults
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trend-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private let expandedReportJSON = """
{
  "generatedAt": "2026-06-24 10:00:00",
  "dataAsOf": "2026-06-24 10:00:00",
  "privacyMode": "脱敏摘要",
  "externalSignalStatus": "available",
  "portfolio": {
    "headline": "组合中性偏积极",
    "riskLevel": "medium",
    "summary": "组合需关注大盘震荡、消费修复和黄金机会。"
  },
  "horizons": [
    {"horizon":"short","direction":"neutral","confidence":{"score":60,"label":"中"},"rationale":"短期大盘仍在震荡确认。","counterSignals":["若放量突破则上修。"]},
    {"horizon":"medium","direction":"neutralPositive","confidence":{"score":64,"label":"中"},"rationale":"中期政策和估值有修复空间。","counterSignals":["若盈利下修则降级。"]},
    {"horizon":"long","direction":"neutralPositive","confidence":{"score":66,"label":"中"},"rationale":"长期分散配置仍有价值。","counterSignals":["若风险偏好持续下行则降级。"]}
  ],
  "marketOutlook": [
    {"id":"market-hs300","name":"沪深300","category":"大盘宽基","direction":"neutral","confidence":{"score":60,"label":"中"},"rationale":"估值处于可观察区间，但短期缺少量能确认。","evidenceIDs":["local-portfolio"],"counterSignals":["若成交持续萎缩且跌破支撑，则判断降级。"]},
    {"id":"market-gold","name":"黄金","category":"商品","direction":"neutralPositive","confidence":{"score":65,"label":"中"},"rationale":"若实际利率回落，黄金仍有避险和配置价值。","evidenceIDs":["local-portfolio"],"counterSignals":["若美元和实际利率同步走强，则黄金机会减弱。"]}
  ],
  "sectors": [
    {"id":"sector-consumption","name":"消费","exposureText":"组合主要波动来源之一","direction":"neutralNegative","confidence":{"score":56,"label":"中"},"rationale":"消费暴露较高但修复不均衡。","evidenceIDs":["local-portfolio"],"counterSignals":["若消费核心资产连续修复，则判断上修。"]}
  ],
  "opportunities": [
    {"id":"opp-gold","name":"黄金配置窗口","category":"商品/避险","direction":"neutralPositive","confidence":{"score":65,"label":"中"},"rationale":"黄金可作为组合外的观察机会，但需要等触发条件确认。","triggerConditions":["实际利率回落","金价回踩不破关键支撑"],"invalidatingConditions":["美元重新走强","金价跌破中期支撑"],"evidenceIDs":["local-portfolio"],"counterSignals":["若风险偏好快速回升，黄金相对吸引力下降。"]}
  ],
  "keyAssets": [],
  "assetTrends": [
    {"id":"asset-consumption","name":"消费指数基金","code":"000001","sector":"消费","impactText":"对组合短期波动影响较大","horizons":[{"horizon":"short","direction":"neutralNegative","confidence":{"score":55,"label":"中"},"rationale":"短期缺少确认信号。","counterSignals":["若净值放量修复则上修。"]}],"rationale":"该基金代表组合消费暴露。","counterSignals":["若消费板块修复扩散，该资产不再是主要拖累。"]}
  ],
  "actions": [],
  "evidence": [
    {"id":"local-portfolio","sourceName":"qieman-manager-dashboard","title":"本地组合上下文","url":null,"publishedAt":null,"retrievedAt":"2026-06-24 10:00:00","summary":"本地持仓、板块和计划构成本次判断的主要证据。"}
  ],
  "warnings": [],
  "disclaimer": "非投资建议，仅供个人研究参考。"
}
"""

extension TrendAnalysisReport {
    static func fixture(
        generatedAt: String,
        externalSignalStatus: TrendExternalSignalStatus
    ) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            generatedAt: generatedAt,
            dataAsOf: "2026-06-22 09:58:00",
            privacyMode: .sanitized,
            externalSignalStatus: externalSignalStatus,
            portfolio: TrendPortfolioSummary(
                headline: "组合偏中性",
                riskLevel: .medium,
                summary: "仓位集中度可控，外部信号需要继续观察。"
            ),
            horizons: [
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 62, label: "中"),
                    rationale: "中性,短期缺少明确突破信号。",
                    whatWouldChange: "成交额连续放大并站上趋势线时,短期判断转偏强。",
                    counterSignals: ["成交量放大后可能改变短期判断"]
                ),
                TrendHorizonView(
                    horizon: .medium,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 58, label: "中"),
                    rationale: "中性,中期等待估值和主理人调仓信号进一步确认。",
                    whatWouldChange: "政策和盈利预期同步改善时,中期判断需要上修。",
                    counterSignals: ["若政策和盈利预期同步改善，中期判断需要上修。"]
                ),
                TrendHorizonView(
                    horizon: .long,
                    direction: .neutralPositive,
                    confidence: TrendConfidence(score: 61, label: "中"),
                    rationale: "偏乐观,长期配置分散度尚可,但仍需控制重复暴露。",
                    whatWouldChange: "主要板块长期盈利下修时,长期判断需要降级。",
                    counterSignals: ["若主要板块长期盈利下修，长期判断需要降级。"]
                )
            ],
            marketOutlook: [
                TrendMarketOutlook(
                    id: "market-environment",
                    name: "市场环境",
                    category: "index",
                    direction: .uncertain,
                    confidence: TrendConfidence(score: 40, label: "低"),
                    rationale: "暂不明确,市场信号需要进一步确认。待观察信号:主要指数放量突破或跌破 20 日均线后转向。",
                    evidenceIDs: [],
                    counterSignals: ["若主要指数趋势改变则重新评估。"]
                )
            ],
            sectors: [],
            keyAssets: [],
            actions: [],
            evidence: externalSignalStatus == .available ? [
                TrendEvidence(
                    id: "local-portfolio",
                    sourceName: "qieman-manager-dashboard",
                    title: "本地组合上下文",
                    url: nil,
                    publishedAt: nil,
                    retrievedAt: generatedAt,
                    summary: "本地持仓、板块、计划和待确认记录构成本次判断的主要证据。"
                )
            ] : [],
            warnings: [],
            disclaimer: "非投资建议，仅供个人研究参考。"
        )
    }

    func groundedForSubmission(
        snapshot: TrendResearchSnapshot
    ) -> TrendAnalysisReport {
        let evidenceID = "portfolio:overview:\(snapshot.runID.uuidString)"
        let claimEvidence = TrendClaimEvidence(
            supportingEvidenceIDs: [evidenceID]
        )
        let canonicalEvidence = TrendEvidence(
            id: evidenceID,
            sourceName: "本地组合快照",
            title: "组合概览基线",
            url: nil,
            publishedAt: nil,
            retrievedAt: snapshot.dataAsOf,
            summary: "测试组合概览基线。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .portfolioSnapshot,
                sourceTier: .primary,
                entityNames: ["组合"],
                metadataConfidence: .deterministic
            )
        )
        let statuses = TrendDataSource.allCases.map {
            TrendSourceStatus(
                source: $0,
                status: .notRequested,
                receivedAt: snapshot.createdAt
            )
        }
        return TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: TrendPortfolioSummary(
                headline: portfolio.headline,
                riskLevel: portfolio.riskLevel,
                summary: portfolio.summary,
                claimEvidence: claimEvidence
            ),
            horizons: horizons.map {
                TrendHorizonView(
                    horizon: $0.horizon,
                    direction: $0.direction,
                    confidence: $0.confidence.appNormalized,
                    rationale: $0.rationale,
                    whatWouldChange: $0.whatWouldChange,
                    counterSignals: $0.counterSignals,
                    claimEvidence: claimEvidence
                )
            },
            marketOutlook: marketOutlook.map {
                TrendMarketOutlook(
                    id: $0.id,
                    name: $0.name,
                    category: $0.category,
                    direction: $0.direction,
                    confidence: $0.confidence.appNormalized,
                    rationale: $0.rationale,
                    evidenceIDs: [evidenceID],
                    counterSignals: $0.counterSignals,
                    claimEvidence: claimEvidence
                )
            },
            sectors: sectors,
            opportunities: opportunities,
            keyAssets: keyAssets,
            assetTrends: assetTrends,
            actions: actions,
            evidence: [canonicalEvidence],
            warnings: warnings,
            disclaimer: disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: .analysisOnly,
            sourceStatuses: statuses
        )
    }

    func replacingActions(_ actions: [TrendActionCandidate]) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }
}
