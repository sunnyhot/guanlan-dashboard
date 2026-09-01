import Foundation

// MARK: - 决策仪表盘（输出契约）

/// 决策仪表盘：流水线的最终输出，也是信号抽取（pipeline 源）的输入。
struct MarketDecisionDashboard: Codable, Hashable, Sendable {
    struct SniperPoints: Codable, Hashable, Sendable {
        var idealBuy: Double?
        var secondaryBuy: Double?
        var stopLoss: Double?
        var takeProfit: Double?
    }

    struct PhaseDecision: Codable, Hashable, Sendable {
        var actionWindow: String
        var immediateAction: String
        var watchConditions: [String]
        var nextCheckTime: String
    }

    struct SignalAttribution: Codable, Hashable, Sendable {
        var technicalIndicators: Int
        var newsSentiment: Int
        var fundamentals: Int
        var marketConditions: Int

        /// 归一化到总和 100（对拍 DSA normalize_report_signal_attribution）。
        var normalized: SignalAttribution {
            let total = technicalIndicators + newsSentiment + fundamentals + marketConditions
            guard total > 0 else {
                return SignalAttribution(technicalIndicators: 25, newsSentiment: 25, fundamentals: 25, marketConditions: 25)
            }
            func share(_ value: Int) -> Int { Int((Double(value) / Double(total) * 100).rounded()) }
            var result = SignalAttribution(
                technicalIndicators: share(technicalIndicators),
                newsSentiment: share(newsSentiment),
                fundamentals: share(fundamentals),
                marketConditions: share(marketConditions)
            )
            // 舍入误差补到技术面
            let drift = 100 - (result.technicalIndicators + result.newsSentiment + result.fundamentals + result.marketConditions)
            result.technicalIndicators += drift
            return result
        }
    }

    var subjectCode: String
    var subjectName: String
    var score: Int
    var action: CanonicalAction
    var confidence: DecisionConfidenceLevel
    var coreConclusion: String
    var noPositionAdvice: String
    var hasPositionAdvice: String
    var sniperPoints: SniperPoints
    var phaseDecision: PhaseDecision?
    var signalAttribution: SignalAttribution?
    var riskAlerts: [String]
    var positiveCatalysts: [String]
    var dataLimitations: [String]
    /// 是否为 LLM 失败后的确定性兜底产物
    var isDegradedFallback: Bool
    /// 护栏审计（M4 管线产物）
    var guardrailNotes: [String]
    var generatedAt: String
}

// MARK: - 流水线模式与上下文

/// 流水线模式（对拍 DSA 四档）。
enum MarketResearchPipelineMode: String, Codable, Hashable, Sendable, CaseIterable {
    case quick       // Technical → Decision（Technical 为确定性计算，quick 实际只 1 次 LLM）
    case standard    // Technical → Intel → Decision
    case full        // Technical → Intel → Risk → Decision
    case specialist  // full + 策略技能批评估

    var llmCallBudget: Int {
        switch self {
        case .quick: return 1
        case .standard: return 2
        case .full: return 3
        case .specialist: return 4
        }
    }
}

/// 流水线输入上下文（调用方预取的外部数据，结构化传递——不学 DSA 的 8000 字符截断注入）。
struct MarketResearchContext: Sendable {
    var subjectCode: String
    var subjectName: String
    var newsHeadlines: [String] = []
    var searchSnippets: [String] = []
    var explicitSkillIDs: [String] = []
    var historicalWinRateSummary: String?
    /// 阶段（默认按当前时间判定）
    var phase: MarketPhase = .unknown
}

// MARK: - 流水线结果

struct MarketResearchPipelineResult: Sendable {
    let dashboard: MarketDecisionDashboard
    let opinions: [AgentOpinion]
    let disagreement: OpinionDisagreementSummary
    let regime: MarketRegime
    let degradedStages: [String]
    let candidateSignal: MarketDecisionSignal
}

// MARK: - 流水线

