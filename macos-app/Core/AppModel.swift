#if canImport(AppKit)
import AppKit
#endif
import Combine
import Foundation
import SwiftUI

// MARK: - Settings

extension Notification.Name {
    static let qiemanNotificationDeepLink = Notification.Name("qieman.notificationDeepLink")
    static let qiemanAppearanceDidChange = Notification.Name("qieman.appearanceDidChange")
    static let qiemanFocusSearch = Notification.Name("qieman.focusSearch")
    static let qiemanToggleSidebar = Notification.Name("qieman.toggleSidebar")
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Map to NSAppearance so NSColor dynamic colors (used by AppPalette.adaptive)
    /// pick up the correct light/dark variant. macOS-only; iOS resolves light/dark
    /// via SwiftUI `.preferredColorScheme` directly.
    #if canImport(AppKit)
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif

    private static let storageKey = "qieman.dashboard.appearance"

    static func load() -> AppAppearance {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = AppAppearance(rawValue: raw) else { return .system }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

struct LiveRefreshError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    // MARK: Sub-models
    @Published private(set) var portfolioState = PortfolioState()
    @Published private(set) var forumState = ForumState()
    @Published private(set) var platformState = PlatformState()
    @Published private(set) var uiState = UIState()
    @Published private(set) var updateState = UpdateState()
    @Published private(set) var enhancementState = EnhancementState()

    // alfa 投顾组合
    @Published var alfaPortfolios: [AlfaPortfolioCatalogItem] = []
    @Published var alfaPayload: PlatformPayload?
    @Published var alfaHoldings: [AlfaHoldingPart] = []
    @Published var selectedAlfaPoCode: String?
    @Published var isLoadingAlfa = false
    @Published var alfaError: String?
    @Published var alfaCatalog: [AlfaPortfolioCatalogItem] = []
    @Published var isLoadingAlfaCatalog = false

    // MARK: Remaining @Published properties
    @Published var form = QueryFormState()
    @Published var isBootstrapping = false
    @Published var isRefreshing = false
    var lastLatestRefreshAt: Date?
    var lastPortfolioRefreshAt: Date?
    @Published var noticeMessage = ""
    @Published var errorMessage = ""
    @Published var logFileURL: URL?
    @Published var dataDirectoryURL: URL?
    @Published var personalAssetRows: [PersonalAssetAggregateRow] = []
    @Published var personalAssetSummary: PersonalAssetAggregateSummary?
    @Published var portfolioLookThroughSnapshot: PortfolioLookThroughSnapshot?
    @Published var portfolioLookThroughSourceWarnings: [String] = []
    @Published var isRefreshingPortfolioLookThrough = false
    @Published var managerWatchSettings = ManagerWatchSettings.default
    @Published var isManagerWatchPolling = false
    @Published var menuBarTickerSettings = MenuBarTickerSettings.load()
    @Published var portfolioValuationAlertProfiles: [String: PortfolioValuationAlertProfile] = [:]
    @Published var portfolioValuationAlertSettings = PortfolioValuationAlertSettings()
    /// 远程增强通道（PROV-3b / ADR-DATA010）诊断状态；默认未配置 = 不启动后台任务
    @Published var remoteStagingSyncStatus: RemoteStagingSyncStatus = .notConfigured("尚未启动")

    // 投资智能 V2 运行时（十六轮审查 P1-1 生产接线）
    @Published var intelligenceRuntime: AppModel.IntelligenceV2Runtime?
    @Published var isRunningMarketDiscovery = false
    @Published var isRunningIntradayDecision = false
    @Published var isRunningPortfolioResearch = false
    /// 最新发现报告（研究链路 top-K 输入；产品重构 §5.3 后 UI 读面统一走
    /// intelligenceDashboard，此字段不再直接驱动 UI）
    @Published var latestDiscoveryReport: MarketDiscoveryReport?
    /// 旧 AI 数据一次性迁移告知（WF-5；展示后由 UI 清空）
    @Published var legacyAIMigrationNotice: String?
    // 投资智能 V2 产品展示层状态（产品重构 §5.3；定义见 InvestmentIntelligenceV2Dashboard.swift）
    @Published var intelligenceDashboard: AppModel.IntelligenceDashboardLoadState = .idle
    @Published var intradayOperationState: AppModel.IntelligenceOperationState = .idle
    @Published var discoveryOperationState: AppModel.IntelligenceOperationState = .idle
    @Published var researchOperationState: AppModel.IntelligenceOperationState = .idle
    // 决策事项（审计 A2；定义见 Core/AppModel/DecisionCases.swift）
    @Published var decisionCases: [DecisionCase] = []
    @Published var isRefreshingDecisionCases = false
    /// 通知深链 / UI 请求打开详情的事项（IntelligenceSectionView 消费后清空）
    @Published var selectedDecisionCaseID: String?
    // 收盘复盘（审计 A1；定义见 Core/AppModel/MarketCloseReviewV2.swift）
    @Published var closeReviewOperationState: AppModel.IntelligenceOperationState = .idle
    @Published var isRunningCloseReview = false
    // 自动调度（审计 B1/C5；定义见 Core/IntelligenceAutomation.swift）
    @Published var intelligenceScheduleSettings = IntelligenceScheduleSettings()
    /// 待跳转的设置分区（消费方：Settings View，消费后清空；产品重构 §9）
    @Published var pendingSettingsSection: AppSettingsSection?

    /// 调仓筛选状态
    let filterState = PlatformFilterState()

    #if os(macOS)
    weak var appDelegate: QiemanApplicationDelegate?
    #endif

    // Services
    let dataController = ApplicationDataController()
    let platformClient = QiemanPlatformNativeClient()
    let alfaClient = QiemanAlfaClient()
    let alfaPortfolioStore = AlfaPortfolioStore()
    let portfolioStore = UserPortfolioStore()
    let personalWatchlistStore = PersonalWatchlistStore()
    let portfolioValuationAlertStore = PortfolioValuationAlertStore()
    let portfolioValuationAlertSettingsStore = PortfolioValuationAlertSettingsStore()
    let pendingTradesStore = PendingTradesStore()
    let investmentPlansStore = InvestmentPlansStore()
    let managerWatchStore = ManagerWatchStore()
    let notificationManager = LocalNotificationManager()
    let personalAssetAutomation = PersonalAssetAutomation()
    /// 平台无关更新服务。macOS 走 GitHub Release 自更新；iOS 由 App Store 管理。
    var updateService: any AppUpdateService = makeDefaultAppUpdateService()
    /// 平台无关开机自启。macOS 走 SMAppService + LaunchAgent；iOS 不支持（no-op）。
    var launchAtLoginController: any LaunchAtLoginController = makeDefaultLaunchAtLoginController()
    var fundLookThroughClient: any FundLookThroughClientProtocol = FundLookThroughClient()
    let portfolioAutoRefreshIntervalSeconds: UInt64 = 60
    let refreshThrottle = RefreshThrottle()

    // Runtime state
    private var didStart = false
    var managerWatchTask: Task<Void, Never>?
    var personalAssetAutomationTask: Task<Void, Never>?
    var portfolioAutoRefreshTask: Task<Void, Never>?
    var remoteStagingSyncTask: Task<Void, Never>?
    var marketDataSyncTask: Task<Void, Never>?
    /// 投资智能自动调度循环（审计 B1/C5）
    var intelligenceAutomationTask: Task<Void, Never>?
    /// 维护轮串行门（十九轮 P3-1：6h 循环与扫描前维护互斥执行）
    let marketDataMaintenanceGate = MarketDataMaintenanceGate()
    /// V2 开库进行中标记（bootstrap 异步化后的幂等守护）
    var isBootstrappingIntelligence = false
    /// 行情 Provider 健康监控（跨维护轮持久——quota 记账不随轮重置）
    let marketProviderHealthMonitor = ProviderHealthMonitor()
    /// 维护引擎降级链工厂的测试注入点（nil = 生产 Stooq/AV 工厂——
    /// 单测注入空候选链避免打真实网络）
    var marketDataChainFactoryOverride:
        (@Sendable (MarketUniverseEntry) -> ProviderFallbackChain)?
    var activeCommentsRequestKey = ""
    var isApplyingPersonalAssetAutomation = false
    var portfolioLookThroughLoadedRequestKey: String?
    var portfolioLookThroughLoadGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    // Lazy native client backing store
    var _nativeClient: QiemanNativeClient?
    var _nativeClientInitialized = false

    // MARK: Proxy computed properties (forwarding to sub-models)

    // PortfolioState proxies
    var userPortfolioHoldings: [UserPortfolioHolding] {
        get { portfolioState.userPortfolioHoldings }
        set { portfolioState.userPortfolioHoldings = newValue }
    }

    var userPortfolioSnapshot: UserPortfolioSnapshot? {
        get { portfolioState.userPortfolioSnapshot }
        set { portfolioState.userPortfolioSnapshot = newValue }
    }

    var isRefreshingPortfolio: Bool {
        get { portfolioState.isRefreshingPortfolio }
        set { portfolioState.isRefreshingPortfolio = newValue }
    }

    var personalWatchlistRecords: [PersonalWatchlistRecord] {
        get { portfolioState.personalWatchlistRecords }
        set { portfolioState.personalWatchlistRecords = newValue }
    }

    var personalWatchlistSnapshot: PersonalWatchlistSnapshot? {
        get { portfolioState.personalWatchlistSnapshot }
        set { portfolioState.personalWatchlistSnapshot = newValue }
    }

    var isRefreshingPersonalWatchlist: Bool {
        get { portfolioState.isRefreshingPersonalWatchlist }
        set { portfolioState.isRefreshingPersonalWatchlist = newValue }
    }

    var pendingTrades: [PersonalPendingTrade] {
        get { portfolioState.pendingTrades }
        set { portfolioState.pendingTrades = newValue }
    }

    var investmentPlans: [PersonalInvestmentPlan] {
        get { portfolioState.investmentPlans }
        set { portfolioState.investmentPlans = newValue }
    }

    var marketIndexQuotes: [MarketIndexKind: MarketIndexQuote] {
        get { portfolioState.marketIndexQuotes }
        set { portfolioState.marketIndexQuotes = newValue }
    }

    var isRefreshingMarketIndices: Bool {
        get { portfolioState.isRefreshingMarketIndices }
        set { portfolioState.isRefreshingMarketIndices = newValue }
    }

    // ForumState proxies
    var currentSnapshot: SnapshotPayload? {
        get { forumState.currentSnapshot }
        set { forumState.currentSnapshot = newValue }
    }

    var commentsPayload: CommentsPayload? {
        get { forumState.commentsPayload }
        set { forumState.commentsPayload = newValue }
    }

    var selectedPostID: String? {
        get { forumState.selectedPostID }
        set { forumState.selectedPostID = newValue }
    }

    var commentSortType: String {
        get { forumState.commentSortType }
        set { forumState.commentSortType = newValue }
    }

    var onlyManagerReplies: Bool {
        get { forumState.onlyManagerReplies }
        set { forumState.onlyManagerReplies = newValue }
    }

    var isLoadingComments: Bool {
        get { forumState.isLoadingComments }
        set { forumState.isLoadingComments = newValue }
    }

    // PlatformState proxies
    var platformPayload: PlatformPayload? {
        get { platformState.platformPayload }
        set { platformState.platformPayload = newValue }
    }

    var selectedPlatformActionID: String? {
        get { platformState.selectedPlatformActionID }
        set { platformState.selectedPlatformActionID = newValue }
    }

    var selectedAlfaActionID: String? {
        get { platformState.selectedAlfaActionID }
        set { platformState.selectedAlfaActionID = newValue }
    }

    // UIState proxies
    var selectedSection: AppSection {
        get { uiState.selectedSection }
        set { uiState.selectedSection = newValue }
    }

    var selectedPlatformActivityTab: PlatformActivityTab {
        get { uiState.selectedPlatformActivityTab }
        set { uiState.selectedPlatformActivityTab = newValue }
    }

    var selectedPlatformAdjustmentViewMode: PlatformAdjustmentViewMode {
        get { uiState.selectedPlatformAdjustmentViewMode }
        set { uiState.selectedPlatformAdjustmentViewMode = newValue }
    }

    var showsInDock: Bool {
        get { uiState.showsInDock }
        set { uiState.showsInDock = newValue }
    }

    var appearance: AppAppearance {
        get { uiState.appearance }
        set {
            guard uiState.appearance != newValue else { return }
            uiState.appearance = newValue
            #if os(macOS)
            appDelegate?.syncWindowAppearances()
            #endif
            NotificationCenter.default.post(name: .qiemanAppearanceDidChange, object: newValue)
        }
    }

    var launchAtLoginEnabled: Bool {
        get { uiState.launchAtLoginEnabled }
        set { uiState.launchAtLoginEnabled = newValue }
    }

    // UpdateState proxies
    var isCheckingForUpdates: Bool {
        get { updateState.isCheckingForUpdates }
        set { updateState.isCheckingForUpdates = newValue }
    }

    var availableUpdate: AppUpdateRelease? {
        get { updateState.availableUpdate }
        set { updateState.availableUpdate = newValue }
    }

    var isPresentingUpdateSheet: Bool {
        get { updateState.isPresentingUpdateSheet }
        set { updateState.isPresentingUpdateSheet = newValue }
    }

    var isInstallingUpdate: Bool {
        get { updateState.isInstallingUpdate }
        set { updateState.isInstallingUpdate = newValue }
    }

    var updateInstallProgress: String {
        get { updateState.updateInstallProgress }
        set { updateState.updateInstallProgress = newValue }
    }

    var updateDownloadFraction: Double {
        get { updateState.updateDownloadFraction }
        set { updateState.updateDownloadFraction = newValue }
    }

    var autoCheckForUpdatesOnLaunch: Bool {
        get { updateState.autoCheckForUpdatesOnLaunch }
        set { updateState.autoCheckForUpdatesOnLaunch = newValue }
    }

    // EnhancementState proxies
    var managerWatchTimelineEvents: [ManagerWatchTimelineEvent] {
        get { enhancementState.managerWatchTimelineEvents }
        set { enhancementState.managerWatchTimelineEvents = newValue }
    }

    var portfolioInsightSnapshots: [PortfolioInsightSnapshot] {
        get { enhancementState.portfolioInsightSnapshots }
        set { enhancementState.portfolioInsightSnapshots = newValue }
    }

    var isPresentingCommandPalette: Bool {
        get { enhancementState.isPresentingCommandPalette }
        set { enhancementState.isPresentingCommandPalette = newValue }
    }

    // MARK: Cache proxies (forwarding to portfolioState)

    var _cachedMonthlyPlatformSummary: [PlatformMonthSummary]? {
        get { portfolioState._cachedMonthlyPlatformSummary }
        set { portfolioState._cachedMonthlyPlatformSummary = newValue }
    }

    var _cachedActiveInvestmentPlans: [PersonalInvestmentPlan]? {
        get { portfolioState._cachedActiveInvestmentPlans }
        set { portfolioState._cachedActiveInvestmentPlans = newValue }
    }

    var _cachedPausedInvestmentPlans: [PersonalInvestmentPlan]? {
        get { portfolioState._cachedPausedInvestmentPlans }
        set { portfolioState._cachedPausedInvestmentPlans = newValue }
    }

    var _cachedEndedInvestmentPlans: [PersonalInvestmentPlan]? {
        get { portfolioState._cachedEndedInvestmentPlans }
        set { portfolioState._cachedEndedInvestmentPlans = newValue }
    }

    var _cachedInvestmentPlanSummary: PersonalInvestmentPlanSummary? {
        get { portfolioState._cachedInvestmentPlanSummary }
        set { portfolioState._cachedInvestmentPlanSummary = newValue }
    }

    var _cachedPendingTradeSummary: PersonalPendingTradeSummary? {
        get { portfolioState._cachedPendingTradeSummary }
        set { portfolioState._cachedPendingTradeSummary = newValue }
    }

    func clearInvestmentPlanCaches() {
        portfolioState.clearInvestmentPlanCaches()
    }

    func clearPendingTradeCaches() {
        portfolioState.clearPendingTradeCaches()
    }

    init() {
        // Forward sub-model changes so views observing AppModel via
        // @EnvironmentObject still re-render.
        portfolioState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        forumState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        platformState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        uiState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        enhancementState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward filterState changes so PlatformSectionView (which observes
        // AppModel via @EnvironmentObject) re-renders when filters change.
        filterState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .qiemanNotificationDeepLink)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let payload = note.object as? NotificationDeepLinkPayload else { return }
                self?.handleNotificationDeepLink(payload)
            }
            .store(in: &cancellables)
        refreshLaunchAtLoginStatus()
    }

