import Foundation

// 工具注册表：组合概览、持仓、市场快照、市场广度、日K技术分析、SEC 官方源、Alpha Vantage 和报告提交。
//
// submit_trend_report 见 SubmitTrendReportTool.swift。

struct TrendResearchToolRegistry: Sendable {
    let tools: [String: any TrendResearchTool]
    let definitions: [AgentToolDefinition]

    init(
        officialSourceClient: any SECOfficialSourceClientProtocol = SECOfficialSourceClient(),
        officialSourceCache: SECOfficialSourceCache = .shared,
        alphaVantageClient: any AlphaVantageClientProtocol = AlphaVantageClient(),
        alphaVantageCache: AlphaVantageResponseCache = .shared,
        marketDataEngine: MarketDataEngine = MarketDataEngine()
    ) {
        let all: [any TrendResearchTool] = [
            PortfolioOverviewTool(),
            PortfolioAssetsTool(),
            FundLookThroughTool(),
            MarketSnapshotTool(),
            MarketBreadthTool(engine: marketDataEngine),
            DailyKlineTool(engine: marketDataEngine),
            SECOfficialResearchTool(
                client: officialSourceClient,
                cache: officialSourceCache
            ),
            AlphaVantageResearchTool(
                client: alphaVantageClient,
                cache: alphaVantageCache
            ),
            SubmitTrendOverviewModuleTool(),
            SubmitTrendMarketModuleTool(),
            SubmitTrendAssetBatchTool(),
            SubmitTrendActionsModuleTool(),
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
                return TrendEvidence(
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
                "disclosure_boundary": "公开定期报告口径，不是实时完整持仓",
                "industry_taxonomy": "statisticalBroadIndustry",
                "investment_sector_rule": "statistical_industries 是 F10 宽泛统计行业，只能描述披露结构；不得直接作为投资板块名称或板块仓位。投资板块需结合底层证券、ETF/基金主题和持仓来源另行归纳。"
            ],
            "top_positions": snapshot.topPositions.prefix(30).map { jsonObject($0) },
            "statistical_industries": snapshot.industries.prefix(20).map { jsonObject($0) },
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
    let description = "读取 App 已获取的大盘指数、基金估值与公开披露底层证券行情。底层行情同时返回来源基金和披露权重，用于解释基金当日涨跌；缺失数据列入 warnings，不得把静态持仓结构或陈旧净值冒充涨跌原因。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "asset_codes": [
                "type": "array",
                "items": ["type": "string"],
                "description": "可选：只返回这些基金代码的估值行情"
            ],
            "include_indices": ["type": "boolean", "description": "是否包含大盘指数，默认 true"],
            "include_underlying_holdings": ["type": "boolean", "description": "是否包含基金披露底层证券的最新行情及来源基金，默认 true"]
        ],
        "additionalProperties": false
    ]

    private struct Params: Codable {
        var asset_codes: [String]?
        var include_indices: Bool?
        var include_underlying_holdings: Bool?
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

        let isMarketOnly = context.scope == .marketRadar
        let includeIndices = params.include_indices ?? true
        let includeUnderlyingHoldings = !isMarketOnly
            && (params.include_underlying_holdings ?? true)
        let snapshot = context.snapshot
        var quotes: [TrendResearchQuote] = []
        if includeIndices {
            quotes += snapshot.marketQuotes.filter { $0.kind == "index" }
        }
        let requestedCodes = params.asset_codes.map { Set($0) }
        if !isMarketOnly {
            quotes += snapshot.marketQuotes.filter { quote in
                quote.kind == "fund-estimate" && (requestedCodes?.contains(quote.code) ?? true)
            }
        }

        let relevantPositions = isMarketOnly
            ? []
            : relevantUnderlyingPositions(
                snapshot: snapshot,
                requestedFundCodes: requestedCodes
            )
        let relevantUnderlyingCodes = Set(relevantPositions.map(\.code))
        if includeUnderlyingHoldings {
            quotes += snapshot.marketQuotes.filter { quote in
                quote.kind == "underlying-stock" && relevantUnderlyingCodes.contains(quote.code)
            }
        }

        var warnings: [String] = []
        if let requestedCodes, !requestedCodes.isEmpty {
            let available = Set(quotes.filter { $0.kind == "fund-estimate" }.map(\.code))
            let missing = requestedCodes.subtracting(available)
            if !missing.isEmpty {
                warnings.append("部分基金代码无估值行情：\(missing.sorted().joined(separator: "、"))")
            }
            // scope guard：请求的代码在冻结快照里一个都匹配不上，视为越界调用
            //（模型臆造代码/串台），硬拒绝而不是返回空数据让模型编故事。
            // 已知代码 = 行情代码 ∪ 穿透持仓底层代码 ∪ 贡献基金代码。
            var knownCodes = Set(snapshot.marketQuotes.map(\.code))
            for position in snapshot.lookThrough?.topPositions ?? [] {
                knownCodes.insert(position.code)
                for contributor in position.contributors {
                    if let fundCode = contributor.fundCode {
                        knownCodes.insert(fundCode)
                    }
                }
            }
            let normalizedKnown = Set(knownCodes.map { MarketCodeNormalizer.canonicalKey(for: $0) })
            let allUnknown = requestedCodes.allSatisfy { code in
                !knownCodes.contains(code) && !normalizedKnown.contains(MarketCodeNormalizer.canonicalKey(for: code))
            }
            if allUnknown, !knownCodes.isEmpty {
                return .content(
                    TrendResearchToolEnvelope.error(
                        code: "scope_violation",
                        message: "请求的资产代码 \(requestedCodes.sorted().joined(separator: "、")) 不在本次分析冻结范围内。本次仅覆盖：\(knownCodes.sorted().prefix(12).joined(separator: "、"))\(knownCodes.count > 12 ? " 等 \(knownCodes.count) 个" : "")。请改用范围内的代码，或去掉 asset_codes 参数获取全部。"
                    ),
                    isError: true
                )
            }
        }
        if includeIndices && !snapshot.marketQuotes.contains(where: { $0.kind == "index" }) {
            warnings.append("本次分析已主动刷新指数，但没有取得可用大盘行情；不得把缺失解读为市场平稳。")
        }
        if includeUnderlyingHoldings, !relevantPositions.isEmpty {
            let quotedCodes = Set(quotes.filter { $0.kind == "underlying-stock" }.map(\.code))
            let missingCodes = relevantUnderlyingCodes.subtracting(quotedCodes)
            if !missingCodes.isEmpty {
                warnings.append("部分披露底层证券没有当日行情：\(missingCodes.sorted().joined(separator: "、"))；相关基金应标记原因待确认。")
            }
        }

        await context.evidenceLedger.record(
            quotes.map { quote in
                let position = relevantPositions.first { $0.code == quote.code }
                let relatedFundCodes = position?.contributors.compactMap(\.fundCode) ?? []
                let relatedFundNames = position?.contributors.map(\.fundName) ?? []
                return TrendEvidence(
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
                        entityCodes: [quote.code] + relatedFundCodes,
                        entityNames: [quote.name] + relatedFundNames,
                        quoteType: quote.assessment.quoteType,
                        freshnessStatus: quote.assessment.freshnessStatus,
                        metadataConfidence: .deterministic
                    )
                )
            }
        )

        let quoteByCode = Dictionary(
            uniqueKeysWithValues: quotes
                .filter { $0.kind == "underlying-stock" }
                .map { ($0.code, $0) }
        )
        let attributionRows: [[String: Any]] = relevantPositions.compactMap { position in
            guard let quote = quoteByCode[position.code] else { return nil }
            let contributors = position.contributors.filter { contributor in
                guard let requestedCodes, !requestedCodes.isEmpty else { return true }
                return contributor.fundCode.map { requestedCodes.contains($0) } ?? false
            }
            return [
                "security": jsonObject(quote),
                "source_funds": contributors.map { jsonObject($0) },
                "disclosure_boundary": "基金定期报告持仓，不代表分析日实时仓位"
            ]
        }
        let data: [String: Any] = [
            "quotes": quotes.map { jsonObject($0) },
            "underlying_attribution": attributionRows,
            "count": quotes.count
        ]
        return .content(TrendResearchToolEnvelope.success(data, warnings: warnings, evidenceIDs: quotes.map(\.evidenceID)))
    }

    private func relevantUnderlyingPositions(
        snapshot: TrendResearchSnapshot,
        requestedFundCodes: Set<String>?
    ) -> [PortfolioLookThroughPosition] {
        guard let positions = snapshot.lookThrough?.topPositions else { return [] }
        guard let requestedFundCodes, !requestedFundCodes.isEmpty else {
            return positions.filter { $0.kind == .stock }
        }
        return positions.filter { position in
            position.kind == .stock && position.contributors.contains { contributor in
                contributor.fundCode.map { requestedFundCodes.contains($0) } ?? false
            }
        }
    }
}

