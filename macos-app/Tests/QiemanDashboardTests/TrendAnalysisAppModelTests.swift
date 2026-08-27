import XCTest
@testable import QiemanDashboard

// 阶段四：AppModel 趋势分析新流程（内嵌 Agent）的单元测试。
// 通过注入 FakeTrendResearchAgent 与假能力探测器驱动，不访问真实模型。
@MainActor
final class TrendAnalysisAppModelTests: XCTestCase {

    func testSuccessfulGenerationStoresReport() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        let report = TrendAnalysisReport.fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial)
        model.trendResearchAgent = FakeTrendResearchAgent(result: .success(report))

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        XCTAssertEqual(model.trendGenerationState, .succeeded)
        XCTAssertEqual(model.trendReport?.generatedAt, "2026-06-22 12:00:00")
        XCTAssertEqual(model.lastTrendGeneratedAt, "2026-06-22 12:00:00")
    }

    func testFailedGenerationKeepsLastReport() async {
        let model = AppModel()
        let previous = TrendAnalysisReport.fixture(generatedAt: "2026-06-21 12:00:00", externalSignalStatus: .partial)
        model.trendReport = previous
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        model.trendResearchAgent = FakeTrendResearchAgent(result: .failure(TrendResearchAgentError.turnLimitExceeded))

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        XCTAssertEqual(model.trendGenerationState, .failed)
        // 失败不覆盖旧报告。
        XCTAssertEqual(model.trendReport?.generatedAt, "2026-06-21 12:00:00")
        XCTAssertFalse(model.lastTrendError.isEmpty)
    }

    func testFailedGenerationPersistsAndRestoresDiagnosticLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trend-agent-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = AppModel()
        model.dataDirectoryURL = directory
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        model.trendResearchAgent = FakeTrendResearchAgent(
            result: .failure(TrendResearchAgentError.turnLimitExceeded)
        )

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        let logURL = try XCTUnwrap(model.trendAgentRunLogFileURL)
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[error] 趋势分析失败"))
        XCTAssertTrue(content.contains("最大轮次"))

        let restored = AppModel()
        restored.dataDirectoryURL = directory
        restored.loadTrendAnalysisState()
        XCTAssertEqual(restored.trendGenerationState, .failed)
        XCTAssertEqual(restored.trendProgressLogs.last?.level, .error)
        XCTAssertTrue(restored.lastTrendError.contains("最大轮次"))
    }

    func testAgentFailureEventAndThrownErrorAreLoggedOnlyOnce() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        model.trendResearchAgent = FakeTrendResearchAgent(
            result: .failure(TrendResearchAgentError.turnLimitExceeded),
            emitsFailureEvent: true
        )

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        let matchingFailures = model.trendProgressLogs.filter {
            $0.level == .error
                && $0.detail == TrendResearchAgentError.turnLimitExceeded.localizedDescription
        }
        XCTAssertEqual(matchingFailures.count, 1)
        XCTAssertEqual(matchingFailures.first?.message, "Agent 执行失败")
    }

    func testCancelledGenerationKeepsLastReport() async {
        let model = AppModel()
        let previous = TrendAnalysisReport.fixture(generatedAt: "2026-06-21 12:00:00", externalSignalStatus: .partial)
        model.trendReport = previous
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        model.trendResearchAgent = FakeTrendResearchAgent(result: .failure(CancellationError()))

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        XCTAssertEqual(model.trendGenerationState, .failed)
        XCTAssertEqual(model.trendReport?.generatedAt, "2026-06-21 12:00:00")
    }

    func testUnsupportedProviderIsGatedAndAgentNotRun() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        let agent = FakeTrendResearchAgent(result: .success(TrendAnalysisReport.fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial)))
        model.trendResearchAgent = agent
        // 注入返回"不支持工具调用"的假探测器；fail-closed 下 Agent 不得运行。
        let fingerprint = model.trendSettings.provider.fingerprint
        model.trendCapabilityProbe = { _ in
            TrendProviderCapabilities(
                supportsToolCalls: false,
                supportsForcedToolChoice: false,
                providerFingerprint: fingerprint,
                checkedAt: "2026-06-22 12:00:00",
                detail: "仅返回普通文本"
            )
        }

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        XCTAssertEqual(model.trendGenerationState, .failed)
        XCTAssertEqual(agent.runCount, 0)
        XCTAssertTrue(model.lastTrendError.contains("不支持工具调用"))
    }

    func testModuleAutoAnalysisRunsOncePerScheduledWindow() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings(dailyAutoAnalysisEnabled: true)
        installSupportingProbe(model)
        // W3.1:默认偏好下 closeReview 成功会发通知;注入 spy 避免触达系统通知中心。
        let notificationSpy = TrendCompletionNotificationSpy()
        notificationSpy.install(on: model)
        let agent = FakeTrendResearchAgent(result: .success(TrendAnalysisReport.fixture(generatedAt: "2026-06-22 09:30:00", externalSignalStatus: .partial)))
        model.trendResearchAgent = agent

        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 09:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 10:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 21:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 22:00:00")

        XCTAssertEqual(agent.runCount, 2)
        XCTAssertEqual(
            model.trendSettings.lastModuleAutoAnalysisKeys[TrendResearchRunScope.marketRadar.rawValue],
            "2026-06-22 09:00"
        )
        XCTAssertEqual(
            model.trendSettings.lastModuleAutoAnalysisKeys[TrendResearchRunScope.closeReview.rawValue],
            "2026-06-22 21:00"
        )
        XCTAssertEqual(model.trendProgressLogs.first?.message, "完整 AI 分析已启动")
        // 雷达通知默认关、复盘通知默认开:只应收到一条 closeReview 成功通知。
        XCTAssertEqual(notificationSpy.notices.count, 1)
        XCTAssertEqual(notificationSpy.notices.first?.scope, .closeReview)
        XCTAssertEqual(notificationSpy.notices.first?.outcome, .succeeded)
    }

    func testFailedAutomaticModuleIsNotRetriedByPollingOrNextLaunchCheck() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings(dailyAutoAnalysisEnabled: true)
        installSupportingProbe(model)
        let notificationSpy = TrendCompletionNotificationSpy()
        notificationSpy.install(on: model)
        let agent = FakeTrendResearchAgent(
            result: .failure(TrendResearchAgentError.turnLimitExceeded)
        )
        model.trendResearchAgent = agent

        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 09:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 10:00:00")

        XCTAssertEqual(agent.runCount, 1)
        XCTAssertEqual(
            model.trendSettings.lastModuleAutoAnalysisKeys[TrendResearchRunScope.marketRadar.rawValue],
            "2026-06-22 09:00"
        )
        // 自动失败默认通知(手动失败不打扰)。
        XCTAssertEqual(notificationSpy.notices.count, 1)
        XCTAssertEqual(notificationSpy.notices.first?.outcome, .failed)
    }

    // MARK: - W3.1 链路 A 完成通知

    func testManualFailureDoesNotNotify() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        let notificationSpy = TrendCompletionNotificationSpy()
        notificationSpy.install(on: model)
        model.trendResearchAgent = FakeTrendResearchAgent(
            result: .failure(TrendResearchAgentError.turnLimitExceeded)
        )

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        XCTAssertEqual(model.trendGenerationState, .failed)
        XCTAssertTrue(notificationSpy.notices.isEmpty, "手动失败用户在场,不发通知")
    }

    func testFirstReportNotificationOnlyWhenPreferenceEnabled() async {
        func makeModel() -> (AppModel, TrendCompletionNotificationSpy) {
            let model = AppModel()
            model.trendSettings = makeProviderSettings()
            installSupportingProbe(model)
            let spy = TrendCompletionNotificationSpy()
            spy.install(on: model)
            model.trendResearchAgent = FakeTrendResearchAgent(
                result: .success(TrendAnalysisReport.fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial))
            )
            return (model, spy)
        }

        // 默认偏好:首份研判通知关。
        let (offModel, offSpy) = makeModel()
        await offModel.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")
        XCTAssertTrue(offSpy.notices.isEmpty)

        // 打开偏好:手动首份成功收到「第一份研判」通知;第二次运行不再发。
        let (onModel, onSpy) = makeModel()
        onModel.trendSettings.notifications.firstReportEnabled = true
        await onModel.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")
        XCTAssertEqual(onSpy.notices.count, 1)
        XCTAssertTrue(onSpy.notices[0].isFirstReport)
        XCTAssertEqual(onSpy.notices[0].title, "你的第一份研判已生成")
        await onModel.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 13:00:00")
        XCTAssertEqual(onSpy.notices.count, 1, "非首份的手动成功不再通知")
    }

    func testProgressLogsReflectAgentEvents() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        let report = TrendAnalysisReport.fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial)
        model.trendResearchAgent = FakeTrendResearchAgent(result: .success(report))

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        let messages = model.trendProgressLogs.map(\.message)
        XCTAssertEqual(messages.first, "完整 AI 分析已启动")
        XCTAssertTrue(messages.contains { $0.contains("内嵌趋势 Agent") })
        XCTAssertTrue(messages.contains { $0.contains("完整 AI 分析完成") })
        let startedIndex = messages.firstIndex(of: "内嵌趋势 Agent 已启动")
        let turnIndex = messages.firstIndex(of: "进入第 1 轮")
        let completedIndex = messages.firstIndex(of: "Agent 已生成有效报告")
        XCTAssertNotNil(startedIndex)
        XCTAssertNotNil(turnIndex)
        XCTAssertNotNil(completedIndex)
        if let startedIndex, let turnIndex, let completedIndex {
            XCTAssertLessThan(startedIndex, turnIndex)
            XCTAssertLessThan(turnIndex, completedIndex)
        }
    }

    // MARK: - W3.5/W3.6 连击与未读角标

    func testAutoFailureStreakIncrementsAndClearsOnSuccess() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        let notificationSpy = TrendCompletionNotificationSpy()
        notificationSpy.install(on: model)
        model.trendResearchAgent = FakeTrendResearchAgent(
            result: .failure(TrendResearchAgentError.turnLimitExceeded)
        )

        await model.generateTrendAnalysis(userInitiated: false, createdAt: "2026-06-22 09:00:00", scope: .marketRadar)
        XCTAssertEqual(model.trendSettings.autoFailureStreaks[TrendResearchRunScope.marketRadar.rawValue], 1)
        await model.generateTrendAnalysis(userInitiated: false, createdAt: "2026-06-23 09:00:00", scope: .marketRadar)
        XCTAssertEqual(model.trendSettings.autoFailureStreaks[TrendResearchRunScope.marketRadar.rawValue], 2)
        XCTAssertNotNil(model.trendSettings.lastAutoFailureMessages[TrendResearchRunScope.marketRadar.rawValue])

        // 成功即清零(手动成功也算——证明了链路本身可用)。
        model.trendResearchAgent = FakeTrendResearchAgent(
            result: .success(TrendAnalysisReport.fixture(generatedAt: "2026-06-24 09:30:00", externalSignalStatus: .partial))
        )
        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-24 09:00:00", scope: .marketRadar)
        XCTAssertNil(model.trendSettings.autoFailureStreaks[TrendResearchRunScope.marketRadar.rawValue])
        XCTAssertNil(model.trendSettings.lastAutoFailureMessages[TrendResearchRunScope.marketRadar.rawValue])
    }

    func testUnreadAIResearchCountClearsAfterSeen() {
        let key = AppStorageKey.aiResearchLastSeen
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let model = AppModel()
        XCTAssertTrue(model.unreadAIResearchCount == 0, "无任何内容时不提示")

        // 从未访问过,但有内容 → 算 1 条未读,引导进去看一次。
        model.trendSettings.markModuleGenerated(scope: .marketRadar, generatedAt: "2026-06-22 09:30:00")
        XCTAssertEqual(model.unreadAIResearchCount, 1)

        // 访问后清零。
        AppModel.markAIResearchSeen()
        XCTAssertEqual(model.unreadAIResearchCount, 0)

        // 之后又有新链路生成 → 再次计数(用未来时间戳保证晚于 seen)。
        model.trendSettings.markModuleGenerated(scope: .closeReview, generatedAt: "2099-01-01 21:05:00")
        XCTAssertEqual(model.unreadAIResearchCount, 1)
    }

    // MARK: - 辅助

    private func makeProviderSettings(dailyAutoAnalysisEnabled: Bool = false) -> TrendAnalysisSettings {
        TrendAnalysisSettings(
            provider: TrendAIProviderSettings(
                providerName: "Test",
                baseURL: "https://api.example.com/v1",
                model: "glm-5.2",
                apiKey: "sk-test",
                timeoutSeconds: 300
            ),
            defaultPrivacyMode: .sanitized,
            dailyAutoAnalysisEnabled: dailyAutoAnalysisEnabled
        )
    }

    /// 注入返回"支持工具调用"的假探测器，避免测试联网；指纹与当前 Provider 一致以跳过重复探测。
    private func installSupportingProbe(_ model: AppModel) {
        let fingerprint = model.trendSettings.provider.fingerprint
        model.trendCapabilityProbe = { _ in
            TrendProviderCapabilities(
                supportsToolCalls: true,
                supportsForcedToolChoice: true,
                providerFingerprint: fingerprint,
                checkedAt: "2026-06-22 12:00:00",
                detail: "支持工具调用"
            )
        }
    }
}

