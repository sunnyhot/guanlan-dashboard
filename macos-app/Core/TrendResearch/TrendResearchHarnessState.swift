import Foundation

/// Harness 维护的确定性研究覆盖度。
///
/// 它不替 Agent 选择研究主题，只记录已经读取的数据、去除重复网页证据，
/// 并把剩余预算与缺口附加到每个工具结果中，让模型能及时收敛到提交阶段。
struct TrendResearchHarnessState: Sendable {
    private let scope: TrendResearchRunScope
    private let requiredAssetIDs: Set<String>
    private let lookThroughRequired: Bool
    private let marketSnapshotRequired: Bool
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

    init(
        snapshot: TrendResearchSnapshot,
        scope: TrendResearchRunScope = .full,
        officialSourceRequired: Bool = false,
        alphaVantageRequired: Bool = false
    ) {
        self.scope = scope
        requiredAssetIDs = scope.requiresPortfolioAssets
            ? Set(snapshot.assets.map(\.id))
            : []
        lookThroughRequired = scope.requiresFundLookThrough && snapshot.lookThrough != nil
        marketSnapshotRequired = scope.requiresMarketSnapshot && !snapshot.marketQuotes.isEmpty
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

    func readyForSubmission() -> Bool {
        (!scope.requiresPortfolioOverview || overviewRead)
            && assetCoverageComplete
            && lookThroughCoverageComplete
            && (!marketSnapshotRequired || marketSnapshotRead)
            && (!officialSourceRequired || officialSourceAttempted)
            && (!alphaVantageRequired || alphaVantageAttempts > 0)
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
        reservedSubmitToolCalls: Int
    ) -> TrendResearchToolResult {
        guard var envelope = Self.jsonObject(result.contentJSON) else { return result }
        let remainingResearchToolCalls = max(
            0,
            maxToolCalls - reservedSubmitToolCalls - toolCallsUsed
        )
        envelope["harness"] = [
            "turn": turn,
            "turns_remaining": max(0, maxTurns - turn),
            "tool_calls_used": toolCallsUsed,
            "tool_calls_remaining": max(0, maxToolCalls - toolCallsUsed),
            "submit_calls_reserved": reservedSubmitToolCalls,
            "research_tool_calls_remaining": remainingResearchToolCalls,
            "overview_read": overviewRead,
            "portfolio_assets_read": readAssetCount,
            "portfolio_assets_total": requiredAssetCount,
            "portfolio_coverage_complete": assetCoverageComplete,
            "fund_look_through_required": lookThroughRequired,
            "fund_look_through_read": lookThroughRead,
            "market_snapshot_required": marketSnapshotRequired,
            "market_snapshot_read": marketSnapshotRead,
            "official_source_required": officialSourceRequired,
            "official_source_attempts": officialSourceAttempts,
            "successful_official_source_queries": successfulOfficialSourceQueries,
            "official_evidence_count": seenOfficialEvidenceIDs.count,
            "alpha_vantage_required": alphaVantageRequired,
            "alpha_vantage_attempts": alphaVantageAttempts,
            "successful_alpha_vantage_queries": successfulAlphaVantageQueries,
            "alpha_vantage_evidence_count": seenAlphaVantageEvidenceIDs.count,
            "ready_for_submission": readyForSubmission(),
            "next_step_hint": nextStepHint(
                remainingResearchToolCalls: remainingResearchToolCalls
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
        remainingResearchToolCalls: Int = .max
    ) -> String {
        if scope.requiresPortfolioOverview, !overviewRead {
            return "先调用 get_portfolio_overview。"
        }
        if !assetCoverageComplete {
            return "继续分页调用 get_portfolio_assets，尚有 \(unreadAssetCount) 个标的未读取。"
        }
        if lookThroughRequired, !lookThroughRead {
            return "调用 get_fund_lookthrough 读取基金底层资产、披露日期与未知仓位。"
        }
        if marketSnapshotRequired, !marketSnapshotRead {
            return "调用 get_market_snapshot 读取基金净值、大盘与底层证券当日涨跌；基金归因不能只复述持仓结构。"
        }
        if officialSourceRequired, !officialSourceAttempted {
            return "先调用 official_sec_research 查询组合相关美股或底层美股的 SEC 官方申报。"
        }
        if alphaVantageRequired, alphaVantageAttempts == 0 {
            return "调用 alpha_vantage_research 获取与当前标的最相关的一项结构化补充；它不是官方源，不得覆盖 SEC 等一手证据。"
        }
        if remainingResearchToolCalls == 0 {
            return "研究工具预算已收敛；使用现有证据提交当前模块。未覆盖的全市场维度不得生成机会结论。"
        }
        return "「\(scope.displayName)」必需数据已覆盖；立即停止新增研究，只提交当前开放模块。"
    }

    private static func jsonObject(_ content: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    }

}

