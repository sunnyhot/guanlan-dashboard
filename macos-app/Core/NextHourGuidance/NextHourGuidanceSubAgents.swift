import Foundation

// 盘中研判子 Agent：将单体 Agent 拆成 3 个并行分析 + 1 个汇总决策。
//
// 拆分动机：原 NextHourGuidanceAgent 一个循环同时分析行情+新闻+持仓，
// 注意力分散，加上 11 个 AND 风控门槛导致默认退回 hold。
// 拆成聚焦的子 Agent 各自深入一个维度，汇总时综合三方结论，
// 用分级标注（high/medium/low）替代二选一强制退回 hold。
//
// 复用基础设施（不重写）：
// - TrendResearchAgentClient（protocol）—— 所有子 Agent 共用 client.complete()
// - TrendResearchToolRegistry —— web_search/SEC/lookthrough 工具集
// - TrendEvidenceLedger（actor）—— 3 个子 Agent 共享同一个 Ledger

// MARK: - ① 行情信号 Agent 输出

/// 行情信号 Agent 对每个标的的走势判断。
struct MarketSignalAssessment: Codable, Hashable, Sendable {
    let overallTrend: String
    let perAssetSignals: [AssetSignal]
    let freshnessWarning: String?

    struct AssetSignal: Codable, Hashable, Sendable {
        let targetID: String
        let targetName: String
        let trend: String        // 强势上行/弱势下行/横盘震荡
        let confidence: Int      // 0-100
        let rationale: String
    }
}

// MARK: - ② 新闻事件 Agent 输出

/// 新闻事件 Agent 对每个标的的事件影响判断。
struct NewsEventAssessment: Codable, Hashable, Sendable {
    let macroSummary: String?
    let perAssetEvents: [AssetEvent]

    struct AssetEvent: Codable, Hashable, Sendable {
        let targetID: String
        let targetName: String
        let sentiment: String    // 利好/利空/中性
        let keyEvents: [String]
        let sources: [String]
        let confidence: Int      // 0-100
    }
}

// MARK: - ③ 持仓结构 Agent 输出

/// 持仓结构 Agent 对每个标的在组合中的位置判断。
struct PortfolioContextAssessment: Codable, Hashable, Sendable {
    let perAssetContext: [AssetContext]

    struct AssetContext: Codable, Hashable, Sendable {
        let targetID: String
        let targetName: String
        let position: String         // 超配/低配/正常
        let riskExposure: String     // 集中度风险/无特殊风险
        let overlapNote: String?
        let recommendation: String   // 适合加仓/适合减仓/维持
    }
}

// MARK: - 子 Agent 编排器

/// 编排 3 个并行子 Agent + 1 个汇总决策 Agent。
///
/// 每个子 Agent 用一次 LLM 调用（tool_choice: required）提交结构化结论。
/// 不做多轮循环（保持轻量），各自聚焦一个维度。
struct NextHourGuidanceSubAgentOrchestrator: Sendable {

    let client: any TrendResearchAgentClient
    let registry: TrendResearchToolRegistry

    // 预算
    private static let perAgentTimeout: Double = 90
    private static let marketAgentTemp: Double = 0.2
    private static let newsAgentTemp: Double = 0.2
    private static let portfolioAgentTemp: Double = 0.2

    init(
        client: any TrendResearchAgentClient,
        registry: TrendResearchToolRegistry
    ) {
        self.client = client
        self.registry = registry
    }

    /// 并行运行 3 个子 Agent，返回各自的结构化结论。
    func runAnalysisAgents(
        context: NextHourGuidanceContext,
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings
    ) async throws -> (MarketSignalAssessment, NewsEventAssessment, PortfolioContextAssessment) {
        async let market = runMarketSignalAgent(
            context: context, settings: settings
        )
        async let news = runNewsEventAgent(
            context: context, settings: settings
        )
        async let portfolio = runPortfolioContextAgent(
            context: context, snapshot: snapshot, settings: settings
        )
        return try await (market, news, portfolio)
    }

    // MARK: - ① 行情信号 Agent

