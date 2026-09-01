import XCTest
@testable import QiemanDashboard

// MARK: - Fake 客户端

/// 可编程 Fake：按调用顺序返回预设响应，记录请求。
private final class FakePipelineClient: TrendResearchAgentClient, @unchecked Sendable {
    struct RecordedCall {
        let system: String
        let user: String
    }

    private var responses: [String]
    private(set) var calls: [RecordedCall] = []
    private let lock = NSLock()

    init(responses: [String]) {
        self.responses = responses
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
        lock.lock(); defer { lock.unlock() }
        calls.append(RecordedCall(
            system: messages.first { $0.role == .system }?.content ?? "",
            user: messages.first { $0.role == .user }?.content ?? ""
        ))
        guard !responses.isEmpty else {
            throw URLError(.timedOut)
        }
        let text = responses.removeFirst()
        return AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: text),
            toolCalls: [],
            stopReason: .stop,
            finishReason: "stop"
        )
    }
}

// MARK: - 测试

final class MarketResearchPipelineTests: XCTestCase {
    private func makeSettings(timeout: Double = 120) -> TrendAIProviderSettings {
        TrendAIProviderSettings(
            providerName: "fake",
            baseURL: "https://example.invalid",
            model: "fake-model",
            apiKey: "key",
            timeoutSeconds: timeout
        )
    }

