import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Settings

extension Notification.Name {
    static let qiemanNotificationDeepLink = Notification.Name("qieman.notificationDeepLink")
    static let qiemanAppearanceDidChange = Notification.Name("qieman.appearanceDidChange")
    static let qiemanFocusSearch = Notification.Name("qieman.focusSearch")
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
    /// pick up the correct light/dark variant.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

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
    @Published var managerWatchSettings = ManagerWatchSettings.default
    @Published var menuBarTickerSettings = MenuBarTickerSettings.load()

    /// 调仓筛选状态
    let filterState = PlatformFilterState()

    weak var appDelegate: QiemanApplicationDelegate?

    // Services
    let dataController = ApplicationDataController()
    let platformClient = QiemanPlatformNativeClient()
    let alfaClient = QiemanAlfaClient()
    let alfaPortfolioStore = AlfaPortfolioStore()
    let portfolioStore = UserPortfolioStore()
    let personalWatchlistStore = PersonalWatchlistStore()
    let pendingTradesStore = PendingTradesStore()
    let investmentPlansStore = InvestmentPlansStore()
    let managerWatchStore = ManagerWatchStore()
    let notificationManager = LocalNotificationManager()
    let personalAssetAutomation = PersonalAssetAutomation()
    var fundLookThroughClient: any FundLookThroughClientProtocol = FundLookThroughClient()
    var trendResearchAgent: any TrendResearchAgentProtocol = TrendResearchAgent()
    var nextHourGuidanceAgent: any NextHourGuidanceAgentProtocol = NextHourGuidanceAgent()
    var nextHourGuidanceNotificationSender: @Sendable (NextHourGuidanceReport) async -> Void = { report in
        let manager = LocalNotificationManager()
        guard await manager.requestAuthorizationIfNeeded() else { return }
        await manager.send(
            title: "下一小时操作指引已生成",
            subtitle: report.scope.displayName,
            body: "\(report.headline) · 有效至 \(String(report.validUntil.suffix(5)))",
            deepLink: NotificationDeepLinkPayload(
                type: .workbenchTrend,
                targetID: "next-hour-guidance"
            )
        )
    }
    /// 工具调用能力探测器；默认走真实 client，测试可替换以避免联网。
    var trendCapabilityProbe: @Sendable (TrendAIProviderSettings) async throws -> TrendProviderCapabilities = { settings in
        try await OpenAICompatibleAgentClient().checkToolCallingCapability(settings: settings)
    }
    var trendProgressHeartbeatIntervalNanoseconds: UInt64 = 15_000_000_000
    let portfolioAutoRefreshIntervalSeconds: UInt64 = 60
    let refreshThrottle = RefreshThrottle()

    // Runtime state
    private var didStart = false
    var managerWatchTask: Task<Void, Never>?
    var personalAssetAutomationTask: Task<Void, Never>?
    var portfolioAutoRefreshTask: Task<Void, Never>?
    var trendGenerationTask: Task<Void, Never>?
    var nextHourGuidanceSchedulerTask: Task<Void, Never>?
    var nextHourGuidanceGenerationTask: Task<Void, Never>?
    var activeCommentsRequestKey = ""
    var isApplyingPersonalAssetAutomation = false
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

