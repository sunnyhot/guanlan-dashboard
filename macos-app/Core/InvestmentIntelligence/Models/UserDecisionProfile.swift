import Foundation

// 用户决策画像(UserDecisionProfile)。
//
// 没有用户目标时,系统不允许输出强行动(adjustReview/exitReview)。
// 这是复核方案第 5.10 节的硬约束,在 ConcentrationRiskEngine 里强制执行。
//
// Slice 1 提供保守默认值(.default),用户可在设置里自定义(Slice 1 的 UI 含 Profile 编辑)。

// MARK: - 投资期限

enum InvestmentHorizon: String, Codable, Hashable, Sendable, CaseIterable {
    case shortTerm    // < 1 年
    case mediumTerm   // 1-3 年
    case longTerm     // > 3 年

    var displayName: String {
        switch self {
        case .shortTerm: return "短期(1 年以内)"
        case .mediumTerm: return "中期(1-3 年)"
        case .longTerm: return "长期(3 年以上)"
        }
    }
}

// MARK: - 风险偏好

enum RiskTolerance: String, Codable, Hashable, Sendable, CaseIterable {
    case conservative   // 保守
    case moderate       // 稳健
    case aggressive     // 进取

    var displayName: String {
        switch self {
        case .conservative: return "保守"
        case .moderate: return "稳健"
        case .aggressive: return "进取"
        }
    }

    /// 对应的单标的集中度上限(百分比)。
    /// 保守 30%、稳健 40%、进取 50%。
    /// 超过此上限才可能触发 adjustReview。
    var defaultConcentrationLimit: Double {
        switch self {
        case .conservative: return 30
        case .moderate: return 40
        case .aggressive: return 50
        }
    }

    /// 对应的穿透重叠上限(百分比)。
    var defaultOverlapLimit: Double {
        switch self {
        case .conservative: return 15
        case .moderate: return 20
        case .aggressive: return 25
        }
    }
}

// MARK: - UserDecisionProfile

struct UserDecisionProfile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var investmentHorizon: InvestmentHorizon
    var riskTolerance: RiskTolerance
    /// 单标的集中度上限(百分比,0-100)。nil 时用 riskTolerance 默认值。
    var concentrationLimit: Double?
    /// 穿透重叠上限(百分比,0-100)。nil 时用 riskTolerance 默认值。
    var overlapLimit: Double?
    /// 是否允许系统给出主动再平衡建议(adjustReview)。
    /// false 时即使超阈值也只能 watch,不能 adjustReview。
    var allowsActiveRebalancing: Bool
    /// 用户是否已完成自定义配置。false 表示用保守默认值。
    var isCustomized: Bool
    var customizedAt: String?

    init(
        schemaVersion: Int = UserDecisionProfile.currentSchemaVersion,
        investmentHorizon: InvestmentHorizon = .longTerm,
        riskTolerance: RiskTolerance = .conservative,
        concentrationLimit: Double? = nil,
        overlapLimit: Double? = nil,
        allowsActiveRebalancing: Bool = false,
        isCustomized: Bool = false,
        customizedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.investmentHorizon = investmentHorizon
        self.riskTolerance = riskTolerance
        self.concentrationLimit = concentrationLimit
        self.overlapLimit = overlapLimit
        self.allowsActiveRebalancing = allowsActiveRebalancing
        self.isCustomized = isCustomized
        self.customizedAt = customizedAt
    }

    /// 保守默认值(未自定义时使用)。
    /// 不允许主动再平衡,期限偏长,风险保守。
    static let `default` = UserDecisionProfile()

    /// 有效的单标的集中度上限(自定义值优先,否则用风险偏好默认值)。
    var effectiveConcentrationLimit: Double {
        concentrationLimit ?? riskTolerance.defaultConcentrationLimit
    }

    /// 有效的穿透重叠上限。
    var effectiveOverlapLimit: Double {
        overlapLimit ?? riskTolerance.defaultOverlapLimit
    }

    /// Profile 是否足够完整,允许系统输出强行动(adjustReview/exitReview)。
    /// 复核方案硬约束:未自定义或不允许再平衡时,不得输出强行动。
    var allowsStrongAction: Bool {
        isCustomized && allowsActiveRebalancing
    }
}
