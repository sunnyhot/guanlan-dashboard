import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - PortfolioState

@MainActor
final class PortfolioState: ObservableObject {
    @Published var userPortfolioHoldings: [UserPortfolioHolding] = []
    @Published var userPortfolioSnapshot: UserPortfolioSnapshot?
    @Published var isRefreshingPortfolio = false
    @Published var isResolvingPortfolioNames = false
    @Published var personalWatchlistRecords: [PersonalWatchlistRecord] = []
    @Published var personalWatchlistSnapshot: PersonalWatchlistSnapshot?
    @Published var isRefreshingPersonalWatchlist = false
    @Published var pendingTrades: [PersonalPendingTrade] = []
    @Published var pendingTradesDraft = ""
    @Published var investmentPlans: [PersonalInvestmentPlan] = []
    @Published var investmentPlansDraft = ""
    @Published var marketIndexQuotes: [MarketIndexKind: MarketIndexQuote] = [:]
    @Published var isRefreshingMarketIndices = false

    // Cached computed property backing stores (moved from AppModel)
    var _cachedAssetRows: [PersonalAssetAggregateRow]?
    var _cachedAssetSummary: PersonalAssetAggregateSummary?
    var _cachedMonthlyPlatformSummary: [PlatformMonthSummary]?
    var _cachedActiveInvestmentPlans: [PersonalInvestmentPlan]?
    var _cachedPausedInvestmentPlans: [PersonalInvestmentPlan]?
    var _cachedEndedInvestmentPlans: [PersonalInvestmentPlan]?
    var _cachedInvestmentPlanSummary: PersonalInvestmentPlanSummary?
    var _cachedPendingTradeSummary: PersonalPendingTradeSummary?

    func clearPortfolioCaches() {
        _cachedAssetRows = nil
        _cachedAssetSummary = nil
    }

    func clearInvestmentPlanCaches() {
        _cachedActiveInvestmentPlans = nil
        _cachedPausedInvestmentPlans = nil
        _cachedEndedInvestmentPlans = nil
        _cachedInvestmentPlanSummary = nil
    }

    func clearPendingTradeCaches() {
        _cachedPendingTradeSummary = nil
    }

    func clearPlatformCaches() {
        _cachedMonthlyPlatformSummary = nil
    }

    func clearAllCaches() {
        _cachedAssetRows = nil
        _cachedAssetSummary = nil
        _cachedMonthlyPlatformSummary = nil
        _cachedActiveInvestmentPlans = nil
        _cachedPausedInvestmentPlans = nil
        _cachedEndedInvestmentPlans = nil
        _cachedInvestmentPlanSummary = nil
        _cachedPendingTradeSummary = nil
    }
}

// MARK: - ForumState

@MainActor
final class ForumState: ObservableObject {
    @Published var currentSnapshot: SnapshotPayload?
    @Published var commentsPayload: CommentsPayload?
    @Published var selectedPostID: String?
    @Published var commentSortType = "hot"
    @Published var onlyManagerReplies = false
    @Published var isLoadingComments = false
}

// MARK: - PlatformState

@MainActor
final class PlatformState: ObservableObject {
    @Published var platformPayload: PlatformPayload?
    @Published var selectedPlatformActionID: String?
}

// MARK: - UIState

@MainActor
final class UIState: ObservableObject {
    @Published var selectedSection: AppSection = .overview
    @Published var selectedPlatformActivityTab: PlatformActivityTab = .adjustments
    @Published var showsInDock: Bool = (UserDefaults.standard.object(forKey: "qieman.dashboard.showsInDock") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: "qieman.dashboard.showsInDock")
            NSApplication.shared.setActivationPolicy(
                AppLaunchPresentationPolicy.configuredActivationPolicy(showsInDock: showsInDock)
            )
        }
    }

    @Published var appearance: AppAppearance = AppAppearance.load() { didSet { appearance.save() } }
    @Published var showAdvancedParams = false
    @Published var launchAtLoginEnabled = false
    @Published var portfolioDraft = ""
}

// MARK: - UpdateState

@MainActor
final class UpdateState: ObservableObject {
    @Published var isCheckingForUpdates = false
    @Published var availableUpdate: AppUpdateRelease?
    @Published var isPresentingUpdateSheet = false
    @Published var isInstallingUpdate = false
    @Published var updateInstallProgress = ""
    @Published var updateDownloadFraction: Double = 0
    @Published var autoCheckForUpdatesOnLaunch: Bool = (UserDefaults.standard.object(forKey: "qieman.dashboard.update.autoCheckOnLaunch") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoCheckForUpdatesOnLaunch, forKey: "qieman.dashboard.update.autoCheckOnLaunch")
        }
    }
}

// MARK: - EnhancementState

@MainActor
final class EnhancementState: ObservableObject {
    @Published var selectedTab: EnhancementCenterTab = .trend
    @Published var lastMonthlyReportExport: MonthlyReportExportMetadata?
    @Published var managerWatchTimelineEvents: [ManagerWatchTimelineEvent] = []
    @Published var activeImportPreviewSession: ImportPreviewSession?
    @Published var importUndoSnapshot: ImportUndoSnapshot?
    @Published var portfolioInsightSnapshots: [PortfolioInsightSnapshot] = []
    @Published var pendingOverwriteReportURL: URL?
    @Published var trendReport: TrendAnalysisReport?
    @Published var trendSettings: TrendAnalysisSettings = .default
    @Published var trendGenerationState: TrendGenerationState = .idle
    @Published var trendConnectionState: TrendConnectionState = .idle
    @Published var trendProviderCapabilities: TrendProviderCapabilities?
    @Published var trendPrivacyMode: TrendPrivacyMode = .sanitized
    @Published var lastTrendGeneratedAt: String?
    @Published var lastTrendError = ""
    @Published var lastTrendConnectionMessage = ""
    @Published var trendProgressLogs: [TrendProgressLog] = []
    @Published var nextHourGuidanceArchive: NextHourGuidanceArchive = .empty
    @Published var nextHourGuidanceGenerationState: TrendGenerationState = .idle
    @Published var nextHourGuidanceError = ""
    @Published var tradeSignalSettings: TradeSignalSettings = .default
    @Published var tradeSignalNotificationState = TradeSignalNotificationState()
    @Published var selectedWorkbenchSegment: WorkbenchSegment = .today
    @Published var trendTrackingItems: [TrendTrackingItem] = []
    @Published var selectedTrendTrackingItemID: UUID?
    @Published var isPresentingCommandPalette = false
}

enum EnhancementCenterTab: String, CaseIterable, Identifiable {
    case review = "复盘"
    case watch = "巡检"
    case importPreview = "录入"
    case insight = "洞察"
    case trend = "趋势"

    var id: String { rawValue }

    static let workbenchTabs: [EnhancementCenterTab] = [.trend]

    var isVisibleInWorkbench: Bool {
        Self.workbenchTabs.contains(self)
    }
}

/// 「AI 研判」内部分段（原 config/report/signals 重构为 today/tracking）
enum WorkbenchSegment: String, CaseIterable, Identifiable, Hashable {
    case today = "今日研判"
    case tracking = "跟踪清单"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .today:
            return "sparkles"
        case .tracking:
            return "bell.badge"
        }
    }
}
