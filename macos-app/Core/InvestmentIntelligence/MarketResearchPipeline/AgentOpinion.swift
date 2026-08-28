import Foundation

// MARK: - 子 Agent 观点契约

/// 子 Agent 关键价位。
struct AgentKeyLevels: Codable, Hashable, Sendable {
    var support: Double?
    var resistance: Double?
    var stopLoss: Double?

    init(support: Double? = nil, resistance: Double? = nil, stopLoss: Double? = nil) {
        self.support = support
        self.resistance = resistance
        self.stopLoss = stopLoss
    }
}

/// 风险项（RiskAgent / IntelAgent 产出）。
struct AgentRiskFlag: Codable, Hashable, Sendable {
    enum Severity: String, Codable, Hashable, Sendable {
        case high, medium, low
    }

    /// 调整动作：none 不动 / downgradeOne 降一档 / downgradeTwo 降两档 / veto 否决到观望
    enum Adjustment: String, Codable, Hashable, Sendable {
        case none, downgradeOne, downgradeTwo, veto
    }

    var kind: String          // 减持/业绩预亏/监管处罚/行业政策/解禁/估值过高/技术破位/其他
    var severity: Severity
    var note: String
    var vetoBuy: Bool
    var adjustment: Adjustment

    init(kind: String, severity: Severity, note: String, vetoBuy: Bool = false, adjustment: Adjustment = .none) {
        self.kind = kind
        self.severity = severity
        self.note = note
        self.vetoBuy = vetoBuy
        self.adjustment = adjustment
    }
}

/// 子 Agent 结构化观点（统一契约，决策合成消费）。
/// confidence 在构造时钳制到 0-1 并记录输入是否合法（对拍 DSA AgentOpinion）。
struct AgentOpinion: Codable, Hashable, Sendable, Identifiable {
    enum AgentName: String, Codable, Hashable, Sendable {
        case technical
        case intel
        case risk
        case decision
    }

    var id: String { "\(agentName)-\(subjectCode)" }
    let agentName: AgentName
    let subjectCode: String
    let signal: CanonicalDecisionType
    let confidence: Double
    /// 原始 confidence 是否合法（越界/NaN 被钳制过）
    let confidenceWasValid: Bool
    let reasoning: String
    var keyLevels: AgentKeyLevels?
    var riskFlags: [AgentRiskFlag]?
    /// 技术面细节（Technical 观点附带）
    var technicalAnalysis: TechnicalAnalysisResult?

    init(
        agentName: AgentName,
        subjectCode: String,
        signal: CanonicalDecisionType,
        confidence: Double,
        reasoning: String,
        keyLevels: AgentKeyLevels? = nil,
        riskFlags: [AgentRiskFlag]? = nil,
        technicalAnalysis: TechnicalAnalysisResult? = nil
    ) {
        self.agentName = agentName
        self.subjectCode = subjectCode
        self.signal = signal
        let valid = confidence.isFinite && confidence >= 0 && confidence <= 1
        self.confidence = valid ? confidence : min(max(confidence.isFinite ? confidence : 0.5, 0), 1)
        self.confidenceWasValid = valid
        self.reasoning = reasoning
        self.keyLevels = keyLevels
        self.riskFlags = riskFlags
        self.technicalAnalysis = technicalAnalysis
    }
}

// MARK: - 分歧摘要

/// 观点分歧摘要（注入决策合成 prompt，对拍 DSA disagreement.py 的分桶）。
struct OpinionDisagreementSummary: Codable, Hashable, Sendable {
    var bullishAgents: [String]
    var bearishAgents: [String]
    var neutralAgents: [String]

    init(opinions: [AgentOpinion]) {
        bullishAgents = opinions.filter { $0.signal == .buy && $0.agentName != .decision }.map(\.agentName.rawValue)
        bearishAgents = opinions.filter { $0.signal == .sell && $0.agentName != .decision }.map(\.agentName.rawValue)
        neutralAgents = opinions.filter { $0.signal == .hold && $0.agentName != .decision }.map(\.agentName.rawValue)
    }

    var isSplit: Bool {
        !bullishAgents.isEmpty && !bearishAgents.isEmpty
    }

    var summaryText: String {
        if isSplit {
            return "观点分歧：看多(\(bullishAgents.joined(separator: "、"))) vs 看空(\(bearishAgents.joined(separator: "、")))；决策时必须解释取舍依据。"
        }
        if !bullishAgents.isEmpty { return "观点一致偏多（\(bullishAgents.count) 个子 Agent）。" }
        if !bearishAgents.isEmpty { return "观点一致偏空（\(bearishAgents.count) 个子 Agent）。" }
        return "子 Agent 均为中性观望。"
    }
}

// MARK: - 风险否决单向状态机

/// 风险否决只允许「更保守」方向的转移（buy→hold 可，buy→sell 直接跳跃不可；
/// sell 在风险语境下已是保守端，不再被否决调整）。对拍 DSA risk_override 转换合法性校验。
enum RiskOverrideStateMachine {
    static func applyRiskOverride(
        action: CanonicalAction,
        riskFlags: [AgentRiskFlag]
    ) -> (action: CanonicalAction, applied: Bool, note: String?) {
        // 任一 high 且 vetoBuy → 直接压到 watch（只对进攻方向生效）
        let vetoFlag = riskFlags.first { $0.severity == .high && $0.vetoBuy }
        if let flag = vetoFlag, action.decisionType == .buy {
            guard DecisionActionTransition.isMoreConservative(from: action, to: .watch) else {
                // buy→watch 恒为保守方向；此分支防御性返回原动作并说明
                return (action, false, "风险否决转移非法（\(flag.kind)），保留原动作")
            }
            return (.watch, true, "风控接管：\(flag.kind)（\(flag.note)），信号下调为观望")
        }
        // 无 veto 的 high → 最多降一档
        if riskFlags.contains(where: { $0.severity == .high }), action.decisionType == .buy {
            let order = DecisionActionTransition.conservatismOrder
            if let index = order.firstIndex(of: action), index + 1 < order.count {
                let downgraded = order[index + 1]
                if DecisionActionTransition.isMoreConservative(from: action, to: downgraded) {
                    return (downgraded, true, "高风险项降一档：\(downgraded.displayName)")
                }
            }
        }
        return (action, false, nil)
    }
}
