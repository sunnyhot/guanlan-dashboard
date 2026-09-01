import XCTest
@testable import QiemanDashboard

// 阶段三：TrendResearchAgent 运行循环单元测试（脚本化 Fake Client 驱动）。
final class TrendResearchAgentTests: XCTestCase {

    func testOverviewThenSubmitSucceeds() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)

        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "c1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "c")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
        XCTAssertEqual(result.privacyMode, .sanitized)
        XCTAssertNotEqual(result.generatedAt, "1999-01-01 00:00:00")
        XCTAssertEqual(result.dataAsOf, "2026-07-24 09:58:00")
    }

    func testRunDeadlineExceededDegradesWithStagedBatches() async throws {
        // W5 根治:预算终局时已暂存批次不白烧。closeReview 覆盖 1/2 只基金后
        // 流式中途撞运行截止时间,应降级生成报告(1 只真实 + 1 只保守占位),
        // 而不是抛 totalTimeoutExceeded 丢弃全部进度(2026-08-31 五连败场景)。
        let codes = ["000001", "000002"]
        let assets = codes.map {
            TrendContextAsset(
                id: $0,
                name: "基金\($0)",
                code: $0,
                assetType: PersonalAssetType.fund.displayName,
                sector: "A股",
                statusText: "已持有",
                weightText: nil,
                profitPct: nil,
                estimateChangePct: nil,
                pendingTradeCount: 0,
                activePlanCount: 0,
                pausedPlanCount: 0,
                endedPlanCount: 0,
                marketValue: nil,
                costValue: nil,
                profitAmount: nil,
                pendingCashAmount: nil,
                estimatedNextPlanAmount: nil,
                totalCumulativePlanAmount: nil
            )
        }
        let snapshot = TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-07-26 10:00:00",
            dataAsOf: "2026-07-26 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 2,
                holdingCount: 2,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: assets,
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            insightHeadline: "",
            sourceWarnings: []
        )
        let baseline = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-25 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)

        let stagedEntry = #"{"code":"000001","name":"基金一","sector":"A股","impactText":"原因待确认：测试快照没有底层证券当日行情。","rationale":"观察。","counterSignals":["若行情变化则重新评估。"]}"#
        let batchArguments = #"{"assetTrends":[@E@]}"#
            .replacingOccurrences(of: "@E@", with: stagedEntry)
        let responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "a1", function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: #"{"cursor":0,"limit":20}"#))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "b1", function: AgentToolFunctionCall(name: "submit_trend_asset_batch", arguments: batchArguments))
            ])),
            .failure(OpenAICompatibleAgentClientError.runDeadlineExceeded(Date())),
        ]
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(
            snapshot: snapshot,
            settings: testSettings(),
            scope: .closeReview,
            baselineReport: baseline
        ) { _ in }

        XCTAssertEqual(result.assetTrends.count, 2)
        let staged = result.assetTrends.first { $0.code == "000001" }
        XCTAssertEqual(staged?.impactText, "原因待确认：测试快照没有底层证券当日行情。")
        let filler = try XCTUnwrap(result.assetTrends.first { $0.code == "000002" })
        XCTAssertTrue(filler.impactText.contains("时间预算耗尽"), "实际：\(filler.impactText)")
        XCTAssertEqual(filler.horizons.count, 3)
    }

    func testRunDeadlineErrorRoundTripAndNonRetryable() {
        // W2:截止时间错误不可重试,且三层错误映射(client→provider→gateway)
        // 保持可识别,Agent 才能把它与可恢复的空闲超时区分开。
        let domain = ModelProviderError.runDeadlineExceeded(providerID: "p")
        XCTAssertFalse(domain.isRetryable, "截止时间重试只会再次超时")
        let transport = GatewayAgentClient.transportError(domain)
        guard case .runDeadlineExceeded = transport else {
            XCTFail("应映射回 runDeadlineExceeded，实际：\(transport)")
            return
        }
        XCTAssertEqual(
            OpenAICompatibleModelProvider.domainError(transport, providerID: "p"),
            domain,
            "三层映射应无损往返"
        )
    }

    func testPlainTextFirstThenRecoversToTools() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)

        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(plainTextResponse("我直接给你结论：市场平稳。")),
            .success(toolCallResponse([
                AgentToolCall(id: "c0", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "plain")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
        XCTAssertEqual(result.privacyMode, .sanitized)
    }

    func testConsecutivePlainTextFails() async throws {
        let snapshot = makeEmptySnapshot()
        let client = ScriptedTrendAgentClient([
            .success(plainTextResponse("一")),
            .success(plainTextResponse("二")),
            .success(plainTextResponse("三"))
        ])
        let agent = TrendResearchAgent(client: client)

        do {
            _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
            XCTFail("Expected missingToolCalls")
        } catch TrendResearchAgentError.missingToolCalls {
            // expected
        }
    }

    func testLengthTruncationDoesNotExecuteIncompleteTool() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)

        // 第一轮：finish_reason=length 且带一个参数残缺的工具调用，不得被执行。
        let truncated = AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: nil, toolCalls: [
                AgentToolCall(id: "bad", function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: "{broken"))
            ]),
            toolCalls: [],
            stopReason: .length,
            finishReason: "length"
        )
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(truncated),
            .success(toolCallResponse([
                AgentToolCall(id: "c0", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "length")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
        XCTAssertEqual(result.privacyMode, .sanitized)
    }

    func testThirdInvalidSubmissionTerminates() async throws {
        let snapshot = makeEmptySnapshot()
        // 缺少非投资建议声明，连续提交都会被 Validator 拒绝。
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .available)
            .groundedForSubmission(snapshot: snapshot)
        let overviewCall = AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([overviewCall])),
            try moduleSubmissionResponse(report: report, stage: .overview, id: "overview"),
            try moduleSubmissionResponse(report: report, stage: .market, id: "market")
        ]
        // 2026-08-31 起 disclaimer 缺失由 App 自动补写（终审爆量修复 2），
        // 改用不可兜底的硬规则触发同一终止路径：actions 超 5 条上限。
        let actionItem = #"{"id":"a","kind":"watch","title":"t","detail":"d","targetName":null,"confidence":{"score":50,"label":"中"},"whatWouldChange":"w","triggerConditions":["t"],"invalidatingConditions":["i"],"claimEvidence":{}}"#
        let oversizedActions = (0..<6).map { index in
            actionItem.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"a\(index)\"")
        }.joined(separator: ",")
        let oversizedArguments = #"{"keyAssets":[],"actions":["@ACTIONS@"],"warnings":[],"disclaimer":"含非投资建议"}"#
            .replacingOccurrences(of: "@ACTIONS@", with: oversizedActions)
        let invalidActions = AgentToolCall(
            id: "bad-actions",
            function: AgentToolFunctionCall(
                name: TrendReportModuleToolName.actions,
                arguments: oversizedArguments
            )
        )
        responses.append(.success(toolCallResponse([invalidActions])))
        responses.append(.success(toolCallResponse([invalidActions])))
        responses.append(.success(toolCallResponse([invalidActions])))
        let client = ScriptedTrendAgentClient(responses)
        var policy = TrendResearchRunPolicy()
        policy.maxInvalidSubmissions = 2
        let agent = TrendResearchAgent(client: client, policy: policy)

        do {
            _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
            XCTFail("Expected invalidSubmissionLimitExceeded")
        } catch TrendResearchAgentError.invalidSubmissionLimitExceeded {
            // expected
        }
    }

    func testSubmitBeforeOverviewIsRejected() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let submitCall = AgentToolCall(id: "s", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{}"))
        let overviewCall = AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))

        // 第 1 轮直接提交整份报告 → 运行时拒绝；第 2 轮 overview；随后按模块提交成功。
        // 若门控失效，首轮 submit 会直接成功，只消耗 1 条响应。
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([submitCall])),
            .success(toolCallResponse([overviewCall]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "after-gate")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
        XCTAssertEqual(result.privacyMode, .sanitized)
        XCTAssertEqual(client.responsesConsumed, 5)
    }

    func testRunPolicyExpandsBudgetForPaginatedAssetsWithinHardCap() {
        let policy = TrendResearchRunPolicy()

        let small = policy.effectiveLimits(assetCount: 13)
        XCTAssertEqual(small.maxTurns, 18)
        XCTAssertEqual(small.maxToolCalls, 40)

        let oneHundred = policy.effectiveLimits(assetCount: 100, sectorCount: 9)
        // 批量 5→8 后,100 基金的分批轮次预算相应下降(2026-08-19 耗时优化)。
        XCTAssertEqual(oneHundred.maxTurns, 32)
        XCTAssertEqual(oneHundred.maxToolCalls, 54)

        let veryLarge = policy.effectiveLimits(assetCount: 2_000, sectorCount: 30)
        XCTAssertEqual(veryLarge.maxTurns, 48)
        XCTAssertEqual(veryLarge.maxToolCalls, 96)
    }

    func testHarnessImmediatelySwitchesToOrderedModuleTools() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "ordered")
        let client = ScriptedTrendAgentClient(responses)
        var policy = TrendResearchRunPolicy()
        policy.maxTurns = 4
        policy.expandedMaxTurns = 4
        policy.maxToolCalls = 4
        policy.expandedMaxToolCalls = 4
        policy.reservedSubmitToolCalls = 2
        let agent = TrendResearchAgent(client: client, policy: policy)

        _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }

        XCTAssertEqual(client.requestedToolNames(at: 0).count, 4)
        XCTAssertEqual(client.requestedToolNames(at: 1), [TrendReportModuleToolName.overview])
        XCTAssertEqual(client.requestedToolNames(at: 2), [TrendReportModuleToolName.market])
        XCTAssertEqual(client.requestedToolNames(at: 3), [TrendReportModuleToolName.actions])
    }

    func testSingleRequestTimeoutIsCappedInsteadOfConsumingRemainingRunBudget() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "timeout-cap")
        let client = ScriptedTrendAgentClient(responses)
        let settings = TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "glm-5.2",
            apiKey: "sk-test",
            timeoutSeconds: 300
        )
        let agent = TrendResearchAgent(client: client)

        _ = try await agent.run(snapshot: snapshot, settings: settings) { _ in }

        XCTAssertEqual(client.requestedTimeouts.compactMap { $0 }, [180, 180, 180, 180])
    }

    /// 2026-09-01 根治(runID 0A55B952):每次模型请求都带输出 token 上限,
    /// 服务端截断退化生成(配合 .length 重发机制),不再发出无上限请求。
    func testEveryModelRequestCarriesMaxOutputTokensCap() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "cap")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client)

        _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }

        XCTAssertEqual(
            client.requestedMaxOutputTokens,
            Array(repeating: TrendResearchRunPolicy().maxOutputTokensPerRequest, count: client.responsesConsumed),
            "所有模型请求（研究轮与提交轮）都应携带 policy 的输出上限"
        )
    }

    func testTimedOutSubmissionAutomaticallyConvergesAndRetries() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .failure(OpenAICompatibleAgentClientError.timedOut(90))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "timeout-retry")
        let client = ScriptedTrendAgentClient(responses)
        let recorder = TrendAgentEventRecorder()
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { event in
            await recorder.record(event)
        }

        XCTAssertEqual(result.privacyMode, .sanitized)
        XCTAssertEqual(client.responsesConsumed, 5)
        XCTAssertEqual(client.requestedToolNames(at: 2), [TrendReportModuleToolName.overview])
        let timeoutEventCount = await recorder.timeoutEventCount
        XCTAssertEqual(timeoutEventCount, 1)
    }

    func testSecondConsecutiveRequestTimeoutFailsAfterRecoveryBudget() async throws {
        let snapshot = makeEmptySnapshot()
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .failure(OpenAICompatibleAgentClientError.timedOut(15)),
            .failure(OpenAICompatibleAgentClientError.timedOut(15))
        ])
        let agent = TrendResearchAgent(client: client)

        do {
            _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
            XCTFail("Expected modelRequestTimeoutRecoveryExceeded")
        } catch TrendResearchAgentError.modelRequestTimeoutRecoveryExceeded {
            // expected
        }
    }

    func testHarnessRequiresAlphaVantageAttemptBeforeSubmission() {
        var harness = TrendResearchHarnessState(
            snapshot: makeEmptySnapshot(),
            alphaVantageRequired: true
        )
        let overview = TrendResearchToolResult.content(
            TrendResearchToolEnvelope.success(["portfolio": [:]])
        )
        _ = harness.process(toolName: "get_portfolio_overview", result: overview)

        XCTAssertFalse(harness.readyForSubmission())
        XCTAssertTrue(
            harness.nextStepHint()
                .contains("alpha_vantage_research")
        )

        let failedVendorQuery = TrendResearchToolResult.content(
            TrendResearchToolEnvelope.error(
                code: "alpha_vantage_failed",
                message: "测试失败"
            ),
            isError: true
        )
        _ = harness.process(
            toolName: "alpha_vantage_research",
            result: failedVendorQuery
        )

        XCTAssertEqual(harness.alphaVantageAttempts, 1)
        XCTAssertTrue(harness.readyForSubmission())
    }

    func testTurnLimitExceeded() async throws {
        let snapshot = makeEmptySnapshot()
        // 每轮只调用只读工具、从不 submit，2 轮后触发 turnLimitExceeded。
        var policy = TrendResearchRunPolicy()
        policy.maxTurns = 2
        let overview = AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([overview])),
            .success(toolCallResponse([overview]))
        ])
        let agent = TrendResearchAgent(client: client, policy: policy)

        do {
            _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
            XCTFail("Expected turnLimitExceeded")
        } catch TrendResearchAgentError.turnLimitExceeded {
            // expected
        }
    }

    // MARK: - 辅助

    private enum ReportModuleStage {
        case overview
        case market
        case actions
    }

    private func moduleSubmissionResponses(
        report: TrendAnalysisReport,
        prefix: String
    ) throws -> [Result<AgentCompletionResult, Error>] {
        var responses: [Result<AgentCompletionResult, Error>] = [
            try moduleSubmissionResponse(
                report: report,
                stage: .overview,
                id: "\(prefix)-overview"
            ),
            try moduleSubmissionResponse(
                report: report,
                stage: .market,
                id: "\(prefix)-market"
            )
        ]
        if !report.assetTrends.isEmpty {
            for start in stride(
                from: 0,
                to: report.assetTrends.count,
                by: TrendReportDraftStore.assetBatchSize
            ) {
                let end = min(
                    start + TrendReportDraftStore.assetBatchSize,
                    report.assetTrends.count
                )
                let batch = Array(report.assetTrends[start..<end])
                let call = try encodedModuleCall(
                    name: TrendReportModuleToolName.assetBatch,
                    id: "\(prefix)-assets-\(start / TrendReportDraftStore.assetBatchSize)",
                    value: TrendReportAssetBatchModule(assetTrends: batch)
                )
                responses.append(.success(toolCallResponse([call])))
            }
        }
        responses.append(
            try moduleSubmissionResponse(
                report: report,
                stage: .actions,
                id: "\(prefix)-actions"
            )
        )
        return responses
    }

    private func moduleSubmissionResponse(
        report: TrendAnalysisReport,
        stage: ReportModuleStage,
        id: String
    ) throws -> Result<AgentCompletionResult, Error> {
        .success(
            toolCallResponse([
                try moduleCall(report: report, stage: stage, id: id)
            ])
        )
    }

    private func moduleCall(
        report: TrendAnalysisReport,
        stage: ReportModuleStage,
        id: String,
        disclaimerOverride: String? = nil
    ) throws -> AgentToolCall {
        switch stage {
        case .overview:
            return try encodedModuleCall(
                name: TrendReportModuleToolName.overview,
                id: id,
                value: TrendReportOverviewModule(
                    portfolio: report.portfolio,
                    horizons: report.horizons
                )
            )
        case .market:
            return try encodedModuleCall(
                name: TrendReportModuleToolName.market,
                id: id,
                value: TrendReportMarketModule(
                    marketOutlook: report.marketOutlook,
                    sectors: report.sectors,
                    opportunities: report.opportunities
                )
            )
        case .actions:
            return try encodedModuleCall(
                name: TrendReportModuleToolName.actions,
                id: id,
                value: TrendReportActionsModule(
                    keyAssets: report.keyAssets,
                    actions: report.actions,
                    warnings: report.warnings,
                    disclaimer: disclaimerOverride ?? report.disclaimer
                )
            )
        }
    }

    private func encodedModuleCall<T: Encodable>(
        name: String,
        id: String,
        value: T
    ) throws -> AgentToolCall {
        let data = try JSONEncoder().encode(value)
        let arguments = try XCTUnwrap(String(data: data, encoding: .utf8))
        return AgentToolCall(
            id: id,
            function: AgentToolFunctionCall(name: name, arguments: arguments)
        )
    }

    private func makeEmptySnapshot() -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: "2026-07-24 10:00:00",
            dataAsOf: "2026-07-24 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 0, holdingCount: 0, activePlanCount: 0, pendingAssetCount: 0,
                totalMarketValue: nil, totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil, totalEffectiveHoldingAmount: nil
            ),
            assets: [],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            insightHeadline: "",
            sourceWarnings: []
        )
    }

    private func testSettings() -> TrendAIProviderSettings {
        TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "glm-5.2",
            apiKey: "sk-test",
            timeoutSeconds: 15
        )
    }

    private func toolCallResponse(_ calls: [AgentToolCall], finishReason: String = "tool_calls") -> AgentCompletionResult {
        let message = AgentChatMessage(role: .assistant, content: nil, toolCalls: calls)
        return AgentCompletionResult(
            assistantMessage: message,
            toolCalls: calls,
            stopReason: AgentStopReason(finishReason: finishReason),
            finishReason: finishReason
        )
    }

    private func plainTextResponse(_ text: String) -> AgentCompletionResult {
        AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: text),
            toolCalls: [],
            stopReason: .stop,
            finishReason: "stop"
        )
    }
}

