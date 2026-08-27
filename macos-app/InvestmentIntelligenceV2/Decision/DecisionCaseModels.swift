import Foundation

// MARK: - 决策事项模型（V2 重建，2026-08-27 审计 A2）
//
// 一个 DecisionCase 表示「一个需要用户关注的组合决策事项」。
// V1 随 ba750e2 删除后按审计清单在 V2 上重建，语义对齐 V1 并做三处
// 刻意演进：
// - 时间戳 String → Date（文件 Store 用 millisecondsSince1970 编码，
//   与 user-intent 既有 Store 一致）
// - id：UUID → 确定性 ID（"dcase_" + caseKey 摘要——一案一文件存储下
//   重放幂等，迁移后 ID 稳定可深链）
// - kind：trendAction → actionMigration（行动候选建案来源从趋势报告
//   改为 V2 研究/决策产物；PortfolioDecisionState 去掉引擎从不产出的
//   exitReview，V1 存量导入时映射 adjustReview）
//
// 设计原则（承 V1）：
// - 生命周期（CaseLifecycle，工作流进度）与投资判断（PortfolioDecisionState，
//   决策语义）正交，一个枚举不混用
// - 追加式事件历史（DecisionCaseEvent），保证审计能力
// - caseKey 稳定，跨运行去重；schemaVersion 从一开始就有

// MARK: - 生命周期（工作流进度）

/// DecisionCase 的工作流阶段。
enum DecisionCaseLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    /// 刚发现，尚未评估。
    case detected
    /// 正在评估。
    case researching
    /// 评估完成，有明确决策状态，等待用户处理。
    case decisionReady
    /// 进入持续监控（用户已确认关注，等待触发/失效条件）。
    case monitoring
    /// 到达复查时间，需要重新评估。
    case reviewDue
    /// 已关闭（用户处理、失效或手动关闭）。
    case closed
}

// MARK: - 投资判断（决策语义）

/// 组合决策状态。与 DecisionCaseLifecycle（工作流）正交。
///
/// - stable：无需处理，组合状态健康
/// - watch：存在变化或风险信号，但暂不满足进一步行动条件
/// - prepare：触发条件接近，需要提前准备
/// - adjustReview：建议用户评估调整（不自动操作）
/// - insufficientEvidence：数据或证据不足，无法给出明确判断
enum PortfolioDecisionState: String, Codable, Hashable, Sendable, CaseIterable {
    case stable
    case watch
    case prepare
    case adjustReview
    case insufficientEvidence
}

// MARK: - Case 类型

/// 四类自动/半自动建案来源（审计 A2：集中度 / 回撤 / 目标偏离 / 行动迁移）。
enum DecisionCaseKind: String, Codable, Hashable, Sendable {
    case concentrationRisk
    case drawdownExpansion
    case targetDeviation
    /// 行动候选建案（V1 trendAction 的 V2 对应物：来源是 V2 研究/决策
    /// 产物的行动候选，用户主动「加入跟踪」）。
    case actionMigration
}

/// 集中度风险的细分维度（非集中度 kind 沿用 directHolding 占位）。
enum ConcentrationDimension: String, Codable, Hashable, Sendable {
    /// 直接持仓（基金/股票）层面的集中度。
    case directHolding
    /// 穿透后底层证券层面的集中度。
    case lookThrough
    /// 穿透后底层证券重叠（多只基金持有同一底层）。
    case lookThroughOverlap
    /// 穿透后行业层面的集中度。
    case sector
}

// MARK: - 事件历史

enum DecisionCaseEventType: String, Codable, Hashable, Sendable {
    case created
    case reassessed
    case userAcknowledged
    case userResolved
    case userClosed
    case userReopened
    case reviewRecorded
    case migrated
}

enum DecisionCaseActor: String, Codable, Hashable, Sendable {
    case system
    case user
    case migration
}

