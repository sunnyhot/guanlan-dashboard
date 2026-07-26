import Foundation

/// Harness 维护的确定性研究覆盖度。
///
/// 它不替 Agent 选择研究主题，只记录已经读取的数据、去除重复网页证据，
/// 并把剩余预算与缺口附加到每个工具结果中，让模型能及时收敛到提交阶段。
struct TrendResearchHarnessState: Sendable {
    private let requiredAssetIDs: Set<String>
    private let lookThroughRequired: Bool
    private(set) var overviewRead = false
    private(set) var assetIDsRead: Set<String> = []
    private(set) var lookThroughRead = false
    private(set) var marketSnapshotRead = false
    private(set) var webSearchAttempts = 0
    private(set) var successfulWebSearches = 0
    private(set) var seenWebEvidenceIDs: Set<String> = []
    private(set) var duplicateWebEvidenceCount = 0

    init(snapshot: TrendResearchSnapshot) {
        requiredAssetIDs = Set(snapshot.assets.map(\.id))
        lookThroughRequired = snapshot.lookThrough != nil
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

    func readyForSubmission(webSearchConfigured: Bool) -> Bool {
        overviewRead
            && assetCoverageComplete
            && lookThroughCoverageComplete
            && (!webSearchConfigured || webSearchAttempts > 0)
    }

    mutating func process(
        toolName: String,
        result: TrendResearchToolResult
    ) -> TrendResearchToolResult {
        var processed = result
        if toolName == TrendResearchAgent.webSearchToolName {
            webSearchAttempts += 1
            if !result.isError {
                successfulWebSearches += 1
                processed = deduplicatingWebEvidence(in: result)
            }
        }

        guard !processed.isError,
              let envelope = Self.jsonObject(processed.contentJSON),
              let data = envelope["data"] as? [String: Any] else {
            return processed
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
            "web_search_attempts": webSearchAttempts,
            "successful_web_searches": successfulWebSearches,
            "web_evidence_count": seenWebEvidenceIDs.count,
            "duplicate_web_evidence_removed": duplicateWebEvidenceCount,
            "web_network_searches_used": webStatus.networkSearchesUsed,
            "web_cache_hits": webStatus.cacheHits,
            "web_searches_remaining": webStatus.remainingNetworkSearches,
            "ready_for_submission": readyForSubmission(webSearchConfigured: webSearchConfigured),
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
        if webSearchConfigured, webSearchAttempts == 0 {
            return "至少调用一次 web_search 核验最新行业或政策信息。"
        }
        if remainingWebSearches == 0 {
            return "联网搜索预算已用完；可读取尚需的本地行情，然后使用现有证据提交报告。"
        }
        return "必需数据已覆盖；仅在存在明确证据缺口时继续定向研究，否则提交报告。"
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
}
