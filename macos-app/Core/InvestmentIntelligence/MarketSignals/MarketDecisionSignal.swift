import Foundation

// MARK: - 信号来源

/// 信号抽取来源。
enum SignalSourceKind: String, Codable, Hashable, Sendable {
    case trendReport   // 趋势研究报告行动候选（既有链路 A）
    case pipeline      // L7 决策流水线仪表盘（M8 接入）
    case manual        // 手工创建（预留）
}

// MARK: - 状态与结局

/// 信号生命周期状态。
enum SignalStatus: String, Codable, Hashable, Sendable {
    case active
    case settledWin        // 触及目标价（方向兑现）
    case settledLoss       // 触及止损/反向确认
    case expiredUnresolved // 到期末触发（计入样本不计入胜率分子）
    case invalidated       // 反向信号出现/用户关闭
    case insufficientData  // 无覆盖行情，无法结算
}

extension SignalStatus {
    var isTerminal: Bool {
        switch self {
        case .active: return false
        case .settledWin, .settledLoss, .expiredUnresolved, .invalidated, .insufficientData: return true
        }
    }

    var displayName: String {
        switch self {
        case .active: return "跟踪中"
        case .settledWin: return "判断成立"
        case .settledLoss: return "判断不成立"
        case .expiredUnresolved: return "到期未触发"
        case .invalidated: return "已被反向信号取代"
        case .insufficientData: return "数据不足"
        }
    }
}

/// 结算明细。
struct SignalSettlement: Codable, Hashable, Sendable {
    /// 结算结局（不用「正确/错误」二元表述，对齐 DecisionReview 口径）。
    enum Outcome: String, Codable, Hashable, Sendable {
        case hitTarget          // 到达目标价/方向兑现
        case hitStop            // 触发止损/反向确认
        case expiredUnresolved  // 到期未触发
        case superseded         // 被反向信号取代
        case insufficientData   // 无覆盖行情
    }

    let settledAt: String
    let outcome: Outcome
    /// 结算价（触价那根 K 线的成交基准价）
    let settlePrice: Double?
    let settleDate: String?
    /// 结算窗口内最大有利波动 %
    let maxFavorablePct: Double?
    /// 结算窗口内最大不利波动 %
    let maxAdversePct: Double?
    /// 结算说明（先止损口径/跳空按开盘价/反推前收盘等）
    let note: String
}

// MARK: - 事件

/// 追加式事件历史（审计，对齐 DecisionCaseEvent 模式）。
struct SignalEvent: Codable, Hashable, Sendable, Identifiable {
    enum EventType: String, Codable, Hashable, Sendable {
        case created
        case invalidated
        case superseded
        case settled
        case expired
        case insufficientData
    }

    let id: UUID
    let at: String
    let type: EventType
    let reason: String

    init(id: UUID = UUID(), at: String, type: EventType, reason: String) {
        self.id = id
        self.at = at
        self.type = type
        self.reason = reason
    }
}

// MARK: - 价格条件

/// 结构化价格条件（结算依据）。不可解析的自然语言条件留在 watchConditions。
struct SignalPriceConditions: Codable, Hashable, Sendable {
    var entryLow: Double?
    var entryHigh: Double?
    var stopLoss: Double?
    var targetPrice: Double?

    var hasAnyPrice: Bool {
        entryLow != nil || entryHigh != nil || stopLoss != nil || targetPrice != nil
    }

    /// 是否具备可自动结算的价格条件（方向价 + 反向价至少各一，或至少一个方向价）。
    var isSettleable: Bool {
        stopLoss != nil || targetPrice != nil
    }

    /// 解析来源说明（正则命中哪些关键词）。
    var parseNotes: [String] = []

    init(
        entryLow: Double? = nil,
        entryHigh: Double? = nil,
        stopLoss: Double? = nil,
        targetPrice: Double? = nil,
        parseNotes: [String] = []
    ) {
        self.entryLow = entryLow
        self.entryHigh = entryHigh
        self.stopLoss = stopLoss
        self.targetPrice = targetPrice
        self.parseNotes = parseNotes
    }
}

// MARK: - 信号主体