/// 多 Agent 研究流水线。
///
/// 与 baseline 9.3 的关系：复用 `TrendResearchAgentClient`（OpenAI 兼容通道）与 L1/L2/L3/L4 成果，
/// 不重构 TrendResearchAgent。子 Agent 均为单发 LLM 调用（无工具循环）——
/// 技术面由 L2 引擎确定性产出（比 LLM 合成更准更省），情报/风险/决策为单发 JSON 调用。
///
/// 关键护栏链：Decision LLM → 风险否决单向状态机 → M4 护栏管线（结构稳定器 + 阶段 + 数据质量）。
/// Decision LLM 彻底失败 → 从 opinions 确定性组装保守仪表盘（LLM 挂了产品不挂）。
struct MarketResearchPipeline: Sendable {
    let client: any TrendResearchAgentClient
    let engine: MarketDataEngine
    let settings: TrendAIProviderSettings
    /// 阶段最小预算（秒）：不足时跳过非关键阶段
    static let minimumStageBudgetSeconds: Double = 15

    init(
        client: any TrendResearchAgentClient,
        engine: MarketDataEngine,
        settings: TrendAIProviderSettings
    ) {
        self.client = client
        self.engine = engine
        self.settings = settings
    }

    // MARK: - 主入口

    func run(
        context input: MarketResearchContext,
        mode: MarketResearchPipelineMode = .full,
        now: Date = Date()
    ) async -> MarketResearchPipelineResult {
        var context = input
        if context.phase == .unknown {
            context.phase = MarketPhase.current(now)
        }
        var degraded: [String] = []
        let started = Date()

        func remainingBudget() -> Double {
            settings.timeoutSeconds - Date().timeIntervalSince(started)
        }

        // Stage 1: Technical（确定性，零 LLM）——TA 结果直接包装为技术观点
        let technical = await runTechnicalStage(context: context)
        if technical == nil { degraded.append("technical") }
        let regime = technical.map { StrategySkillRouter.regime(from: $0) } ?? .sideways
        let technicalOpinion = technical.map { ta in
            AgentOpinion(
                agentName: .technical,
                subjectCode: context.subjectCode,
                signal: CanonicalScoreBand.band(forScore: ta.score).decisionType,
                confidence: min(max(Double(ta.score) / 100, 0), 1),
                reasoning: ta.evidenceSummary,
                keyLevels: AgentKeyLevels(
                    support: ta.support,
                    resistance: ta.resistance,
                    stopLoss: ta.support.map { $0 * 0.97 }
                ),
                technicalAnalysis: ta
            )
        }

        // Stage 2: Intel（LLM，非关键——失败降级继续）
        var intel: AgentOpinion?
        if mode != .quick, remainingBudget() >= Self.minimumStageBudgetSeconds {
            intel = try? await runIntelStage(context: context, technical: technical, subjectCode: context.subjectCode)
            if intel == nil { degraded.append("intel") }
        } else if mode != .quick {
            degraded.append("intel(budgetSkip)")
        }

        // Stage 3: Risk（LLM，非关键）
        var riskOpinion: AgentOpinion?
        if mode == .full || mode == .specialist, remainingBudget() >= Self.minimumStageBudgetSeconds {
            riskOpinion = try? await runRiskStage(context: context, technical: technical, intel: intel)
            if riskOpinion == nil { degraded.append("risk") }
        } else if mode == .full || mode == .specialist {
            degraded.append("risk(budgetSkip)")
        }

        // Specialist: 策略技能批评估（单次 LLM 评估全部激活技能，对拍技能子 Agent 的轻量替代）
        var skillOpinions: [AgentOpinion] = []
        if mode == .specialist, remainingBudget() >= Self.minimumStageBudgetSeconds {
            skillOpinions = (try? await runSkillStage(context: context, technical: technical, regime: regime)) ?? []
            if skillOpinions.isEmpty { degraded.append("skills") }
        } else if mode == .specialist {
            degraded.append("skills(budgetSkip)")
        }

        let opinions = [technicalOpinion, intel, riskOpinion].compactMap { $0 } + skillOpinions
        let disagreement = OpinionDisagreementSummary(opinions: opinions)

        // Stage 4: Decision（LLM，关键——失败走确定性兜底）
        let riskFlags = (riskOpinion?.riskFlags ?? []) + skillOpinions.flatMap { $0.riskFlags ?? [] }
        var dashboard: MarketDecisionDashboard
        if remainingBudget() > 0,
           let llmDashboard = try? await runDecisionStage(
               context: context,
               opinions: opinions,
               disagreement: disagreement,
               riskFlags: riskFlags,
               technical: technical,
               regime: regime,
               now: now
           ) {
            dashboard = llmDashboard
        } else {
            dashboard = Self.fallbackDashboard(
                context: context,
                opinions: opinions,
                riskFlags: riskFlags,
                technical: technical,
                now: now
            )
            degraded.append("decision(fallback)")
        }

        // 护栏链：风险否决（单向）→ M4 管线
        let (riskAdjustedAction, applied, note) = RiskOverrideStateMachine.applyRiskOverride(
            action: dashboard.action,
            riskFlags: riskFlags
        )
        if applied {
            dashboard.action = riskAdjustedAction
            dashboard.guardrailNotes.append(note ?? "风控接管")
        }
        let technicalTA = technical
        let quoteStatuses: [DataQualityStatus] = technicalTA == nil ? [.missing] : [.ok]
        let guarded = DecisionGuardrailPipeline.apply(
            DecisionGuardrailPipeline.Input(
                score: dashboard.score,
                action: dashboard.action,
                confidence: dashboard.confidence,
                price: technicalTA?.close,
                support: technicalTA?.support,
                resistance: technicalTA?.resistance,
                capitalFlow: .unavailable,
                phase: context.phase,
                coreDataStatuses: quoteStatuses
            )
        )
        dashboard.score = guarded.score
        dashboard.action = guarded.action
        dashboard.confidence = guarded.confidence
        dashboard.guardrailNotes += guarded.guardrailNotes
        if guarded.calibration.adjustedScore != guarded.calibration.rawScore || !guarded.calibration.guardrailReasons.isEmpty {
            dashboard.dataLimitations.append(
                "分数校准：raw \(guarded.calibration.rawScore) → \(guarded.calibration.adjustedScore)"
            )
        }

        let signal = Self.candidateSignal(from: dashboard, now: now)
        return MarketResearchPipelineResult(
            dashboard: dashboard,
            opinions: opinions,
            disagreement: disagreement,
            regime: regime,
            degradedStages: degraded,
            candidateSignal: signal
        )
    }

