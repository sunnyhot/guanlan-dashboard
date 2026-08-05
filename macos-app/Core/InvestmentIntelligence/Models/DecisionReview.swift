import Foundation

// DecisionCase 复盘模型(Slice 7)。
//
// 复核方案第 12.4 节:复盘不只根据最终涨跌判断 AI 是否正确。
// 复盘维度:触发/失效条件结果、Claim 结果、组合变化、决策过程质量、可复用经验。
// 结论:supported / partiallySupported / contradicted / unresolved / invalidatedBeforeEvaluation / insufficientData
//
// 见 docs/ai-pipeline-baseline.md 第 9.4 节。

/// 复盘结论(不用"正确/错误")。
enum DecisionReviewConclusion: String, Codable, Hashable, Sendable {
    case supported                    // 判断被后续事实充分支持
    case partiallySupported           // 部分支持
    case contradicted                 // 被后续事实推翻
    case unresolved                   // 无法定论(条件未触发/数据不足)
    case invalidatedBeforeEvaluation  // 复盘前 Case 已失效
    case insufficientData             // 数据不足以复盘

    var displayName: String {
        switch self {
        case .supported: return "判断成立"
        case .partiallySupported: return "部分成立"
        case .contradicted: return "判断不成立"
        case .unresolved: return "无法定论"
        case .invalidatedBeforeEvaluation: return "提前失效"
        case .insufficientData: return "数据不足"
        }
    }
}

/// 单条 Claim 在复盘时的结果。
struct DecisionReviewClaimOutcome: Codable, Hashable, Sendable {
    let claim: String
    let originalDirection: String   // 原判断方向
    let outcome: ClaimDisposition   // supported/contradicted/...
    let note: String
}

/// 复盘记录。
struct DecisionReview: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let caseID: UUID
    let reviewedAt: String
    let reviewHorizon: String        // 复盘周期(如"7天后""30天后")

    /// 原 Case 被复盘时的决策状态(复盘前的快照)。
    let originalDecisionState: PortfolioDecisionState
    /// 原 Case 的核心指标值(复盘前)。
    let originalMetricValue: Double
    /// 复盘时的指标值。
    let currentMetricValue: Double

    /// 触发条件是否触发。
    let triggerResult: Bool?
    /// 失效条件是否触发。
    let invalidationResult: Bool?

    /// Claim 级结果(来自研究报告的 finding 逐条评估)。
    let claimOutcomes: [DecisionReviewClaimOutcome]

    /// 复盘时的组合变化描述(文字)。
    let portfolioOutcome: String
    /// 决策过程质量评估(人工填写或自动生成)。
    let processQuality: String

    /// 最终结论。
    let conclusion: DecisionReviewConclusion
    /// 可复用经验。
    let lessons: String

    init(
        id: UUID = UUID(),
        schemaVersion: Int = DecisionReview.currentSchemaVersion,
        caseID: UUID,
        reviewedAt: String,
        reviewHorizon: String,
        originalDecisionState: PortfolioDecisionState,
        originalMetricValue: Double,
        currentMetricValue: Double,
        triggerResult: Bool? = nil,
        invalidationResult: Bool? = nil,
        claimOutcomes: [DecisionReviewClaimOutcome] = [],
        portfolioOutcome: String = "",
        processQuality: String = "",
        conclusion: DecisionReviewConclusion,
        lessons: String = ""
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.reviewedAt = reviewedAt
        self.reviewHorizon = reviewHorizon
        self.originalDecisionState = originalDecisionState
        self.originalMetricValue = originalMetricValue
        self.currentMetricValue = currentMetricValue
        self.triggerResult = triggerResult
        self.invalidationResult = invalidationResult
        self.claimOutcomes = claimOutcomes
        self.portfolioOutcome = portfolioOutcome
        self.processQuality = processQuality
        self.conclusion = conclusion
        self.lessons = lessons
    }
}

// MARK: - 复盘时间计算(Schema V2:显式 reviewDueAt,不用 updatedAt)

extension DecisionCase {
    /// 显式存储的复查时间(Schema V2)。
    /// 进入 monitoring 时由 computeReviewDueAt 设定,到期不改。
    var nextReviewAt: String? { reviewDueAt }

    /// 是否到达复查时间(用显式 reviewDueAt,不用 updatedAt)。
    func isReviewDue(asOf now: String) -> Bool {
        guard let reviewDueAt else { return false }
        return now >= reviewDueAt
    }

    /// 计算复查时间(进入 monitoring 时调用一次,存入 reviewDueAt)。
    static func computeReviewDueAt(decisionState: PortfolioDecisionState, from timestamp: String) -> String? {
        let days: Int
        switch decisionState {
        case .watch: days = 7
        case .prepare, .insufficientEvidence: days = 3
        case .adjustReview, .exitReview: days = 1
        case .stable: return nil
        }
        return dateString(addingDays: days, to: timestamp)
    }

    private static func dateString(addingDays days: Int, to timestamp: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = formatter.date(from: timestamp) else { return nil }
        let future = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date)!
        return formatter.string(from: future)
    }
}
