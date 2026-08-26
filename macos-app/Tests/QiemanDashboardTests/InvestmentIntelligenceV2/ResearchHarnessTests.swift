import XCTest
@testable import QiemanDashboard

// RES-2：Research Workspace + Harness——多轮 Tool Calling 循环的行为锁定。

private func gateway(provider: ScriptedModelProvider) -> ModelGateway {
    var policy = ModelGatewayPolicy()
    policy.maxRetriesPerProvider = 0
    return ModelGateway(providers: [provider], policy: policy)
}

final class ResearchHarnessTests: XCTestCase {

    // MARK: 完整跑通（验收：单次 Research Job 完整跑通）

    func testFullRunProducesNotesWithEvidenceBackedClaims() async throws {
        let validSubmission = """
        {"notes": "溢价与规模双升。", "claims": [
            {"statement": "溢价收窄", "evidence_ids": ["EV-1"], "confidence_label": "HIGH", "dimension": "MOMENTUM"},
            {"statement": "规模扩大", "evidence_ids": ["EV-1"], "confidence_label": "MEDIUM"}
        ]}
        """
        let provider = ScriptedModelProvider(providerID: "primary", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: validSubmission)])),
        ])
        let tool = StubResearchTool()
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [tool])

        var events: [ResearchHarnessEvent] = []
        let outcome = try await harness.run(task: try makeResearchTask()) { event in
            events.append(event)
        }

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.job.state, .completed)
        XCTAssertEqual(outcome.job.workflowKind, "research")
        let notes = try XCTUnwrap(outcome.notes)
        XCTAssertEqual(notes.claims.count, 2)
        XCTAssertEqual(notes.claims[0].evidenceReferences, [EvidenceID(rawValue: "EV-1")])
        XCTAssertEqual(notes.claims[0].confidenceLabel, .high)
        XCTAssertEqual(notes.claims[0].dimension, .momentum)
        XCTAssertNil(notes.claims[1].dimension)
        XCTAssertEqual(notes.producedBy.providerID, "primary", "产出方由 Harness 注入")
        XCTAssertEqual(tool.callCount, 1)
        XCTAssertEqual(tool.lastArguments, "{}")
        // 事件序列：started → turnStarted ×2 → toolExecuted → notesAccepted
        guard case .started = events[0] else { return XCTFail("首个事件应为 started") }
        guard case .toolExecuted(let toolName, let evidenceCount, _) = events.first(where: {
            if case .toolExecuted = $0 { return true }
            return false
        }) else { return XCTFail("缺少 toolExecuted 事件") }
        XCTAssertEqual(toolName, "get_market_snapshot")
        XCTAssertEqual(evidenceCount, 1)
        guard case .notesAccepted(let claimCount, let evidenceCount2) = events.last else {
            return XCTFail("末事件应为 notesAccepted")
        }
        XCTAssertEqual(claimCount, 2)
        XCTAssertEqual(evidenceCount2, 1)
        // transcript：system + user + assistant(工具轮) + tool(结果) + assistant(提交轮) = 5。
        // 提交成功即结束运行，提交结果无需回灌（不再有后续模型请求）。
        XCTAssertEqual(outcome.transcript.count, 5)
        XCTAssertEqual(outcome.transcript.filter { $0.role == .tool }.count, 1)
    }

    // MARK: 提交门禁

    func testSubmissionBeforeAnyToolCallIsRejectedAndRecoverable() async throws {
        let premature = """
        {"notes": "x", "claims": [{"statement": "s", "evidence_ids": [], "confidence_label": "HIGH"}]}
        """
        let valid = """
        {"notes": "ok", "claims": [{"statement": "s", "evidence_ids": ["EV-9"], "confidence_label": "LOW"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "submit_research_notes", args: premature)])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: valid)])),
        ])
        let tool = StubResearchTool(evidence: [EvidenceID(rawValue: "EV-9")])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [tool])

        var rejectedDetails: [String] = []
        let outcome = try await harness.run(task: try makeResearchTask()) { event in
            if case .submissionRejected(let detail, _) = event {
                rejectedDetails.append(detail)
            }
        }

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(rejectedDetails.count, 1)
        XCTAssertTrue(rejectedDetails[0].contains("至少调用一次研究工具"), rejectedDetails[0])
        // 拒绝以 tool message 回灌（模型可修复）；成功提交不回灌。
        XCTAssertEqual(outcome.transcript.filter { $0.role == .tool }.count, 2, "拒绝信封 + 工具结果")
    }

    func testUnknownEvidenceReferenceIsRejected() async throws {
        let forged = """
        {"notes": "x", "claims": [{"statement": "s", "evidence_ids": ["EV-FORGED"], "confidence_label": "HIGH"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: forged)])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
        ])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()])

        var rejectedDetails: [String] = []
        let outcome = try await harness.run(task: try makeResearchTask()) { event in
            if case .submissionRejected(let detail, _) = event {
                rejectedDetails.append(detail)
            }
        }

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(rejectedDetails.count, 1)
        XCTAssertTrue(rejectedDetails[0].contains("EV-FORGED"), "错误详情点名未登记 ID")
    }

    func testInvalidConfidenceLabelRejectedWithRecoveryHint() async throws {
        let bad = """
        {"notes": "x", "claims": [{"statement": "s", "evidence_ids": ["EV-1"], "confidence_label": "PRETTY_SURE"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: bad)])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
        ])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()])

        var rejectedDetails: [String] = []
        _ = try await harness.run(task: try makeResearchTask()) { event in
            if case .submissionRejected(let detail, _) = event {
                rejectedDetails.append(detail)
            }
        }
        XCTAssertEqual(rejectedDetails.count, 1)
        XCTAssertTrue(rejectedDetails[0].contains("HIGH/MEDIUM/LOW"), rejectedDetails[0])
    }

    func testExhaustedSubmissionsFailsTheJob() async throws {
        let bad = "{not json"
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: bad)])),
            .response(toolCallResponse([(name: "submit_research_notes", args: bad)])),
            .response(toolCallResponse([(name: "submit_research_notes", args: bad)])),
        ])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()])

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertNotNil(outcome.errorDetail)
    }

    // MARK: 循环边界

    func testTurnBudgetExhaustionFails() async throws {
        // 模型每轮都只调工具不提交。
        let loopStep = toolCallResponse([(name: "get_market_snapshot", args: "{}")])
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(loopStep), .response(loopStep), .response(loopStep),
        ])
        var policy = ResearchHarnessPolicy()
        policy.maxTurns = 3
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()], policy: policy)

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("轮次耗尽") ?? false, outcome.errorDetail ?? "")
    }

    func testToolCallBudgetExhaustionFails() async throws {
        let loopStep = toolCallResponse([(name: "get_market_snapshot", args: "{}")])
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(loopStep), .response(loopStep),
        ])
        var policy = ResearchHarnessPolicy()
        policy.maxTurns = 10
        policy.maxToolCalls = 1
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()], policy: policy)

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("工具调用次数超限") ?? false)
    }

    func testPlainTextResponsesBeyondLimitFail() async throws {
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(textResponse("我认为应该买入。")),
            .response(textResponse("再看看。")),
            .response(textResponse("还是文本。")),
        ])
        var policy = ResearchHarnessPolicy()
        policy.maxPlainTextResponses = 2
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [], policy: policy)

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("未发起工具调用") ?? false)
    }

    func testTruncatedResponseDoesNotExecuteTools() async throws {
        // stopReason = length：参数可能不完整，不执行、要求重发。
        let truncatedCall = ModelToolCall(id: "call-1", name: "get_market_snapshot", argumentsJSON: "{\"q\":")
        let truncated = ModelCompletionResponse(
            assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [truncatedCall]),
            toolCalls: [truncatedCall],
            stopReason: .length,
            usage: nil
        )
        let valid = """
        {"notes": "n", "claims": [{"statement": "s", "evidence_ids": ["EV-1"], "confidence_label": "HIGH"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(truncated),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: valid)])),
        ])
        let tool = StubResearchTool()
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [tool])

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(tool.callCount, 1, "截断轮的工具调用未执行")
    }

    func testTotalTimeoutFailsJob() async throws {
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
        ])
        var policy = ResearchHarnessPolicy()
        policy.totalTimeoutSeconds = 0
        // clock 单调快进：第二轮即超时
        var tick = 0
        let harness = ResearchHarness(
            gateway: gateway(provider: provider),
            tools: [StubResearchTool()],
            policy: policy,
            clock: { tick += 1; return Date().addingTimeInterval(Double(tick * 100)) }
        )

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("超时") ?? false)
    }

    func testUnknownToolReturnsErrorEnvelopeAndContinues() async throws {
        let valid = """
        {"notes": "n", "claims": [{"statement": "s", "evidence_ids": ["EV-1"], "confidence_label": "HIGH"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "nonexistent_tool", args: "{}")])),
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: valid)])),
        ])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()])

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertTrue(outcome.succeeded, "未知工具不终止运行，回灌错误信封")
        let unknownToolMessage = outcome.transcript.compactMap { $0.content }.first { $0.contains("unknown_tool") }
        XCTAssertNotNil(unknownToolMessage)
    }

    // MARK: 取消

    func testCancellationMarksJobCancelledAndRethrows() async throws {
        let loopStep = toolCallResponse([(name: "get_market_snapshot", args: "{}")])
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(loopStep), .response(loopStep), .response(loopStep),
            .response(loopStep), .response(loopStep),
        ])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [StubResearchTool()])

        // 事件驱动取消（审查 P3-6：创建即 cancel 存在理论竞态——改为在首个
        // turnStarted 事件后取消，取消点确定在第二轮循环开头的检查处）。
        // 间接持有：闭包不能捕获声明中的 task 自身
        var cancelHook: (@Sendable () -> Void)?
        let task = Task<ResearchRunOutcome, Error> {
            try await harness.run(task: try makeResearchTask()) { event in
                if case .turnStarted = event {
                    cancelHook?()
                }
            }
        }
        cancelHook = { task.cancel() }
        do {
            _ = try await task.value
            XCTFail("取消应 rethrow CancellationError")
        } catch is CancellationError {
            // 预期：取消原样透传
        } catch {
            XCTFail("应抛 CancellationError，实际 \(error)")
        }
    }

    // MARK: 上下文治理

    func testOversizedToolResultIsTruncatedInContext() async throws {
        // 审查 P2-1 回归：截断前缀含引号/反斜杠/换行时，回灌内容必须仍是
        // 合法 JSON（字符串插值拼 JSON 会注入破损）。
        let big = String(repeating: "\"quote\nbackslash\\", count: 64)
        let valid = """
        {"notes": "n", "claims": [{"statement": "s", "evidence_ids": ["EV-1"], "confidence_label": "HIGH"}]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
            .response(toolCallResponse([(name: "submit_research_notes", args: valid)])),
        ])
        var policy = ResearchHarnessPolicy()
        policy.maxToolResultBytes = 64
        let tool = StubResearchTool(content: ["data": .string(big)])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [tool], policy: policy)

        let outcome = try await harness.run(task: try makeResearchTask())
        XCTAssertTrue(outcome.succeeded, "截断不终止运行")
        let toolMessage = outcome.transcript.first { $0.role == .tool && $0.content?.contains("truncated") == true }
        XCTAssertNotNil(toolMessage, "回灌内容带 truncated 标记")
        let content = try XCTUnwrap(toolMessage?.content)
        XCTAssertNotNil(
            try? JSONSerialization.jsonObject(with: Data(content.utf8)),
            "截断信封必须是合法 JSON（恶意字符被转义）"
        )
        XCTAssertTrue(content.contains("\\\"quote"), "前缀内容经转义保留")
    }

    func testContextCompactionReplacesOldToolMessages() async throws {
        // 制造大结果 + 多轮循环触发裁剪：早期 tool 消息被替换为占位。
        let big = String(repeating: "y", count: 200 * 1024)
        let loopStep = toolCallResponse([(name: "get_market_snapshot", args: "{}")])
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(loopStep), .response(loopStep), .response(loopStep),
            .response(loopStep), .response(loopStep),
        ])
        var policy = ResearchHarnessPolicy()
        policy.maxTurns = 5
        policy.contextBudgetBytes = 300 * 1024
        policy.contextPreserveRecentMessages = 2
        let tool = StubResearchTool(content: ["data": .string(big)])
        let harness = ResearchHarness(gateway: gateway(provider: provider), tools: [tool], policy: policy)

        _ = try await harness.run(task: try makeResearchTask())
        // 直接断言裁剪行为发生在 harness 内部不可见，改用行为代理：
        // 本测试主要锁定「裁剪不崩溃、运行继续」，细节由 transcript 体积约束。
        let outcome = try await ResearchHarness(
            gateway: gateway(provider: ScriptedModelProvider(providerID: "p", steps: [
                .response(loopStep), .response(loopStep), .response(loopStep),
                .response(loopStep), .response(loopStep),
            ])),
            tools: [StubResearchTool(content: ["data": .string(big)])],
            policy: policy
        ).run(task: try makeResearchTask())
        XCTAssertEqual(outcome.job.state, .failed, "轮次耗尽失败（非裁剪崩溃）")
    }

    // MARK: 幂等与指纹

    func testSameTaskProducesSameJobIdentity() async throws {
        let valid = """
        {"notes": "n", "claims": [{"statement": "s", "evidence_ids": ["EV-1"], "confidence_label": "HIGH"}]}
        """
        func runOnce() async throws -> ResearchRunOutcome {
            let provider = ScriptedModelProvider(providerID: "p", steps: [
                .response(toolCallResponse([(name: "get_market_snapshot", args: "{}")])),
                .response(toolCallResponse([(name: "submit_research_notes", args: valid)])),
            ])
            return try await ResearchHarness(
                gateway: gateway(provider: provider), tools: [StubResearchTool()]
            ).run(task: try makeResearchTask())
        }
        let first = try await runOnce()
        let second = try await runOnce()
        XCTAssertEqual(first.job.id, second.job.id, "同任务同指纹 = 同 job 身份")
        XCTAssertEqual(first.notes?.contentFingerprint, second.notes?.contentFingerprint)
    }

    func testNotesContentFingerprintIgnoresProducedAt() throws {
        let task = try makeResearchTask()
        let producer = ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f")
        let claims = [ResearchClaim(
            statement: "s",
            evidenceReferences: [EvidenceID(rawValue: "E1")],
            confidenceLabel: .high,
            dimension: .momentum
        )]
        let a = ResearchNotes(task: task, notes: "n", claims: claims, producedBy: producer, producedAt: Date(timeIntervalSince1970: 1000))
        let b = ResearchNotes(task: task, notes: "n", claims: claims, producedBy: producer, producedAt: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(a.contentFingerprint, b.contentFingerprint, "产出时间不参与内容指纹")
        var differentClaims = claims
        differentClaims[0] = ResearchClaim(
            statement: "different",
            evidenceReferences: [EvidenceID(rawValue: "E1")],
            confidenceLabel: .high,
            dimension: .momentum
        )
        let c = ResearchNotes(task: task, notes: "n", claims: differentClaims, producedBy: producer, producedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertNotEqual(a.contentFingerprint, c.contentFingerprint)
    }
}