/// 记录调用次数、按预设结果返回的假 Agent。
private final class FakeTrendResearchAgent: TrendResearchAgentProtocol, @unchecked Sendable {    private let lock = NSLock()
    private(set) var runCount = 0
    let result: Result<TrendAnalysisReport, Error>
    let emitsFailureEvent: Bool

    init(
        result: Result<TrendAnalysisReport, Error>,
        emitsFailureEvent: Bool = false
    ) {
        self.result = result
        self.emitsFailureEvent = emitsFailureEvent
    }

    func run(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings = .empty,
        officialSourceSettings: OfficialSourceSettings = .empty,
        alphaVantageSettings: AlphaVantageSettings = .empty,
        scope: TrendResearchRunScope = .full,
        baselineReport: TrendAnalysisReport? = nil,
        eventHandler: @escaping @MainActor @Sendable (TrendResearchAgentEvent) async -> Void
    ) async throws -> TrendAnalysisReport {
        lock.lock()
        runCount += 1
        lock.unlock()
        await eventHandler(.started(runID: snapshot.runID))
        await eventHandler(.turnStarted(1))
        await eventHandler(.completed(duration: 0.1))
        switch result {
        case .success(let report):
            return report
        case .failure(let error):
            if emitsFailureEvent {
                await eventHandler(.failed(message: error.localizedDescription))
            }
            throw error
        }
    }
}

/// W3.1:记录链路 A 完成通知的假 sender,避免测试触达系统通知中心。
private final class TrendCompletionNotificationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var notices: [TrendCompletionNotification] = []

    @MainActor
    func install(on model: AppModel) {
        model.trendAnalysisNotificationSender = { [self] notice in
            lock.lock()
            notices.append(notice)
            lock.unlock()
        }
    }
}
