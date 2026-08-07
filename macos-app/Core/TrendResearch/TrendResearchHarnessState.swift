import Foundation

/// Harness 维护的确定性研究覆盖度。
///
/// 它不替 Agent 选择研究主题，只记录已经读取的数据、去除重复网页证据，
/// 并把剩余预算与缺口附加到每个工具结果中，让模型能及时收敛到提交阶段。
struct TrendResearchHarnessState: Sendable {
    private let requiredAssetIDs: Set<String>
    private let lookThroughRequired: Bool
    private let officialSourceRequired: Bool
    private let alphaVantageRequired: Bool
    private(set) var overviewRead = false
    private(set) var assetIDsRead: Set<String> = []
    private(set) var lookThroughRead = false
    private(set) var marketSnapshotRead = false
    private(set) var officialSourceAttempts = 0
    private(set) var successfulOfficialSourceQueries = 0
    private(set) var seenOfficialEvidenceIDs: Set<String> = []
    private(set) var alphaVantageAttempts = 0
    private(set) var successfulAlphaVantageQueries = 0
    private(set) var seenAlphaVantageEvidenceIDs: Set<String> = []
    private(set) var webSearchAttempts = 0
    private(set) var successfulWebSearches = 0
    private(set) var seenWebEvidenceIDs: Set<String> = []
    private(set) var duplicateWebEvidenceCount = 0
    private(set) var opportunitySearchTargetKinds: Set<TrendResearchTargetKind> = []
    private(set) var opportunitySearchSectorGroups: Set<String> = []

    private static let requiredOpportunitySearchTargetKinds: Set<TrendResearchTargetKind> = [
        .assetClass,
        .index,
        .sector,
    ]

    init(
        snapshot: TrendResearchSnapshot,
        officialSourceRequired: Bool = false,
        alphaVantageRequired: Bool = false
    ) {
        requiredAssetIDs = Set(snapshot.assets.map(\.id))
        lookThroughRequired = snapshot.lookThrough != nil
        self.officialSourceRequired = officialSourceRequired
        self.alphaVantageRequired = alphaVantageRequired
    }

    var requiredAssetCount: Int {
        requiredAssetIDs.count
    }

    var readAssetCount: Int {
        assetIDsRead.intersection(requiredAssetIDs).count
    }

    var unreadAssetCount: Int {
        max(0, requiredAssetCount - readAssetCount)
    }

    var assetCoverageComplete: Bool {
        unreadAssetCount == 0
    }

    var lookThroughCoverageComplete: Bool {
        !lookThroughRequired || lookThroughRead
    }

    var officialSourceAttempted: Bool {
        officialSourceAttempts > 0
    }

    var opportunitySearchCoverageComplete: Bool {
        Self.requiredOpportunitySearchTargetKinds.isSubset(of: opportunitySearchTargetKinds)
            && missingOpportunitySearchSectorGroups.isEmpty
    }

    var missingOpportunitySearchTargetKinds: [TrendResearchTargetKind] {
        Self.requiredOpportunitySearchTargetKinds
            .subtracting(opportunitySearchTargetKinds)
            .sorted { $0.opportunityScanOrder < $1.opportunityScanOrder }
    }

    var missingOpportunitySearchSectorGroups: [String] {
        MarketOpportunityUniverse.requiredSectorGroupKeys.filter {
            !opportunitySearchSectorGroups.contains(Self.normalized($0))
        }
    }

    func readyForSubmission(
        webSearchConfigured: Bool,
        allowInsufficientWebEvidence: Bool = false
    ) -> Bool {
        overviewRead
            && assetCoverageComplete
            && lookThroughCoverageComplete
            && (!officialSourceRequired || officialSourceAttempted)
            && (!alphaVantageRequired || alphaVantageAttempts > 0)
            && (
                !webSearchConfigured
                    || (
                        opportunitySearchCoverageComplete
                            && (
                                successfulWebSearches > 0
                                    || allowInsufficientWebEvidence
                            )
                    )
            )
    }