    var isResolvingPortfolioNames: Bool {
        get { portfolioState.isResolvingPortfolioNames }
        set { portfolioState.isResolvingPortfolioNames = newValue }
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

    var pendingTradesDraft: String {
        get { portfolioState.pendingTradesDraft }
        set { portfolioState.pendingTradesDraft = newValue }
    }

    var investmentPlans: [PersonalInvestmentPlan] {
        get { portfolioState.investmentPlans }
        set { portfolioState.investmentPlans = newValue }
    }

    var investmentPlansDraft: String {
        get { portfolioState.investmentPlansDraft }
        set { portfolioState.investmentPlansDraft = newValue }
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

    // UIState proxies
    var selectedSection: AppSection {
        get { uiState.selectedSection }
        set { uiState.selectedSection = newValue }
    }

    var selectedPlatformActivityTab: PlatformActivityTab {
        get { uiState.selectedPlatformActivityTab }
        set { uiState.selectedPlatformActivityTab = newValue }
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
            appDelegate?.syncWindowAppearances()
            NotificationCenter.default.post(name: .qiemanAppearanceDidChange, object: newValue)
        }
    }

    var showAdvancedParams: Bool {
        get { uiState.showAdvancedParams }
        set { uiState.showAdvancedParams = newValue }
    }

    var launchAtLoginEnabled: Bool {
        get { uiState.launchAtLoginEnabled }
        set { uiState.launchAtLoginEnabled = newValue }
    }

    var portfolioDraft: String {
        get { uiState.portfolioDraft }
        set { uiState.portfolioDraft = newValue }
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
    var selectedEnhancementTab: EnhancementCenterTab {
        get { enhancementState.selectedTab }
        set { enhancementState.selectedTab = newValue }
    }

    var lastMonthlyReportExport: MonthlyReportExportMetadata? {
        get { enhancementState.lastMonthlyReportExport }
        set { enhancementState.lastMonthlyReportExport = newValue }
    }

    var managerWatchTimelineEvents: [ManagerWatchTimelineEvent] {
        get { enhancementState.managerWatchTimelineEvents }
        set { enhancementState.managerWatchTimelineEvents = newValue }
    }

    var activeImportPreviewSession: ImportPreviewSession? {
        get { enhancementState.activeImportPreviewSession }
        set { enhancementState.activeImportPreviewSession = newValue }
    }

    var importUndoSnapshot: ImportUndoSnapshot? {
        get { enhancementState.importUndoSnapshot }
        set { enhancementState.importUndoSnapshot = newValue }
    }

    var portfolioInsightSnapshots: [PortfolioInsightSnapshot] {
        get { enhancementState.portfolioInsightSnapshots }
        set { enhancementState.portfolioInsightSnapshots = newValue }
    }

    var pendingOverwriteReportURL: URL? {
        get { enhancementState.pendingOverwriteReportURL }
        set { enhancementState.pendingOverwriteReportURL = newValue }
    }

    var trendReport: TrendAnalysisReport? {
        get { enhancementState.trendReport }
        set { enhancementState.trendReport = newValue }
    }

    var trendSettings: TrendAnalysisSettings {
        get { enhancementState.trendSettings }
        set { enhancementState.trendSettings = newValue }
    }

    var trendGenerationState: TrendGenerationState {
        get { enhancementState.trendGenerationState }
        set { enhancementState.trendGenerationState = newValue }
    }

    var trendConnectionState: TrendConnectionState {
        get { enhancementState.trendConnectionState }
        set { enhancementState.trendConnectionState = newValue }
    }

    var trendProviderCapabilities: TrendProviderCapabilities? {
        get { enhancementState.trendProviderCapabilities }
        set { enhancementState.trendProviderCapabilities = newValue }
    }

    var trendPrivacyMode: TrendPrivacyMode {
        get { enhancementState.trendPrivacyMode }
        set { enhancementState.trendPrivacyMode = newValue }
    }

    var lastTrendGeneratedAt: String? {
        get { enhancementState.lastTrendGeneratedAt }
        set { enhancementState.lastTrendGeneratedAt = newValue }
    }

    var lastTrendError: String {
        get { enhancementState.lastTrendError }
        set { enhancementState.lastTrendError = newValue }
    }

    var lastTrendConnectionMessage: String {
        get { enhancementState.lastTrendConnectionMessage }
        set { enhancementState.lastTrendConnectionMessage = newValue }
    }

    var trendProgressLogs: [TrendProgressLog] {
        get { enhancementState.trendProgressLogs }
        set { enhancementState.trendProgressLogs = newValue }
    }

    var nextHourGuidanceArchive: NextHourGuidanceArchive {
        get { enhancementState.nextHourGuidanceArchive }
        set { enhancementState.nextHourGuidanceArchive = newValue }
    }

    var nextHourGuidanceReport: NextHourGuidanceReport? {
        nextHourGuidanceArchive.report
    }

    var nextHourGuidanceGenerationState: TrendGenerationState {
        get { enhancementState.nextHourGuidanceGenerationState }
        set { enhancementState.nextHourGuidanceGenerationState = newValue }
    }

    var nextHourGuidanceError: String {
        get { enhancementState.nextHourGuidanceError }
        set { enhancementState.nextHourGuidanceError = newValue }
    }

    var tradeSignalSettings: TradeSignalSettings {
        get { enhancementState.tradeSignalSettings }
        set { enhancementState.tradeSignalSettings = newValue }
    }

    var tradeSignalNotificationState: TradeSignalNotificationState {
        get { enhancementState.tradeSignalNotificationState }
        set { enhancementState.tradeSignalNotificationState = newValue }
    }

    var selectedWorkbenchSegment: WorkbenchSegment {
        get { enhancementState.selectedWorkbenchSegment }
        set { enhancementState.selectedWorkbenchSegment = newValue }
    }

    var trendTrackingItems: [TrendTrackingItem] {
        get { enhancementState.trendTrackingItems }
        set { enhancementState.trendTrackingItems = newValue }
    }

    var selectedTrendTrackingItemID: UUID? {
        get { enhancementState.selectedTrendTrackingItemID }
        set { enhancementState.selectedTrendTrackingItemID = newValue }
    }

    // MARK: Cache proxies (forwarding to portfolioState)

    var _cachedAssetRows: [PersonalAssetAggregateRow]? {
        get { portfolioState._cachedAssetRows }
        set { portfolioState._cachedAssetRows = newValue }
    }

    var _cachedAssetSummary: PersonalAssetAggregateSummary? {
        get { portfolioState._cachedAssetSummary }
        set { portfolioState._cachedAssetSummary = newValue }
    }

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

    func clearCachedComputedProperties() {
        portfolioState.clearAllCaches()
    }

    func clearPortfolioCaches() {
        portfolioState.clearPortfolioCaches()
    }

    func clearPlatformCaches() {
        portfolioState.clearPlatformCaches()
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
        nextHourGuidanceSchedulerTask?.cancel()
        nextHourGuidanceGenerationTask?.cancel()
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
            loadSavedPortfolio()
            loadSavedPersonalWatchlist()
            loadPendingTrades()
            loadInvestmentPlans()
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
                    try await self.refreshLatest(persist: false, updateNotice: false)
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
        // 每日自动分析由 ContentView.task 在 start() 之后统一触发，避免双重入口。
        restartManagerWatchLoop(immediate: false)
        restartPersonalAssetAutomationLoop()
        restartPortfolioAutoRefreshLoop()
        restartNextHourGuidanceSchedulerLoop(immediate: true)
        scheduleAutomaticUpdateCheckIfNeeded()
    }

    func refreshLatest(persist: Bool, updateNotice: Bool = true) async throws {
        let telemetryStart = PerformanceTelemetry.start()
        var telemetryResult = "completed"
        defer {
            PerformanceTelemetry.record(
                "refresh.latest",
                startedAt: telemetryStart,
                metadata: [
                    "persist": "\(persist)",
                    "result": telemetryResult,
                    "snapshotRecords": "\(currentSnapshot?.records.count ?? 0)",
                    "platformActions": "\(platformPayload?.actions?.count ?? 0)"
                ]
            )
        }
        isRefreshing = true
        errorMessage = ""
        defer { isRefreshing = false }

        async let snapshotTask = nativeClient.fetchSnapshot(form: form, persist: false, outputDirectory: nil)
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

    /// 按 filterMode 决定如何拉取论坛快照：
    /// - `.managerSubscription`：根据选中的主理人聚合多小组。
    /// - `.preciseParams`：沿用既有 fetchSnapshot 的精确参数模式。
}
