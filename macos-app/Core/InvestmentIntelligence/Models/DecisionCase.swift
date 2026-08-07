import Foundation

// 投资智能系统的核心持久化对象:DecisionCase。
//
// 一个 DecisionCase 表示「一个需要用户关注的组合决策事项」。
// Slice 1 只实现 concentrationRisk 一种类型(直接持仓集中度 + 穿透重叠)。
//
// 设计原则(见 docs/ai-pipeline-baseline.md 第 9 节):
// - 生命周期(CaseLifecycle)与投资判断(PortfolioDecisionState)分离,避免一个枚举混用。
// - 追加式事件历史(DecisionCaseEvent),保证审计能力。
// - caseKey 稳定,用于跨运行去重。
// - schemaVersion 从一开始就有(吸取 TrendTrackingItem 无版本的教训)。

// MARK: - 生命周期(工作流进度)

/// DecisionCase 的工作流阶段。与 PortfolioDecisionState(投资判断)正交。
enum DecisionCaseLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    /// 刚发现,尚未评估。
    case detected
    /// 正在评估(本地计算 + 未来 Slice 3 的专项研究)。
    case researching
    /// 评估完成,有明确决策状态,等待用户处理。
    case decisionReady
    /// 进入持续监控(用户已确认关注,等待触发/失效条件)。
    case monitoring
    /// 到达复查时间,需要重新评估。
    case reviewDue
    /// 已关闭(用户处理、失效或手动关闭)。
    case closed
}

// MARK: - 投资判断(决策语义)

/// 组合决策状态。与 CaseLifecycle(工作流)正交。
///
/// 含义:
/// - stable:无需处理,组合状态健康。
/// - watch:存在变化或风险信号,但暂不满足进一步行动条件。
/// - prepare:触发条件接近,需要提前准备。
/// - adjustReview:建议用户评估调整(但不自动操作)。
/// - exitReview:原投资逻辑可能失效,建议重点复核。
/// - insufficientEvidence:数据或证据不足,无法给出明确判断。
enum PortfolioDecisionState: String, Codable, Hashable, Sendable, CaseIterable {
    case stable
    case watch
    case prepare
    case adjustReview
    case exitReview
    case insufficientEvidence

    /// 是否属于「强行动」状态(需要资金复核)。
    /// 复核方案规定:未配置完整 UserDecisionProfile 时禁止进入强行动状态。
    var requiresCompleteProfile: Bool {
        switch self {
        case .adjustReview, .exitReview:
            return true
        case .stable, .watch, .prepare, .insufficientEvidence:
            return false
        }
    }
}

// MARK: - Case 类型

/// Slice 1 起 concentrationRisk;Slice 7 扩展 drawdown / deviation。
enum DecisionCaseKind: String, Codable, Hashable, Sendable {
    case concentrationRisk
    case drawdownExpansion     // 回撤扩大(Slice 7)
    case targetDeviation       // 目标配置偏离(Slice 7)

    var displayName: String {
        switch self {
        case .concentrationRisk: return "集中度风险"
        case .drawdownExpansion: return "回撤扩大"
        case .targetDeviation: return "目标配置偏离"
        }
    }
}

/// 集中度风险的细分维度。
enum ConcentrationDimension: String, Codable, Hashable, Sendable {
    /// 直接持仓(基金/股票)层面的集中度。
    case directHolding
    /// 穿透后底层证券层面的集中度。
    case lookThrough
    /// 穿透后底层证券重叠(多只基金持有同一底层)。
    case lookThroughOverlap
    /// 穿透后行业层面的集中度(Slice 2)。
    case sector
}

// MARK: - 事件历史

/// 追加式状态变更记录,保证审计能力。
struct DecisionCaseEvent: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let at: String
    let type: DecisionCaseEventType
    let previousLifecycle: DecisionCaseLifecycle?
    let newLifecycle: DecisionCaseLifecycle
    let previousDecisionState: PortfolioDecisionState?
    let newDecisionState: PortfolioDecisionState
    let reason: String
    let actor: DecisionCaseActor

    init(
        id: UUID = UUID(),
        at: String,
        type: DecisionCaseEventType,
        previousLifecycle: DecisionCaseLifecycle?,
        newLifecycle: DecisionCaseLifecycle,
        previousDecisionState: PortfolioDecisionState?,
        newDecisionState: PortfolioDecisionState,
        reason: String,
        actor: DecisionCaseActor
    ) {
        self.id = id
        self.at = at
        self.type = type
        self.previousLifecycle = previousLifecycle
        self.newLifecycle = newLifecycle
        self.previousDecisionState = previousDecisionState
        self.newDecisionState = newDecisionState
        self.reason = reason
        self.actor = actor
    }
}