    mutating func process(
        toolName: String,
        result: TrendResearchToolResult
    ) -> TrendResearchToolResult {
        var processed = result
        if toolName == TrendResearchAgent.officialSourceToolName {
            officialSourceAttempts += 1
            if !result.isError,
               let envelope = Self.jsonObject(result.contentJSON) {
                let evidenceIDs = envelope["evidence_ids"] as? [String] ?? []
                let newIDs = evidenceIDs.filter {
                    seenOfficialEvidenceIDs.insert($0).inserted
                }
                if !newIDs.isEmpty {
                    successfulOfficialSourceQueries += 1
                }
            }
        }
        if toolName == TrendResearchAgent.alphaVantageToolName {
            alphaVantageAttempts += 1
            if !result.isError,
               let envelope = Self.jsonObject(result.contentJSON) {
                let evidenceIDs = envelope["evidence_ids"] as? [String] ?? []
                let newIDs = evidenceIDs.filter {
                    seenAlphaVantageEvidenceIDs.insert($0).inserted
                }
                if !newIDs.isEmpty {
                    successfulAlphaVantageQueries += 1
                }
            }
        }
        if toolName == TrendResearchAgent.webSearchToolName {
            webSearchAttempts += 1
            if !result.isError {
                let evidenceCountBefore = seenWebEvidenceIDs.count
                processed = deduplicatingWebEvidence(in: result)
                if seenWebEvidenceIDs.count > evidenceCountBefore {
                    successfulWebSearches += 1
                }
            }
        }

        guard !processed.isError,
              let envelope = Self.jsonObject(processed.contentJSON),
              let data = envelope["data"] as? [String: Any] else {
            return processed
        }

        if toolName == TrendResearchAgent.webSearchToolName,
           let target = data["research_target"] as? [String: Any],
           let rawKind = target["kind"] as? String,
           let kind = TrendResearchTargetKind(rawValue: rawKind),
           Self.requiredOpportunitySearchTargetKinds.contains(kind) {
            opportunitySearchTargetKinds.insert(kind)
            if kind == .sector,
               let key = target["key"] as? String,
               let group = MarketOpportunityUniverse.sectorGroup(matching: key) {
                opportunitySearchSectorGroups.insert(Self.normalized(group.key))
            }
        }

        switch toolName {
        case TrendResearchAgent.overviewToolName:
            overviewRead = true
        case "get_portfolio_assets":
            let assets = data["assets"] as? [[String: Any]] ?? []
            for asset in assets {
                if let id = asset["id"] as? String {
                    assetIDsRead.insert(id)
                }
            }
        case "get_fund_lookthrough":
            lookThroughRead = true
        case "get_market_snapshot":
            marketSnapshotRead = true
        default:
            break
        }
        return processed
    }

