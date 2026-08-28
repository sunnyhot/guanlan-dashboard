import Foundation

// MARK: - 置信度档位

/// 决策置信度档位（高/中/低）。与数值映射：高 0.8 / 中 0.6 / 低 0.4。
enum DecisionConfidenceLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case high
    case medium
    case low

    var numericValue: Double {
        switch self {
        case .high: return 0.8
        case .medium: return 0.6
        case .low: return 0.4
        }
    }

    var displayName: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    /// 只降不升的封顶：取两者中更保守的档位。
    func capped(at ceiling: DecisionConfidenceLevel) -> DecisionConfidenceLevel {
        let order: [DecisionConfidenceLevel] = [.low, .medium, .high]
        guard let selfIndex = order.firstIndex(of: self),
              let ceilingIndex = order.firstIndex(of: ceiling) else { return self }
        return selfIndex <= ceilingIndex ? self : ceiling
    }
}

// MARK: - 数据质量状态

/// 数据块质量状态（一等公民，随数据进 prompt 并驱动置信度封顶）。
/// 口径对拍 daily_stock_analysis `analysis_context_pack.py` 的 CORE_DEGRADED_STATUSES。
enum DataQualityStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case ok
    case stale
    case fallback
    case missing
    case partial
    case estimated
    case failed

    var isDegraded: Bool { self != .ok }

    var displayName: String {
        switch self {
        case .ok: return "正常"
        case .stale: return "过期"
        case .fallback: return "降级来源"
        case .missing: return "缺失"
        case .partial: return "部分覆盖"
        case .estimated: return "估算值"
        case .failed: return "抓取失败"
        }
    }
}

// MARK: - 置信度封顶策略

/// 数据质量 → 置信度封顶：
/// - 核心数据（行情/K线/技术面）任一 degraded → 封顶 medium；
/// - 两个以上 degraded 或任一 failed → 封顶 low。
enum DataQualityConfidencePolicy {
    static func confidenceCeiling(coreStatuses: [DataQualityStatus]) -> DecisionConfidenceLevel {
        let degraded = coreStatuses.filter(\.isDegraded)
        if degraded.contains(where: { $0 == .failed }) || degraded.count >= 2 {
            return .low
        }
        if degraded.count == 1 {
            return .medium
        }
        return .high
    }
}

// MARK: - 分数校准审计

/// LLM 后护栏的审计记录：每次修正都落结构化字段，报告层/API 都能展示「为什么被调整」。
struct DecisionScoreCalibration: Codable, Hashable, Sendable {
    var rawScore: Int
    var adjustedScore: Int
    var guardrailReasons: [String]
    /// 触发护栏时的结构上下文快照（位置区间/资金流/阶段）。
    var structureSnapshot: String

    init(rawScore: Int, adjustedScore: Int, guardrailReasons: [String] = [], structureSnapshot: String = "") {
        self.rawScore = rawScore
        self.adjustedScore = adjustedScore
        self.guardrailReasons = guardrailReasons
        self.structureSnapshot = structureSnapshot
    }
}
