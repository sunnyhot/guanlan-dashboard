import Foundation

// 工具注册表：组合概览、持仓、市场快照、Tavily 网页搜索和报告提交。
//
// submit_trend_report 见 SubmitTrendReportTool.swift。

struct TrendResearchToolRegistry: Sendable {
    let tools: [String: any TrendResearchTool]
    let definitions: [AgentToolDefinition]

    init(webSearchClient: any TavilySearchClientProtocol = TavilySearchClient()) {
        let all: [any TrendResearchTool] = [
            PortfolioOverviewTool(),
            PortfolioAssetsTool(),
            FundLookThroughTool(),
            MarketSnapshotTool(),
            TavilyWebSearchTool(client: webSearchClient),
            SubmitTrendReportTool()
        ]
        tools = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        definitions = all.map { tool in
            AgentToolDefinition.function(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
    }

    func execute(_ call: AgentToolCall, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        guard let tool = tools[call.function.name] else {
            return .content(TrendResearchToolEnvelope.error(code: "unknown_tool", message: "未知工具：\(call.function.name)"), isError: true)
        }
        return await tool.execute(argumentsJSON: call.function.arguments, context: context)
    }
}

private func jsonObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
    return object
}

// MARK: - get_portfolio_overview

struct PortfolioOverviewTool: TrendResearchTool {
    let name = "get_portfolio_overview"
    let description = "取得组合基线：持仓数量、计划数量、待确认交易数量、板块暴露、集中度摘要、隐私模式、本地洞察标题、数据截止时间与来源警告。提交报告前必须至少调用一次。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let snapshot = context.snapshot
        let evidenceID = "portfolio:overview:\(snapshot.runID.uuidString)"
        let signalEvidence = (snapshot.platformSignals + snapshot.managerSignals).map { signal in
            TrendEvidence(
                id: signal.evidenceID,
                sourceName: signal.source,
                title: signal.title,
                url: signal.articleURL,
                publishedAt: signal.occurredAt,
                retrievedAt: snapshot.dataAsOf,
                summary: signal.detail ?? signal.title,
                metadata: TrendEvidenceMetadata(
                    sourceKind: signal.source == "manager" ? .managerSignal : .platformSignal,
                    sourceTier: signal.articleURL == nil ? .unknown : .secondary,
                    requestedTopicKeys: [signal.source, signal.kind, signal.title],
                    entityCodes: [signal.fundCode].compactMap { $0 },
                    entityNames: [signal.fundName].compactMap { $0 },
                    metadataConfidence: .deterministic
                )
            )
        }
        await context.evidenceLedger.record([
            TrendEvidence(
                id: evidenceID,
                sourceName: "本地组合快照",
                title: "组合概览基线",
                url: nil,
                publishedAt: nil,
                retrievedAt: snapshot.dataAsOf,
                summary: "本次分析冻结的组合基线：\(snapshot.portfolio.assetCount) 个持仓标的、\(snapshot.portfolio.holdingCount) 个已持有、\(snapshot.portfolio.activePlanCount) 个计划、\(snapshot.portfolio.pendingAssetCount) 个待确认。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .portfolioSnapshot,
                    sourceTier: .primary,
                    requestedTopicKeys: ["portfolio", "组合"],
                    entityNames: ["组合"],
                    metadataConfidence: .deterministic
                )
            )
        ] + signalEvidence)
        let data: [String: Any] = [
            "portfolio": jsonObject(snapshot.portfolio),
            "sectors": snapshot.sectors.map { jsonObject($0) },
            "privacyMode": snapshot.privacyMode.rawValue,
            "dataAsOf": snapshot.dataAsOf,
            "insightHeadline": snapshot.insightHeadline,
            "sourceWarnings": snapshot.sourceWarnings,
            "sourceStatuses": snapshot.sourceStatuses.map { jsonObject($0) },
            "platformSignals": snapshot.platformSignals.map { jsonObject($0) },
            "managerSignals": snapshot.managerSignals.map { jsonObject($0) },
            "evidenceID": evidenceID
        ]
        return .content(
            TrendResearchToolEnvelope.success(
                data,
                evidenceIDs: [evidenceID] + signalEvidence.map(\.id)
            )
        )
    }
}