// MARK: - get_market_breadth

/// 全市场广度工具：涨跌家数/涨停跌停/两市成交额（本地计算）。
/// 首次调用需拉全市场快照（约 15-30 秒），之后 10 分钟内命中缓存。
struct MarketBreadthTool: TrendResearchTool {
    let name = "get_market_breadth"
    let description = "获取A股全市场广度统计：上涨/下跌/平盘家数、涨停/跌停家数、两市成交额（亿元）与数据边界说明。适合判断市场整体情绪与赚钱效应，为市场判断（marketOutlook）提供客观基数；不得用单只标的涨跌推断整体。数据 10 分钟内新鲜，首次计算较慢。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false
    ]

    let engine: MarketDataEngine

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        do {
            let stats = try await engine.marketBreadth()
            let evidenceID = "market:breadth:\(String(stats.computedAt.prefix(10)))"
            let amountText = stats.totalAmountYi.map { String(format: "%.1f", $0) } ?? "缺失"
            await context.evidenceLedger.record([
                TrendEvidence(
                    id: evidenceID,
                    sourceName: "全市场行情快照",
                    title: "A股市场广度统计",
                    url: nil,
                    publishedAt: nil,
                    retrievedAt: stats.computedAt,
                    summary: "\(stats.advanceDeclineSummary)；\(stats.limitSummary)；两市成交额约 \(amountText) 亿元。边界：\(stats.dataBoundary.isEmpty ? "无" : stats.dataBoundary)",
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .marketQuote,
                        sourceTier: .primary,
                        requestedTopicKeys: ["market-breadth", "市场广度"],
                        entityNames: ["A股整体"],
                        metadataConfidence: .deterministic
                    )
                )
            ])
            let data: [String: Any] = [
                "up_count": stats.upCount,
                "down_count": stats.downCount,
                "flat_count": stats.flatCount,
                "limit_up_count": stats.limitUpCount,
                "limit_down_count": stats.limitDownCount,
                "total_amount_yi": stats.totalAmountYi ?? NSNull(),
                "sample_count": stats.sampleCount,
                "excluded_count": stats.excludedCount,
                "computed_at": stats.computedAt,
                "data_boundary": stats.dataBoundary,
                "summary": "\(stats.advanceDeclineSummary)；\(stats.limitSummary)",
                "evidence_id": evidenceID
            ]
            var warnings: [String] = []
            if stats.sampleCount < 4000 {
                warnings.append("广度样本偏少（\(stats.sampleCount) 只），全市场约 5400 只，解读时注明覆盖不完整。")
            }
            return .content(TrendResearchToolEnvelope.success(data, warnings: warnings, evidenceIDs: [evidenceID]))
        } catch {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "market_breadth_unavailable",
                    message: "全市场广度暂不可用：\((error as? MarketDataError)?.errorDescription ?? error.localizedDescription)。不得把缺失解读为市场平稳。"
                ),
                isError: true
            )
        }
    }
}

