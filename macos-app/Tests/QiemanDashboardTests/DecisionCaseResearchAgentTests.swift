import Foundation
import XCTest
@testable import QiemanDashboard

// DecisionCaseResearchAgent 测试。
//
// 用自有的 FakeDecisionCaseResearchClient(参考 NextHourGuidanceTests 的 FakeNextHourAgentClient 模式)
// mock TrendResearchAgentClient,测 Agent 循环 + submit 校验 + 建议状态输出。
final class DecisionCaseResearchAgentTests: XCTestCase {

    // MARK: - 正常路径:context + submit 成功

    func testContextThenSubmitSucceeds() async throws {
        let submitArgs = makeSubmitArgumentsJSON(
            findings: [ResearchFinding(claim: "集中度确实偏高", direction: .supportive, significance: .high, evidenceIDs: ["decision-case:context:\(Self.caseID.uuidString)"])],
            counterFindings: [],
            uncertainties: ["未来政策不确定"],
            suggestedState: .watch,
            rationale: "风险存在但可控"
        )
        let client = FakeDecisionCaseResearchClient(submitArguments: submitArgs)
        let agent = DecisionCaseResearchAgent(client: client)

        let report = try await agent.run(
            decisionCase: makeCase(),
            snapshot: makeSnapshot(),
            settings: Self.configuredSettings
        )

        XCTAssertEqual(client.responsesConsumed, 2, "应两轮:context + submit")
        XCTAssertEqual(report.caseID, Self.caseID)
        XCTAssertEqual(report.suggestedState, .watch)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.rationale, "风险存在但可控")
        // context 证据应保留(Ledger 真实产出)
        XCTAssertTrue(report.evidence.contains { $0.id.hasPrefix("decision-case:context:") })
    }

    // MARK: - submit 前未调 context 被拒(验证门禁触发重试)

    func testSubmitBeforeContextTriggersRetry() async {
        // 第1轮 submit(跳过 context)→ 被拒 → 第2轮 context → 第3轮 submit 成功
        let submitArgs = makeSubmitArgumentsJSON(
            findings: [ResearchFinding(
                claim: "集中度偏高",
                direction: .supportive,
                significance: .high,
                evidenceIDs: ["decision-case:context:\(Self.caseID.uuidString)"]
            )],
            counterFindings: [], uncertainties: [],
            suggestedState: .watch, rationale: "风险存在"
        )
        let client = FakeDecisionCaseResearchClient(submitArguments: submitArgs, submitOnFirstRound: true)
        let agent = DecisionCaseResearchAgent(client: client)

        do {
            let report = try await agent.run(
                decisionCase: makeCase(),
                snapshot: makeSnapshot(),
                settings: Self.configuredSettings
            )
            // 成功:说明门禁触发了重试(context → submit)
            XCTAssertEqual(report.suggestedState, .watch)
        } catch {
            // 门禁触发后,如果 submit 内容仍被拒(证据校验等),可能抛错——也是可接受的
            // 关键是验证 client 被调了 ≥3 次(说明有重试)
            XCTAssertTrue(error is DecisionCaseResearchAgentError, "应抛 Agent 错误")
        }
        XCTAssertGreaterThanOrEqual(client.responsesConsumed, 3, "submit 前未调 context 应触发重试(≥3 轮)")
    }

    // MARK: - 未配置模型抛 missingConfiguration

    func testMissingConfigurationThrows() async {
        let agent = DecisionCaseResearchAgent(client: FakeDecisionCaseResearchClient(submitArguments: "{}"))
        do {
            _ = try await agent.run(
                decisionCase: makeCase(),
                snapshot: makeSnapshot(),
                settings: TrendAIProviderSettings.empty  // 未配置
            )
            XCTFail("应抛 missingConfiguration")
        } catch let error as DecisionCaseResearchAgentError {
            if case .missingConfiguration = error { } else { XCTFail("应抛 missingConfiguration,实际:\(error)") }
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    // MARK: - exitReview 门槛:反向证据不足被拒

    func testExitReviewRejectedWithoutTwoIndependentCounterSources() async {
        // 建议 exitReview 但只有 1 个来源的反向证据 → 被拒
        let submitArgs = makeSubmitArgumentsJSON(
            findings: [],
            counterFindings: [ResearchFinding(claim: "反向", direction: .counter, significance: .high, evidenceIDs: ["decision-case:context:\(Self.caseID.uuidString)"])],
            uncertainties: [],
            suggestedState: .exitReview,
            rationale: "逻辑失效"
        )
        // 第一轮 submit 被拒,后续循环会继续 submit,最终 turnLimitExceeded 或 invalidSubmissionLimitExceeded
        let client = FakeDecisionCaseResearchClient(submitArguments: submitArgs)
        let agent = DecisionCaseResearchAgent(client: client)

        do {
            _ = try await agent.run(
                decisionCase: makeCase(),
                snapshot: makeSnapshot(),
                settings: Self.configuredSettings
            )
            XCTFail("exitReview 反向证据不足应导致提交失败")
        } catch {
            // 预期抛错(轮次超限或校验失败超限)
            XCTAssertTrue(error is DecisionCaseResearchAgentError, "应抛 Agent 错误")
        }
    }

    // MARK: - 回归:风险不成立时空 findings 应被接受

    func testStableConclusionWithEmptyFindingsIsAccepted() async throws {
        // 研究「风险不成立」结论:findings 空 + rationale 说明 + suggestedState=.stable
        // 修复前会被「缺少必填字段:findings」误拒,导致 3 次重试后抛错。
        let submitArgs = makeSubmitArgumentsJSON(
            findings: [],
            counterFindings: [],
            uncertainties: [],
            suggestedState: .stable,
            rationale: "研究表明集中度已回落到阈值以内,风险不成立"
        )
        let client = FakeDecisionCaseResearchClient(submitArguments: submitArgs)
        let agent = DecisionCaseResearchAgent(client: client)

        let report = try await agent.run(
            decisionCase: makeCase(),
            snapshot: makeSnapshot(),
            settings: Self.configuredSettings
        )
        XCTAssertEqual(report.suggestedState, .stable)
        XCTAssertTrue(report.findings.isEmpty, "空 findings 的 stable 结论应原样保留")
        XCTAssertFalse(report.rationale.isEmpty)
    }

    // MARK: - 回归:findings 解码失败应回灌真实原因,而非误报「缺少必填字段」

    func testMalformedFindingsReportsDecodeError() async {
        // findings 传成对象(非数组)→ 解码失败 → 应抛 Agent 错误,
        // 且错误信息含真实解码原因(类型不匹配),不含「缺少必填字段:findings」。
        let malformedArgs = makeRawSubmitArgumentsJSON(findingsValue: ["type": "object"])
        let client = FakeDecisionCaseResearchClient(submitArguments: malformedArgs)
        let agent = DecisionCaseResearchAgent(client: client)

        do {
            _ = try await agent.run(
                decisionCase: makeCase(),
                snapshot: makeSnapshot(),
                settings: Self.configuredSettings
            )
            XCTFail("findings 非数组应导致解码失败")
        } catch let error as DecisionCaseResearchAgentError {
            guard case .invalidSubmissionLimitExceeded(let errors) = error else {
                return XCTFail("应抛 invalidSubmissionLimitExceeded,实际:\(error)")
            }
            let combined = errors.joined(separator: "、")
            XCTAssertTrue(combined.contains("解码失败") || combined.contains("类型不匹配"), "错误应含真实解码原因,实际:\(combined)")
            XCTAssertFalse(combined.contains("缺少必填字段:findings"), "不应误报缺少 findings")
        } catch {
            XCTFail("错误类型不对:\(error)")
        }
    }

    // MARK: - 回归:findings 里 direction/significance 用同义词或非法值应容错降级,不抛解码错误

    func testFindingWithSynonymDirectionIsAccepted() async throws {
        // direction 用 "supports"（同义词，非合法枚举值）、significance 用 "moderate"
        // 修复前会让整条 finding 解码失败（字段类型不匹配 findings.Index 0），3 次重试后抛错。
        // 修复后应容错降级并成功提交。
        let submitArgs = makeRawFindingsArgumentsJSON(
            direction: "supports",
            significance: "moderate",
            evidenceID: "decision-case:context:\(Self.caseID.uuidString)"
        )
        let client = FakeDecisionCaseResearchClient(submitArguments: submitArgs)
        let agent = DecisionCaseResearchAgent(client: client)

        let report = try await agent.run(
            decisionCase: makeCase(),
            snapshot: makeSnapshot(),
            settings: Self.configuredSettings
        )
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].direction, .supportive, "supports 应降级为 .supportive")
        XCTAssertEqual(report.findings[0].significance, .medium, "moderate 应降级为 .medium")
    }

    // MARK: - 辅助

    private static let caseID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let configuredSettings = TrendAIProviderSettings(
        providerName: "test", baseURL: "https://api.test.com",
        model: "test-model", apiKey: "test-key", timeoutSeconds: 60
    )

    private func makeCase() -> DecisionCase {
        DecisionCase(
            id: Self.caseID,
            caseKey: "concentrationRisk|directHolding|001000",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "测试基金", subjectCode: "001000",
            lifecycle: .decisionReady,
            decisionState: .watch,
            metricValue: 42, metricLabel: "42.0%",
            metricDescription: "第一大标的占比",
            title: "集中度测试", detail: "测试用例",
            createdAt: "2026-08-05 10:00:00", updatedAt: "2026-08-05 10:00:00"
        )
    }

    private func makeSnapshot() -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            createdAt: "2026-08-05 10:00:00",
            dataAsOf: "2026-08-05 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 0, holdingCount: 0, activePlanCount: 0, pendingAssetCount: 0,
                totalMarketValue: nil, totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil, totalEffectiveHoldingAmount: nil
            ),
            assets: [], sectors: [], platformSignals: [], managerSignals: [],
            marketQuotes: [], lookThrough: nil,
            insightHeadline: "测试", sourceWarnings: [], sourceStatuses: []
        )
    }

    private func makeSubmitArgumentsJSON(
        findings: [ResearchFinding],
        counterFindings: [ResearchFinding],
        uncertainties: [String],
        suggestedState: PortfolioDecisionState,
        rationale: String
    ) -> String {
        let encoder = JSONEncoder()
        let obj: [String: Any] = [
            "findings": findings.map { f in
                ["claim": f.claim, "direction": f.direction.rawValue, "significance": f.significance.rawValue, "evidenceIDs": f.evidenceIDs] as [String: Any]
            },
            "counterFindings": counterFindings.map { f in
                ["claim": f.claim, "direction": f.direction.rawValue, "significance": f.significance.rawValue, "evidenceIDs": f.evidenceIDs] as [String: Any]
            },
            "uncertainties": uncertainties,
            "suggestedState": suggestedState.rawValue,
            "rationale": rationale
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
    }

    /// 用任意 findings 值构造提交 JSON（用于注入畸形 findings 测解码失败）。
    private func makeRawSubmitArgumentsJSON(findingsValue: Any) -> String {
        let obj: [String: Any] = [
            "findings": findingsValue,
            "counterFindings": [],
            "uncertainties": [],
            "suggestedState": PortfolioDecisionState.watch.rawValue,
            "rationale": "测试"
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
    }

    /// 构造带一条 finding 的提交 JSON，允许自定义 direction/significance（测同义词容错）。
    private func makeRawFindingsArgumentsJSON(direction: String, significance: String, evidenceID: String) -> String {
        let obj: [String: Any] = [
            "findings": [[
                "claim": "集中度确实偏高",
                "direction": direction,
                "significance": significance,
                "evidenceIDs": [evidenceID]
            ]],
            "counterFindings": [],
            "uncertainties": [],
            "suggestedState": PortfolioDecisionState.watch.rawValue,
            "rationale": "风险存在但可控"
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - Fake Client

/// 模拟 Agent Client:第 1 轮返回 get_case_context 工具调用,
/// 之后返回 submit_case_research 工具调用(带预设 arguments)。
/// submitOnFirstRound=true 时第 1 轮就 submit(用于测"未调 context 被拒")。
final class FakeDecisionCaseResearchClient: TrendResearchAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private let submitArguments: String
    private let submitOnFirstRound: Bool
    private(set) var responsesConsumed = 0

    init(submitArguments: String, submitOnFirstRound: Bool = false) {
        self.submitArguments = submitArguments
        self.submitOnFirstRound = submitOnFirstRound
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
        let isFirst = responsesConsumed == 1
        lock.unlock()

        let call: AgentToolCall
        if submitOnFirstRound {
            // 第 1 轮 submit(被拒),第 2 轮 context,之后 submit
            if responsesConsumed == 1 {
                call = AgentToolCall(id: "call-submit", function: AgentToolFunctionCall(name: "submit_case_research", arguments: submitArguments))
            } else if responsesConsumed == 2 {
                call = AgentToolCall(id: "call-ctx", function: AgentToolFunctionCall(name: "get_case_context", arguments: "{}"))
            } else {
                call = AgentToolCall(id: "call-submit", function: AgentToolFunctionCall(name: "submit_case_research", arguments: submitArguments))
            }
        } else if isFirst {
            // 正常:第 1 轮 get_case_context
            call = AgentToolCall(id: "call-ctx", function: AgentToolFunctionCall(name: "get_case_context", arguments: "{}"))
        } else {
            // submit
            call = AgentToolCall(id: "call-submit", function: AgentToolFunctionCall(name: "submit_case_research", arguments: submitArguments))
        }

        return AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: nil, toolCalls: [call]),
            toolCalls: [call],
            stopReason: .toolCalls,
            finishReason: "tool_calls"
        )
    }
}
