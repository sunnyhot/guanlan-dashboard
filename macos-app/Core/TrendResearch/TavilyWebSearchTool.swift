import CryptoKit
import Foundation

struct TavilyWebSearchTool: TrendResearchTool {
    let client: any TavilySearchClientProtocol

    let name = "web_search"
    let description = "通过 Tavily 搜索最新网页信息，用于行业变化、宏观环境、监管政策、重要市场事件和独立于当前持仓的全市场机会扫描。查询中不得包含用户姓名、组合名称、金额或其他个人信息。优先使用近期、权威和可追溯来源。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "minLength": 2,
                "maxLength": 400,
                "description": "搜索关键词。只包含通用行业、政策或资产类别，不得包含个人组合和金额信息。"
            ],
            "research_target": [
                "type": "object",
                "description": "本次搜索要回答的结构化研究目标。App 会对目标与当前快照或全市场研究池做校验；它只表示查询意图，不代表返回结果一定支持该目标。",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["asset", "index", "sector", "assetClass", "macro"]
                    ],
                    "key": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 120,
                        "description": "单项研究填写受控池中的具体名称；全市场聚合扫描固定使用“大类资产配置”或“大盘宽基指数”。六个受控板块分组只需填写分组名，App 会自动补齐完整 sectorKeys。"
                    ],
                    "entityCodes": [
                        "type": "array",
                        "maxItems": 20,
                        "items": ["type": "string"]
                    ],
                    "sectorKeys": [
                        "type": "array",
                        "maxItems": 20,
                        "items": ["type": "string"]
                    ],
                    "assetClassKeys": [
                        "type": "array",
                        "maxItems": 10,
                        "items": ["type": "string"]
                    ]
                ],
                "required": ["kind", "key"],
                "additionalProperties": false
            ],
            "topic": [
                "type": "string",
                "enum": ["general", "news", "finance"],
                "description": "搜索类别，默认 news。政策和行业动态优先使用 news，市场数据可使用 finance。"
            ],
            "time_range": [
                "type": "string",
                "enum": ["day", "week", "month", "year"],
                "description": "发布时间范围，默认 month。"
            ],
            "max_results": [
                "type": "integer",
                "minimum": 1,
                "maximum": 8,
                "description": "返回条数，默认 5，范围 1...8。"
            ],
            "include_domains": [
                "type": "array",
                "maxItems": 8,
                "items": ["type": "string"],
                "description": "可选域名白名单，例如 gov.cn、pbc.gov.cn、csrc.gov.cn。不要包含协议或路径。"
            ]
        ],
        "required": ["query", "research_target"],
        "additionalProperties": false
    ]

    private struct Params: Decodable {
        let query: String
        let research_target: TrendResearchTarget
        let topic: String?
        let time_range: String?
        let max_results: Int?
        let include_domains: [String]?
    }

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        guard context.webSearchSettings.isConfigured else {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "web_search_not_configured",
                    message: TavilySearchClientError.missingAPIKey.localizedDescription
                ),
                isError: true
            )
        }

        let params: Params
        do {
            params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
        } catch {
            return invalidArguments("参数不是合法 JSON：\(error.localizedDescription)")
        }

        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...400).contains(query.count) else {
            return invalidArguments("query 长度必须在 2...400 个字符之间")
        }
        guard TrendAgentAuditRedactor.redactedSensitiveText(query) == query else {
            return invalidArguments("query 包含金额、密钥或认证信息，已在联网请求前拒绝")
        }
        let researchTarget = MarketOpportunityUniverse.canonicalizedTarget(
            params.research_target
        )
        guard validate(target: researchTarget, snapshot: context.snapshot) else {
            return invalidArguments(
                "research_target 与本次组合快照或全市场研究池不匹配。全市场板块分组仅接受：\(MarketOpportunityUniverse.requiredSectorGroupKeys.joined(separator: "、"))。"
            )
        }

        let topic = params.topic ?? "news"
        guard ["general", "news", "finance"].contains(topic) else {
            return invalidArguments("topic 只能是 general/news/finance")
        }

        let timeRange = params.time_range ?? "month"
        guard ["day", "week", "month", "year"].contains(timeRange) else {
            return invalidArguments("time_range 只能是 day/week/month/year")
        }

        let maxResults = params.max_results ?? 5
        guard (1...8).contains(maxResults) else {
            return invalidArguments("max_results 必须在 1...8 之间")
        }

        let domains: [String]?
        do {
            domains = try normalizedDomains(params.include_domains)
        } catch {
            return invalidArguments(error.localizedDescription)
        }

        let request = TavilySearchRequest(
            query: query,
            topic: topic,
            searchDepth: "basic",
            maxResults: maxResults,
            timeRange: timeRange,
            includeDomains: domains,
            includeAnswer: false,
            includeRawContent: false,
            includeImages: false
        )

        do {
            let outcome = try await context.webSearchGovernor.search(
                request,
                apiKey: context.webSearchSettings.apiKey,
                timeoutSeconds: 30,
                client: client,
                cacheKeyOverride: MarketOpportunityUniverse.stableSearchCacheScope(
                    for: researchTarget
                )
            )
            return await makeResult(
                response: outcome.response,
                query: query,
                researchTarget: researchTarget,
                cacheHit: outcome.cacheHit,
                remainingSearchBudget: outcome.remainingNetworkSearches,
                context: context
            )
        } catch is CancellationError {
            return .content(
                TrendResearchToolEnvelope.error(code: "web_search_cancelled", message: "Tavily 搜索已取消"),
                isError: true
            )
        } catch let error as TrendWebSearchGovernorError {
            return webSearchFailure(code: error.toolErrorCode, message: error.localizedDescription)
        } catch let error as TavilySearchClientError {
            return webSearchFailure(code: error.toolErrorCode, message: error.userFacingToolMessage)
        } catch {
            return webSearchFailure(
                code: "web_search_failed",
                message: "Tavily 联网搜索暂不可用，本次已停止继续请求。"
            )
        }
    }

    private func makeResult(
        response: TavilySearchResponse,
        query: String,
        researchTarget: TrendResearchTarget,
        cacheHit: Bool,
        remainingSearchBudget: Int,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        var seenURLs = Set<String>()
        let results = response.results.compactMap { result -> SearchResult? in
            let normalizedURL = result.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: normalizedURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !seenURLs.contains(normalizedURL) else {
                return nil
            }
            seenURLs.insert(normalizedURL)
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !content.isEmpty else { return nil }
            return SearchResult(
                evidenceID: Self.evidenceID(for: normalizedURL),
                title: title,
                url: normalizedURL,
                source: Self.sourceName(for: url),
                publishedAt: result.publishedDate,
                summary: String(content.prefix(1_200)),
                score: result.score
            )
        }

        let retrievedAt = ISO8601DateFormatter().string(from: Date())
        let registry = TrendSourceAuthorityRegistry()
        await context.evidenceLedger.record(
            results.map {
                let classification = registry.classify(urlString: $0.url)
                let content = "\($0.title) \($0.summary)".lowercased()
                let targetKey = researchTarget.key.lowercased()
                let matchedCodes = researchTarget.entityCodes.filter {
                    content.contains($0.lowercased())
                }
                let keyIsMentioned = targetKey.count >= 2 && content.contains(targetKey)
                let matchedSectors = researchTarget.sectorKeys.filter {
                    content.contains($0.lowercased())
                }
                let matchedAssetClasses = researchTarget.assetClassKeys.filter {
                    content.contains($0.lowercased())
                }
                let matchedIndexNames = researchTarget.kind == .index
                    ? MarketOpportunityUniverse.indices.filter {
                        content.contains($0.lowercased())
                    }
                    : []
                let entityNames = Array(Set(
                    ([.asset, .index].contains(researchTarget.kind) && keyIsMentioned
                        ? [researchTarget.key]
                        : []) + matchedIndexNames
                )).sorted()
                let sectorKeys = researchTarget.kind == .sector && keyIsMentioned
                    ? Array(Set(matchedSectors + [researchTarget.key])).sorted()
                    : matchedSectors
                let assetClassCandidates = researchTarget.kind == .assetClass
                    && MarketOpportunityUniverse.isAggregateTarget(
                        researchTarget.key,
                        kind: .assetClass
                    )
                    ? MarketOpportunityUniverse.assetClasses
                    : researchTarget.assetClassKeys
                let matchedAggregateAssetClasses = assetClassCandidates.filter {
                    content.contains($0.lowercased())
                }
                let assetClassKeys = researchTarget.kind == .assetClass && keyIsMentioned
                    ? Array(Set(matchedAssetClasses + matchedAggregateAssetClasses + [researchTarget.key])).sorted()
                    : Array(Set(matchedAssetClasses + matchedAggregateAssetClasses)).sorted()
                let hasContentTags = !matchedCodes.isEmpty
                    || !entityNames.isEmpty
                    || !sectorKeys.isEmpty
                    || !assetClassKeys.isEmpty
                return TrendEvidence(
                    id: $0.evidenceID,
                    sourceName: $0.source,
                    title: $0.title,
                    url: $0.url,
                    publishedAt: $0.publishedAt,
                    retrievedAt: retrievedAt,
                    summary: $0.summary,
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .webSearch,
                        sourceTier: classification.tier,
                        publisherKey: classification.publisherKey,
                        requestedTopicKeys: researchTarget.topicKeys,
                        entityCodes: matchedCodes,
                        entityNames: entityNames,
                        sectorKeys: sectorKeys,
                        assetClassKeys: assetClassKeys,
                        metadataConfidence: hasContentTags ? .ruleDerived : .unknown
                    )
                )
            }
        )

        let payload: [[String: Any]] = results.map {
            [
                "evidence_id": $0.evidenceID,
                "title": $0.title,
                "url": $0.url,
                "source": $0.source,
                "published_at": $0.publishedAt ?? NSNull(),
                "summary": $0.summary,
                "score": $0.score ?? NSNull()
            ]
        }
        let warnings = results.isEmpty ? ["Tavily 未返回可用结果，请调整关键词、时间范围或域名限制。"] : []
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "query": query,
                    "research_target": encodedObject(researchTarget),
                    "results": payload,
                    "count": results.count,
                    "request_id": response.requestID ?? NSNull(),
                    "cache_hit": cacheHit,
                    "remaining_search_budget": remainingSearchBudget
                ],
                warnings: warnings,
                evidenceIDs: results.map(\.evidenceID)
            )
        )
    }

    private func normalizedDomains(_ values: [String]?) throws -> [String]? {
        guard let values, !values.isEmpty else { return nil }
        guard values.count <= 8 else {
            throw ValidationError(message: "include_domains 最多包含 8 个域名")
        }
        let domains = values.map {
            $0.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "www.", with: "", options: [.anchored])
        }
        guard domains.allSatisfy({
            !$0.isEmpty
                && !$0.contains("://")
                && !$0.contains("/")
                && !$0.contains(" ")
                && $0.contains(".")
        }) else {
            throw ValidationError(message: "include_domains 只能填写不带协议和路径的域名")
        }
        var seen = Set<String>()
        return domains.filter { seen.insert($0).inserted }
    }

    private func validate(
        target: TrendResearchTarget,
        snapshot: TrendResearchSnapshot
    ) -> Bool {
        let key = target.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        switch target.kind {
        case .asset:
            let requestedCodes = Set(target.entityCodes.map { $0.lowercased() })
            return snapshot.assets.contains { asset in
                [asset.id, asset.name, asset.code]
                    .compactMap { $0?.lowercased() }
                    .contains(key)
                    || asset.code.map { requestedCodes.contains($0.lowercased()) } == true
            }
        case .index:
            return MarketOpportunityUniverse.isAggregateTarget(target.key, kind: .index)
                || MarketOpportunityUniverse.contains(target.key, kind: .index)
                || snapshot.marketQuotes.contains { quote in
                quote.kind == "index"
                    && [quote.code.lowercased(), quote.name.lowercased()].contains(key)
            }
        case .sector:
            if MarketOpportunityUniverse.sectorGroup(matching: target.key) != nil {
                return MarketOpportunityUniverse.isCompleteSectorGroupTarget(target)
            }
            let known = snapshot.sectors.map { $0.name.lowercased() }
                + (snapshot.lookThrough?.industries.map { $0.name.lowercased() } ?? [])
            return MarketOpportunityUniverse.contains(target.key, kind: .sector)
                || known.contains(key)
                || target.sectorKeys.contains { known.contains($0.lowercased()) }
        case .assetClass:
            let known = snapshot.lookThrough?.assetClasses.map { $0.name.lowercased() } ?? []
            return MarketOpportunityUniverse.isAggregateTarget(target.key, kind: .assetClass)
                || MarketOpportunityUniverse.contains(target.key, kind: .assetClass)
                || known.contains(key)
                || target.assetClassKeys.contains { known.contains($0.lowercased()) }
        case .macro:
            return true
        }
    }

    private func webSearchFailure(code: String, message: String) -> TrendResearchToolResult {
        .content(
            TrendResearchToolEnvelope.error(code: code, message: message),
            isError: true
        )
    }

    private func encodedObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
    }

    private func invalidArguments(_ message: String) -> TrendResearchToolResult {
        .content(
            TrendResearchToolEnvelope.error(code: "invalid_arguments", message: message),
            isError: true
        )
    }

    private static func evidenceID(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.lowercased().utf8))
        let value = digest.map { String(format: "%02x", $0) }.joined()
        return "web:tavily:\(value.prefix(20))"
    }

    private static func sourceName(for url: URL) -> String {
        let host = url.host?.replacingOccurrences(of: "www.", with: "", options: [.anchored]) ?? "网页"
        return "Tavily · \(host)"
    }

    private struct SearchResult {
        let evidenceID: String
        let title: String
        let url: String
        let source: String
        let publishedAt: String?
        let summary: String
        let score: Double?
    }

    private struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