// MARK: - get_daily_kline

/// 日 K + 规则技术分析工具：返回预计算的技术面摘要（评分/均线排列/量价/MACD/RSI/支撑压力/逐条理由），
/// 而不是原始 K 线数组——LLM 负责合成解读，不负责算数（对拍 DSA 预计算证据进 prompt 的设计）。
struct DailyKlineTool: TrendResearchTool {
    let name = "get_daily_kline"
    let description = "获取A股个股日 K 与确定性技术分析：0-100 加权评分（趋势/乖离/量能/支撑/MACD/RSI 六模块）、均线排列、量价状态、支撑压力位、逐条 ✅/❌ 理由与风险项。引用技术面判断时必须以本工具评分为准，不得自行心算指标。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "code": [
                "type": "string",
                "description": "6 位 A股代码，如 600519"
            ],
            "days": [
                "type": "integer",
                "description": "取多少个交易日的 K 线（默认 120，上限 500）"
            ]
        ],
        "required": ["code"],
        "additionalProperties": false
    ]

    let engine: MarketDataEngine

    private struct Params: Codable {
        var code: String
        var days: Int?
    }

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let params: Params
        do {
            params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
        } catch {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "参数不是合法 JSON：\(error.localizedDescription)"), isError: true)
        }
        let bare = MarketCodeNormalizer.bareACode(from: params.code)
        guard bare.count == 6, bare.allSatisfy(\.isNumber) else {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_code", message: "仅支持 6 位 A股代码，收到：\(params.code)"), isError: true)
        }
        let days = min(max(params.days ?? 120, 30), 500)

        do {
            let bars = try await engine.dailyBars(code: bare, days: days)
            let sanitized = TechnicalAnalysisEngine.analyze(code: bare, bars: bars)
            let (sanitizedResult, consistencyNotes) = TechnicalAnalysisEngine.sanitizeForPrompt(sanitized)
            await context.evidenceLedger.record([
                TrendEvidence(
                    id: sanitizedResult.evidenceID,
                    sourceName: "日K技术分析（本地规则计算）",
                    title: "\(bare) 技术面评分 \(sanitizedResult.score)",
                    url: nil,
                    publishedAt: nil,
                    retrievedAt: sanitizedResult.asOf,
                    summary: sanitizedResult.evidenceSummary,
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .derived,
                        sourceTier: .primary,
                        requestedTopicKeys: ["technical-analysis", bare],
                        entityCodes: [bare],
                        metadataConfidence: .ruleDerived
                    )
                )
            ])
            let recentBars = bars.suffix(5).map { bar -> [String: Any] in
                [
                    "date": bar.date,
                    "close": bar.close,
                    "pct_chg": bar.pctChg ?? NSNull(),
                    "volume": bar.volume,
                ]
            }
            let data: [String: Any] = [
                "code": bare,
                "score": sanitizedResult.score,
                "signal_band": sanitizedResult.signalBand.rawValue,
                "score_breakdown": sanitizedResult.scoreBreakdown,
                "ma_alignment": sanitizedResult.maAlignment?.rawValue ?? NSNull(),
                "volume_price_state": sanitizedResult.volumePriceState?.rawValue ?? NSNull(),
                "macd_state": sanitizedResult.macdState?.rawValue ?? NSNull(),
                "rsi_state": sanitizedResult.rsiState?.rawValue ?? NSNull(),
                "ma5": sanitizedResult.ma5 ?? NSNull(),
                "ma20": sanitizedResult.ma20 ?? NSNull(),
                "bias_ma5": sanitizedResult.biasMA5.map { (round($0 * 100) / 100) } ?? NSNull(),
                "support": sanitizedResult.support ?? NSNull(),
                "resistance": sanitizedResult.resistance ?? NSNull(),
                "volume_ratio": sanitizedResult.volumeRatio.map { (round($0 * 100) / 100) } ?? NSNull(),
                "reasons": sanitizedResult.reasons.map(\.text),
                "risk_factors": sanitizedResult.riskFactors.map(\.text),
                "recent_bars": recentBars,
                "data_boundary": sanitizedResult.dataBoundary,
                "evidence_id": sanitizedResult.evidenceID
            ]
            var warnings: [String] = consistencyNotes
            if sanitizedResult.dataBoundary.contains("不足") {
                warnings.append("技术面样本边界：\(sanitizedResult.dataBoundary)")
            }
            return .content(TrendResearchToolEnvelope.success(data, warnings: warnings, evidenceIDs: [sanitizedResult.evidenceID]))
        } catch {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "kline_unavailable",
                    message: "日 K 数据暂不可用：\((error as? MarketDataError)?.errorDescription ?? error.localizedDescription)。不得在无 K 线时编造技术指标。"
                ),
                isError: true
            )
        }
    }
}