enum DecisionCaseEventType: String, Codable, Hashable, Sendable {
    case created
    case reassessed
    case userAcknowledged
    case userResolved
    case userClosed
    case userReopened
    case profileUpdated
    case migrated  // Slice 6:从旧 TrendTracking 迁移
}

enum DecisionCaseActor: String, Codable, Hashable, Sendable {
    case system
    case user
    case migration
}

// MARK: - DecisionCase 主体

struct DecisionCase: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 2

    var id: UUID
    var schemaVersion: Int
    /// 稳定去重键:kind | dimension | subjectType | subjectID | horizon
    let caseKey: String
    let kind: DecisionCaseKind
    let dimension: ConcentrationDimension

    // 标的标识(集中度场景下是标的名称/代码)
    let subjectName: String
    let subjectCode: String?

    // 状态
    var lifecycle: DecisionCaseLifecycle
    var decisionState: PortfolioDecisionState

    // 量化指标快照(评估时的数值,用于 UI 展示和历史对比)
    var metricValue: Double          // 如 top1 占比 55.3
    var metricLabel: String          // 如 "55.3%"
    var metricDescription: String    // 如 "第一大标的占比"

    // 人话解释
    var title: String
    var detail: String

    // 时间
    var createdAt: String
    var updatedAt: String

    // Schema V2 新增(显式存储,不用 updatedAt 算)
    var lastEvaluatedAt: String       // 最近一次指标评估时间
    var reviewDueAt: String?          // 显式复查时间(monitoring 时设定)
    var resolvedAt: String?           // 关闭时间
    var latestResearchRunID: UUID?    // 最近研究运行 ID
    var latestReviewID: UUID?         // 最近复盘 ID

    // 追加式事件历史
    var events: [DecisionCaseEvent]

    // 用户处置
    var userDisposition: DecisionCaseUserDisposition

    init(
        id: UUID = UUID(),
        schemaVersion: Int = DecisionCase.currentSchemaVersion,
        caseKey: String,
        kind: DecisionCaseKind,
        dimension: ConcentrationDimension,
        subjectName: String,
        subjectCode: String?,
        lifecycle: DecisionCaseLifecycle,
        decisionState: PortfolioDecisionState,
        metricValue: Double,
        metricLabel: String,
        metricDescription: String,
        title: String,
        detail: String,
        createdAt: String,
        updatedAt: String,
        lastEvaluatedAt: String? = nil,
        reviewDueAt: String? = nil,
        resolvedAt: String? = nil,
        latestResearchRunID: UUID? = nil,
        latestReviewID: UUID? = nil,
        events: [DecisionCaseEvent] = [],
        userDisposition: DecisionCaseUserDisposition = .pending
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.caseKey = caseKey
        self.kind = kind
        self.dimension = dimension
        self.subjectName = subjectName
        self.subjectCode = subjectCode
        self.lifecycle = lifecycle
        self.decisionState = decisionState
        self.metricValue = metricValue
        self.metricLabel = metricLabel
        self.metricDescription = metricDescription
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEvaluatedAt = lastEvaluatedAt ?? createdAt
        self.reviewDueAt = reviewDueAt
        self.resolvedAt = resolvedAt
        self.latestResearchRunID = latestResearchRunID
        self.latestReviewID = latestReviewID
        self.events = events
        self.userDisposition = userDisposition
    }

    // MARK: - V1 兼容解码

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        caseKey = try c.decodeIfPresent(String.self, forKey: .caseKey) ?? ""
        kind = try c.decodeIfPresent(DecisionCaseKind.self, forKey: .kind) ?? .concentrationRisk
        dimension = try c.decodeIfPresent(ConcentrationDimension.self, forKey: .dimension) ?? .directHolding
        subjectName = try c.decodeIfPresent(String.self, forKey: .subjectName) ?? ""
        subjectCode = try c.decodeIfPresent(String.self, forKey: .subjectCode)
        lifecycle = try c.decodeIfPresent(DecisionCaseLifecycle.self, forKey: .lifecycle) ?? .decisionReady
        decisionState = try c.decodeIfPresent(PortfolioDecisionState.self, forKey: .decisionState) ?? .watch
        metricValue = try c.decodeIfPresent(Double.self, forKey: .metricValue) ?? 0
        metricLabel = try c.decodeIfPresent(String.self, forKey: .metricLabel) ?? ""
        metricDescription = try c.decodeIfPresent(String.self, forKey: .metricDescription) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        // V2 新增(缺失时默认值)
        lastEvaluatedAt = try c.decodeIfPresent(String.self, forKey: .lastEvaluatedAt) ?? updatedAt
        reviewDueAt = try c.decodeIfPresent(String.self, forKey: .reviewDueAt)
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt)
        latestResearchRunID = try c.decodeIfPresent(UUID.self, forKey: .latestResearchRunID)
        latestReviewID = try c.decodeIfPresent(UUID.self, forKey: .latestReviewID)
        events = try c.decodeIfPresent([DecisionCaseEvent].self, forKey: .events) ?? []
        userDisposition = try c.decodeIfPresent(DecisionCaseUserDisposition.self, forKey: .userDisposition) ?? .pending
    }
}

