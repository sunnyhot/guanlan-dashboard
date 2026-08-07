import XCTest
@testable import QiemanDashboard

// 阶段二：快照、工具、证据账本与增强 Validator 的单元测试。
final class TrendResearchToolTests: XCTestCase {
    private let registry = TrendResearchToolRegistry()

    // MARK: - 资产分页

    func testAssetsPaginateStablyWithoutGapsOrDuplicates() async throws {
        let snapshot = makeSnapshot(assets: (0..<25).map { makeAsset(code: String(format: "%05d", $0)) })
        let context = makeContext(snapshot: snapshot)

        let page1 = try parseData(await runAssetTool(cursor: 0, limit: 20, context: context))
        XCTAssertEqual(page1["total_count"] as? Int, 25)
        XCTAssertEqual((page1["assets"] as? [Any])?.count, 20)
        XCTAssertEqual(page1["has_more"] as? Bool, true)
        XCTAssertEqual(page1["next_cursor"] as? Int, 20)

        let page2 = try parseData(await runAssetTool(cursor: 20, limit: 20, context: context))
        XCTAssertEqual((page2["assets"] as? [Any])?.count, 5)
        XCTAssertEqual(page2["has_more"] as? Bool, false)

        // 顺序稳定、无重复、无遗漏。
        let codes = collectCodes(page1) + collectCodes(page2)
        XCTAssertEqual(codes, (0..<25).map { String(format: "%05d", $0) })
    }

    func testAssetsRejectNegativeCursor() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001")])
        let context = makeContext(snapshot: snapshot)

