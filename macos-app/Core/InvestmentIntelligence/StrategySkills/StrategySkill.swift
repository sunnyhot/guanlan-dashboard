import Foundation

// MARK: - 市场状态与技能分类

/// 市场状态（regime），由技术分析结果 + 市场广度推导，用于策略路由。
enum MarketRegime: String, Codable, Hashable, Sendable, CaseIterable {
    case trendingUp
    case trendingDown
    case sideways
    case volatile
    case sectorHot

    var displayName: String {
        switch self {
        case .trendingUp: return "趋势上行"
        case .trendingDown: return "趋势下行"
        case .sideways: return "横盘震荡"
        case .volatile: return "巨量分歧"
        case .sectorHot: return "板块热点"
        }
    }
}

/// 策略技能分类。
enum StrategySkillCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case trend      // 趋势类
    case reversal   // 反转类
    case framework  // 分析框架类
    case pattern    // 形态类

    var displayName: String {
        switch self {
        case .trend: return "趋势"
        case .reversal: return "反转"
        case .framework: return "框架"
        case .pattern: return "形态"
        }
    }
}

// MARK: - 技能模型

/// 策略技能：数据化的策略 prompt + 元数据（移植自 DSA strategies/*.yaml，MIT）。
/// requiredTools 约束子 Agent 的工具子集；marketRegimes 驱动路由；coreRules 关联默认纪律基线条目。
struct StrategySkill: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let description: String
    let category: StrategySkillCategory
    /// 关联默认纪律基线的条目编号（1-7）
    let coreRules: [Int]
    /// 本技能分析时需要的工具名（约束工具子集）
    let requiredTools: [String]
    let aliases: [String]
    let defaultPriority: Int
    let marketRegimes: [MarketRegime]
    /// 完整策略指令（量化条件 + 评分调整）
    let instructions: String

    var isBuiltIn: Bool { true }
}

// MARK: - 默认纪律基线

/// 默认交易纪律基线（7 条）。仅当用户未显式选择技能时注入，
/// 显式选择后不再叠加（避免「选了龙头策略还被塞趋势基线」）。
/// 移植自 DSA agent/skills/defaults.py CORE_TRADING_SKILL_POLICY_ZH。
enum CoreTradingSkillPolicy {
    static let rules: [String] = [
        "严进策略（不追高）：绝对不追高。偏离 MA5 超过 5% 坚决不买入；乖离率 <2% 为最佳买点；2%-5% 只可小仓试探；>5% 严禁追高，直接判定观望。",
        "趋势交易：多头排列（MA5>MA10>MA20）是做多必要条件；空头排列坚决不碰。",
        "效率优先（筹码结构）：90% 集中度 <15% 视为筹码集中；70%-90% 获利盘时警惕回吐压力；现价高于平均成本 5%-15% 为健康区间。",
        "买点偏好：最佳买点 = 缩量回踩 MA5 获支撑；次优 = 回踩 MA10；跌破 MA20 一律观望。",
        "风险排查重点：减持公告、业绩预亏、监管处罚、行业政策利空、30 天内大额解禁，出现任一项必须在风险点中说明。",
        "估值关注（PE/PB）：PE 明显偏高时需在风险点中说明估值风险。",
        "强势趋势股放宽：强趋势中可适当放宽乖离率限制，轻仓追踪，但必须设止损。",
    ]

    /// 渲染为 prompt 基线段。
    static func promptSection() -> String {
        var lines = ["## 默认交易纪律基线（必须严格遵守）"]
        for (index, rule) in rules.enumerated() {
            lines.append("### \(index + 1). \(rule)")
        }
        return lines.joined(separator: "\n")
    }
}
