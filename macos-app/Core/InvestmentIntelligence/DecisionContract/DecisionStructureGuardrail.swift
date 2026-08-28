import Foundation

// MARK: - 输入

/// 资金流方向信号（缺省 unavailable，不编造）。
enum CapitalFlowSignal: String, Codable, Hashable, Sendable {
    case inflow
    case outflow
    case neutral
    case unavailable

    var displayName: String {
        switch self {
        case .inflow: return "净流入"
        case .outflow: return "净流出"
        case .neutral: return "均衡"
        case .unavailable: return "不可用"
        }
    }
}

/// 价格相对支撑/压力的位置区间（容差带对拍 DSA `stabilize_decision_with_structure`）。
enum PricePositionZone: String, Codable, Hashable, Sendable {
    case brokeSupport      // < 0.985 × support
    case nearSupport       // ≤ 1.03 × support
    case breakout          // > 1.01 × resistance
    case nearResistance    // ≥ 0.97 × resistance
    case midRange
    case unknown

    var displayName: String {
        switch self {
        case .brokeSupport: return "跌破支撑"
        case .nearSupport: return "贴近支撑"
        case .breakout: return "突破压力"
        case .nearResistance: return "贴近压力"
        case .midRange: return "区间中部"
        case .unknown: return "位置未知"
        }
    }

    static func zone(price: Double?, support: Double?, resistance: Double?) -> PricePositionZone {
        guard let price, price > 0 else { return .unknown }
        if let support, support > 0 {
            if price < support * 0.985 { return .brokeSupport }
            if price <= support * 1.03 { return .nearSupport }
        }
        if let resistance, resistance > 0 {
            if price > resistance * 1.01 { return .breakout }
            if price >= resistance * 0.97 { return .nearResistance }
        }
        if support == nil && resistance == nil { return .unknown }
        return .midRange
    }
}

// MARK: - 输出

/// 护栏后的决策。
struct GuardedDecision: Codable, Hashable, Sendable {
    var score: Int
    var action: CanonicalAction
    var decisionType: CanonicalDecisionType
    var confidence: DecisionConfidenceLevel
    var calibration: DecisionScoreCalibration
    /// 护栏后追加的行为提示（进 prompt/报告的「为什么被调整」）。
    var guardrailNotes: [String]

    init(
        score: Int,
        action: CanonicalAction,
        confidence: DecisionConfidenceLevel,
        calibration: DecisionScoreCalibration,
        guardrailNotes: [String] = []
    ) {
        self.score = score
        self.action = action
        self.decisionType = action.decisionType
        self.confidence = confidence
        self.calibration = calibration
        self.guardrailNotes = guardrailNotes
    }
}

// MARK: - 单向保守转移校验

/// 护栏降级只允许「更保守」方向的单向转移（对拍 DSA `risk_override.py` 的转换合法性校验）。
/// 保守序：buy < add < hold < watch < reduce < sell < avoid。
enum DecisionActionTransition {
    static let conservatismOrder: [CanonicalAction] = [.buy, .add, .hold, .watch, .reduce, .sell, .avoid]

    static func isMoreConservative(from: CanonicalAction, to: CanonicalAction) -> Bool {
        guard let fromIndex = conservatismOrder.firstIndex(of: from),
              let toIndex = conservatismOrder.firstIndex(of: to) else { return false }
        return toIndex > fromIndex
    }
}

// MARK: - 结构稳定器

/// LLM 后确定性护栏（结构稳定器）：按支撑/压力几何关系 + 资金流方向，
/// 强制把过度激进的 buy/sell 降级为 hold/watch。
///
/// 动机（对拍 DSA `analyzer.py:1000` docstring）：LLM 会对单日涨跌过度反应。
/// 降级矩阵（全部单向保守，经转移合法性校验）：
/// - buy + 贴近压力 + 资金非流入 → hold
/// - buy + 区间中部 + 资金均衡 → hold
/// - buy + 资金流出且未突破 → hold
/// - buy + 资金不可用 → hold（「买入缺资金面确认，先观察」）
/// - sell + 贴近支撑 + 资金非流出且无重大风险 → hold（洗盘观察）
/// - sell + 资金流入且未破位 → hold
/// 降级时分数钳制到 45-59 观望带，raw/adjusted/reason 落审计字段。
enum DecisionStructureGuardrail {
    static let watchBand = 45...59

    struct Input {
        var score: Int
        var action: CanonicalAction
        var confidence: DecisionConfidenceLevel
        var price: Double?
        var support: Double?
        var resistance: Double?
        var capitalFlow: CapitalFlowSignal
        var hasMajorRisk: Bool = false

        init(
            score: Int,
            action: CanonicalAction,
            confidence: DecisionConfidenceLevel,
            price: Double?,
            support: Double?,
            resistance: Double?,
            capitalFlow: CapitalFlowSignal,
            hasMajorRisk: Bool = false
        ) {
            self.score = score
            self.action = action
            self.confidence = confidence
            self.price = price
            self.support = support
            self.resistance = resistance
            self.capitalFlow = capitalFlow
            self.hasMajorRisk = hasMajorRisk
        }
    }