/// 追加式状态变更记录（审计能力）。
struct DecisionCaseEvent: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let at: Date
    let type: DecisionCaseEventType
    let previousLifecycle: DecisionCaseLifecycle?
    let newLifecycle: DecisionCaseLifecycle
    let previousDecisionState: PortfolioDecisionState?
    let newDecisionState: PortfolioDecisionState
    let reason: String
    let actor: DecisionCaseActor

    init(
        id: UUID = UUID(),
        at: Date,
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

// MARK: - 用户处置

enum DecisionCaseUserDisposition: String, Codable, Hashable, Sendable {
    /// 未处理（默认）。
    case pending
    /// 用户已确认关注（进入 monitoring）。
    case acknowledged
    /// 用户已解决（标记为已处理）。
    case resolved
    /// 用户已关闭（不再关注）。
    case closed
}

// MARK: - 复盘（六选一 + 经验笔记）

/// 复盘结论（不用「正确/错误」——复盘维度是判断与后续事实的关系）。
enum DecisionReviewConclusion: String, Codable, Hashable, Sendable, CaseIterable {
    /// 判断被后续事实充分支持
    case supported
    /// 部分支持
    case partiallySupported
    /// 被后续事实推翻
    case contradicted
    /// 无法定论（条件未触发/数据不足）
    case unresolved
    /// 复盘前 Case 已失效
    case invalidatedBeforeEvaluation
    /// 数据不足以复盘
    case insufficientData
}

/// 复盘记录（用户动作产物；V1 的 journal 文件在 V2 内嵌进 case 文件）。
struct DecisionReview: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 2

    let id: String
    let schemaVersion: Int
    let caseID: String
    let reviewedAt: Date
    /// 复盘时的决策状态（复盘前快照）。
    let originalDecisionState: PortfolioDecisionState
    /// 复盘前的核心指标值。
    let originalMetricValue: Double
    /// 复盘时的指标值。
    let currentMetricValue: Double
    let conclusion: DecisionReviewConclusion
    /// 可复用经验（用户手写）。
    let lessons: String

    init(
        id: String? = nil,
        schemaVersion: Int = DecisionReview.currentSchemaVersion,
        caseID: String,
        reviewedAt: Date,
        originalDecisionState: PortfolioDecisionState,
        originalMetricValue: Double,
        currentMetricValue: Double,
        conclusion: DecisionReviewConclusion,
        lessons: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.reviewedAt = reviewedAt
        self.originalDecisionState = originalDecisionState
        self.originalMetricValue = originalMetricValue
        self.currentMetricValue = currentMetricValue
        self.conclusion = conclusion
        self.lessons = lessons
        // 确定性 ID：caseID + 时间 + 结论 + 笔记的语义摘要（重复提交幂等）
        if let id {
            self.id = id
        } else {
            let payload = ReviewIDPayload(
                caseID: caseID,
                reviewedAt: reviewedAt.timeIntervalSince1970,
                conclusion: conclusion.rawValue,
                lessons: lessons)
            self.id = "drev_\(StableDigest.digest((try? StableDigest.jsonPayload(payload)) ?? caseID))"
        }
    }

    /// 确定性 ID 的 payload（私有形状，勿含无序结构）。
    private struct ReviewIDPayload: Encodable {
        let caseID: String
        let reviewedAt: Double
        let conclusion: String
        let lessons: String
    }
}

// MARK: - DecisionCase 主体

