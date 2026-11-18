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

    func testThreePlusOneAgentDecodesSubmittedGuidance() async throws {
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
          "risk_checks": ["确认行情时间没有滞后", "确认没有待处理的重复订单"],
          "followup_reviews": [{
            "item_index": 0,
            "status": "confirmed",
            "note": "今日行情已确认该关注事项",
            "evidence_ids": ["analysis:market:fund:510300"]
          }]
        }
        """
        let client = FakeNextHourAgentClient(arguments: arguments)
        let agent = NextHourGuidanceAgent(client: client)
        let context = try makeAgentContext(
            lastCloseReview: LastCloseReviewContext(
                generatedAt: "2026-07-26 21:00:00",
                tomorrowWatch: ["红利能否放量"]
            )
        )
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
        XCTAssertEqual(
            Set(report.actions.first?.evidenceIDs ?? []),
            Set([
                "analysis:market:fund:510300",
                "analysis:news:fund:510300",
                "analysis:portfolio:fund:510300",
            ])
        )
        XCTAssertEqual(client.callCount, 4, "行情、新闻、持仓三个分析调用加一次汇总决策")
        XCTAssertFalse(report.warnings.contains { $0.contains("禁止输出买入或卖出") })
        XCTAssertFalse(report.warnings.contains { $0.contains("只允许持有") })
        XCTAssertTrue(report.warnings.contains { $0.contains("NewsNow") })
        let followupReview = try XCTUnwrap(report.followupReviews.first)
        XCTAssertEqual(report.followupReviews.count, 1)
        XCTAssertEqual(followupReview.status, .confirmed)
        XCTAssertEqual(followupReview.evidenceIDs, ["analysis:market:fund:510300"])
    }

    private func makeAgentContext(
        lastCloseReview: LastCloseReviewContext? = nil
    ) throws -> NextHourGuidanceContext {
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
            dataRules: [],
            lastCloseReview: lastCloseReview
        )
    }

    func testBuyWithLiveMarketContextRemainsActionable() async throws {
        let (report, client) = try await runGuidance(
            action: "buy",
            evidenceIDs: [
                "local:next-hour:asset:fund:510300",
                "analysis:market:fund:510300",
                "analysis:news:fund:510300",
            ],
            includeMarketToolCall: true
        )

        XCTAssertEqual(report.actions.first?.action, .buy)
        XCTAssertEqual(report.disposition, .actionable)
        XCTAssertTrue(report.auditEvidence.contains { $0.id == "local:next-hour:asset:fund:510300" })
        XCTAssertEqual(client.callCount, 5, "一次真实行情工具、三次分析调用和一次汇总决策")
    }

    func testRepeatedSameEvidenceIDDoesNotSatisfyFloor() async throws {
        let (report, _) = try await runGuidance(
            action: "buy",
            evidenceIDs: [
                "local:next-hour:asset:fund:510300",
                "local:next-hour:asset:fund:510300",
                "local:next-hour:asset:fund:510300",
            ],
            includeMarketToolCall: true
        )

        XCTAssertEqual(report.actions.first?.action, .hold)
        XCTAssertEqual(report.disposition, .insufficientEvidence)
        XCTAssertEqual(report.actions.first?.evidenceIDs, ["local:next-hour:asset:fund:510300"])
        XCTAssertTrue(report.actions.first?.rationale.contains("真实证据不足 3 条") ?? false)
    }

    func testBuyWithoutRawQuoteEvidenceDowngradesToHold() async throws {
        let (report, _) = try await runGuidance(
            action: "buy",
            evidenceIDs: [
                "analysis:market:fund:510300",
                "analysis:news:fund:510300",
                "analysis:portfolio:fund:510300",
            ]
        )

        XCTAssertEqual(report.actions.first?.action, .hold)
        XCTAssertEqual(report.disposition, .insufficientEvidence)
        XCTAssertTrue(report.actions.first?.rationale.contains("原始行情证据") ?? false)
    }

    func testBuyAfterEvidenceRepairNeedsThreeRealIDs() async throws {
        let (report, _) = try await runGuidance(
            action: "buy",
            evidenceIDs: [
                "local:next-hour:asset:fund:510300",
                "fake:1",
                "fake:2",
            ],
            includeMarketToolCall: true
        )

        XCTAssertEqual(report.actions.first?.action, .hold)
        XCTAssertEqual(report.disposition, .insufficientEvidence)
        XCTAssertEqual(report.actions.first?.evidenceIDs, ["local:next-hour:asset:fund:510300"])
        XCTAssertTrue(report.actions.first?.rationale.contains("真实证据不足 3 条") ?? false)
    }

    private func runGuidance(
        action: String,
        evidenceIDs: [String],
        includeMarketToolCall: Bool = false
    ) async throws -> (NextHourGuidanceReport, FakeNextHourAgentClient) {
        let object: [String: Any] = [
            "headline": "盘中测试",
            "posture": "balanced",
            "summary": "验证最终证据门禁。",
            "actions": [[
                "target_id": "fund:510300",
                "target_name": "沪深300ETF",
                "action": action,
                "instruction": "小仓测试",
                "rationale": "测试动作",
                "trigger": "测试触发条件",
                "invalidation": "测试失效条件",
                "confidence": 90,
                "evidence_ids": evidenceIDs,
            ]],
            "risk_checks": ["确认行情", "确认持仓"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let arguments = String(data: data, encoding: .utf8) ?? "{}"
        let client = FakeNextHourAgentClient(
            arguments: arguments,
            includeMarketToolCall: includeMarketToolCall
        )
        let agent = NextHourGuidanceAgent(client: client)
        let settings = TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "test-model",
            apiKey: "sk-test",
            timeoutSeconds: 300
        )
        let report = try await agent.run(
            context: makeAgentContext(),
            researchSnapshot: makeResearchSnapshot(),
            settings: settings
        )
        return (report, client)
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
    private let guidanceArguments: String
    private let includeMarketToolCall: Bool
    private var didRequestMarketContext = false
    private(set) var callCount = 0

    init(arguments: String, includeMarketToolCall: Bool = false) {
        self.guidanceArguments = arguments
        self.includeMarketToolCall = includeMarketToolCall
    }

    func complete(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition],
        toolChoice: AgentToolChoice,
        temperature: Double,
        maxOutputTokens: Int?,
        settings: TrendAIProviderSettings,
        timeout: Double?,
        deadline: Date?,
        streamProgress: (@Sendable (AgentStreamProgress) async -> Void)?
    ) async throws -> AgentCompletionResult {
        let currentCallCount = lock.withLock {
            callCount += 1
            return callCount
        }

        if includeMarketToolCall,
           tools.contains(where: { $0.function.name == "get_live_market_context" }) {
            let shouldRequest = lock.withLock {
                if didRequestMarketContext { return false }
                didRequestMarketContext = true
                return true
            }
            if shouldRequest {
                let call = AgentToolCall(
                    id: "call-live-market-context",
                    function: AgentToolFunctionCall(name: "get_live_market_context", arguments: "{}")
                )
                let message = AgentChatMessage(role: .assistant, content: nil, toolCalls: [call])
                return AgentCompletionResult(
                    assistantMessage: message,
                    toolCalls: [call],
                    stopReason: .toolCalls,
                    finishReason: "tool_calls"
                )
            }
        }

        let submitNames = [
            "submit_market_signal",
            "submit_news_events",
            "submit_portfolio_context",
            "submit_next_hour_guidance",
        ]
        guard let submitName = submitNames.first(where: { name in
            tools.contains { $0.function.name == name }
        }) else {
            throw NextHourGuidanceAgentError.invalidSubmission(["测试未识别提交工具"])
        }

        let arguments: String
        switch submitName {
        case "submit_market_signal":
            arguments = #"{"overallTrend":"横盘震荡","perAssetSignals":[{"targetID":"fund:510300","targetName":"沪深300ETF","trend":"横盘震荡","confidence":68,"rationale":"价格维持区间震荡"}],"freshnessWarning":null}"#
        case "submit_news_events":
            arguments = #"{"macroSummary":null,"perAssetEvents":[{"targetID":"fund:510300","targetName":"沪深300ETF","sentiment":"中性","keyEvents":[],"sources":[],"confidence":50}]}"#
        case "submit_portfolio_context":
            arguments = #"{"perAssetContext":[{"targetID":"fund:510300","targetName":"沪深300ETF","position":"正常","riskExposure":"无特殊风险","overlapNote":null,"recommendation":"维持"}]}"#
        default:
            arguments = guidanceArguments
        }

        let call = AgentToolCall(
            id: "call-next-hour-\(currentCallCount)",
            function: AgentToolFunctionCall(name: submitName, arguments: arguments)
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