// MARK: - get_portfolio_assets

struct PortfolioAssetsTool: TrendResearchTool {
    let name = "get_portfolio_assets"
    let description = "分页读取资产明细（替代一次性塞入全部持仓）。按快照既定顺序返回，不重新排序。必须读完全部页面或用 codes 覆盖全部持有基金。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "cursor": ["type": "integer", "minimum": 0, "description": "起始偏移，默认 0"],
            "limit": ["type": "integer", "minimum": 1, "maximum": 20, "description": "本页条数，默认 20，范围 1...20"],
            "codes": ["type": "array", "items": ["type": "string"], "description": "可选：只返回匹配这些基金代码的资产"]
        ],
        "additionalProperties": false
    ]

    private struct Params: Codable {
        var cursor: Int?
        var limit: Int?
        var codes: [String]?
    }

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let params: Params
        do {
            if argumentsJSON.isEmpty || argumentsJSON == "{}" {
                params = Params()
            } else {
                params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
            }
        } catch {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "参数不是合法 JSON：\(error.localizedDescription)"), isError: true)
        }

        if let requested = params.cursor, requested < 0 {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "cursor 不能为负数"), isError: true)
        }
        if let requested = params.limit, !(1...20).contains(requested) {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "limit 必须在 1...20 之间"), isError: true)
        }

        let snapshot = context.snapshot
        let cursor = max(params.cursor ?? 0, 0)
        let limit = params.limit ?? 20
        let ordered: [TrendContextAsset]
        if let codes = params.codes, !codes.isEmpty {
            let set = Set(codes)
            ordered = snapshot.assets.filter { asset in asset.code.map { set.contains($0) } ?? false }
        } else {
            ordered = snapshot.assets
        }

        let totalCount = ordered.count
        let start = min(cursor, totalCount)
        let end = min(start + limit, totalCount)
        let page = Array(ordered[start..<end])
        let hasMore = end < totalCount

        let evidenceIDs = page.map { "portfolio:asset:\($0.id)" }
        await context.evidenceLedger.record(
            page.map { asset in
                TrendEvidence(
                    id: "portfolio:asset:\(asset.id)",
                    sourceName: "本地组合快照",
                    title: asset.name,
                    url: nil,
                    publishedAt: nil,
                    retrievedAt: snapshot.dataAsOf,
                    summary: "\(asset.name)（\(asset.code ?? "无代码")）持仓明细快照。",
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .portfolioSnapshot,
                        sourceTier: .primary,
                        requestedTopicKeys: [asset.id, asset.name, asset.code].compactMap { $0 },
                        entityCodes: [asset.code].compactMap { $0 },
                        entityNames: [asset.name],
                        sectorKeys: [asset.sector],
                        metadataConfidence: .deterministic
                    )
                )
            }
        )

        let nextCursor: Any = hasMore ? end : NSNull()
        let data: [String: Any] = [
            "assets": page.map { jsonObject($0) },
            "cursor": start,
            "next_cursor": nextCursor,
            "has_more": hasMore,
            "total_count": totalCount
        ]
        return .content(TrendResearchToolEnvelope.success(data, evidenceIDs: evidenceIDs))
    }
}

// MARK: - get_fund_lookthrough