    private func makeEngine() -> MarketDataEngine {
        struct StubKline: MarketKlineProviding {
            let name = "stub"
            func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
                // 40 根稳步上行：强多头排列
                var bars: [MarketDailyBar] = []
                for index in 0..<40 {
                    let close = 10 + Double(index) * 0.1
                    let dateText = String(format: "2026-07-%02d", index + 1)
                    bars.append(MarketDailyBar(
                        date: dateText,
                        open: close,
                        high: close + 0.2,
                        low: close - 0.1,
                        close: close,
                        volume: 1000,
                        amount: 10_000
                    ))
                }
                return bars
            }
        }
        return MarketDataEngine(klineProviders: [StubKline()])
    }

    private func context(phase: MarketPhase = .intraday) -> MarketResearchContext {
        var context = MarketResearchContext(subjectCode: "600519", subjectName: "贵州茅台")
        context.phase = phase
        context.newsHeadlines = ["2026-08-28 财联社：白酒板块批价企稳"]
        return context
    }

    private let decisionJSON = """
    {"score":72,"action":"buy","confidence":"medium",
     "core_conclusion":"技术面强多头，回踩支撑可加仓",
     "no_position_advice":"等回踩 13.9 附近再介入","has_position_advice":"持有，回踩加仓",
     "sniper":{"ideal_buy":13.9,"secondary_buy":13.5,"stop_loss":12.8,"take_profit":16.0},
     "phase_decision":{"action_window":"盘中","immediate_action":"等待回踩","watch_conditions":["回踩不破 MA10"],"next_check_time":"2026-08-29 10:00"},
     "attribution":{"technical":60,"news":20,"fundamentals":10,"market":10},
     "risk_alerts":["2026-08-20 某股东减持公告"],"positive_catalysts":[],"data_limitations":[]}
    """

    func testFullPipelineProducesGuardedDashboardAndSignal() async {
        let client = FakePipelineClient(responses: [
            // intel
            #"{"signal":"buy","confidence":0.65,"reasoning":"批价企稳利好","risk_alerts":[],"positive_catalysts":[]}"#,
            // risk
            #"{"signal":"hold","confidence":0.55,"reasoning":"减持风险存疑","risk_flags":[{"kind":"减持公告","severity":"medium","note":"2026-08-20 减持","veto_buy":false,"adjustment":"downgrade_one"}]}"#,
            // decision
            decisionJSON,
        ])
        let pipeline = MarketResearchPipeline(client: client, engine: makeEngine(), settings: makeSettings())
        let result = await pipeline.run(context: context(), mode: .full)

        // 四个子观点：technical(确定性) + intel + risk
        XCTAssertEqual(result.opinions.count, 3)
        XCTAssertEqual(result.opinions.first { $0.agentName == .technical }?.signal, .buy, "强多头 TA → 看多")
        XCTAssertNotNil(result.opinions.first { $0.agentName == .technical }?.technicalAnalysis)

        // 决策仪表盘经过护栏：买入 72 分 + 资金不可用 → 结构稳定器降级观望
        XCTAssertEqual(result.dashboard.isDegradedFallback, false)
        XCTAssertEqual(result.dashboard.action, .watch, "买入缺资金面确认 → 结构稳定器降级")
        XCTAssertEqual(result.dashboard.score, 59, "钳制观望带上限")
        XCTAssertEqual(result.dashboard.confidence, .medium)
        XCTAssertTrue(result.dashboard.guardrailNotes.contains { $0.contains("资金面") })

        // 信号抽取：狙击点直填
        XCTAssertEqual(result.candidateSignal.sourceKind, .pipeline)
        XCTAssertEqual(result.candidateSignal.direction, .hold, "降级后 watch → hold")
        XCTAssertEqual(result.candidateSignal.priceConditions.stopLoss ?? 0, 12.8)
        XCTAssertEqual(result.candidateSignal.priceConditions.targetPrice ?? 0, 16.0)
        XCTAssertEqual(result.candidateSignal.priceConditions.entryLow ?? 0, 13.761, accuracy: 0.001)

        XCTAssertEqual(result.degradedStages, [])
        XCTAssertEqual(result.regime, .trendingUp)
        XCTAssertFalse(result.disagreement.isSplit, "无看空观点")
    }

    func testQuickModeUsesSingleLLMCall() async {
        let client = FakePipelineClient(responses: [decisionJSON])
        let pipeline = MarketResearchPipeline(client: client, engine: makeEngine(), settings: makeSettings())
        let result = await pipeline.run(context: context(), mode: .quick)
        XCTAssertEqual(client.calls.count, 1, "quick 只有一次决策 LLM 调用")
        XCTAssertEqual(result.opinions.count, 1, "只有确定性技术观点")
        XCTAssertEqual(result.dashboard.subjectCode, "600519")
    }

    func testRiskVetoCapsBullishSignal() async {
        let vetoJSON = decisionJSON.replacingOccurrences(of: "\"score\":72", with: "\"score\":85")
        let client = FakePipelineClient(responses: [
            #"{"signal":"buy","confidence":0.7,"reasoning":"ok","risk_alerts":[],"positive_catalysts":[]}"#,
            #"{"signal":"hold","confidence":0.6,"reasoning":"重大处罚","risk_flags":[{"kind":"监管处罚","severity":"high","note":"2026-08-27 立案","veto_buy":true,"adjustment":"veto"}]}"#,
            vetoJSON,
        ])
        let pipeline = MarketResearchPipeline(client: client, engine: makeEngine(), settings: makeSettings())
        let result = await pipeline.run(context: context(), mode: .full)
        // 风险否决（85 buy → watch）+ 结构护栏先后生效，最终观望
        XCTAssertEqual(result.dashboard.action, .watch)
        XCTAssertTrue(result.dashboard.guardrailNotes.contains { $0.contains("风控接管") })
    }

    func testDecisionFailureFallsBackDeterministically() async {
        let client = FakePipelineClient(responses: [
            #"{"signal":"buy","confidence":0.7,"reasoning":"ok","risk_alerts":[],"positive_catalysts":[]}"#,
            "not json at all", // risk 阶段失败 → 降级继续
        ])
        let pipeline = MarketResearchPipeline(client: client, engine: makeEngine(), settings: makeSettings())
        let result = await pipeline.run(context: context(), mode: .full)
        // risk 失败降级 + decision 无响应 → 确定性兜底
        XCTAssertTrue(result.degradedStages.contains("risk"))
        XCTAssertTrue(result.degradedStages.contains("decision(fallback)"))
        XCTAssertTrue(result.dashboard.isDegradedFallback)
        // 多数决：technical(buy) + intel(buy) → buy 方向，但兜底动作保守为 watch
        XCTAssertEqual(result.dashboard.coreConclusion.contains("降级生成"), true)
        XCTAssertLessThanOrEqual(result.dashboard.confidence.numericValue, 0.6, "兜底置信度打折")
    }

    func testPremarketGuardrailApplies() async {
        let client = FakePipelineClient(responses: [decisionJSON])
        let pipeline = MarketResearchPipeline(client: client, engine: makeEngine(), settings: makeSettings())
        let result = await pipeline.run(context: context(phase: .nonTrading), mode: .quick)
        XCTAssertTrue(result.dashboard.guardrailNotes.contains { $0.contains("阶段护栏") } || result.dashboard.action == .watch)
        XCTAssertEqual(result.dashboard.action, .watch, "非交易日不给立即交易行动")
    }

    func testJSONParsingTolerance() {
        let plain = #"{"a":1}"#
        XCTAssertEqual(MarketResearchPipeline.parseJSONobject(plain)?["a"] as? Int, 1)
        let fenced = "```json\n{\"a\":2}\n```"
        XCTAssertEqual(MarketResearchPipeline.parseJSONobject(fenced)?["a"] as? Int, 2)
        let noisy = "好的，以下是结果：{\"a\":3} 以上。"
        XCTAssertEqual(MarketResearchPipeline.parseJSONobject(noisy)?["a"] as? Int, 3)
        XCTAssertNil(MarketResearchPipeline.parseJSONobject("完全不是 JSON"))
    }

    func testAttributionNormalizesTo100() {
        let attribution = MarketDecisionDashboard.SignalAttribution(
            technicalIndicators: 60, newsSentiment: 20, fundamentals: 10, marketConditions: 10
        ).normalized
        let total = attribution.technicalIndicators + attribution.newsSentiment + attribution.fundamentals + attribution.marketConditions
        XCTAssertEqual(total, 100)
        let zero = MarketDecisionDashboard.SignalAttribution(
            technicalIndicators: 0, newsSentiment: 0, fundamentals: 0, marketConditions: 0
        ).normalized
        XCTAssertEqual(zero.technicalIndicators, 25, "全零回落均分")
    }
}