/// 用户对 DecisionCase 的处置状态。
enum DecisionCaseUserDisposition: String, Codable, Hashable, Sendable {
    /// 未处理(默认)。
    case pending
    /// 用户已确认关注(进入 monitoring)。
    case acknowledged
    /// 用户已解决(标记为已处理)。
    case resolved
    /// 用户已关闭(不再关注)。
    case closed
}

extension DecisionCaseLifecycle {
    var displayName: String {
        switch self {
        case .detected: return "待评估"
        case .researching: return "研究中"
        case .decisionReady: return "待处理"
        case .monitoring: return "跟踪中"
        case .reviewDue: return "待复盘"
        case .closed: return "已结束"
        }
    }
}

extension PortfolioDecisionState {
    var displayName: String {
        switch self {
        case .stable: return "保持现状"
        case .watch: return "持续观察"
        case .prepare: return "准备应对"
        case .adjustReview: return "复核调整"
        case .exitReview: return "复核退出"
        case .insufficientEvidence: return "证据不足"
        }
    }

    var guidanceText: String {
        switch self {
        case .stable: return "暂不需要改变组合"
        case .watch: return "保留持仓，等待条件确认"
        case .prepare: return "先准备方案，不立即交易"
        case .adjustReview: return "评估是否降低相关暴露"
        case .exitReview: return "重点复核原投资逻辑"
        case .insufficientEvidence: return "先补充数据，再做判断"
        }
    }
}

extension DecisionCaseUserDisposition {
    var displayName: String {
        switch self {
        case .pending: return "待处理"
        case .acknowledged: return "已关注"
        case .resolved: return "已解决"
        case .closed: return "已关闭"
        }
    }
}

// MARK: - caseKey 生成

extension DecisionCase {
    /// 生成稳定的 caseKey,用于跨运行去重。
    static func makeCaseKey(
        kind: DecisionCaseKind,
        dimension: ConcentrationDimension,
        subjectCode: String?,
        subjectName: String
    ) -> String {
        // subject 优先用 code(更稳定),兜底用 name
        let subjectID = subjectCode?.lowercased() ?? subjectName.lowercased()
        return "\(kind.rawValue)|\(dimension.rawValue)|\(subjectID)"
    }
}

// MARK: - 状态转换(状态机)

extension DecisionCase {
    /// 应用一次状态变更,追加事件历史。
    /// 返回的新 case 的 lifecycle/decisionState 已更新,events 末尾追加了本次变更。
    mutating func applyTransition(
        to newLifecycle: DecisionCaseLifecycle,
        decisionState newDecisionState: PortfolioDecisionState,
        at timestamp: String,
        type: DecisionCaseEventType,
        reason: String,
        actor: DecisionCaseActor
    ) {
        let event = DecisionCaseEvent(
            at: timestamp,
            type: type,
            previousLifecycle: lifecycle,
            newLifecycle: newLifecycle,
            previousDecisionState: decisionState,
            newDecisionState: newDecisionState,
            reason: reason,
            actor: actor
        )
        lifecycle = newLifecycle
        decisionState = newDecisionState
        updatedAt = timestamp
        events.append(event)
    }
}
