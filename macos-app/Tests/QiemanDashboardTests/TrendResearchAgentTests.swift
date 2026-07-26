import XCTest
@testable import QiemanDashboard

// 阶段三：TrendResearchAgent 运行循环单元测试（脚本化 Fake Client 驱动）。
final class TrendResearchAgentTests: XCTestCase {

    func testOverviewThenSubmitSucceeds() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))

        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "c1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "c2", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
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
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))

        let client = ScriptedTrendAgentClient([
            .success(plainTextResponse("我直接给你结论：市场平稳。")),
            .success(toolCallResponse([
                AgentToolCall(id: "c0", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "c1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
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
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))

        // 第一轮：finish_reason=length 且带一个参数残缺的工具调用，不得被执行。
        let truncated = AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: nil, toolCalls: [
                AgentToolCall(id: "bad", function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: "{broken"))
            ]),
            toolCalls: [],
            stopReason: .length,
            finishReason: "length"
        )
        let client = ScriptedTrendAgentClient([
            .success(truncated),
            .success(toolCallResponse([
                AgentToolCall(id: "c0", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "c1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
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
        var reportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        reportObject["disclaimer"] = "仅供参考。"
        let reportData = try JSONSerialization.data(withJSONObject: reportObject)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        let submitCall = AgentToolCall(id: "s", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))

        let overviewCall = AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([overviewCall])),
            .success(toolCallResponse([submitCall])),
            .success(toolCallResponse([submitCall])),
            .success(toolCallResponse([submitCall]))
        ])
        let agent = TrendResearchAgent(client: client)

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
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        let submitCall = AgentToolCall(id: "s", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
        let overviewCall = AgentToolCall(id: "o", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))

        // 第 1 轮直接 submit（未先 overview）→ 运行时拒绝；第 2 轮 overview；第 3 轮 submit 成功。
        // 若门控失效，首轮 submit 会直接成功，只消耗 1 条响应。
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([submitCall])),
            .success(toolCallResponse([overviewCall])),
            .success(toolCallResponse([submitCall]))
        ])
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }
        XCTAssertEqual(result.privacyMode, .sanitized)
        XCTAssertEqual(client.responsesConsumed, 3)
    }

    func testWebSearchFailureTripsCircuitBreakerForRemainingRun() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        let webClient = FailingCountingTavilyClient()

        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "w1", function: AgentToolFunctionCall(name: "web_search", arguments: #"{"query":"最新产业政策","time_range":"day","research_target":{"kind":"macro","key":"产业政策"}}"#))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "w2", function: AgentToolFunctionCall(name: "web_search", arguments: #"{"query":"最新行业动态","time_range":"day","research_target":{"kind":"macro","key":"行业动态"}}"#))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "s1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
        let agent = TrendResearchAgent(client: client, webSearchClient: webClient)

        _ = try await agent.run(
            snapshot: snapshot,
            settings: testSettings(),
            webSearchSettings: TavilySearchSettings(apiKey: "tvly-test")
        ) { _ in }

        let callCount = await webClient.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRunPolicyExpandsBudgetForPaginatedAssetsWithinHardCap() {
        let policy = TrendResearchRunPolicy()

        let small = policy.effectiveLimits(assetCount: 13)
        XCTAssertEqual(small.maxTurns, 12)
        XCTAssertEqual(small.maxToolCalls, 32)
        XCTAssertEqual(small.preferredWebSearches, 6)
        XCTAssertEqual(small.maxWebSearches, 10)

        let oneHundred = policy.effectiveLimits(assetCount: 100, sectorCount: 9)
        XCTAssertEqual(oneHundred.maxTurns, 16)
        XCTAssertEqual(oneHundred.maxToolCalls, 36)
        XCTAssertEqual(oneHundred.preferredWebSearches, 8)
        XCTAssertEqual(oneHundred.maxWebSearches, 12)

        let veryLarge = policy.effectiveLimits(assetCount: 2_000, sectorCount: 30)
        XCTAssertEqual(veryLarge.maxTurns, 24)
        XCTAssertEqual(veryLarge.maxToolCalls, 64)
        XCTAssertEqual(veryLarge.maxWebSearches, 12)
    }

    func testHarnessReservesFinalBudgetAndOnlyExposesSubmitTool() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "s1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
        var policy = TrendResearchRunPolicy()
        policy.maxTurns = 4
        policy.expandedMaxTurns = 4
        policy.maxToolCalls = 3
        policy.expandedMaxToolCalls = 3
        policy.reservedSubmitTurns = 2
        policy.reservedSubmitToolCalls = 2
        let agent = TrendResearchAgent(client: client, policy: policy)

        _ = try await agent.run(snapshot: snapshot, settings: testSettings()) { _ in }

        XCTAssertEqual(client.requestedToolNames(at: 0).count, 4)
        XCTAssertEqual(client.requestedToolNames(at: 1), ["submit_trend_report"])
    }

    func testSingleRequestTimeoutIsCappedInsteadOfConsumingRemainingRunBudget() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .success(toolCallResponse([
                AgentToolCall(id: "s1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
        let settings = TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "glm-5.2",
            apiKey: "sk-test",
            timeoutSeconds: 300
        )
        let agent = TrendResearchAgent(client: client)

        _ = try await agent.run(snapshot: snapshot, settings: settings) { _ in }

        XCTAssertEqual(client.requestedTimeouts.compactMap { $0 }, [90, 90])
    }

    func testTimedOutSubmissionAutomaticallyConvergesAndRetries() async throws {
        let snapshot = makeEmptySnapshot()
        let report = TrendAnalysisReport
            .fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportJSON = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        let client = ScriptedTrendAgentClient([
            .success(toolCallResponse([
                AgentToolCall(id: "o1", function: AgentToolFunctionCall(name: "get_portfolio_overview", arguments: "{}"))
            ])),
            .failure(OpenAICompatibleAgentClientError.timedOut(90)),
            .success(toolCallResponse([
                AgentToolCall(id: "s1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: "{\"report\":\(reportJSON)}"))
            ]))
        ])
        let recorder = TrendAgentEventRecorder()
        let agent = TrendResearchAgent(client: client)

        let result = try await agent.run(snapshot: snapshot, settings: testSettings()) { event in
            await recorder.record(event)
        }

        XCTAssertEqual(result.privacyMode, .sanitized)
        XCTAssertEqual(client.responsesConsumed, 3)
        XCTAssertEqual(client.requestedToolNames(at: 2), ["submit_trend_report"])
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