/// 按入队顺序逐条返回预设响应的假客户端，用于驱动 Agent 循环测试。
final class ScriptedTrendAgentClient: TrendResearchAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<AgentCompletionResult, Error>]
    private var requestToolNames: [[String]] = []
    private var recordedRequestTimeouts: [Double?] = []
    private var recordedMaxOutputTokens: [Int?] = []
    private(set) var responsesConsumed = 0

    init(_ responses: [Result<AgentCompletionResult, Error>]) {
        self.responses = responses
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
        lock.lock()
        responsesConsumed += 1
        requestToolNames.append(tools.map(\.function.name))
        recordedRequestTimeouts.append(timeout)
        recordedMaxOutputTokens.append(maxOutputTokens)
        let next = responses.isEmpty
            ? Result<AgentCompletionResult, Error>.failure(URLError(.badServerResponse))
            : responses.removeFirst()
        lock.unlock()
        switch next {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func requestedToolNames(at index: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard requestToolNames.indices.contains(index) else { return [] }
        return requestToolNames[index]
    }

    var requestedTimeouts: [Double?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequestTimeouts
    }

    var requestedMaxOutputTokens: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaxOutputTokens
    }
}

private actor TrendAgentEventRecorder {
    private(set) var timeoutEventCount = 0
    private(set) var validationErrors: [String] = []
    private var summaries: [String] = []

    func record(_ event: TrendResearchAgentEvent) {
        if case .modelRequestTimedOut = event {
            timeoutEventCount += 1
        }
        if case .reportValidationFailed(let errors, _) = event {
            validationErrors.append(contentsOf: errors)
        }
        switch event {
        case .started: summaries.append("started")
        case .harnessConfigured(let turns, let calls): summaries.append("configured(\(turns)/\(calls))")
        case .moduleProgress(let done, let total, let next): summaries.append("progress(\(done)/\(total),next=\(next ?? "-"))")
        case .harnessGuidance(let message): summaries.append("guidance:\(message.prefix(80))")
        case .turnStarted(let turn): summaries.append("turn\(turn)")
        case .modelRequestStarted(let turn): summaries.append("req\(turn)")
        case .modelRequestTimedOut: summaries.append("reqTimeout")
        case .modelStreamProgress: break
        case .modelResponseReceived: summaries.append("resp")
        case .modelCorrection(let message): summaries.append("correction:\(message.prefix(80))")
        case .toolStarted(let name): summaries.append("tool:\(name)")
        case .toolFinished(let name, let summary): summaries.append("toolDone:\(name)|\(summary.prefix(100))")
        case .reportValidationFailed: summaries.append("validationFailed")
        case .auditArtifactReady: summaries.append("artifact")
        case .completed(let duration): summaries.append("completed(\(Int(duration)))")
        case .failed(let message): summaries.append("FAILED:\(message.prefix(120))")
        case .cancelled: summaries.append("cancelled")
        }
    }

    func debugSummary() -> String {
        summaries.joined(separator: " | ")
    }
}
