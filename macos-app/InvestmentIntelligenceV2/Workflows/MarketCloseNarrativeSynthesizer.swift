import Foundation

// MARK: - MarketCloseNarrativeSynthesizer（审计 A1：收盘复盘的 LLM 增强）
//
// 市场摘要（指数涨跌 + 因子评分）→ 结构化市场脉搏 / 强弱主题。
// 输出走 StructuredGeneration（tool call 承载 JSON，禁止 Markdown parse）；
// 任何失败向上抛（MarketCloseReviewWorkflow 捕获后降级本地因子版，
// 不阻断冻结）。

struct MarketCloseNarrativeSynthesizer: Sendable {

    let gateway: ModelGateway

    init(gateway: ModelGateway) {
        self.gateway = gateway
    }

    // MARK: - 结构化输出契约

    /// 提交工具 schema（显式手写，与 CloseReviewNarrative 的 Codable 形状成对维护）。
    static let schema = StructuredGenerationSchema(
        functionName: "submit_close_review_narrative",
        description: "提交当日收盘复盘的市场叙述：市场脉搏（指数/风格层面的方向判断）与强弱主题（领涨/领跌板块或资产）",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "market_pulse": .object([
                    "type": .string("array"),
                    "description": .string("市场脉搏，2-4 条；每条一个市场层面的判断"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string"), "description": .string("判断对象名，如「沪深300」「小盘风格」")]),
                            "direction": .object([
                                "type": .string("string"),
                                "enum": .array([.string("up"), .string("down"), .string("flat")]),
                            ]),
                            "confidence_text": .object(["type": .string("string"), "description": .string("把握程度人话，如「证据较强」「方向不明」")]),
                            "rationale": .object(["type": .string("string"), "description": .string("一句话依据，只引用给定摘要中的数字")]),
                        ]),
                        "required": .array([.string("name"), .string("direction"), .string("confidence_text"), .string("rationale")]),
                    ]),
                ]),
                "strong_themes": .object([
                    "type": .string("array"),
                    "description": .string("当日强势主题，0-3 条"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string")]),
                            "direction": .object(["type": .string("string"), "enum": .array([.string("strong")])]),
                            "rationale": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("name"), .string("direction"), .string("rationale")]),
                    ]),
                ]),
                "weak_themes": .object([
                    "type": .string("array"),
                    "description": .string("当日弱势主题，0-3 条"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string")]),
                            "direction": .object(["type": .string("string"), "enum": .array([.string("weak")])]),
                            "rationale": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("name"), .string("direction"), .string("rationale")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("market_pulse"), .string("strong_themes"), .string("weak_themes")]),
        ]))

    // MARK: - 合成

    func synthesize(digestJSON: String) async throws -> CloseReviewNarrative {
        let messages = [
            ModelChatMessage(
                role: .system,
                content: """
                你是中国市场的收盘复盘分析师。基于给定的当日市场摘要（指数涨跌幅与本地因子评分），\
                生成收盘复盘的市场叙述。纪律：
                - 只引用摘要中出现的数字与标的，不编造行情
                - 判断克制：方向不明就写 flat，把握不足就在 confidence_text 说明
                - rationale 一句话，说清依据（如「沪深300 +1.2% 领先主要指数」）
                - 强弱主题来自摘要中的因子/板块信号，没有就返回空数组
                """),
            ModelChatMessage(
                role: .user,
                content: "当日市场摘要 JSON：\n\(digestJSON)"),
        ]
        let request = StructuredGeneration.request(
            messages: messages,
            schema: Self.schema,
            temperature: 0.2,
            maxOutputTokens: 1200,
            purpose: "closeReview.narrative")
        let response = try await gateway.complete(request)
        let narrative = try StructuredGeneration.decode(
            response, as: CloseReviewNarrative.self, schema: Self.schema)
        return sanitize(narrative)
    }

    /// 数量边界清洗（模型超量输出截断到产品口径）。
    private func sanitize(_ narrative: CloseReviewNarrative) -> CloseReviewNarrative {
        CloseReviewNarrative(
            marketPulse: Array(narrative.marketPulse.prefix(4)),
            strongThemes: Array(narrative.strongThemes.prefix(3)),
            weakThemes: Array(narrative.weakThemes.prefix(3)))
    }
}