    deinit {
        managerWatchTask?.cancel()
        personalAssetAutomationTask?.cancel()
        portfolioAutoRefreshTask?.cancel()
        remoteStagingSyncTask?.cancel()
        marketDataSyncTask?.cancel()
        intelligenceAutomationTask?.cancel()
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        let telemetryStart = PerformanceTelemetry.start()
        defer {
            PerformanceTelemetry.record(
                "app.start",
                startedAt: telemetryStart,
                metadata: [
                    "hasPortfolio": "\(hasPersonalPortfolio)",
                    "menuBarEnabled": "\(menuBarTickerSettings.isEnabled)"
                ]
            )
        }
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let supportDirectory = try dataController.prepareEnvironment()
            logFileURL = dataController.logFileURL
            dataDirectoryURL = supportDirectory
            // 投资智能 V2：composition root 引导 + 旧 AI 数据一次性迁移告知
            bootstrapIntelligenceV2()
            let migrationOutcome = LegacyAIDataMigration.migrateIfNeeded(
                in: supportDirectory
            )
            legacyAIMigrationNotice = migrationOutcome.notice
            // 基金穿透披露接入磁盘缓存：完整披露落盘，部分失败时用历史完整披露兜底，
            // 避免残缺数据冒充完整披露（如股票接口失败只剩债券时）。
            fundLookThroughClient = FundLookThroughClient(
                storageFileURL: fundLookThroughCacheFileURL
            )
            loadSavedPortfolio()
            loadSavedPersonalWatchlist()
            loadPendingTrades()
            loadInvestmentPlans()
            loadSavedPortfolioValuationAlerts()
            loadManagerWatchSettings()
            loadAlfaPortfolios()
            loadEnhancementState()
            refreshLaunchAtLoginStatus()
        } catch {
            errorMessage = error.localizedDescription
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                do {
                    try await self.refreshLatest(updateNotice: false)
                } catch {
                    if self.currentSnapshot == nil {
                        self.errorMessage = error.localizedDescription
                    } else {
                        self.noticeMessage = "原生直连暂时不可用，已保留当前界面数据。"
                    }
                }
            }
            group.addTask { @MainActor in
                if !self.activeUserPortfolioHoldings.isEmpty {
                    try? await self.refreshUserPortfolio(updateNotice: false)
                }
            }
            group.addTask { @MainActor in
                if self.hasPersonalWatchlist {
                    try? await self.refreshPersonalWatchlist(updateNotice: false)
                }
            }
            group.addTask { @MainActor in
                await self.refreshMarketIndicesIfNeeded()
            }
        }

        await applyPersonalAssetAutomation(updateNotice: false)
        restartManagerWatchLoop(immediate: managerWatchSettings.isEnabled)
        restartPersonalAssetAutomationLoop()
        restartPortfolioAutoRefreshLoop()
        startRemoteStagingSyncLoopIfNeeded()
        startMarketDataSyncLoopIfNeeded()
        // 投资智能自动调度（审计 B1/C5）：设置从数据目录加载后启动循环
        if let dataDirectory = dataDirectoryURL {
            intelligenceScheduleSettings = IntelligenceScheduleSettings.load(
                dataDirectory: dataDirectory)
        }
        restartIntelligenceAutomationLoop()
        scheduleAutomaticUpdateCheckIfNeeded()
    }

    func refreshLatest(updateNotice: Bool = true) async throws {
        let telemetryStart = PerformanceTelemetry.start()
        var telemetryResult = "completed"
        defer {
            PerformanceTelemetry.record(
                "refresh.latest",
                startedAt: telemetryStart,
                metadata: [
                    "result": telemetryResult,
                    "snapshotRecords": "\(currentSnapshot?.records.count ?? 0)",
                    "platformActions": "\(platformPayload?.actions?.count ?? 0)"
                ]
            )
        }
        isRefreshing = true
        errorMessage = ""
        defer { isRefreshing = false }

        async let snapshotTask = nativeClient.fetchSnapshot(form: form)
        async let platformTask = fetchPlatformIfPossible()

        var refreshedSnapshot: SnapshotPayload?
        var refreshedPlatform: PlatformPayload?
        var failures: [String] = []

        do {
            refreshedSnapshot = try await snapshotTask
        } catch {
            failures.append("论坛发言刷新失败：\(error.localizedDescription)")
        }

        do {
            refreshedPlatform = try await platformTask
        } catch {
            failures.append("平台调仓刷新失败：\(error.localizedDescription)")
        }

        if let snapshot = refreshedSnapshot {
            currentSnapshot = snapshot
            commentsPayload = nil
            ensureSelectedForumPost()
        }

        if let platform = refreshedPlatform {
            platformPayload = platform
            _cachedMonthlyPlatformSummary = nil
            ensureSelectedPlatformAction()
        }

        if refreshedSnapshot != nil || refreshedPlatform != nil {
            lastLatestRefreshAt = Date()
        }

        guard refreshedSnapshot != nil || refreshedPlatform != nil else {
            let message = failures.isEmpty ? "原生刷新失败，论坛和平台数据都没有拉到。" : failures.joined(separator: "；")
            telemetryResult = "failed"
            errorMessage = message
            throw LiveRefreshError(message: message)
        }

        if failures.isEmpty {
            if updateNotice {
                noticeMessage = "已通过原生抓取刷新到最新结果。"
            }
        } else {
            telemetryResult = "partial"
            errorMessage = failures.joined(separator: "；")
            if updateNotice {
                noticeMessage = "已刷新可用数据，但有部分内容拉取失败。"
            }
        }

        await refreshMarketIndicesIfNeeded()
    }
}