struct FundLookThroughTool: TrendResearchTool {
    let name = "get_fund_lookthrough"
    let description = "读取基金公开定期报告的组合穿透结果：底层股票/债券、基金间重叠持仓、行业与资产类别暴露、披露日期、覆盖率和未知仓位。默认返回组合聚合摘要；fund_codes 最多指定 5 只基金以读取细项。披露数据不是实时持仓。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "fund_codes": [
                "type": "array",
                "maxItems": 5,
                "items": ["type": "string"],
                "description": "可选：返回这些基金的底层披露细项，最多 5 只"
            ]
        ],
        "additionalProperties": false
    ]

    private struct Params: Codable {
        var fund_codes: [String]?
    }

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let params: Params
        do {
            if argumentsJSON.isEmpty || argumentsJSON == "{}" {
                params = Params()
            } else {
                params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
            }
        } catch {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "invalid_arguments",
                    message: "参数不是合法 JSON：\(error.localizedDescription)"
                ),
                isError: true
            )
        }

        if let codes = params.fund_codes, codes.count > 5 {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "invalid_arguments",
                    message: "fund_codes 最多指定 5 只基金。"
                ),
                isError: true
            )
        }
        guard let snapshot = context.snapshot.lookThrough else {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "look_through_unavailable",
                    message: "当前组合没有可用的基金穿透快照。"
                ),
                isError: true
            )
        }

        let requestedCodes = Set(
            (params.fund_codes ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let selectedDisclosures = requestedCodes.isEmpty
            ? []
            : snapshot.disclosures.values
                .filter { requestedCodes.contains($0.fundCode) }
                .sorted { $0.fundCode < $1.fundCode }

        let aggregateEvidenceID = "portfolio:look-through:\(context.snapshot.runID.uuidString)"
        let disclosureEvidence = snapshot.disclosures.values.map { disclosure in
            TrendEvidence(
                id: evidenceID(for: disclosure),
                sourceName: disclosure.sourceLabel,
                title: "\(disclosure.fundName)（\(disclosure.fundCode)）底层资产披露",
                url: disclosure.sourceURL,
                publishedAt: disclosure.asOf.isEmpty ? nil : disclosure.asOf,
                retrievedAt: context.snapshot.dataAsOf,
                summary: "截至 \(disclosure.asOf.isEmpty ? "未知日期" : disclosure.asOf)，包含 \(disclosure.holdings.count) 条股票/债券持仓、\(disclosure.industries.count) 条行业配置；披露证券合计占基金净值 \(String(format: "%.2f%%", disclosure.disclosedSecurityWeightPct))。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .fundDisclosure,
                    sourceTier: .secondary,
                    publisherKey: "fundf10.eastmoney.com",
                    requestedTopicKeys: [disclosure.fundCode, disclosure.fundName],
                    entityCodes: [disclosure.fundCode] + disclosure.holdings.map(\.code),
                    entityNames: [disclosure.fundName] + disclosure.holdings.map(\.name),
                    sectorKeys: disclosure.industries.map(\.name),
                    metadataConfidence: .deterministic
                )
            )
        }
        await context.evidenceLedger.record(
            [
                TrendEvidence(
                    id: aggregateEvidenceID,
                    sourceName: "本地组合穿透计算",
                    title: "基金底层资产聚合",
                    url: nil,
                    publishedAt: nil,
                    retrievedAt: context.snapshot.dataAsOf,
                    summary: "按基金组合权重乘以底层披露权重聚合；覆盖 \(snapshot.coveredFundCount)/\(snapshot.expectedFundCount) 只基金，已披露底层证券覆盖组合 \(String(format: "%.2f%%", snapshot.disclosedSecurityCoveragePct))，未知基金证券仓位 \(String(format: "%.2f%%", snapshot.unknownPortfolioWeightPct))。",
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .derived,
                        requestedTopicKeys: ["portfolio-look-through", "组合穿透"],
                        entityCodes: snapshot.funds.map(\.fundCode),
                        entityNames: snapshot.funds.map(\.fundName),
                        sectorKeys: snapshot.industries.map(\.name),
                        assetClassKeys: snapshot.assetClasses.map(\.name),
                        metadataConfidence: .deterministic
                    )
                )
            ] + disclosureEvidence
        )

        var data: [String: Any] = [
            "summary": [
                "expected_fund_count": snapshot.expectedFundCount,
                "covered_fund_count": snapshot.coveredFundCount,
                "fund_data_coverage_pct": snapshot.fundDataCoveragePct,
                "disclosed_security_coverage_pct": snapshot.disclosedSecurityCoveragePct,
                "unknown_portfolio_weight_pct": snapshot.unknownPortfolioWeightPct,
                "calculation": "组合内基金权重 × 基金底层资产披露权重；直接股票按 100% 计入并与基金间接持仓合并",
                "disclosure_boundary": "公开定期报告口径，不是实时完整持仓"
            ],
            "top_positions": snapshot.topPositions.prefix(30).map { jsonObject($0) },
            "industries": snapshot.industries.prefix(20).map { jsonObject($0) },
            "asset_classes": snapshot.assetClasses.map { jsonObject($0) },
            "funds": snapshot.funds.map { jsonObject($0) }
        ]
        if !requestedCodes.isEmpty {
            data["fund_details"] = selectedDisclosures.map { jsonObject($0) }
            let missing = requestedCodes.subtracting(selectedDisclosures.map(\.fundCode))
            if !missing.isEmpty {
                data["missing_fund_codes"] = missing.sorted()
            }
        }

        return .content(
            TrendResearchToolEnvelope.success(
                data,
                warnings: snapshot.warnings,
                evidenceIDs: [aggregateEvidenceID] + disclosureEvidence.map(\.id)
            )
        )
    }

    private func evidenceID(for disclosure: FundLookThroughDisclosure) -> String {
        "fund:look-through:\(disclosure.fundCode):\(disclosure.asOf)"
    }
}

