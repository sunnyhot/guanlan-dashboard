import Foundation

// 决策条件(Schema V2)。
//
// 区分自然语言条件和机器可计算条件:
// - displayText:人类可读(包括旧 TrendTracking 迁移的自然语言)
// - machineCondition:结构化条件,可自动判断(仅机器可计算才允许自动触发)
//
// 复核方案硬约束:不允许把自然语言条件伪装成自动触发条件。

struct DecisionCondition: Codable, Hashable, Sendable {
    let displayText: String
    let machineCondition: MachineDecisionCondition?

    init(displayText: String, machineCondition: MachineDecisionCondition? = nil) {
        self.displayText = displayText
        self.machineCondition = machineCondition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayText = try c.decodeIfPresent(String.self, forKey: .displayText) ?? ""
        machineCondition = try c.decodeIfPresent(MachineDecisionCondition.self, forKey: .machineCondition)
    }

    var isMachineEvaluable: Bool { machineCondition != nil }
}

struct MachineDecisionCondition: Codable, Hashable, Sendable {
    let metric: DecisionMetricIdentifier
    let comparator: DecisionMetricComparator
    let threshold: Double
    let unit: DecisionMetricUnit

    init(metric: DecisionMetricIdentifier, comparator: DecisionMetricComparator, threshold: Double, unit: DecisionMetricUnit) {
        self.metric = metric
        self.comparator = comparator
        self.threshold = threshold
        self.unit = unit
    }

    /// 评估条件是否满足。
    func evaluate(currentValue: Double?) -> Bool? {
        guard let value = currentValue else { return nil }  // 数据不足返回 nil
        switch comparator {
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        }
    }
}

// MARK: - 指标标识

enum DecisionMetricIdentifier: String, Codable, Hashable, Sendable {
    case directHoldingWeight       // 直接持仓占比(%)
    case lookThroughSecurityWeight // 穿透底层证券占比(%)
    case lookThroughOverlapWeight  // 穿透重叠占比(%)
    case sectorWeight              // 行业占比(%)
    case drawdown                  // 回撤(%)
    case targetDeviation           // 目标配置偏离(pp)

    var displayName: String {
        switch self {
        case .directHoldingWeight: return "直接持仓占比"
        case .lookThroughSecurityWeight: return "穿透证券占比"
        case .lookThroughOverlapWeight: return "穿透重叠占比"
        case .sectorWeight: return "行业占比"
        case .drawdown: return "回撤"
        case .targetDeviation: return "配置偏离"
        }
    }
}

enum DecisionMetricComparator: String, Codable, Hashable, Sendable {
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case lessThan = "<"
    case lessThanOrEqual = "<="
}

enum DecisionMetricUnit: String, Codable, Hashable, Sendable {
    case percent       // %
    case percentagePoint  // pp
}