    func attachingHarnessMetadata(
        to result: TrendResearchToolResult,
        turn: Int,
        maxTurns: Int,
        toolCallsUsed: Int,
        maxToolCalls: Int,
        reservedSubmitToolCalls: Int,
        webStatus: TrendWebSearchGovernorStatus,
        webSearchConfigured: Bool
    ) -> TrendResearchToolResult {
        guard var envelope = Self.jsonObject(result.contentJSON) else { return result }
        envelope["harness"] = [
            "turn": turn,
            "turns_remaining": max(0, maxTurns - turn),
            "tool_calls_used": toolCallsUsed,
            "tool_calls_remaining": max(0, maxToolCalls - toolCallsUsed),
            "submit_calls_reserved": reservedSubmitToolCalls,
            "overview_read": overviewRead,
            "portfolio_assets_read": readAssetCount,
            "portfolio_assets_total": requiredAssetCount,
            "portfolio_coverage_complete": assetCoverageComplete,
            "fund_look_through_required": lookThroughRequired,
            "fund_look_through_read": lookThroughRead,
            "market_snapshot_read": marketSnapshotRead,
            "official_source_required": officialSourceRequired,
            "official_source_attempts": officialSourceAttempts,
            "successful_official_source_queries": successfulOfficialSourceQueries,
            "official_evidence_count": seenOfficialEvidenceIDs.count,
            "alpha_vantage_required": alphaVantageRequired,
            "alpha_vantage_attempts": alphaVantageAttempts,
            "successful_alpha_vantage_queries": successfulAlphaVantageQueries,
            "alpha_vantage_evidence_count": seenAlphaVantageEvidenceIDs.count,
            "web_search_attempts": webSearchAttempts,
            "successful_web_searches": successfulWebSearches,
            "web_evidence_count": seenWebEvidenceIDs.count,
            "duplicate_web_evidence_removed": duplicateWebEvidenceCount,
            "opportunity_search_dimensions": opportunitySearchTargetKinds
                .sorted { $0.opportunityScanOrder < $1.opportunityScanOrder }
                .map(\.rawValue),
            "opportunity_sector_groups": MarketOpportunityUniverse.requiredSectorGroupKeys.filter {
                opportunitySearchSectorGroups.contains(Self.normalized($0))
            },
            "opportunity_sector_groups_missing": missingOpportunitySearchSectorGroups,
            "opportunity_search_coverage_complete": opportunitySearchCoverageComplete,
            "web_network_searches_used": webStatus.networkSearchesUsed,
            "web_cache_hits": webStatus.cacheHits,
            "web_searches_remaining": webStatus.remainingNetworkSearches,
            "ready_for_submission": readyForSubmission(
                webSearchConfigured: webSearchConfigured,
                allowInsufficientWebEvidence: webSearchAttempts > 0
                    && webStatus.remainingNetworkSearches == 0
            ),
            "next_step_hint": nextStepHint(
                webSearchConfigured: webSearchConfigured,
                remainingWebSearches: webStatus.remainingNetworkSearches
            )
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let content = String(data: data, encoding: .utf8) else {
            return result
        }
        return TrendResearchToolResult(
            contentJSON: content,
            isError: result.isError,
            completion: result.completion
        )
    }

    func nextStepHint(
        webSearchConfigured: Bool,
        remainingWebSearches: Int
    ) -> String {
        if !overviewRead {
            return "先调用 get_portfolio_overview。"
        }
        if !assetCoverageComplete {
            return "继续分页调用 get_portfolio_assets，尚有 \(unreadAssetCount) 个标的未读取。"
        }
        if lookThroughRequired, !lookThroughRead {
            return "调用 get_fund_lookthrough 读取基金底层资产、披露日期与未知仓位。"
        }
        if officialSourceRequired, !officialSourceAttempted {
            return "先调用 official_sec_research 查询组合相关美股或底层美股的 SEC 官方申报；官方源完成或明确失败后，才使用网页搜索补缺。"
        }
        if alphaVantageRequired, alphaVantageAttempts == 0 {
            if !officialSourceRequired,
               webSearchConfigured,
               successfulWebSearches == 0 {
                return "中国标的先调用 web_search 并限定交易所、监管机构或政府官方域名；取得一手证据后，再用 alpha_vantage_research 补充结构化行情。"
            }
            return "调用 alpha_vantage_research 获取与当前标的最相关的一项结构化补充；它不是官方源，不得覆盖 SEC 等一手证据。"
        }
        if webSearchConfigured, !opportunitySearchCoverageComplete {
            if remainingWebSearches == 0 {
                return "全市场机会扫描未覆盖全部维度且联网预算已用完；本次不得提交新的机会报告，也不得用组合长期观点填充机会清单。"
            }
            let missing = missingOpportunitySearchTargetKinds
                .map(\.opportunityScanDisplayName)
                .joined(separator: "、")
            if !missing.isEmpty {
                return "继续调用 web_search 完成独立于当前持仓的全市场机会扫描，尚缺：\(missing)。每次使用对应的 research_target.kind。"
            }
            let nextGroup = missingOpportunitySearchSectorGroups.first ?? "行业板块"
            return "继续调用 web_search 扫描板块分组「\(nextGroup)」，research_target.key 使用分组名，并在 sectorKeys 中完整填写该组板块。"
        }
        if webSearchConfigured, successfulWebSearches == 0 {
            if remainingWebSearches == 0 {
                return "联网搜索未形成有效新证据且预算已用完；以 insufficientEvidence/analysisOnly 收尾，所有行动降为 watch。"
            }
            return "调用 web_search 并取得至少一条非空、未重复的新证据；必须携带 research_target。"
        }
        if remainingWebSearches == 0 {
            return "联网搜索预算已用完；可读取尚需的本地行情，然后使用现有证据提交报告。"
        }
        return "必需数据已覆盖；立即停止新增研究，进入组合、市场、持仓分批、操作风险的分模块提交。"
    }

    private mutating func deduplicatingWebEvidence(
        in result: TrendResearchToolResult
    ) -> TrendResearchToolResult {
        guard var envelope = Self.jsonObject(result.contentJSON),
              var data = envelope["data"] as? [String: Any],
              let results = data["results"] as? [[String: Any]] else {
            return result
        }

        var newEvidenceIDs: [String] = []
        let uniqueResults = results.filter { item in
            guard let evidenceID = item["evidence_id"] as? String else { return true }
            if seenWebEvidenceIDs.contains(evidenceID) {
                duplicateWebEvidenceCount += 1
                return false
            }
            seenWebEvidenceIDs.insert(evidenceID)
            newEvidenceIDs.append(evidenceID)
            return true
        }

        data["results"] = uniqueResults
        data["count"] = uniqueResults.count
        envelope["data"] = data
        envelope["evidence_ids"] = newEvidenceIDs
        if uniqueResults.count < results.count {
            var warnings = envelope["warnings"] as? [String] ?? []
            warnings.append("Harness 已移除 \(results.count - uniqueResults.count) 条本次运行中重复出现的网页证据。")
            envelope["warnings"] = warnings
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope),
              let content = String(data: encoded, encoding: .utf8) else {
            return result
        }
        return TrendResearchToolResult(
            contentJSON: content,
            isError: result.isError,
            completion: result.completion
        )
    }

    private static func jsonObject(_ content: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private extension TrendResearchTargetKind {
    var opportunityScanOrder: Int {
        switch self {
        case .assetClass: 0
        case .index: 1
        case .sector: 2
        case .asset: 3
        case .macro: 4
        }
    }

    var opportunityScanDisplayName: String {
        switch self {
        case .assetClass: "大类资产"
        case .index: "大盘/宽基"
        case .sector: "行业/主题板块"
        case .asset: "持仓标的"
        case .macro: "宏观环境"
        }
    }
}