// MARK: - get_market_snapshot

struct MarketSnapshotTool: TrendResearchTool {
    let name = "get_market_snapshot"
    let description = "读取 App 已获取的大盘指数与基金估值行情快照。只返回快照已有数据，缺失数据列入 warnings。不得把陈旧净值表达成实时行情。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "asset_codes": [
                "type": "array",
                "items": ["type": "string"],
                "description": "可选：只返回这些基金代码的估值行情"
            ],
            "include_indices": ["type": "boolean", "description": "是否包含大盘指数，默认 true"]
        ],
        "additionalProperties": false
    ]

    private struct Params: Codable {
        var asset_codes: [String]?
        var include_indices: Bool?
    }

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let params: Params
        do {
            if argumentsJSON.isEmpty || argumentsJSON == "{}" {
                params = Params()
            } else {
                params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
            }
        } catch {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "参数不是合法 JSON：\(error.localizedDescription)"), isError: true)
        }

        let includeIndices = params.include_indices ?? true
        let snapshot = context.snapshot
        var quotes: [TrendResearchQuote] = []
        if includeIndices {
            quotes += snapshot.marketQuotes.filter { $0.kind == "index" }
        }
        let requestedCodes = params.asset_codes.map { Set($0) }
        quotes += snapshot.marketQuotes.filter { quote in
            quote.kind == "fund-estimate" && (requestedCodes?.contains(quote.code) ?? true)
        }

        var warnings: [String] = []
        if let requestedCodes, !requestedCodes.isEmpty {
            let available = Set(quotes.filter { $0.kind == "fund-estimate" }.map(\.code))
            let missing = requestedCodes.subtracting(available)
            if !missing.isEmpty {
                warnings.append("部分基金代码无估值行情：\(missing.sorted().joined(separator: "、"))")
            }
        }
        if includeIndices && !snapshot.marketQuotes.contains(where: { $0.kind == "index" }) {
            warnings.append("本次分析已主动刷新指数，但没有取得可用大盘行情；不得把缺失解读为市场平稳。")
        }

        await context.evidenceLedger.record(
            quotes.map { quote in
                TrendEvidence(
                    id: quote.evidenceID,
                    sourceName: quote.sourceLabel ?? quote.kind,
                    title: quote.name,
                    url: nil,
                    publishedAt: quote.quotedAt,
                    retrievedAt: snapshot.dataAsOf,
                    summary: "\(quote.name)（\(quote.code)）行情：\(quote.price.map { String($0) } ?? "无报价")，涨跌 \(quote.changePct.map { String($0) } ?? "未知")；报价类型 \(quote.assessment.quoteType.rawValue)，新鲜度 \(quote.assessment.freshnessStatus.rawValue)。",
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .marketQuote,
                        sourceTier: .primary,
                        requestedTopicKeys: [quote.code, quote.name],
                        entityCodes: [quote.code],
                        entityNames: [quote.name],
                        quoteType: quote.assessment.quoteType,
                        freshnessStatus: quote.assessment.freshnessStatus,
                        metadataConfidence: .deterministic
                    )
                )
            }
        )

        let data: [String: Any] = [
            "quotes": quotes.map { jsonObject($0) },
            "count": quotes.count
        ]
        return .content(TrendResearchToolEnvelope.success(data, warnings: warnings, evidenceIDs: quotes.map(\.evidenceID)))
    }
}
