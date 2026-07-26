import Foundation
import XCTest
@testable import QiemanDashboard

final class NextHourGuidanceTests: XCTestCase {
    func testScheduleStartsAt0915AndSkipsLunch() {
        let schedule = NextHourGuidanceSchedule.default

        XCTAssertNil(schedule.dueSlot(at: "2026-07-27 09:14:59", lastAttemptedSlotKey: nil))
        XCTAssertEqual(
            schedule.dueSlot(at: "2026-07-27 09:15:00", lastAttemptedSlotKey: nil)?.key,
            "2026-07-27 09:15"
        )
        XCTAssertEqual(
            schedule.dueSlot(at: "2026-07-27 10:48:00", lastAttemptedSlotKey: nil)?.key,
            "2026-07-27 10:15"
        )
        XCTAssertEqual(
            schedule.dueSlot(at: "2026-07-27 11:30:00", lastAttemptedSlotKey: nil)?.key,
            "2026-07-27 11:15"
        )
        XCTAssertNil(schedule.dueSlot(at: "2026-07-27 11:31:00", lastAttemptedSlotKey: nil))
        XCTAssertNil(schedule.dueSlot(at: "2026-07-27 13:14:59", lastAttemptedSlotKey: nil))
        XCTAssertEqual(
            schedule.dueSlot(at: "2026-07-27 13:15:00", lastAttemptedSlotKey: nil)?.key,
            "2026-07-27 13:15"
        )
    }

    func testClosingSlotIsOnlyScopeIncludingOffExchangeFunds() {
        let schedule = NextHourGuidanceSchedule.default
        let marketSlot = schedule.dueSlot(
            at: "2026-07-27 14:49:00",
            lastAttemptedSlotKey: nil
        )
        let closingSlot = schedule.dueSlot(
            at: "2026-07-27 14:50:00",
            lastAttemptedSlotKey: nil
        )

        XCTAssertEqual(marketSlot?.scope, .marketTrading)
        XCTAssertFalse(marketSlot?.scope.includesOffExchangeFunds ?? true)
        XCTAssertEqual(closingSlot?.key, "2026-07-27 14:50")
        XCTAssertEqual(closingSlot?.validUntil, "2026-07-27 15:00")
        XCTAssertEqual(closingSlot?.scope, .closingWindow)
        XCTAssertTrue(closingSlot?.scope.includesOffExchangeFunds ?? false)
    }

    func testScheduleSkipsAttemptedSlotAndWeekends() {
        let schedule = NextHourGuidanceSchedule.default

        XCTAssertNil(
            schedule.dueSlot(
                at: "2026-07-27 10:30:00",
                lastAttemptedSlotKey: "2026-07-27 10:15"
            )
        )
        XCTAssertNil(
            schedule.dueSlot(
                at: "2026-08-01 10:30:00",
                lastAttemptedSlotKey: nil
            )
        )
    }

    func testManualSlotWorksOutsideTradingHoursAndAcrossMidnight() throws {
        let schedule = NextHourGuidanceSchedule.default

        let weekendSlot = try XCTUnwrap(schedule.manualSlot(at: "2026-08-01 20:10:00"))
        XCTAssertEqual(weekendSlot.scope, .manual)
        XCTAssertEqual(weekendSlot.key, "2026-08-01 20:10")
        XCTAssertEqual(weekendSlot.validUntil, "2026-08-01 21:10")
        XCTAssertTrue(weekendSlot.scope.includesOffExchangeFunds)

        let lateSlot = try XCTUnwrap(schedule.manualSlot(at: "2026-08-01 23:30:00"))
        XCTAssertEqual(lateSlot.validUntil, "2026-08-02 00:30")
    }

    func testStoreRoundTripsReportAndSlotState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("next-hour-guidance-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("archive.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = makeReport()
        let archive = NextHourGuidanceArchive(
            report: report,
            lastAttemptedSlotKey: report.slotKey,
            lastCompletedSlotKey: report.slotKey
        )

        try NextHourGuidanceStore().save(archive, to: fileURL)
        let restored = try NextHourGuidanceStore().load(from: fileURL)

        XCTAssertEqual(restored, archive)
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMarketFreshnessRequiresTimestampWithinTwentyMinutes() {
        XCTAssertTrue(
            NextHourGuidanceFreshness.isFresh(
                quoteTime: "2026-07-27 10:02:00",
                generatedAt: "2026-07-27 10:15:00"
            )
        )
        XCTAssertFalse(
            NextHourGuidanceFreshness.isFresh(
                quoteTime: "2026-07-27 09:30:00",
                generatedAt: "2026-07-27 10:15:00"
            )
        )
        XCTAssertFalse(
            NextHourGuidanceFreshness.isFresh(
                quoteTime: "2026-07-26 15:00:00",
                generatedAt: "2026-07-27 09:15:00"
            )
        )
    }

    func testFocusedAgentDecodesSubmittedGuidance() async throws {
        let arguments = """
        {
          "headline": "缩量震荡，以持有为主",
          "posture": "balanced",
          "summary": "下一小时以持有为主，没有明确买入或卖出信号。",
          "actions": [{
            "target_id": "fund:510300",
            "target_name": "沪深300ETF",
            "action": "hold",
            "instruction": "持有现有仓位，暂不新增买卖。",
            "rationale": "当前快照只支持震荡判断。",
            "trigger": "指数回到日内关键位置且涨幅稳定",
            "invalidation": "指数跌破前低并持续走弱",
            "confidence": 68,
            "evidence_ids": ["local:next-hour:asset:fund:510300"]
          }],
          "risk_checks": ["确认行情时间没有滞后", "确认没有待处理的重复订单"]
        }
        """
        let client = FakeNextHourAgentClient(arguments: arguments)
        let agent = NextHourGuidanceAgent(client: client)
        let context = try makeAgentContext()
        let settings = TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "test-model",
            apiKey: "sk-test",
            timeoutSeconds: 300
        )
        let researchSnapshot = makeResearchSnapshot()

        let report = try await agent.run(
            context: context,
            researchSnapshot: researchSnapshot,
            settings: settings,
            webSearchSettings: .empty
        )

        XCTAssertEqual(report.slotKey, "2026-07-27 10:15")
        XCTAssertEqual(report.validUntil, "2026-07-27 11:15")
        XCTAssertEqual(report.posture, .balanced)
        XCTAssertEqual(report.actions.first?.action, .hold)
        XCTAssertEqual(report.actions.first?.confidence, 68)
        XCTAssertEqual(report.actions.first?.evidenceIDs, ["local:next-hour:asset:fund:510300"])
        XCTAssertEqual(client.callCount, 2)
    }

