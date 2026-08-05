import Foundation

// Presenter 输出模型(Milestone 4 用,先定义好接口)。
//
// 把领域模型转换为 UI 展示模型,View 不做业务计算。
// 整体状态只允许 4 种,禁止生成无依据的"72 分"等评分。

enum InvestmentIntelligenceOverallState: String, Codable, Hashable, Sendable {
    case stable              // 无需处理
    case attentionNeeded     // 有风险需要关注
    case actionReviewNeeded  // 需要评估调整
    case insufficientData    // 数据不足

    var displayName: String {
        switch self {
        case .stable: return "组合状态稳定"
        case .attentionNeeded: return "需要关注"
        case .actionReviewNeeded: return "建议复核"
        case .insufficientData: return "数据不足"
        }
    }
}

struct InvestmentIntelligenceDashboardSummary: Hashable {
    let overallState: InvestmentIntelligenceOverallState
    let headline: String
    let detail: String
    let activeCaseCount: Int
    let reviewDueCount: Int
    let primaryCaseID: UUID?
    let topDirectHoldingText: String?
    let topSectorText: String?
    let lookThroughCoverageText: String?
    let evaluatedAtText: String
}