    static func apply(_ input: Input) -> GuardedDecision {
        var score = min(max(input.score, 0), 100)
        var action = input.action
        var reasons: [String] = []
        let zone = PricePositionZone.zone(price: input.price, support: input.support, resistance: input.resistance)
        let structureText = "位置:\(zone.displayName)（支撑\(input.support.map { String(format: "%.2f", $0) } ?? "无")/压力\(input.resistance.map { String(format: "%.2f", $0) } ?? "无")）；资金:\(input.capitalFlow.displayName)"

        // 分数-行动先对齐（模型自相矛盾在这里先修）
        let aligned = CanonicalDecisionScale.alignAction(score: score, declared: action)
        action = aligned.action
        if aligned.adjusted, let reason = aligned.reason {
            reasons.append(reason)
        }

        var downgraded = false
        switch action {
        case .buy, .add:
            let bullish = action == .buy
            if bullish {
                if zone == .nearResistance && input.capitalFlow != .inflow {
                    downgraded = true
                    reasons.append("接近压力位且资金面未确认流入，追买风险高，降级观望")
                } else if zone == .midRange && input.capitalFlow == .neutral {
                    downgraded = true
                    reasons.append("区间中部且资金均衡，缺乏方向确认，降级观望")
                } else if input.capitalFlow == .outflow && zone != .breakout {
                    downgraded = true
                    reasons.append("主力资金流出且未有效突破，买入结论降级观望")
                } else if input.capitalFlow == .unavailable {
                    downgraded = true
                    reasons.append("买入结论缺少资金面确认，先按观察处理")
                }
            }
        case .sell, .reduce, .avoid:
            if action == .sell {
                if zone == .nearSupport && input.capitalFlow != .outflow && !input.hasMajorRisk {
                    downgraded = true
                    reasons.append("贴近支撑且资金未持续流出，按洗盘观察处理，不急于杀跌")
                } else if input.capitalFlow == .inflow && zone != .brokeSupport {
                    downgraded = true
                    reasons.append("资金净流入且未跌破关键支撑，卖出结论降级观望")
                }
            }
        case .hold, .watch, .alert:
            break
        }

        if downgraded {
            // 反过度反应稳定：激进行动一律拉回观望带（buy→watch / sell→watch 都朝中性收敛）。
            // 注意与风险否决（RiskOverrideStateMachine，M8）区分：那边才是「只许更保守」的单向状态机。
            action = .watch
            score = min(max(score, watchBand.lowerBound), watchBand.upperBound)
        }

        let calibration = DecisionScoreCalibration(
            rawScore: input.score,
            adjustedScore: score,
            guardrailReasons: reasons,
            structureSnapshot: reasons.isEmpty ? structureText : structureText
        )
        return GuardedDecision(
            score: score,
            action: action,
            confidence: input.confidence,
            calibration: calibration,
            guardrailNotes: reasons
        )
    }
}

// MARK: - 阶段护栏 + 数据质量封顶的合成管线

/// 护栏管线：结构稳定器 → 市场阶段护栏 → 数据质量置信度封顶。
/// 纯函数，供 L7 决策合成与信号抽取复用。
enum DecisionGuardrailPipeline {
    struct Input {
        var score: Int
        var action: CanonicalAction
        var confidence: DecisionConfidenceLevel
        var price: Double?
        var support: Double?
        var resistance: Double?
        var capitalFlow: CapitalFlowSignal
        var hasMajorRisk: Bool = false
        var phase: MarketPhase
        var coreDataStatuses: [DataQualityStatus] = []

        init(
            score: Int,
            action: CanonicalAction,
            confidence: DecisionConfidenceLevel,
            price: Double?,
            support: Double?,
            resistance: Double?,
            capitalFlow: CapitalFlowSignal,
            hasMajorRisk: Bool = false,
            phase: MarketPhase,
            coreDataStatuses: [DataQualityStatus] = []
        ) {
            self.score = score
            self.action = action
            self.confidence = confidence
            self.price = price
            self.support = support
            self.resistance = resistance
            self.capitalFlow = capitalFlow
            self.hasMajorRisk = hasMajorRisk
            self.phase = phase
            self.coreDataStatuses = coreDataStatuses
        }
    }

    static func apply(_ input: Input) -> GuardedDecision {
        // 1) 结构稳定器
        var decision = DecisionStructureGuardrail.apply(
            DecisionStructureGuardrail.Input(
                score: input.score,
                action: input.action,
                confidence: input.confidence,
                price: input.price,
                support: input.support,
                resistance: input.resistance,
                capitalFlow: input.capitalFlow,
                hasMajorRisk: input.hasMajorRisk
            )
        )

        // 2) 市场阶段护栏：不允许立即交易行动的阶段强制「等待」并降置信
        if !input.phase.allowsImmediateTradeActions {
            switch decision.action {
            case .buy, .add, .sell, .reduce:
                decision.guardrailNotes.append("阶段护栏：\(input.phase.displayName)不支持立即交易行动，改为观望并等待\(input.phase == .nonTrading ? "下一交易日" : "开盘")确认")
                decision.action = .watch
                decision.decisionType = .hold
                decision.score = min(max(decision.score, 45), 59)
                decision.calibration.adjustedScore = decision.score
                decision.calibration.guardrailReasons.append("阶段护栏（\(input.phase.displayName)）触发降级")
                decision.confidence = decision.confidence.capped(at: .low)
            case .hold, .watch, .avoid, .alert:
                break
            }
        }

        // 3) 数据质量置信度封顶
        let ceiling = DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: input.coreDataStatuses)
        let capped = decision.confidence.capped(at: ceiling)
        if capped != decision.confidence {
            decision.guardrailNotes.append("数据质量护栏：核心数据降级（\(input.coreDataStatuses.filter(\.isDegraded).map(\.displayName).joined(separator: "、"))），置信度封顶\(ceiling.displayName)")
            decision.confidence = capped
        }

        return decision
    }
}
