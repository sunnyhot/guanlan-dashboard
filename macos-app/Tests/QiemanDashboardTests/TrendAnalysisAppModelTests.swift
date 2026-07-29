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

    func testDailyAutoAnalysisRunsOncePerScheduledSlot() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings(dailyAutoAnalysisEnabled: true)
        model.trendSettings.dailyAutoAnalysisTimes = ["09:30", "14:30"]
        installSupportingProbe(model)
        let agent = FakeTrendResearchAgent(result: .success(TrendAnalysisReport.fixture(generatedAt: "2026-06-22 09:30:00", externalSignalStatus: .partial)))
        model.trendResearchAgent = agent

        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 09:30:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 10:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 15:00:00")
        await model.runDailyTrendAnalysisIfNeeded(createdAt: "2026-06-22 16:00:00")

        XCTAssertEqual(agent.runCount, 2)
        XCTAssertEqual(model.trendSettings.lastAutoAnalysisDay, "2026-06-22")
        XCTAssertEqual(model.trendSettings.lastAutoAnalysisSlotKey, "2026-06-22 14:30")
        XCTAssertEqual(model.trendProgressLogs.first?.message, "定时自动分析已启动")
    }

    func testProgressLogsReflectAgentEvents() async {
        let model = AppModel()
        model.trendSettings = makeProviderSettings()
        installSupportingProbe(model)
        let report = TrendAnalysisReport.fixture(generatedAt: "2026-06-22 12:00:00", externalSignalStatus: .partial)
        model.trendResearchAgent = FakeTrendResearchAgent(result: .success(report))

        await model.generateTrendAnalysis(userInitiated: true, createdAt: "2026-06-22 12:00:00")

        let messages = model.trendProgressLogs.map(\.message)
        XCTAssertEqual(messages.first, "手动分析已启动")
        XCTAssertTrue(messages.contains { $0.contains("内嵌趋势 Agent") })
        XCTAssertTrue(messages.contains { $0.contains("趋势分析完成") })
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
private final class FakeTrendResearchAgent: TrendResearchAgentProtocol, @unchecked Sendable {
    private let lock = NSLock()
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