/// 标的级市场决策信号：从研判产物抽取的结构化、可到期结算的判断。
/// 与 DecisionCase 正交互补——Case 是组合级决策事项（用户处置中心），
/// Signal 是标的级市场判定（自动结算中心）；数据不互写。
struct MarketDecisionSignal: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    /// 创建去重键：sourceKind|actionID|subjectKey
    let dedupKey: String
    let sourceKind: SignalSourceKind
    /// 来源行动/报告标识（审计溯源）
    let sourceActionID: String

    // 标的（代码可能为 nil：组合级动作无市场标的）
    let subjectCode: String?
    let subjectName: String
    /// 可解析出的 A股代码才走市价结算；否则仅计样本
    let marketSettleable: Bool

    // 判断
    let direction: CanonicalDecisionType
    let action: CanonicalAction
    /// canonical 分数带的锚点分（审计口径：非市场预测分）
    let score: Int
    let rawConfidence: Double
    var calibratedConfidence: Double

    // 条件
    var priceConditions: SignalPriceConditions
    let watchConditions: [String]
    let invalidatingConditions: [String]
    let reason: String
    let evidenceIDs: [String]
    let dataQualitySummary: String

    // 生命周期
    let createdAt: String
    let reviewDueAt: String
    var status: SignalStatus
    var settlement: SignalSettlement?
    var events: [SignalEvent]

    init(
        id: UUID = UUID(),
        schemaVersion: Int = MarketDecisionSignal.currentSchemaVersion,
        dedupKey: String,
        sourceKind: SignalSourceKind,
        sourceActionID: String,
        subjectCode: String?,
        subjectName: String,
        marketSettleable: Bool,
        direction: CanonicalDecisionType,
        action: CanonicalAction,
        score: Int,
        rawConfidence: Double,
        calibratedConfidence: Double? = nil,
        priceConditions: SignalPriceConditions,
        watchConditions: [String],
        invalidatingConditions: [String],
        reason: String,
        evidenceIDs: [String],
        dataQualitySummary: String,
        createdAt: String,
        reviewDueAt: String,
        status: SignalStatus = .active,
        settlement: SignalSettlement? = nil,
        events: [SignalEvent] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.dedupKey = dedupKey
        self.sourceKind = sourceKind
        self.sourceActionID = sourceActionID
        self.subjectCode = subjectCode
        self.subjectName = subjectName
        self.marketSettleable = marketSettleable
        self.direction = direction
        self.action = action
        self.score = score
        self.rawConfidence = rawConfidence
        self.calibratedConfidence = calibratedConfidence ?? rawConfidence
        self.priceConditions = priceConditions
        self.watchConditions = watchConditions
        self.invalidatingConditions = invalidatingConditions
        self.reason = reason
        self.evidenceIDs = evidenceIDs
        self.dataQualitySummary = dataQualitySummary
        self.createdAt = createdAt
        self.reviewDueAt = reviewDueAt
        self.status = status
        self.settlement = settlement
        self.events = events
    }

    // MARK: - V1 兼容解码（对齐 DecisionCase 的 decodeIfPresent 模式）

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        dedupKey = try c.decodeIfPresent(String.self, forKey: .dedupKey) ?? ""
        sourceKind = try c.decodeIfPresent(SignalSourceKind.self, forKey: .sourceKind) ?? .trendReport
        sourceActionID = try c.decodeIfPresent(String.self, forKey: .sourceActionID) ?? ""
        subjectCode = try c.decodeIfPresent(String.self, forKey: .subjectCode)
        subjectName = try c.decodeIfPresent(String.self, forKey: .subjectName) ?? ""
        marketSettleable = try c.decodeIfPresent(Bool.self, forKey: .marketSettleable) ?? false
        direction = try c.decodeIfPresent(CanonicalDecisionType.self, forKey: .direction) ?? .hold
        action = try c.decodeIfPresent(CanonicalAction.self, forKey: .action) ?? .watch
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 50
        rawConfidence = try c.decodeIfPresent(Double.self, forKey: .rawConfidence) ?? 0.6
        calibratedConfidence = try c.decodeIfPresent(Double.self, forKey: .calibratedConfidence) ?? rawConfidence
        priceConditions = try c.decodeIfPresent(SignalPriceConditions.self, forKey: .priceConditions) ?? SignalPriceConditions()
        watchConditions = try c.decodeIfPresent([String].self, forKey: .watchConditions) ?? []
        invalidatingConditions = try c.decodeIfPresent([String].self, forKey: .invalidatingConditions) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        dataQualitySummary = try c.decodeIfPresent(String.self, forKey: .dataQualitySummary) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        reviewDueAt = try c.decodeIfPresent(String.self, forKey: .reviewDueAt) ?? createdAt
        status = try c.decodeIfPresent(SignalStatus.self, forKey: .status) ?? .active
        settlement = try c.decodeIfPresent(SignalSettlement.self, forKey: .settlement)
        events = try c.decodeIfPresent([SignalEvent].self, forKey: .events) ?? []
    }
}