    // MARK: - Stage 1: Technical（确定性）

    private func runTechnicalStage(context: MarketResearchContext) async -> TechnicalAnalysisResult? {
        guard let bars = try? await engine.dailyBars(code: context.subjectCode, days: 120) else { return nil }
        return TechnicalAnalysisEngine.analyze(code: context.subjectCode, bars: bars)
    }

    // MARK: - Stage 2: Intel

    private func runIntelStage(
        context: MarketResearchContext,
        technical: TechnicalAnalysisResult?,
        subjectCode: String
    ) async throws -> AgentOpinion {
        var contextBlock = ""
        if let technical {
            contextBlock += "技术面：\(technical.evidenceSummary)；支撑 \(technical.support.map { String(format: "%.2f", $0) } ?? "无")/压力 \(technical.resistance.map { String(format: "%.2f", $0) } ?? "无")。\n"
        }
        if !context.newsHeadlines.isEmpty {
            contextBlock += "\n近期热榜标题（每条必须带来源日期，无日期注明未知）：\n" + context.newsHeadlines.prefix(10).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !context.searchSnippets.isEmpty {
            contextBlock += "\n搜索摘要片段：\n" + context.searchSnippets.prefix(8).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if contextBlock.isEmpty {
            contextBlock = "（无可用情报数据——输出 insufficient-data 语义，signal 用 hold，confidence ≤ 0.4）\n"
        }

        let system = """
        你是一名投资情报分析 Agent。基于提供的技术面与新闻情报，输出标的级情报观点。
        规则：
        - 输出纯 JSON（无 markdown 代码块），字段：signal(buy/hold/sell)、confidence(0-1)、reasoning(≤120字)、risk_alerts(数组,每条带YYYY-MM-DD日期,无日期忽略)、positive_catalysts(同上)
        - 新闻时间硬约束：超出近 14 天或日期未知的一律忽略，不得编造
        - 无情报数据时 signal=hold 且 confidence≤0.4，reasoning 写「情报数据缺失」
        - 只输出 JSON
        """
        let user = "标的：\(context.subjectName)（\(subjectCode)）\n\n\(contextBlock)"
        let json = try await singleShotJSON(system: system, user: user)
        let signal = string(json["signal"]) ?? "hold"
        let confidence = double(json["confidence"]) ?? 0.5
        return AgentOpinion(
            agentName: .intel,
            subjectCode: subjectCode,
            signal: CanonicalDecisionType(rawValue: signal) ?? .hold,
            confidence: confidence,
            reasoning: string(json["reasoning"]) ?? "情报观点解析失败",
            riskFlags: (json["risk_alerts"] as? [Any])?.compactMap { $0 as? String }.map { text in
                AgentRiskFlag(kind: "情报风险", severity: .medium, note: text)
            }
        )
    }

    // MARK: - Stage 3: Risk

    private func runRiskStage(
        context: MarketResearchContext,
        technical: TechnicalAnalysisResult?,
        intel: AgentOpinion?
    ) async throws -> AgentOpinion {
        var contextBlock = ""
        if let technical {
            contextBlock += "技术面：\(technical.evidenceSummary)。破位判定：\(technical.maAlignment?.displayName ?? "未知")。\n"
        }
        if let intel {
            contextBlock += "情报观点：\(intel.reasoning)\n"
        }
        if !context.newsHeadlines.isEmpty {
            contextBlock += "热榜：\n" + context.newsHeadlines.prefix(6).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !context.searchSnippets.isEmpty {
            contextBlock += "搜索片段：\n" + context.searchSnippets.prefix(6).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }

        let system = """
        你是一名风险管理 Agent，做 7 项强制风险检查：减持公告、业绩预亏、监管处罚、行业政策利空、30 天内解禁、估值过高、技术破位。
        规则：
        - 只报告有证据支撑的风险，不发明风险（Only flag risks backed by evidence. Do NOT invent risks）
        - 无数据支撑的检查项输出 unknown，不算风险
        - 输出纯 JSON：{ "signal": buy/hold/sell, "confidence": 0-1, "reasoning": "≤120字", "risk_flags": [ { "kind": "...", "severity": high/medium/low, "note": "带日期说明", "veto_buy": true/false, "adjustment": none/downgrade_one/downgrade_two/veto } ] }
        - severity=high 且确凿才允许 veto_buy=true
        """
        let user = "标的：\(context.subjectName)（\(context.subjectCode)）\n\n\(contextBlock.isEmpty ? "（无附加上下文，基于常识性检查框架输出 unknown 为主）" : contextBlock)"
        let json = try await singleShotJSON(system: system, user: user)

        var flags: [AgentRiskFlag] = []
        if let flagRows = json["risk_flags"] as? [[String: Any]] {
            for row in flagRows {
                let severityRaw = string(row["severity"]) ?? "low"
                let severity = AgentRiskFlag.Severity(rawValue: severityRaw) ?? .low
                let adjustmentRaw = string(row["adjustment"]) ?? "none"
                let adjustment = AgentRiskFlag.Adjustment(rawValue: adjustmentRaw) ?? .none
                flags.append(AgentRiskFlag(
                    kind: string(row["kind"]) ?? "未分类风险",
                    severity: severity,
                    note: string(row["note"]) ?? "",
                    vetoBuy: row["veto_buy"] as? Bool ?? false,
                    adjustment: adjustment
                ))
            }
        }
        // 技术破位是确定性检查（不依赖 LLM 自觉）
        if let technical, technical.maAlignment == .strongBear || technical.maAlignment == .bear {
            flags.append(AgentRiskFlag(kind: "技术破位", severity: .medium, note: "均线\(technical.maAlignment?.displayName ?? "空头")", adjustment: .downgradeOne))
        }

        return AgentOpinion(
            agentName: .risk,
            subjectCode: context.subjectCode,
            signal: CanonicalDecisionType(rawValue: string(json["signal"]) ?? "hold") ?? .hold,
            confidence: double(json["confidence"]) ?? 0.5,
            reasoning: string(json["reasoning"]) ?? "风险检查解析失败",
            riskFlags: flags
        )
    }

    // MARK: - Specialist: 技能批评估

    private func runSkillStage(
        context: MarketResearchContext,
        technical: TechnicalAnalysisResult?,
        regime: MarketRegime
    ) async throws -> [AgentOpinion] {
        let skills: [StrategySkill]
        if !context.explicitSkillIDs.isEmpty {
            skills = context.explicitSkillIDs.compactMap { StrategySkillLibrary.skill(id: $0) }
        } else {
            skills = Array(StrategySkillRouter.suggestedSkills(for: regime).prefix(3))
        }
        guard !skills.isEmpty else { return [] }

        var contextBlock = technical.map { "技术面：\($0.evidenceSummary)；支撑 \($0.support ?? 0)；压力 \($0.resistance ?? 0)" } ?? "技术面数据缺失"
        contextBlock += "\n当前市场状态判定：\(regime.displayName)"

        let system = """
        你是策略技能评估器。对下列每个策略技能，基于技术面数据判断其触发条件是否满足。
        输出纯 JSON：{ "evaluations": [ { "skill_id": "...", "signal": buy/hold/sell, "confidence": 0-1, "conditions_met": ["..."], "conditions_missed": ["..."], "reasoning": "≤80字" } ] }
        只评估给定技能，不新增；条件不满足时 signal=hold。
        """
        let user = """
        标的：\(context.subjectName)（\(context.subjectCode)）
        \(contextBlock)

        技能清单与指令：
        \(StrategySkillInjector.renderSkills(skills, header: "## 待评估技能"))
        """
        let json = try await singleShotJSON(system: system, user: user)
        guard let rows = json["evaluations"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let skillID = string(row["skill_id"]) ?? ""
            guard skills.contains(where: { $0.id == skillID }) else { return nil }
            return AgentOpinion(
                agentName: .decision, // 技能观点挂 decision 名下会被排除出 disagreement？不——技能观点独立命名
                subjectCode: context.subjectCode,
                signal: CanonicalDecisionType(rawValue: string(row["signal"]) ?? "hold") ?? .hold,
                confidence: double(row["confidence"]) ?? 0.5,
                reasoning: "技能[\(skillID)]：" + (string(row["reasoning"]) ?? "")
            )
        }
    }

    // MARK: - Stage 4: Decision

    private func runDecisionStage(
        context: MarketResearchContext,
        opinions: [AgentOpinion],
        disagreement: OpinionDisagreementSummary,
        riskFlags: [AgentRiskFlag],
        technical: TechnicalAnalysisResult?,
        regime: MarketRegime,
        now: Date
    ) async throws -> MarketDecisionDashboard {
        var evidenceChain = ""
        for opinion in opinions where opinion.agentName != .decision {
            evidenceChain += "### \(opinion.agentName.rawValue) / signal=\(opinion.signal.rawValue) / confidence=\(String(format: "%.2f", opinion.confidence))\n\(opinion.reasoning)\n"
            if let levels = opinion.keyLevels {
                evidenceChain += "key_levels: support=\(levels.support.map { String($0) } ?? "-") resistance=\(levels.resistance.map { String($0) } ?? "-")\n"
            }
        }
        if !riskFlags.isEmpty {
            evidenceChain += "\n### 风险项\n" + riskFlags.map { "- [\($0.severity.rawValue)] \($0.kind)：\($0.note)" }.joined(separator: "\n") + "\n"
        }
        if let winRate = context.historicalWinRateSummary {
            evidenceChain += "\n### 历史校准\n\(winRate)\n"
        }

        let system = """
        你是决策合成 Agent（零工具，纯综合）。权重指南：technical ~40% / intel ~30% / risk ~30%（任一 high 风险把信号封顶为 hold/watch）；技能观点合计 ~20%。分数与动作必须自洽：80-100 买入带、60-79 买入/加仓、40-59 观望、20-39 减仓、0-19 卖出。
        铁律：
        - 禁止因单日涨跌在买卖间剧烈切换；支撑压力之间资金不明时给中性建议
        - \(context.phase.behaviorConstraints.joined(separator: "；"))
        - 每条 risk_alerts/catalysts 必须带 YYYY-MM-DD，未知或超窗忽略
        - 狙击点必须给具体价格（基于支撑/压力），不能只写方向
        - 数据缺失写「数据缺失，无法判断」，禁止编造
        输出纯 JSON：{"score":0-100,"action":"buy/add/hold/reduce/sell/watch/avoid","confidence":"high/medium/low","core_conclusion":"≤40字","no_position_advice":"空仓者建议","has_position_advice":"持仓者建议","sniper":{"ideal_buy":数字,"secondary_buy":数字,"stop_loss":数字,"take_profit":数字},"phase_decision":{"action_window":"...","immediate_action":"...","watch_conditions":["..."],"next_check_time":"yyyy-MM-dd HH:mm"},"attribution":{"technical":0-100,"news":0-100,"fundamentals":0-100,"market":0-100},"risk_alerts":["..."],"positive_catalysts":["..."],"data_limitations":["..."]}
        """
        let user = """
        标的：\(context.subjectName)（\(context.subjectCode)）；市场状态：\(regime.displayName)；阶段：\(context.phase.displayName)
        分歧摘要：\(disagreement.summaryText)

        ## 证据链
        \(evidenceChain.isEmpty ? "（无子 Agent 观点——输出保守观望）" : evidenceChain)
        """
        let json = try await singleShotJSON(system: system, user: user)

        let score = Int(double(json["score"]) ?? 50)
        let actionRaw = string(json["action"]) ?? "watch"
        let action = CanonicalAction(rawValue: actionRaw) ?? .watch
        let confidenceRaw = string(json["confidence"]) ?? "medium"
        let confidence = DecisionConfidenceLevel(rawValue: confidenceRaw) ?? .medium
        var sniper = MarketDecisionDashboard.SniperPoints()
        if let sniperJSON = json["sniper"] as? [String: Any] {
            sniper.idealBuy = double(sniperJSON["ideal_buy"])
            sniper.secondaryBuy = double(sniperJSON["secondary_buy"])
            sniper.stopLoss = double(sniperJSON["stop_loss"])
            sniper.takeProfit = double(sniperJSON["take_profit"])
        }
        var phase: MarketDecisionDashboard.PhaseDecision?
        if let phaseJSON = json["phase_decision"] as? [String: Any] {
            phase = MarketDecisionDashboard.PhaseDecision(
                actionWindow: string(phaseJSON["action_window"]) ?? "",
                immediateAction: string(phaseJSON["immediate_action"]) ?? "",
                watchConditions: (phaseJSON["watch_conditions"] as? [Any])?.compactMap { $0 as? String } ?? [],
                nextCheckTime: string(phaseJSON["next_check_time"]) ?? ""
            )
        }
        var attribution: MarketDecisionDashboard.SignalAttribution?
        if let attrJSON = json["attribution"] as? [String: Any] {
            attribution = MarketDecisionDashboard.SignalAttribution(
                technicalIndicators: Int(double(attrJSON["technical"]) ?? 0),
                newsSentiment: Int(double(attrJSON["news"]) ?? 0),
                fundamentals: Int(double(attrJSON["fundamentals"]) ?? 0),
                marketConditions: Int(double(attrJSON["market"]) ?? 0)
            ).normalized
        }

        return MarketDecisionDashboard(
            subjectCode: context.subjectCode,
            subjectName: context.subjectName,
            score: min(max(score, 0), 100),
            action: action,
            confidence: confidence,
            coreConclusion: string(json["core_conclusion"]) ?? "",
            noPositionAdvice: string(json["no_position_advice"]) ?? "",
            hasPositionAdvice: string(json["has_position_advice"]) ?? "",
            sniperPoints: sniper,
            phaseDecision: phase,
            signalAttribution: attribution,
            riskAlerts: (json["risk_alerts"] as? [Any])?.compactMap { $0 as? String } ?? [],
            positiveCatalysts: (json["positive_catalysts"] as? [Any])?.compactMap { $0 as? String } ?? [],
            dataLimitations: (json["data_limitations"] as? [Any])?.compactMap { $0 as? String } ?? [],
            isDegradedFallback: false,
            guardrailNotes: [],
            generatedAt: Self.timestamp(now)
        )
    }

    // MARK: - 确定性兜底

    /// Decision LLM 失败时从 opinions 代码侧组装保守仪表盘（对拍 DSA _prepare_dashboard_payload）。
    static func fallbackDashboard(
        context: MarketResearchContext,
        opinions: [AgentOpinion],
        riskFlags: [AgentRiskFlag],
        technical: TechnicalAnalysisResult?,
        now: Date
    ) -> MarketDecisionDashboard {
        // 多数决 + 平均置信度 × 0.6（降级打折）
        let directional = opinions.filter { $0.agentName != .decision && $0.signal != .hold }
        var signal: CanonicalDecisionType
        if directional.isEmpty {
            signal = .hold
        } else {
            let buys = directional.filter { $0.signal == .buy }.count
            let sells = directional.filter { $0.signal == .sell }.count
            signal = buys > sells ? .buy : sells > buys ? .sell : .hold
        }
        let avgConfidence = directional.isEmpty
            ? 0.4
            : directional.map(\.confidence).reduce(0, +) / Double(directional.count)
        let anyHighRisk = riskFlags.contains { $0.severity == .high }
        if anyHighRisk && signal == .buy { signal = .hold }

        let score = signal == .buy ? 55 : signal == .sell ? 35 : 45
        let action: CanonicalAction = signal == .buy ? .watch : signal == .sell ? .reduce : .watch

        return MarketDecisionDashboard(
            subjectCode: context.subjectCode,
            subjectName: context.subjectName,
            score: score,
            action: action,
            confidence: avgConfidence * 0.6 >= 0.6 ? .medium : .low,
            coreConclusion: "降级生成：模型合成不可用，按子观点多数决输出保守结论",
            noPositionAdvice: "观望为主，等待模型服务恢复后重跑",
            hasPositionAdvice: signal == .sell ? "评估减仓，注意风险项" : "持有观察，不追加",
            sniperPoints: MarketDecisionDashboard.SniperPoints(
                idealBuy: technical?.support,
                secondaryBuy: technical?.ma10,
                stopLoss: technical?.support.map { $0 * 0.97 },
                takeProfit: technical?.resistance
            ),
            phaseDecision: nil,
            signalAttribution: nil,
            riskAlerts: riskFlags.map { "[\($0.severity.rawValue)] \($0.kind)：\($0.note)" },
            positiveCatalysts: [],
            dataLimitations: ["决策合成为确定性兜底产物（isDegradedFallback）"],
            isDegradedFallback: true,
            guardrailNotes: ["兜底仪表盘：LLM 决策合成失败，按规则组装"],
            generatedAt: timestamp(now)
        )
    }

    // MARK: - 信号抽取（pipeline 源）

    /// 仪表盘 → 候选信号（M5 sourceKind.pipeline）。
    static func candidateSignal(from dashboard: MarketDecisionDashboard, now: Date) -> MarketDecisionSignal {
        let created = timestamp(now)
        let reviewDays = dashboard.action.decisionType == .hold ? 7 : 3
        let conditions = SignalPriceConditions(
            entryLow: dashboard.sniperPoints.idealBuy.map { $0 * 0.99 },
            entryHigh: dashboard.sniperPoints.idealBuy.map { $0 * 1.01 },
            stopLoss: dashboard.sniperPoints.stopLoss,
            targetPrice: dashboard.sniperPoints.takeProfit,
            parseNotes: ["仪表盘狙击点直填"]
        )
        return MarketDecisionSignal(
            dedupKey: "pipeline|\(dashboard.subjectCode)|\(dashboard.generatedAt.prefix(10))",
            sourceKind: .pipeline,
            sourceActionID: "pipeline-\(dashboard.generatedAt)",
            subjectCode: dashboard.subjectCode,
            subjectName: dashboard.subjectName,
            marketSettleable: conditions.isSettleable,
            direction: dashboard.action.decisionType,
            action: dashboard.action,
            score: dashboard.score,
            rawConfidence: dashboard.confidence.numericValue,
            priceConditions: conditions,
            watchConditions: dashboard.phaseDecision?.watchConditions ?? [],
            invalidatingConditions: [],
            reason: dashboard.coreConclusion,
            evidenceIDs: [],
            dataQualitySummary: dashboard.isDegradedFallback ? "兜底产物，置信度打折" : "流水线仪表盘",
            createdAt: created,
            reviewDueAt: timestamp(now.addingTimeInterval(Double(reviewDays * 86_400))),
            events: [SignalEvent(at: created, type: .created, reason: "从研究流水线仪表盘抽取")]
        )
    }

    // MARK: - LLM 单发调用

    private func singleShotJSON(system: String, user: String) async throws -> [String: Any] {
        let result = try await client.complete(
            messages: [
                AgentChatMessage(role: .system, content: system),
                AgentChatMessage(role: .user, content: user),
            ],
            tools: [],
            toolChoice: .auto,
            temperature: 0.3,
            maxOutputTokens: nil,
            settings: settings,
            timeout: settings.timeoutSeconds,
            deadline: nil,
            streamProgress: nil
        )
        let text = result.assistantMessage.content ?? ""
        guard let object = Self.parseJSONobject(text) else {
            throw TrendResearchAgentError.missingToolCalls
        }
        return object
    }

    /// 文本 → JSON 对象（markdown fence / 首尾大括号兜底，对拍 DSA 四级解析的精简版）。
    static func parseJSONobject(_ text: String) -> [String: Any]? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = candidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        if let first = candidate.firstIndex(of: "{"), let last = candidate.lastIndex(of: "}"), first < last {
            let inner = String(candidate[first...last])
            if let data = inner.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
