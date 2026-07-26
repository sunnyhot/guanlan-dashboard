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

    var monthlyReportExportMetadataURL: URL? {
        dataDirectoryURL?.appendingPathComponent("monthly-report-export.json", isDirectory: false)
    }

    var managerWatchTimelineFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("manager-watch-timeline.json", isDirectory: false)
    }

    var importUndoSnapshotFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("latest-import-undo.json", isDirectory: false)
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

    var nextHourGuidanceFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("next-hour-guidance.json", isDirectory: false)
    }

    var tradeSignalSettingsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trade-signal-settings.json", isDirectory: false)
    }

    var tradeSignalNotificationStateFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trade-signal-notification-state.json", isDirectory: false)
    }

    var trendTrackingItemsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("trend-tracking-items.json", isDirectory: false)
    }

    var hasLiveService: Bool {
        true
    }

    var canRefreshWithoutLiveService: Bool {
        true
    }

    var liveModeLabel: String {
        if isRefreshing {
            return "刷新中"
        }
        return "原生直连"
    }

    var currentSnapshotSupportsComments: Bool {
        currentSnapshot?.snapshotType == "posts" && selectedPost?.postId != nil
    }

    var activePortfolioHoldingCount: Int {
        userPortfolioHoldings.reduce(0) { $0 + ($1.isArchived ? 0 : 1) }
    }

    var archivedPortfolioHoldingCount: Int {
        userPortfolioHoldings.reduce(0) { $0 + ($1.isArchived ? 1 : 0) }
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

    var portfolioMenuBarTitle: String {
        if let menuBarTickerTitle {
            return menuBarTickerTitle
        }
        return portfolioMenuBarFallbackTitle
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

    var portfolioAutoRefreshStatusText: String {
        guard hasPersonalPortfolio else {
            if hasPersonalWatchlist {
                return isRefreshingPersonalWatchlist
                    ? "关注行情刷新中…"
                    : "关注行情每 \(portfolioAutoRefreshIntervalSeconds) 秒自动刷新"
            }
            if hasArchivedPortfolio {
                return "暂无活跃持仓，归档记录已保留"
            }
            return "添加持仓后自动刷新估值"
        }
        if isRefreshingPortfolio {
            return "持仓估值刷新中…"
        }
        return "持仓估值每 \(portfolioAutoRefreshIntervalSeconds) 秒自动刷新"
    }

    var managerWatchStatusText: String {
        if managerWatchSettings.isEnabled {
            return "已开启 · \(managerWatchSettings.intervalLabel)"
        }
        return "已关闭"
    }

    var managerWatchScopeText: String {
        let scopes = [
            managerWatchSettings.watchPlatform ? "调仓" : nil,
            managerWatchSettings.watchForum ? "发言" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " + ")
        let scopeText = scopes.isEmpty ? "未选择" : scopes
        return "\(managerWatchSettings.prodCode) · \(managerWatchSettings.managerName) · \(scopeText)"
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