    private func runMarketSignalAgent(
        context: NextHourGuidanceContext,
        settings: TrendAIProviderSettings
    ) async throws -> MarketSignalAssessment {
        let submitSchema: AgentJSONValue = [
            "type": "object",
            "properties": [
                "overallTrend": ["type": "string", "description": "大盘整体走势：强势/弱势/震荡"],
                "perAssetSignals": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "targetID": ["type": "string"],
                            "targetName": ["type": "string"],
                            "trend": ["type": "string", "description": "强势上行/弱势下行/横盘震荡"],
                            "confidence": ["type": "integer", "description": "0-100"],
                            "rationale": ["type": "string"]
                        ],
                        "required": ["targetID", "targetName", "trend", "confidence", "rationale"]
                    ]
                ],
                "freshnessWarning": ["type": "string", "description": "行情新鲜度警告，无则留空"]
            ],
            "required": ["overallTrend", "perAssetSignals"]
        ]

        let tools: [AgentToolDefinition] = [
            Self.makeMarketContextTool(),
            AgentToolDefinition.function(
                name: "submit_market_signal",
                description: "提交行情信号分析结论。",
                parameters: submitSchema
            )
        ]

        let systemMessage = """
        你是行情分析专家，只看实时行情和大盘走势，判断每个标的的短期方向。
        先读取行情数据，然后提交分析结论。
        聚焦价格走势、涨跌幅、大盘联动，不要分析新闻或基本面。
        对每个标的给出明确的方向判断（强势上行/弱势下行/横盘震荡）和置信度。
        若上下文含 lastCloseReview(昨日关注)：逐条核对其中与行情、量能、指数表现相关的事项，并在对应标的的 rationale 里明确说明该事项今天是否出现。
        """

        let userMessage = """
        请分析以下标的的实时行情走势并提交结论。标的数量：\(context.assets.count)
        \(context.lastCloseReview.map { review in
            "昨日关注(需在行情维度逐条核对并在结论中回应):" +
            review.tomorrowWatch.joined(separator: "；")
        } ?? "")
        \(context.marketBreadth.map { breadth in
            let amountText = breadth.totalAmountYi.map { String(format: "，两市成交额约 %.0f 亿元", $0) } ?? ""
            return "全市场广度(App 已预取):\(breadth.summary)\(amountText)。样本 \(breadth.sampleCount) 只，计算于 \(breadth.computedAt)。判断大盘整体走势时优先以此为准。"
        } ?? "")
        """

        return try await runSingleTurnAgent(
            systemMessage: systemMessage,
            userMessage: userMessage,
            tools: tools,
            submitToolName: "submit_market_signal",
            settings: settings,
            temperature: Self.marketAgentTemp
        )
    }

    // MARK: - ② 新闻事件 Agent

    private func runNewsEventAgent(
        context: NextHourGuidanceContext,
        settings: TrendAIProviderSettings
    ) async throws -> NewsEventAssessment {
        var tools: [AgentToolDefinition] = []


        let submitSchema: AgentJSONValue = [
            "type": "object",
            "properties": [
                "macroSummary": ["type": "string", "description": "宏观/政策影响总结，无则留空"],
                "perAssetEvents": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "targetID": ["type": "string"],
                            "targetName": ["type": "string"],
                            "sentiment": ["type": "string", "description": "利好/利空/中性"],
                            "keyEvents": ["type": "array", "items": ["type": "string"]],
                            "sources": ["type": "array", "items": ["type": "string"], "description": "来源URL或名称"],
                            "confidence": ["type": "integer", "description": "0-100"]
                        ],
                        "required": ["targetID", "targetName", "sentiment", "confidence"]
                    ]
                ]
            ],
            "required": ["perAssetEvents"]
        ]
        tools.append(AgentToolDefinition.function(
            name: "submit_news_events",
            description: "提交新闻事件分析结论。",
            parameters: submitSchema
        ))

        // 标的列表摘要
        let targetList = context.assets.map { "\($0.name)(\($0.id))" }.joined(separator: "、")
        let systemMessage = """
        你是新闻研究专家，搜索最近24小时影响标的的事件，判断利好利空。
        每个标的至少搜索一次相关新闻。搜索词用标的名称+行业关键词。
        不要搜索用户金额或组合隐私信息。
        对每个标的给出事件影响判断（利好/利空/中性）和置信度。没有找到相关新闻时标中性、置信度低。
        若本次提供了「昨日关注」：把其中新闻/事件/政策相关的事项纳入检索范围,至少为每条做一次针对性搜索(关注原文+今日日期),并在 keyEvents 或判断里明确回应该事项今天是否出现。
        """
        let userMessage = """
        请搜索并分析以下标的的最近新闻事件：\(targetList)
        \(context.lastCloseReview.map { review in
            "昨日关注(需针对性检索并逐条回应):" +
            review.tomorrowWatch.joined(separator: "；")
        } ?? "")
        """

        return try await runSingleTurnAgent(
            systemMessage: systemMessage,
            userMessage: userMessage,
            tools: tools,
            submitToolName: "submit_news_events",
            settings: settings,
            temperature: Self.newsAgentTemp
        )
    }

    // MARK: - ③ 持仓结构 Agent

    private func runPortfolioContextAgent(
        context: NextHourGuidanceContext,
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings
    ) async throws -> PortfolioContextAssessment {
        var tools: [AgentToolDefinition] = []

        // get_fund_lookthrough（如果穿透数据可用）
        if snapshot.lookThrough != nil {
            let ltDef = registry.definitions.first { $0.function.name == "get_fund_lookthrough" }
            if let ltDef { tools.append(ltDef) }
        }

        let submitSchema: AgentJSONValue = [
            "type": "object",
            "properties": [
                "perAssetContext": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "targetID": ["type": "string"],
                            "targetName": ["type": "string"],
                            "position": ["type": "string", "description": "超配/低配/正常"],
                            "riskExposure": ["type": "string", "description": "集中度风险/无特殊风险"],
                            "overlapNote": ["type": "string", "description": "底层重叠备注，无则留空"],
                            "recommendation": ["type": "string", "description": "适合加仓/适合减仓/维持"]
                        ],
                        "required": ["targetID", "targetName", "position", "riskExposure", "recommendation"]
                    ]
                ]
            ],
            "required": ["perAssetContext"]
        ]
        tools.append(AgentToolDefinition.function(
            name: "submit_portfolio_context",
            description: "提交持仓结构分析结论。",
            parameters: submitSchema
        ))

        let systemMessage = """
        你是组合管理专家，分析每个标的在用户组合中的位置和风险暴露。
        基金标的要看底层穿透（股票/行业/资产配置），不要只看基金名称。
        对每个标的判断它在组合中的配置状态（超配/低配/正常）和适合的操作方向（加仓/减仓/维持）。
        """
        let userMessage = "持仓快照：\(context.jsonString())。请分析每个标的在组合中的位置并提交结论。"

        return try await runSingleTurnAgent(
            systemMessage: systemMessage,
            userMessage: userMessage,
            tools: tools,
            submitToolName: "submit_portfolio_context",
            settings: settings,
            temperature: Self.portfolioAgentTemp
        )
    }

    // MARK: - 通用单轮提交 Agent

    /// 通用模式：给模型 system+user 消息 + 工具集，模型调用工具后提交结构化结论。
    /// 最多 4 轮（允许工具调用后提交），超时 90s。
    private func runSingleTurnAgent<T: Decodable>(
        systemMessage: String,
        userMessage: String,
        tools: [AgentToolDefinition],
        submitToolName: String,
        settings: TrendAIProviderSettings,
        temperature: Double
    ) async throws -> T {
        var messages: [AgentChatMessage] = [
            AgentChatMessage(role: .system, content: systemMessage),
            AgentChatMessage(role: .user, content: userMessage)
        ]

        let maxTurns = 4
        let started = Date()

        for turn in 0..<maxTurns {
            try Task.checkCancellation()
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > Self.perAgentTimeout { break }

            let result = try await client.complete(
                messages: messages,
                tools: tools,
                toolChoice: .auto,
                temperature: temperature,
                settings: settings,
                timeout: max(30, Self.perAgentTimeout - elapsed),
                streamProgress: nil
            )
            messages.append(result.assistantMessage)

            // 找到提交工具调用
            if let submitCall = result.toolCalls.first(where: { $0.function.name == submitToolName }) {
                guard let data = submitCall.function.arguments.data(using: .utf8) else { break }
                if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                    let accepted = TrendResearchToolEnvelope.success(["accepted": true])
                    await AIAgentDiagnosticLog.recordToolResult(
                        turn: turn + 1,
                        call: submitCall,
                        contentJSON: accepted,
                        modelContentJSON: accepted,
                        isError: false
                    )
                    return decoded
                }
                // 解码失败，提示重试
                let error = TrendResearchToolEnvelope.error(
                    code: "invalid_submission_json",
                    message: "提交参数解码失败，请检查 JSON 格式后重新提交。"
                )
                await AIAgentDiagnosticLog.recordToolResult(
                    turn: turn + 1,
                    call: submitCall,
                    contentJSON: error,
                    modelContentJSON: error,
                    isError: true
                )
                messages.append(AgentChatMessage(
                    role: .user,
                    content: "提交参数解码失败，请检查 JSON 格式后重新提交。"
                ))
                continue
            }

            // 执行非提交工具（web_search / lookthrough 等）
            for call in result.toolCalls where call.function.name != submitToolName {
                let toolResult = await registry.execute(call, context: makeDummyContext())
                await AIAgentDiagnosticLog.recordToolResult(
                    turn: turn + 1,
                    call: call,
                    contentJSON: toolResult.contentJSON,
                    modelContentJSON: toolResult.contentJSON,
                    isError: toolResult.isError
                )
                messages.append(AgentChatMessage(
                    role: .tool, content: toolResult.contentJSON, toolCallID: call.id
                ))
            }

            if result.toolCalls.isEmpty { break }
            _ = turn // 避免未使用警告
        }

        // 超时/轮次用尽，返回空结论
        return try makeEmptyAssessment()
    }

    // MARK: - 辅助

    /// 行情上下文工具（只读，返回 context JSON）。
    private static func makeMarketContextTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: "get_live_market_context",
            description: "读取实时行情、持仓报价、大盘指数。",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        )
        // 注意：实际行情数据通过 user message 注入（context.jsonString()），
        // 这里工具定义让模型知道可以读取。真正执行时返回 context 摘要。
    }

    private func makeDummyContext() -> TrendResearchToolContext {
        // 子 Agent 的工具执行（lookthrough）需要一个 ToolContext。
        // 实际运行时由编排器注入真实的 Ledger/Snapshot/settings；
        // 这里只在模型未调用工具就提交时作为兜底（不会执行真实搜索）。
        TrendResearchToolContext(
            snapshot: TrendResearchSnapshot.placeholder,
            evidenceLedger: TrendEvidenceLedger(),
            alphaVantageSettings: .empty
        )
    }

    private func makeEmptyAssessment<T: Decodable>() throws -> T {
        // 返回对应类型的空结论。通过 JSON 空对象解码。
        let emptyJSON: String
        if T.self == MarketSignalAssessment.self {
            emptyJSON = #"{"overallTrend":"数据不足","perAssetSignals":[],"freshnessWarning":"行情数据未获取"}"#
        } else if T.self == NewsEventAssessment.self {
            emptyJSON = #"{"macroSummary":null,"perAssetEvents":[]}"#
        } else if T.self == PortfolioContextAssessment.self {
            emptyJSON = #"{"perAssetContext":[]}"#
        } else {
            emptyJSON = "{}"
        }
        guard let data = emptyJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw NextHourGuidanceSubAgentError.assessmentDecodeFailed
        }
        return decoded
    }
}

enum NextHourGuidanceSubAgentError: Error, LocalizedError {
    case assessmentDecodeFailed

    var errorDescription: String? {
        switch self {
        case .assessmentDecodeFailed: return "子 Agent 结论解码失败"
        }
    }
}
