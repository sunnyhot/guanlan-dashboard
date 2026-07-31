import Foundation
import ServiceManagement

// MARK: - Public Computed Properties

extension AppModel {
    var selectedPost: SnapshotRecordPayload? {
        currentSnapshot?.records.first(where: { $0.id == selectedPostID }) ?? currentSnapshot?.records.first
    }

    var selectedPlatformAction: PlatformActionPayload? {
        guard let actions = platformPayload?.actions, !actions.isEmpty else { return nil }
        if let selectedPlatformActionID,
           let matched = actions.first(where: { $0.id == selectedPlatformActionID }) {
            return matched
        }
        return actions.first
    }

    var latestPlatformActions: [PlatformActionPayload] {
        Array((platformPayload?.actions ?? []).prefix(8))
    }

    var platformHoldings: [HoldingItemPayload] {
        platformPayload?.holdings?.items ?? []
    }

    var forumRecords: [SnapshotRecordPayload] {
        currentSnapshot?.records ?? []
    }

    var portfolioFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("user-portfolio.json", isDirectory: false)
    }

    var personalWatchlistFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("user-watchlist.json", isDirectory: false)
    }

    var pendingTradeFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("user-pending-trades.json", isDirectory: false)
    }

    var investmentPlanFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("user-investment-plans.json", isDirectory: false)
    }

    var portfolioValuationAlertFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("portfolio-valuation-alerts.json", isDirectory: false)
    }

    var portfolioValuationAlertSettingsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("portfolio-valuation-alert-settings.json", isDirectory: false)
    }

    var managerWatchTimelineFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("manager-watch-timeline.json", isDirectory: false)
    }

    var portfolioInsightSnapshotsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("portfolio-insight-snapshots.json", isDirectory: false)
    }

    var trendAnalysisSettingsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-analysis-settings.json", isDirectory: false)
    }

    var trendAnalysisReportFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-analysis-report.json", isDirectory: false)
    }

    var trendAgentRunLogFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-agent.log", isDirectory: false)
    }

    var trendAgentRunArtifactsDirectoryURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-agent-runs", isDirectory: true)
    }

    var nextHourGuidanceFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("next-hour-guidance.json", isDirectory: false)
    }

    var trendTrackingItemsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-tracking-items.json", isDirectory: false)
    }

    var fundLookThroughCacheFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("fund-look-through-cache.json", isDirectory: false)
    }

    var hasLiveService: Bool {
        true
    }

    var canRefreshWithoutLiveService: Bool {
        true
    }

    var currentSnapshotSupportsComments: Bool {
        currentSnapshot?.snapshotType == "posts" && selectedPost?.postId != nil
    }

    var activePortfolioHoldingCount: Int {
        userPortfolioHoldings.reduce(0) { $0 + ($1.isArchived ? 0 : 1) }
    }

    var hasAnyPortfolioRecords: Bool {
        !userPortfolioHoldings.isEmpty
    }

    var hasPersonalPortfolio: Bool {
        userPortfolioHoldings.contains { !$0.isArchived }
    }

    var hasPersonalWatchlist: Bool {
        !personalWatchlistRecords.isEmpty
    }

    var hasActivePersonalWatchlistAlerts: Bool {
        personalWatchlistRecords.contains { $0.hasActiveAlerts }
    }

    var hasArchivedPortfolio: Bool {
        userPortfolioHoldings.contains { $0.isArchived }
    }

    var hasPendingTrades: Bool {
        !pendingTrades.isEmpty
    }

    var hasInvestmentPlans: Bool {
        !investmentPlans.isEmpty
    }

    var portfolioMenuBarFallbackTitle: String {
        PortfolioMenuBarTitle.fallback(
            totalEffectiveHoldingAmount: personalAssetSummary?.totalEffectiveHoldingAmount,
            hasPersonalPortfolio: hasPersonalPortfolio,
            hasPendingTrades: hasPendingTrades,
            hasInvestmentPlans: hasInvestmentPlans,
            hasArchivedPortfolio: hasArchivedPortfolio
        )
    }

    var managerWatchStatusText: String {
        if isManagerWatchPolling {
            return "巡检中…"
        }
        if managerWatchSettings.isEnabled {
            return "已开启 · \(managerWatchSettings.intervalLabel)"
        }
        return "已关闭"
    }

    var managerWatchScopeText: String {
        var scopes = managerWatchSelectedAdjustmentSources.map(\.displayName)
        if managerWatchSettings.watchForum {
            scopes.append("论坛发言")
        }
        return scopes.isEmpty ? "未选择巡检范围" : scopes.joined(separator: " + ")
    }

    var managerWatchNextCheckText: String {
        guard managerWatchSettings.isEnabled else { return "巡检已关闭" }
        guard !isManagerWatchPolling else { return "正在执行" }
        guard
            let lastCheckedAt = managerWatchSettings.lastCheckedAt,
            let lastDate = Self.timestampFormatter.date(from: lastCheckedAt),
            let nextDate = Calendar.current.date(
                byAdding: .minute,
                value: max(5, managerWatchSettings.intervalMinutes),
                to: lastDate
            )
        else {
            return "等待首次巡检"
        }
        if nextDate <= Date() {
            return "即将执行"
        }
        return Self.timestampFormatter.string(from: nextDate)
    }

    var managerWatchBaselineStatusText: String {
        guard managerWatchSettings.watchForum || !managerWatchSelectedAdjustmentSources.isEmpty else {
            return "未选择"
        }
        let adjustmentReady = managerWatchSelectedAdjustmentSources.allSatisfy {
            managerWatchSettings.adjustmentBaselineTargetKeys[$0.id] == $0.baselineTargetKey
        }
        let forumKey = "forum|\(managerWatchSettings.prodCode.trimmingCharacters(in: .whitespacesAndNewlines))|\(managerWatchSettings.managerName.trimmingCharacters(in: .whitespacesAndNewlines))"
        let forumReady = !managerWatchSettings.watchForum
            || managerWatchSettings.forumBaselineTargetKey == forumKey
        return adjustmentReady && forumReady ? "已建立" : "等待静默建立"
    }

    var launchAtLoginStatusText: String {
        let launchAgent = LaunchAtLoginAgent()
        if launchAgent.isInstalled {
            return "已开启"
        }
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return "已开启"
            case .requiresApproval:
                return "待系统授权"
            case .notFound:
                return "当前构建不支持"
            case .notRegistered:
                return "已关闭"
            @unknown default:
                return "未知"
            }
        }
        return "已关闭"
    }

    var hasForumPosts: Bool {
        currentSnapshot?.snapshotType == "posts" && !forumRecords.isEmpty
    }

    var hasPlatformActions: Bool {
        !(platformPayload?.actions?.isEmpty ?? true)
    }
}