    func testAgentRejectsBuyWhenWebSearchIsNotConfigured() async throws {
        let arguments = """
        {
          "headline": "尝试买入",
          "posture": "opportunistic",
          "summary": "测试缺少联网搜索时的风控门槛。",
          "actions": [{
            "target_id": "fund:510300",
            "target_name": "沪深300ETF",
            "action": "buy",
            "instruction": "分批买入 5% 仓位。",
            "rationale": "测试理由。",
            "trigger": "价格保持强势",
            "invalidation": "价格转弱",
            "confidence": 70,
            "evidence_ids": ["local:next-hour:asset:fund:510300"]
          }],
          "risk_checks": ["确认行情时间", "确认没有重复订单"]
        }
        """
        let client = FakeNextHourAgentClient(arguments: arguments)
        let agent = NextHourGuidanceAgent(client: client)
        let settings = TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "test-model",
            apiKey: "sk-test",
            timeoutSeconds: 300
        )

        do {
            _ = try await agent.run(
                context: makeAgentContext(),
                researchSnapshot: makeResearchSnapshot(),
                settings: settings,
                webSearchSettings: .empty
            )
            XCTFail("未配置联网搜索时不应接受 buy")
        } catch let error as NextHourGuidanceAgentError {
            XCTAssertTrue(error.localizedDescription.contains("未配置联网搜索"))
        }
    }

    private func makeAgentContext() throws -> NextHourGuidanceContext {
        let slot = try XCTUnwrap(
            NextHourGuidanceSchedule.default.dueSlot(
                at: "2026-07-27 10:15:00",
                lastAttemptedSlotKey: nil
            )
        )
        return NextHourGuidanceContext(
            generatedAt: "2026-07-27 10:15:00",
            slot: slot,
            assets: [
                .init(
                    id: "fund:510300",
                    evidenceID: "local:next-hour:asset:fund:510300",
                    name: "沪深300ETF",
                    code: "510300",
                    assetType: "场内基金",
                    status: "已持有",
                    weightPct: 100,
                    currentPrice: 4.2,
                    quoteTime: "2026-07-27 10:14:00",
                    quoteSource: "测试行情",
                    quoteIsFresh: true,
                    profitPct: 3.1,
                    estimateChangePct: -0.4,
                    pendingTradeCount: 0,
                    activePlanCount: 0
                )
            ],
            market: [],
            marketDataIsFresh: true,
            marketDataWarnings: [],
            latestTrendGeneratedAt: "2026-07-27 09:30:00",
            latestTrendHeadline: "中性",
            latestTrendActions: [],
            latestAssetConclusions: [],
            dataRules: []
        )
    }

    private func makeResearchSnapshot() -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-07-27 10:15:00",
            dataAsOf: "2026-07-27 10:15:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 1,
                holdingCount: 1,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: [],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            lookThrough: nil,
            insightHeadline: "",
            sourceWarnings: []
        )
    }

    private func makeReport() -> NextHourGuidanceReport {
        NextHourGuidanceReport(
            generatedAt: "2026-07-27 14:50:00",
            validUntil: "2026-07-27 15:00",
            slotKey: "2026-07-27 14:50",
            scope: .closingWindow,
            headline: "收盘前以复核为主",
            posture: .balanced,
            summary: "场外基金只在此窗口参与。",
            actions: [
                .init(
                    targetName: "组合整体",
                    action: .hold,
                    instruction: "保持现有计划。",
                    rationale: "没有明确反向信号。",
                    trigger: "估值维持当前区间",
                    invalidation: "尾盘快速转弱",
                    confidence: 60
                )
            ],
            riskChecks: ["确认估值时间"],
            assetCount: 1
        )
    }
}

private final class FakeNextHourAgentClient: TrendResearchAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private let arguments: String
    private(set) var callCount = 0

    init(arguments: String) {
        self.arguments = arguments
    }

    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice,
        temperature: Double,
        settings: TrendAIProviderSettings,
        timeout: Double?,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult {
        lock.lock()
        callCount += 1
        let currentCallCount = callCount
        lock.unlock()
        let toolName = currentCallCount == 1
            ? "get_live_market_context"
            : "submit_next_hour_guidance"
        let call = AgentToolCall(
            id: "call-next-hour-\(currentCallCount)",
            function: AgentToolFunctionCall(
                name: toolName,
                arguments: currentCallCount == 1 ? "{}" : arguments
            )
        )
        let message = AgentChatMessage(
            role: .assistant,
            content: nil,
            toolCalls: [call]
        )
        return AgentCompletionResult(
            assistantMessage: message,
            toolCalls: [call],
            stopReason: .toolCalls,
            finishReason: "tool_calls"
        )
    }
}