struct DecisionCase: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 3

    let id: String
    let schemaVersion: Int
    /// 稳定去重键：kind | dimension | subjectID。
    let caseKey: String
    let kind: DecisionCaseKind
    let dimension: ConcentrationDimension

    /// 标的标识（集中度场景下是标的名称/代码）。
    let subjectName: String
    let subjectCode: String?

    // 状态
    var lifecycle: DecisionCaseLifecycle
    var decisionState: PortfolioDecisionState

    // 量化指标快照（评估时的数值，用于 UI 展示和历史对比）
    var metricValue: Double
    var metricLabel: String
    var metricDescription: String

    // 人话解释
    var title: String
    var detail: String

    // 触发 / 失效条件（审计 B2：自然语言，人工复核，不自动触发）
    var triggerCondition: String?
    var invalidationCondition: String?

    // 时间
    var createdAt: Date
    var updatedAt: Date
    var lastEvaluatedAt: Date
    /// 显式复查时间（monitoring 时设定，到期不改）。
    var reviewDueAt: Date?
    var resolvedAt: Date?

    // 追加式事件历史 + 复盘记录
    var events: [DecisionCaseEvent]
    var reviews: [DecisionReview]

    // 用户处置
    var userDisposition: DecisionCaseUserDisposition

    init(
        id: String? = nil,
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
        triggerCondition: String? = nil,
        invalidationCondition: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        lastEvaluatedAt: Date? = nil,
        reviewDueAt: Date? = nil,
        resolvedAt: Date? = nil,
        events: [DecisionCaseEvent] = [],
        reviews: [DecisionReview] = [],
        userDisposition: DecisionCaseUserDisposition = .pending
    ) {
        self.id = id ?? Self.makeCaseID(caseKey: caseKey)
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
        self.triggerCondition = triggerCondition
        self.invalidationCondition = invalidationCondition
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastEvaluatedAt = lastEvaluatedAt ?? createdAt
        self.reviewDueAt = reviewDueAt
        self.resolvedAt = resolvedAt
        self.events = events
        self.reviews = reviews
        self.userDisposition = userDisposition
    }
}

// MARK: - caseKey / ID 生成

extension DecisionCase {

    /// 生成稳定的 caseKey（跨运行去重）。subject 优先用 code（更稳定），
    /// 兜底用 name。
    static func makeCaseKey(
        kind: DecisionCaseKind,
        dimension: ConcentrationDimension,
        subjectCode: String?,
        subjectName: String
    ) -> String {
        let subjectID = subjectCode?.lowercased() ?? subjectName.lowercased()
        return "\(kind.rawValue)|\(dimension.rawValue)|\(subjectID)"
    }

    /// 确定性 case ID：caseKey 摘要（一案一文件存储的重放幂等基础）。
    static func makeCaseID(caseKey: String) -> String {
        let payload = CaseIDPayload(caseKey: caseKey)
        let digest = (try? StableDigest.jsonPayload(payload)).map(StableDigest.digest)
            ?? StableDigest.digest(caseKey)
        return "dcase_\(digest)"
    }

    private struct CaseIDPayload: Encodable {
        let caseKey: String
        let schemaVersion: Int = DecisionCase.currentSchemaVersion
    }
}

// MARK: - 状态转换（状态机）

extension DecisionCase {

    /// 应用一次状态变更，追加事件历史。
    mutating func applyTransition(
        to newLifecycle: DecisionCaseLifecycle,
        decisionState newDecisionState: PortfolioDecisionState,
        at timestamp: Date,
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
            actor: actor)
        lifecycle = newLifecycle
        decisionState = newDecisionState
        updatedAt = timestamp
        events.append(event)
    }

    /// 是否到达复查时间（用显式 reviewDueAt）。
    func isReviewDue(asOf now: Date) -> Bool {
        guard let reviewDueAt else { return false }
        return now >= reviewDueAt
    }

    /// 进入 monitoring 时的复查时间：watch 7 天 / prepare+insufficient 3 天 /
    /// adjustReview 1 天 / stable 不设复查（V1 语义，上海日历日推算）。
    static func computeReviewDueAt(
        decisionState: PortfolioDecisionState, from date: Date
    ) -> Date? {
        let days: Int
        switch decisionState {
        case .watch: days = 7
        case .prepare, .insufficientEvidence: days = 3
        case .adjustReview: days = 1
        case .stable: return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.date(byAdding: .day, value: days, to: date)
    }
}

// MARK: - 展示文案（V2 域内稳定文案，供 Formatter 与测试共用）

extension DecisionCaseKind {
    var displayName: String {
        switch self {
        case .concentrationRisk: return "集中度风险"
        case .drawdownExpansion: return "回撤扩大"
        case .targetDeviation: return "目标偏离"
        case .actionMigration: return "行动迁移"
        }
    }
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
        case .insufficientEvidence: return "证据不足"
        }
    }

    var guidanceText: String {
        switch self {
        case .stable: return "暂不需要改变组合"
        case .watch: return "保留持仓，等待条件确认"
        case .prepare: return "先准备方案，不立即交易"
        case .adjustReview: return "评估是否降低相关暴露"
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

extension DecisionReviewConclusion {
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
