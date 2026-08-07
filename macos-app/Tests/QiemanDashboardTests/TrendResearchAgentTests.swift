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
        let invalidActions = try moduleCall(
            report: report,
            stage: .actions,
            id: "bad-actions",
            disclaimerOverride: "仅供参考。"
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

    func testWebSearchFailureTripsCircuitBreakerForRemainingRun() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let webClient = FailingCountingTavilyClient()

        var responses: [Result<AgentCompletionResult, Error>] = [
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "w1", function: AgentToolFunctionCall(name: "web_search", arguments: #"{"query":"最新产业政策","time_range":"day","research_target":{"kind":"macro","key":"产业政策"}}"#))
            ]))
        ]
        responses += try moduleSubmissionResponses(report: report, prefix: "web")
        let client = ScriptedTrendAgentClient(responses)
        let agent = TrendResearchAgent(client: client, webSearchClient: webClient)

        do {
            _ = try await agent.run(
                snapshot: snapshot,
                settings: testSettings(),
                webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
            ) { _ in }
            XCTFail("全市场扫描未完成时不应提交新的机会报告")
        } catch let error as TrendResearchAgentError {
            guard case .marketOpportunityScanIncomplete = error else {
                return XCTFail("预期市场扫描不完整错误，实际为 \(error)")
            }
        }

        let callCount = await webClient.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRunPolicyExpandsBudgetForPaginatedAssetsWithinHardCap() {
        let policy = TrendResearchRunPolicy()

        let small = policy.effectiveLimits(assetCount: 13)
        XCTAssertEqual(small.maxTurns, 18)
        XCTAssertEqual(small.maxToolCalls, 40)
        XCTAssertEqual(small.preferredWebSearches, 6)
        XCTAssertEqual(small.maxWebSearches, 10)

        let oneHundred = policy.effectiveLimits(assetCount: 100, sectorCount: 9)
        XCTAssertEqual(oneHundred.maxTurns, 39)
        XCTAssertEqual(oneHundred.maxToolCalls, 61)
        XCTAssertEqual(oneHundred.preferredWebSearches, 8)
        XCTAssertEqual(oneHundred.maxWebSearches, 12)

        let veryLarge = policy.effectiveLimits(assetCount: 2_000, sectorCount: 30)
        XCTAssertEqual(veryLarge.maxTurns, 48)
        XCTAssertEqual(veryLarge.maxToolCalls, 96)
        XCTAssertEqual(veryLarge.maxWebSearches, 12)
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
        policy.reservedSubmitTurns = 2
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

    func testHarnessRemovesRepeatedWebEvidenceFromLaterToolResult() throws {
        var harness = TrendResearchHarnessState(snapshot: makeEmptySnapshot())
        let content = TrendResearchToolEnvelope.success(
            [
                "query": "测试",
                "results": [[
                    "evidence_id": "web:tavily:same",
                    "title": "同一来源",
                    "url": "https://example.com/same"
                ]],
                "count": 1
            ],
            evidenceIDs: ["web:tavily:same"]
        )
        let result = TrendResearchToolResult.content(content)

        let first = harness.process(toolName: "web_search", result: result)
        let second = harness.process(toolName: "web_search", result: result)
        let firstObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.contentJSON.utf8)) as? [String: Any]
        )
        let secondObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(second.contentJSON.utf8)) as? [String: Any]
        )
        let firstData = try XCTUnwrap(firstObject["data"] as? [String: Any])
        let secondData = try XCTUnwrap(secondObject["data"] as? [String: Any])

        XCTAssertEqual(firstData["count"] as? Int, 1)
        XCTAssertEqual(secondData["count"] as? Int, 0)
        XCTAssertEqual(harness.duplicateWebEvidenceCount, 1)
    }

    func testHarnessRequiresOfficialSourceAttemptBeforeSubmission() {
        var harness = TrendResearchHarnessState(
            snapshot: makeEmptySnapshot(),
            officialSourceRequired: true
        )
        let overview = TrendResearchToolResult.content(
            TrendResearchToolEnvelope.success(["portfolio": [:]])
        )
        _ = harness.process(toolName: "get_portfolio_overview", result: overview)

        XCTAssertFalse(harness.readyForSubmission(webSearchConfigured: false))
        XCTAssertTrue(
            harness.nextStepHint(
                webSearchConfigured: false,
                remainingWebSearches: 0
            ).contains("official_sec_research")
        )

        let failedOfficialQuery = TrendResearchToolResult.content(
            TrendResearchToolEnvelope.error(
                code: "official_sec_failed",
                message: "测试失败"
            ),
            isError: true
        )
        _ = harness.process(
            toolName: "official_sec_research",
            result: failedOfficialQuery
        )

        XCTAssertTrue(harness.officialSourceAttempted)
        XCTAssertTrue(harness.readyForSubmission(webSearchConfigured: false))
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

        XCTAssertFalse(harness.readyForSubmission(webSearchConfigured: false))
        XCTAssertTrue(
            harness.nextStepHint(
                webSearchConfigured: false,
                remainingWebSearches: 0
            ).contains("alpha_vantage_research")
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
        XCTAssertTrue(harness.readyForSubmission(webSearchConfigured: false))
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

private actor FailingCountingTavilyClient: TavilySearchClientProtocol {
    private var count = 0

    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double
    ) async throws -> TavilySearchResponse {
        count += 1
        throw TavilySearchClientError.invalidResponse("测试响应格式错误")
    }

    func callCount() -> Int {
        count
    }
}

/// 按入队顺序逐条返回预设响应的假客户端，用于驱动 Agent 循环测试。
final class ScriptedTrendAgentClient: TrendResearchAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<AgentCompletionResult, Error>]
    private var requestToolNames: [[String]] = []
    private var recordedRequestTimeouts: [Double?] = []
    private(set) var responsesConsumed = 0

    init(_ responses: [Result<AgentCompletionResult, Error>]) {
        self.responses = responses
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
        responsesConsumed += 1
        requestToolNames.append(tools.map(\.function.name))
        recordedRequestTimeouts.append(timeout)
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
}

private actor TrendAgentEventRecorder {
    private(set) var timeoutEventCount = 0

    func record(_ event: TrendResearchAgentEvent) {
        if case .modelRequestTimedOut = event {
            timeoutEventCount += 1
        }
    }
}