        let result = await runAssetTool(cursor: -1, limit: 5, context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("invalid_arguments"))
    }

    func testAssetsRejectOutOfRangeLimit() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001"), makeAsset(code: "00002")])
        let context = makeContext(snapshot: snapshot)

        let result = await runAssetTool(cursor: 0, limit: 99, context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("invalid_arguments"))
    }

    func testAssetsFilterByCodes() async throws {
        let snapshot = makeSnapshot(assets: ["00001", "00002", "00003"].map { makeAsset(code: $0) })
        let context = makeContext(snapshot: snapshot)

        let data = try parseData(await runAssetTool(cursor: 0, limit: 20, codes: ["00002"], context: context))
        XCTAssertEqual(collectCodes(data), ["00002"])
    }

    // MARK: - Tavily 联网搜索

    func testWebSearchRequiresConfiguredKey() async {
        let context = makeContext(snapshot: makeSnapshot())
        let result = await runWebSearch(registry: registry, arguments: ["query": "中国最新产业政策"], context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("web_search_not_configured"))
    }

    func testWebSearchRejectsOutOfRangeResultCount() async {
        let webRegistry = TrendResearchToolRegistry(webSearchClient: FakeTavilySearchClient(response: .empty))
        let context = makeContext(
            snapshot: makeSnapshot(),
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )
        let result = await runWebSearch(
            registry: webRegistry,
            arguments: ["query": "中国最新产业政策", "max_results": 20],
            context: context
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("invalid_arguments"))
    }

    func testWebSearchRecordsCanonicalTavilyEvidence() async throws {
        let response = TavilySearchResponse(
            query: "中国最新产业政策",
            results: [
                TavilySearchResult(
                    title: "政策发布",
                    url: "https://www.gov.cn/zhengce/example",
                    content: "国务院发布最新产业政策。",
                    score: 0.92,
                    publishedDate: "2026-07-23"
                )
            ],
            responseTime: "0.45",
            requestID: "request-1"
        )
        let webRegistry = TrendResearchToolRegistry(webSearchClient: FakeTavilySearchClient(response: response))
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(),
            evidenceLedger: ledger,
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )

        let result = await runWebSearch(
            registry: webRegistry,
            arguments: [
                "query": "中国最新产业政策",
                "topic": "news",
                "time_range": "week",
                "max_results": 5,
                "include_domains": ["www.gov.cn"]
            ],
            context: context
        )

        XCTAssertFalse(result.isError)
        let data = try parseData(result)
        XCTAssertEqual(data["count"] as? Int, 1)
        let id = try XCTUnwrap((data["results"] as? [[String: Any]])?.first?["evidence_id"] as? String)
        XCTAssertTrue(id.hasPrefix("web:tavily:"))
        let evidence = await ledger.canonical(for: id)
        XCTAssertEqual(evidence?.sourceName, "Tavily · gov.cn")
        XCTAssertEqual(evidence?.url, "https://www.gov.cn/zhengce/example")
    }

    func testWebSearchAllowsControlledSectorOutsidePortfolioAndTagsEvidence() async throws {
        let response = TavilySearchResponse(
            query: "人工智能产业最新进展",
            results: [
                TavilySearchResult(
                    title: "人工智能产业观察",
                    url: "https://example.com/ai-sector",
                    content: "人工智能产业近期出现新的订单与政策信号。",
                    score: 0.85,
                    publishedDate: "2026-08-07"
                )
            ],
            responseTime: "0.2",
            requestID: "broad-sector"
        )
        let webRegistry = TrendResearchToolRegistry(
            webSearchClient: FakeTavilySearchClient(response: response)
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(),
            evidenceLedger: ledger,
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )

        let result = await runWebSearch(
            registry: webRegistry,
            arguments: [
                "query": "人工智能产业最新进展",
                "research_target": ["kind": "sector", "key": "人工智能"],
            ],
            context: context
        )

        XCTAssertFalse(result.isError)
        let allEvidence = await ledger.allEvidence()
        let evidence = try XCTUnwrap(allEvidence.first)
        XCTAssertTrue(evidence.metadata.isAssociated(sectorKey: "人工智能"))
    }

    func testWebSearchAllowsCompleteSectorGroupAndTagsMentionedMembers() async throws {
        let group = try XCTUnwrap(
            MarketOpportunityUniverse.sectorGroup(matching: "科技成长")
        )
        let response = TavilySearchResponse(
            query: "科技成长板块比较",
            results: [
                TavilySearchResult(
                    title: "科技成长行业比较",
                    url: "https://example.com/technology-growth",
                    content: "人工智能订单改善，半导体周期仍需观察。",
                    score: 0.86,
                    publishedDate: "2026-08-07"
                )
            ],
            responseTime: "0.2",
            requestID: "sector-group"
        )
        let ledger = TrendEvidenceLedger()
        let registry = TrendResearchToolRegistry(
            webSearchClient: FakeTavilySearchClient(response: response)
        )
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(),
            evidenceLedger: ledger,
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )

        let result = await runWebSearch(
            registry: registry,
            arguments: [
                "query": "科技成长板块比较",
                "research_target": [
                    "kind": "sector",
                    "key": group.key,
                    "sectorKeys": group.sectors,
                ],
            ],
            context: context
        )

        XCTAssertFalse(result.isError)
        let allEvidence = await ledger.allEvidence()
        let evidence = try XCTUnwrap(allEvidence.first)
        XCTAssertTrue(evidence.metadata.isAssociated(sectorKey: "人工智能"))
        XCTAssertTrue(evidence.metadata.isAssociated(sectorKey: "半导体"))
    }

    func testWebSearchRejectsSectorGroupWhenMemberListIsIncomplete() async throws {
        let group = try XCTUnwrap(
            MarketOpportunityUniverse.sectorGroup(matching: "科技成长")
        )
        let registry = TrendResearchToolRegistry(
            webSearchClient: FakeTavilySearchClient(response: .empty)
        )
        let context = makeContext(
            snapshot: makeSnapshot(),
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )

        let result = await runWebSearch(
            registry: registry,
            arguments: [
                "query": "科技成长板块比较",
                "research_target": [
                    "kind": "sector",
                    "key": group.key,
                    "sectorKeys": Array(group.sectors.dropLast()),
                ],
            ],
            context: context
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("research_target 与本次组合快照或全市场研究池不匹配"))
    }

    func testWebSearchRejectsUnknownSectorOutsideControlledUniverse() async {
        let webRegistry = TrendResearchToolRegistry(
            webSearchClient: FakeTavilySearchClient(response: .empty)
        )
        let context = makeContext(
            snapshot: makeSnapshot(),
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )

        let result = await runWebSearch(
            registry: webRegistry,
            arguments: [
                "query": "火星采矿最新进展",
                "research_target": ["kind": "sector", "key": "火星采矿"],
            ],
            context: context
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("research_target 与本次组合快照或全市场研究池不匹配"))
    }

    func testWebSearchCacheIsSharedAcrossRunsAndDoesNotConsumeSecondBudget() async throws {
        let response = TavilySearchResponse(
            query: "China AI policy",
            results: [
                TavilySearchResult(
                    title: "Policy",
                    url: "https://example.com/policy",
                    content: "Latest policy summary.",
                    score: 0.8,
                    publishedDate: "2026-07-24"
                )
            ],
            responseTime: "0.2",
            requestID: "cache-test"
        )
        let client = CountingTavilySearchClient(response: response)
        let registry = TrendResearchToolRegistry(webSearchClient: client)
        let cache = TrendWebSearchResponseCache(ttlSeconds: 600)
        let firstGovernor = TrendWebSearchGovernor(maxNetworkSearches: 1, cache: cache)
        let secondGovernor = TrendWebSearchGovernor(maxNetworkSearches: 1, cache: cache)

        let first = await runWebSearch(
            registry: registry,
            arguments: ["query": "China AI Policy"],
            context: makeContext(
                snapshot: makeSnapshot(),
                webSearchSettings: TavilySearchSettings(apiKey: "tvly-test"),
                webSearchGovernor: firstGovernor
            )
        )
        XCTAssertFalse(first.isError)

        let second = await runWebSearch(
            registry: registry,
            arguments: ["query": "  china, ai policy  "],
            context: makeContext(
                snapshot: makeSnapshot(),
                webSearchSettings: TavilySearchSettings(apiKey: "tvly-test"),
                webSearchGovernor: secondGovernor
            )
        )
        let secondData = try parseData(second)
        XCTAssertEqual(secondData["cache_hit"] as? Bool, true)
        XCTAssertEqual(secondData["remaining_search_budget"] as? Int, 1)
        let callCount = await client.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testWebSearchGovernorRejectsNewQueryAfterNetworkBudgetIsExhausted() async {
        let client = CountingTavilySearchClient(response: .empty)
        let registry = TrendResearchToolRegistry(webSearchClient: client)
        let governor = TrendWebSearchGovernor(
            maxNetworkSearches: 1,
            cache: TrendWebSearchResponseCache(ttlSeconds: 600)
        )
        let context = makeContext(
            snapshot: makeSnapshot(),
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test"),
            webSearchGovernor: governor
        )

        let first = await runWebSearch(
            registry: registry,
            arguments: ["query": "第一条行业查询"],
            context: context
        )
        XCTAssertFalse(first.isError)

        let second = await runWebSearch(
            registry: registry,
            arguments: ["query": "第二条政策查询"],
            context: context
        )
        XCTAssertTrue(second.isError)
        XCTAssertTrue(second.contentJSON.contains("web_search_budget_exhausted"))
        let callCount = await client.callCount()
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - 证据账本

    func testToolsRecordStableEvidenceIDs() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001")])
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)

        _ = await runAssetTool(cursor: 0, limit: 20, context: context)

        let ids = await ledger.allIDs()
        XCTAssertTrue(ids.contains("portfolio:asset:00001"))
    }

    // MARK: - submit 归一化

    func testSubmitNormalizesTimestampsAndPrivacyMode() async throws {
        // 快照无可覆盖基金（assets 为空）→ 覆盖率校验平凡通过，便于聚焦归一化行为。
        let snapshot = makeSnapshot(assets: [])
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)
        await recordOverviewEvidence(context: context)

        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let arguments = jsonString(["report": reportObject])
        let call = AgentToolCall(id: "submit_1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: arguments))

        let result = await registry.execute(call, context: context)
        XCTAssertFalse(result.isError)
        guard case .report(let normalized) = result.completion else {
            XCTFail("期望 submit 成功并返回报告")
            return
        }
        XCTAssertEqual(normalized.dataAsOf, "2026-07-24 09:58:00")
        XCTAssertEqual(normalized.privacyMode, .sanitized)
        XCTAssertNotEqual(normalized.generatedAt, "1999-01-01 00:00:00")
        XCTAssertEqual(normalized.disposition, .insufficientEvidence)
        XCTAssertEqual(
            normalized.horizons.first(where: { $0.horizon == .short })?.direction,
            .uncertain
        )
        XCTAssertEqual(normalized.sourceStatuses.count, TrendDataSource.allCases.count)
    }

    func testSubmitPromotesStatusOnlyWhenReportReferencesTavilyEvidence() async throws {
        let snapshot = makeSnapshot(assets: [])
        let ledger = TrendEvidenceLedger()
        let webEvidence = TrendEvidence(
            id: "web:tavily:abc123",
            sourceName: "Tavily · gov.cn",
            title: "政策发布",
            url: "https://www.gov.cn/zhengce/example",
            publishedAt: "2026-07-23",
            retrievedAt: "2026-07-24T10:00:00Z",
            summary: "国务院发布最新产业政策。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .webSearch,
                sourceTier: .primary,
                publisherKey: "gov.cn",
                sectorKeys: ["政策环境"],
                metadataConfidence: .ruleDerived
            )
        )
        await ledger.record([webEvidence])
        let context = TrendResearchToolContext(
            snapshot: snapshot,
            evidenceLedger: ledger,
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        )
        await recordOverviewEvidence(context: context)

        let base = TrendAnalysisReport.fixture(
            generatedAt: "1999-01-01 00:00:00",
            externalSignalStatus: .unavailable
        ).groundedForSubmission(snapshot: snapshot)
        var reportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        reportObject["sectors"] = [[
            "id": "policy",
            "name": "政策环境",
            "exposureText": "影响组合相关行业",
            "direction": "neutralPositive",
            "confidence": ["score": 65, "label": "中"],
            "rationale": "近期政策提供边际支持。",
            "evidenceIDs": [webEvidence.id],
            "counterSignals": ["若后续执行力度不足则下调判断。"]
        ]]
        let call = AgentToolCall(
            id: "submit_web",
            function: AgentToolFunctionCall(
                name: "submit_trend_report",
                arguments: jsonString(["report": reportObject])
            )
        )

        let result = await registry.execute(call, context: context)
        guard case .report(let normalized) = result.completion else {
            XCTFail("期望带 Tavily 引用的报告通过校验")
            return
        }
        XCTAssertEqual(normalized.externalSignalStatus, .available)
        XCTAssertTrue(normalized.evidence.contains(webEvidence))
        XCTAssertTrue(normalized.evidence.contains {
            $0.id == "portfolio:overview:\(snapshot.runID.uuidString)"
        })
    }

    // MARK: - Validator 增强

    func testValidatorRejectsAvailableStatusWithoutExternalResearchEvidence() {
        let report = TrendAnalysisReport.fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .available)
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("官方源或联网搜索") })
    }

    func testValidatorRejectsFabricatedEvidenceID() throws {
        let base = TrendAnalysisReport.fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        dict["sectors"] = [[
            "name": "A股",
            "exposureText": "30%",
            "direction": "neutral",
            "confidence": ["score": 60, "label": "中"],
            "rationale": "测试板块",
            "evidenceIDs": ["fabricated:eid"],
            "counterSignals": ["无"]
        ]]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let report = try JSONDecoder().decode(TrendAnalysisReport.self, from: data)

        let result = TrendAnalysisValidator().validate(report)
        XCTAssertTrue(result.messages.contains { $0.contains("引用的证据 ID 不存在：fabricated:eid") })
    }

    // MARK: - 辅助构造

    private func makeContext(
        snapshot: TrendResearchSnapshot,
        webSearchSettings: TavilySearchSettings = .empty,
        webSearchGovernor: TrendWebSearchGovernor = TrendWebSearchGovernor(maxNetworkSearches: 10)
    ) -> TrendResearchToolContext {
        TrendResearchToolContext(
            snapshot: snapshot,
            evidenceLedger: TrendEvidenceLedger(),
            webSearchSettings: webSearchSettings,
            webSearchGovernor: webSearchGovernor
        )
    }

    private func makeSnapshot(
        assets: [TrendContextAsset] = [],
        signals: [TrendResearchSignal] = [],
        quotes: [TrendResearchQuote] = []
    ) -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: "2026-07-24 10:00:00",
            dataAsOf: "2026-07-24 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: assets.count,
                holdingCount: assets.count,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: assets,
            sectors: [],
            platformSignals: signals,
            managerSignals: [],
            marketQuotes: quotes,
            insightHeadline: "测试洞察",
            sourceWarnings: []
        )
    }

    private func makeAsset(code: String, marketValue: Double? = nil) -> TrendContextAsset {
        TrendContextAsset(
            id: code,
            name: "基金\(code)",
            code: code,
            assetType: PersonalAssetType.fund.displayName,
            sector: "A股",
            statusText: "已持有",
            weightText: nil,
            profitPct: 0.1,
            estimateChangePct: 0.2,
            pendingTradeCount: 0,
            activePlanCount: 0,
            pausedPlanCount: 0,
            endedPlanCount: 0,
            marketValue: marketValue,
            costValue: nil,
            profitAmount: nil,
            pendingCashAmount: nil,
            estimatedNextPlanAmount: nil,
            totalCumulativePlanAmount: nil
        )
    }

    private func runAssetTool(
        cursor: Int?,
        limit: Int?,
        codes: [String]? = nil,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        var args: [String: Any] = [:]
        if let cursor { args["cursor"] = cursor }
        if let limit { args["limit"] = limit }
        if let codes { args["codes"] = codes }
        let call = AgentToolCall(
            id: "asset_call",
            function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: jsonString(args))
        )
        return await registry.execute(call, context: context)
    }

    private func runWebSearch(
        registry: TrendResearchToolRegistry,
        arguments: [String: Any],
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        var enrichedArguments = arguments
        if enrichedArguments["research_target"] == nil {
            enrichedArguments["research_target"] = [
                "kind": "macro",
                "key": (arguments["query"] as? String) ?? "市场"
            ]
        }
        let call = AgentToolCall(
            id: "web_search_call",
            function: AgentToolFunctionCall(
                name: "web_search",
                arguments: jsonString(enrichedArguments)
            )
        )
        return await registry.execute(call, context: context)
    }

    private func recordOverviewEvidence(
        context: TrendResearchToolContext
    ) async {
        let call = AgentToolCall(
            id: "overview_for_submit",
            function: AgentToolFunctionCall(
                name: "get_portfolio_overview",
                arguments: "{}"
            )
        )
        _ = await registry.execute(call, context: context)
    }

    private func parseData(_ result: TrendResearchToolResult) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(json["data"] as? [String: Any])
    }

    private func collectCodes(_ data: [String: Any]) -> [String] {
        ((data["assets"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["code"] as? String }
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

private struct FakeTavilySearchClient: TavilySearchClientProtocol {
    let response: TavilySearchResponse

    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double
    ) async throws -> TavilySearchResponse {
        response
    }
}

private actor CountingTavilySearchClient: TavilySearchClientProtocol {
    let response: TavilySearchResponse
    private var count = 0

    init(response: TavilySearchResponse) {
        self.response = response
    }

    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double
    ) async throws -> TavilySearchResponse {
        count += 1
        return response
    }

    func callCount() -> Int {
        count
    }
}

private extension TavilySearchResponse {
    static let empty = TavilySearchResponse(
        query: nil,
        results: [],
        responseTime: nil,
        requestID: nil
    )
}
