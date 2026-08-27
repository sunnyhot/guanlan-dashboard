import Foundation

/// AI 研判页面术语的人话解释表。
///
/// 页面上的每个专业词汇都应在这里登记一条「一句人话 + 一个例子」，
/// 由 `TermHelpView`（macOS）等展示层引用；新增术语不登记解释视为遗漏。
/// 文案只描述呈现层语义，不承诺模型内部实现。
enum ResearchTerm: String, CaseIterable, Identifiable {
    /// 把握（0-100 的确定性档位，不是涨跌概率）
    case confidence
    /// 触发 / 失效（行动的进场与放弃条件）
    case triggerInvalidation
    /// 三方判断约束（行情/新闻/持仓三个独立角度的提醒）
    case teamConstraints
    /// 独立来源（依据来自几个互不相关的渠道）
    case independentSources
    /// 穿透覆盖（多少比例的持仓能查到底层明细）
    case lookThroughCoverage
    /// 姿态（防御/均衡/选择/进取的总体倾向）
    case posture
    /// 把握档位怎么用（W4.6:高/中/低各自该怎么对待）
    case confidenceAnchor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .confidence: return "把握"
        case .triggerInvalidation: return "触发与失效"
        case .teamConstraints: return "三方判断约束"
        case .independentSources: return "独立来源"
        case .lookThroughCoverage: return "穿透覆盖"
        case .posture: return "姿态"
        case .confidenceAnchor: return "把握档位怎么用"
        }
    }

    var plainExplanation: String {
        switch self {
        case .confidence:
            return "AI 对这条判断的确定程度，分很高 / 较高 / 中等 / 偏低四档。它表示证据有多扎实，不是上涨或下跌的概率。"
        case .triggerInvalidation:
            return "「触发」是这项判断成立需要的信号，没出现就先不动；「失效」是让你放弃这项判断的信号，出现就该重新评估。"
        case .teamConstraints:
            return "行情、新闻、持仓三个角度各自独立分析后给出的限制条件，用来防止单一视角把话说满。"
        case .independentSources:
            return "支撑这条判断的证据来自几个互不相关的渠道。渠道越多、越独立，判断越不容易被单一来源带偏。"
        case .lookThroughCoverage:
            return "组合里有多大比例的持仓能查到基金底层的股票和债券明细。比例越高，行业和风险判断的依据越完整。"
        case .posture:
            return "当前一小时整体的进攻或防守倾向：防御最保守，进取最积极。它是氛围判断，不是具体买卖指令。"
        case .confidenceAnchor:
            return "把握高（≥75）可以直接参考；中（45-74）需要结合自己的判断再看；低（<45）仅供参考，先别据此动仓。"
        }
    }

    var example: String {
        switch self {
        case .confidence:
            return "例：「把握 较高 78」= 证据比较扎实，但仍有两成多不确定性，不适合重仓押注。"
        case .triggerInvalidation:
            return "例：触发「缩量回落后企稳」才考虑买入；一旦失效「跌破日内均线」就放弃这个计划。"
        case .teamConstraints:
            return "例：行情角度说「波动放大」，持仓角度提醒「红利已偏高配」，两条一起看就不会只追涨。"
        case .independentSources:
            return "例：「5 条依据 · 来自 3 个不同渠道」比「8 条依据 · 同一家媒体」更可信。"
        case .lookThroughCoverage:
            return "例：覆盖 83% = 每 100 元持仓里约 83 元查得到底层明细，其余按未知处理、判断会更谨慎。"
        case .posture:
            return "例：姿态「均衡偏防守」时，AI 倾向建议持有或观望，而不是追加买入。"
        case .confidenceAnchor:
            return "例：把握 80 的「偏强」可以直接参考；把握 40 的「偏强」先别动，等证据更充分再说。"
        }
    }
}

/// 全站统一的把握档位（0-100 → 四档）。
///
/// 盘中优先动作、全市场机会雷达等所有向用户展示确定性评分的地方统一用这套
/// 档位与文案，避免「把握」与「置信度」、四档与三档并存。
/// 注意：`TrendConfidence.label`（高/中/低）是落盘契约，不在统一范围内。
///
/// 阈值刻意取 85/75/45，与 `TrendConfidenceMeter` 色带（75/45）及磁盘
/// label 边界对齐：≥75 绿=较高、45-74 黄=中等、<45 红=偏低，85+ 为「很高」
/// 顶级。这样文字档位与色带颜色不会出现「较高却显示黄色」的打架。
enum ConfidenceGrade: Hashable, Sendable {
    case veryHigh
    case high
    case medium
    case low

    init(score: Int) {
        switch score {
        case 85...: self = .veryHigh
        case 75...: self = .high
        case 45...: self = .medium
        default: self = .low
        }
    }

    var gradeText: String {
        switch self {
        case .veryHigh: return "很高"
        case .high: return "较高"
        case .medium: return "中等"
        case .low: return "偏低"
        }
    }

    /// 卡片徽章用的「把握 中等 65」形式。
    static func badgeText(score: Int) -> String {
        let grade = ConfidenceGrade(score: score)
        return "把握 \(grade.gradeText) \(score)"
    }
}
