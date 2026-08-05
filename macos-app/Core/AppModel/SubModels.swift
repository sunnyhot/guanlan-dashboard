#if canImport(AppKit)
import AppKit
#endif
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
    @Published var investmentPlans: [PersonalInvestmentPlan] = []
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
    @Published var selectedAlfaActionID: String?
}

// MARK: - UIState

@MainActor
final class UIState: ObservableObject {
    @Published var selectedSection: AppSection = .overview
    @Published var selectedPlatformActivityTab: PlatformActivityTab = .adjustments
    @Published var selectedPlatformAdjustmentViewMode: PlatformAdjustmentViewMode = .longWin
    @Published var showsInDock: Bool = (UserDefaults.standard.object(forKey: AppStorageKey.showsInDock) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: AppStorageKey.showsInDock)
            #if os(macOS)
            NSApplication.shared.setActivationPolicy(
                AppLaunchPresentationPolicy.configuredActivationPolicy(showsInDock: showsInDock)
            )
            #endif
        }
    }

    @Published var appearance: AppAppearance = AppAppearance.load() { didSet { appearance.save() } }
    @Published var showAdvancedParams = false
    @Published var launchAtLoginEnabled = false
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
    @Published var autoCheckForUpdatesOnLaunch: Bool = (UserDefaults.standard.object(forKey: AppStorageKey.autoCheckUpdateOnLaunch) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoCheckForUpdatesOnLaunch, forKey: AppStorageKey.autoCheckUpdateOnLaunch)
        }
    }
}

// MARK: - EnhancementState

@MainActor
final class EnhancementState: ObservableObject {
    @Published var managerWatchTimelineEvents: [ManagerWatchTimelineEvent] = []
    @Published var portfolioInsightSnapshots: [PortfolioInsightSnapshot] = []
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
    @Published var selectedWorkbenchSegment: WorkbenchSegment = .today
    @Published var trendTrackingItems: [TrendTrackingItem] = []
    @Published var selectedTrendTrackingItemID: UUID?
    @Published var isPresentingCommandPalette = false

    // 投资智能(Slice 1):DecisionCase + UserDecisionProfile。
    // 全部由 InvestmentIntelligence.enabled gate,enabled=false 时不加载不消费。
    @Published var decisionCases: [DecisionCase] = []
    @Published var userDecisionProfile: UserDecisionProfile = .default
    @Published var isRefreshingDecisionCases = false
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