// MARK: - 风险否决状态机

final class RiskOverrideStateMachineTests: XCTestCase {
    func testVetoOnlyAffectsBullishDirection() {
        let veto = AgentRiskFlag(kind: "监管处罚", severity: .high, note: "立案调查", vetoBuy: true, adjustment: .veto)
        // buy → watch（保守方向）合法
        let fromBuy = RiskOverrideStateMachine.applyRiskOverride(action: .buy, riskFlags: [veto])
        XCTAssertEqual(fromBuy.action, .watch)
        XCTAssertTrue(fromBuy.applied)
        XCTAssertTrue(fromBuy.note?.contains("风控接管") ?? false)
        // sell 已在保守端，不受 veto 调整
        let fromSell = RiskOverrideStateMachine.applyRiskOverride(action: .sell, riskFlags: [veto])
        XCTAssertEqual(fromSell.action, .sell)
        XCTAssertFalse(fromSell.applied)
        // 无风险不动
        let untouched = RiskOverrideStateMachine.applyRiskOverride(action: .buy, riskFlags: [])
        XCTAssertEqual(untouched.action, .buy)
        XCTAssertFalse(untouched.applied)
    }

    func testHighRiskWithoutVetoDowngradesOneNotch() {
        let high = AgentRiskFlag(kind: "解禁", severity: .high, note: "30 天内大额解禁", vetoBuy: false)
        let result = RiskOverrideStateMachine.applyRiskOverride(action: .buy, riskFlags: [high])
        XCTAssertEqual(result.action, .add, "buy 降一档为 add")
        XCTAssertTrue(result.applied)
        let watchResult = RiskOverrideStateMachine.applyRiskOverride(action: .watch, riskFlags: [high])
        XCTAssertFalse(watchResult.applied, "非进攻方向不降")
    }

    func testDisagreementBuckets() {
        let opinions = [
            AgentOpinion(agentName: .technical, subjectCode: "600519", signal: .buy, confidence: 0.7, reasoning: "r"),
            AgentOpinion(agentName: .intel, subjectCode: "600519", signal: .sell, confidence: 0.6, reasoning: "r"),
            AgentOpinion(agentName: .risk, subjectCode: "600519", signal: .hold, confidence: 0.5, reasoning: "r"),
        ]
        let summary = OpinionDisagreementSummary(opinions: opinions)
        XCTAssertTrue(summary.isSplit)
        XCTAssertEqual(summary.bullishAgents, ["technical"])
        XCTAssertEqual(summary.bearishAgents, ["intel"])
        XCTAssertTrue(summary.summaryText.contains("分歧"))
    }

    func testOpinionConfidenceClamped() {
        let invalid = AgentOpinion(agentName: .intel, subjectCode: "x", signal: .buy, confidence: 1.7, reasoning: "r")
        XCTAssertFalse(invalid.confidenceWasValid)
        XCTAssertEqual(invalid.confidence, 1.0)
        let nan = AgentOpinion(agentName: .intel, subjectCode: "x", signal: .buy, confidence: .nan, reasoning: "r")
        XCTAssertFalse(nan.confidenceWasValid)
    }
}
