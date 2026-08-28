import Foundation

// MARK: - 决策类型（三态，统计稳定用）

/// 标的级决策方向。只保留三态供统计口径稳定；细粒度建议用 `CanonicalAction`。
enum CanonicalDecisionType: String, Codable, Hashable, Sendable, CaseIterable {
    case buy
    case hold
    case sell

    var displayName: String {
        switch self {
        case .buy: return "看多"
        case .hold: return "观望"
        case .sell: return "看空"
        }
    }
}

// MARK: - 行动（八态）

/// 标的级行动建议。八态表达细粒度，`alert` 为中性提醒（不改变方向语义）。
enum CanonicalAction: String, Codable, Hashable, Sendable, CaseIterable {
    case buy      // 买入（建仓）
    case add      // 加仓
    case hold     // 持有
    case reduce   // 减仓
    case sell     // 卖出（清仓）
    case watch    // 观望（未持仓者等待）
    case avoid    // 回避
    case alert    // 提醒（事件/风险通知，中性）

    var displayName: String {
        switch self {
        case .buy: return "买入"
        case .add: return "加仓"
        case .hold: return "持有"
        case .reduce: return "减仓"
        case .sell: return "卖出"
        case .watch: return "观望"
        case .avoid: return "回避"
        case .alert: return "提醒"
        }
    }

    var decisionType: CanonicalDecisionType {
        switch self {
        case .buy, .add: return .buy
        case .hold, .watch, .alert: return .hold
        case .reduce, .sell, .avoid: return .sell
        }
    }
}

// MARK: - 分数带

/// canonical 分数带（单一事实源）：prompt 注入、规则引擎、信号抽取三处共用，永不漂移。
/// 口径对拍 daily_stock_analysis `schemas/decision_scale.py`。
enum CanonicalScoreBand: String, Codable, Hashable, Sendable, CaseIterable {
    case strongBuy   // 80-100
    case buy         // 60-79
    case watch       // 40-59
    case reduce      // 20-39
    case sell        // 0-19

    var scoreRange: ClosedRange<Int> {
        switch self {
        case .strongBuy: return 80...100
        case .buy: return 60...79
        case .watch: return 40...59
        case .reduce: return 20...39
        case .sell: return 0...19
        }
    }

    var displayName: String {
        switch self {
        case .strongBuy: return "强烈看多"
        case .buy: return "看多"
        case .watch: return "观望"
        case .reduce: return "减仓"
        case .sell: return "看空"
        }
    }

    var decisionType: CanonicalDecisionType {
        switch self {
        case .strongBuy, .buy: return .buy
        case .watch: return .hold
        case .reduce, .sell: return .sell
        }
    }

    /// 该分数带内自洽的行动集合（alert 中性，任何带都合法）。
    var coherentActions: Set<CanonicalAction> {
        switch self {
        case .strongBuy: return [.buy, .alert]
        case .buy: return [.buy, .add, .alert]
        case .watch: return [.watch, .hold, .alert]
        case .reduce: return [.reduce, .alert]
        case .sell: return [.sell, .avoid, .alert]
        }
    }

    static func band(forScore score: Int) -> CanonicalScoreBand {
        let clamped = min(max(score, 0), 100)
        switch clamped {
        case 80...100: return .strongBuy
        case 60...79: return .buy
        case 40...59: return .watch
        case 20...39: return .reduce
        default: return .sell
        }
    }
}

// MARK: - 对齐工具

/// 分数与行动的对齐/一致性检查。
/// 核心契约：score ≥60 但行动是 hold/watch，或 score <40 但行动是 hold/watch → 不自洽，
/// 必须携带 guardrailReason（把「模型自相矛盾」变成可审计字段）。
enum CanonicalDecisionScale {
    /// 分数带与行动是否自洽。
    static func isCoherent(score: Int, action: CanonicalAction) -> Bool {
        CanonicalScoreBand.band(forScore: score).coherentActions.contains(action)
    }

    /// 把声明的行动对齐到分数带：自洽则原样返回；不自洽则按分数带折算，
    /// 返回是否调整过与调整原因（写入审计字段）。
    static func alignAction(score: Int, declared: CanonicalAction) -> (action: CanonicalAction, adjusted: Bool, reason: String?) {
        if isCoherent(score: score, action: declared) {
            return (declared, false, nil)
        }
        let band = CanonicalScoreBand.band(forScore: score)
        let fallback: CanonicalAction
        switch band {
        case .strongBuy, .buy: fallback = .buy
        case .watch: fallback = .watch
        case .reduce: fallback = .reduce
        case .sell: fallback = .sell
        }
        let reason = "分数 \(score)（\(band.displayName)）与行动 \(declared.displayName) 不自洽，已按分数带对齐为 \(fallback.displayName)"
        return (fallback, true, reason)
    }

    /// 置信度档位（高/中/低 → 数值），供信号抽取与校准使用。
    static func confidenceValue(for label: String) -> Double {
        switch label {
        case "高", "high", "High": return 0.8
        case "低", "low", "Low": return 0.4
        default: return 0.6
        }
    }
}
