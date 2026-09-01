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

    func testCompleteEvidenceLedgerKeepsUncitedTeamAssessmentsAndDeduplicates() {
        let cited = TrendEvidence(
            id: "analysis:news:fund:510300",
            sourceName: "新闻事件分析",
            title: "新闻结论",
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-07-27 10:15:00",
            summary: "新闻维度结论。"
        )
        let uncited = TrendEvidence(
            id: "analysis:market:fund:510300",
            sourceName: "行情信号分析",
            title: "行情结论",
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-07-27 10:15:00",
            summary: "行情维度结论。"
        )
        let report = NextHourGuidanceReport(
            generatedAt: "2026-07-27 10:15:00",
            validUntil: "2026-07-27 11:15",
            slotKey: "2026-07-27 10:15",
            scope: .marketTrading,
            headline: "测试",
            posture: .balanced,
            summary: "测试完整证据账本。",
            actions: [],
            riskChecks: [],
            assetCount: 1,
            evidence: [cited],
            auditEvidence: [cited, uncited]
        )

        XCTAssertEqual(report.completeEvidenceLedger.map(\.id), [cited.id, uncited.id])
    }

    func testActionDetailSeparatesRelatedTeamAssessmentsFromSupportingEvidence() {
        let targetID = "fund:510300"
        let targetName = "沪深300ETF"
        let metadata = TrendEvidenceMetadata(
            sourceKind: .portfolioSnapshot,
            sourceTier: .primary,
            entityNames: [targetName],
            metadataConfidence: .deterministic
        )
        let teamEvidence = [
            TrendEvidence(
                id: "analysis:market:\(targetID)",
                sourceName: "行情信号分析",
                title: "行情判断",
                url: nil,
                publishedAt: nil,
                retrievedAt: "2026-07-27 10:15:00",
                summary: "行情结论。",
                metadata: metadata
            ),
            TrendEvidence(
                id: "analysis:news:\(targetID)",
                sourceName: "新闻事件分析",
                title: "新闻判断",
                url: nil,
                publishedAt: nil,
                retrievedAt: "2026-07-27 10:15:00",
                summary: "新闻结论。",
                metadata: metadata
            ),
            TrendEvidence(
                id: "analysis:portfolio:\(targetID)",
                sourceName: "持仓结构分析",
                title: "持仓判断",
                url: nil,
                publishedAt: nil,
                retrievedAt: "2026-07-27 10:15:00",
                summary: "持仓结论。",
                metadata: metadata
            )
        ]
        let rawEvidence = TrendEvidence(
            id: "local:next-hour:asset:\(targetID)",
            sourceName: "本地行情快照",
            title: "行情快照",
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-07-27 10:15:00",
            summary: "原始支持证据。",
            metadata: metadata
        )
        let action = NextHourGuidanceAction(
            targetID: targetID,
            targetName: targetName,
            action: .hold,
            instruction: "继续持有",
            rationale: "等待确认",
            trigger: "放量突破",
            invalidation: "跌破支撑",
            confidence: 70,
            evidenceIDs: [teamEvidence[1].id, rawEvidence.id]
        )
        let report = NextHourGuidanceReport(
            generatedAt: "2026-07-27 10:15:00",
            validUntil: "2026-07-27 11:15",
            slotKey: "2026-07-27 10:15",
            scope: .marketTrading,
            headline: "测试",
            posture: .balanced,
            summary: "测试条目详情证据分组。",
            actions: [action],
            riskChecks: [],
            assetCount: 1,
            evidence: [teamEvidence[1], rawEvidence],
            auditEvidence: teamEvidence
        )

        XCTAssertEqual(report.teamEvidence(for: action).map(\.id), teamEvidence.map(\.id))
        XCTAssertEqual(report.supportingEvidence(for: action).map(\.id), [rawEvidence.id])
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
            settings: settings
        )

        XCTAssertEqual(report.slotKey, "2026-07-27 10:15")
        XCTAssertEqual(report.validUntil, "2026-07-27 11:15")
        XCTAssertEqual(report.posture, .balanced)
        XCTAssertEqual(report.actions.first?.action, .hold)
        XCTAssertEqual(report.actions.first?.confidence, 68)
        XCTAssertEqual(report.actions.first?.evidenceIDs, ["local:next-hour:asset:fund:510300"])
        XCTAssertEqual(client.callCount, 2)
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
                    quoteAssessment: TrendSourceFreshnessPolicy.assess(
                        quoteType: .lastTrade,
                        asOf: "2026-07-27 10:14:00",
                        receivedAt: "2026-07-27 10:15:00"
                    ),
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
        deadline: Date?,
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
