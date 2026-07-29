import Foundation

/// 跟踪项状态（第一版人工管理，不根据自然语言条件伪造自动触发）
enum TrendTrackingStatus: String, Codable, Hashable, CaseIterable {
    case observing
    case approaching
    case triggered
    case invalidated
    case staleData
    case processed
    case ended

    var displayText: String {
        switch self {
        case .observing:
            return "观察中"
        case .approaching:
            return "接近触发"
        case .triggered:
            return "已触发"
        case .invalidated:
            return "已失效"
        case .staleData:
            return "数据过期"
        case .processed:
            return "已处理"
        case .ended:
            return "已结束"
        }
    }
}

/// 跟踪项状态变更记录（用于状态历史）
struct TrendTrackingStatusChange: Codable, Hashable {
    let at: String
    let from: TrendTrackingStatus?
    let to: TrendTrackingStatus
    let note: String

    init(at: String, from: TrendTrackingStatus?, to: TrendTrackingStatus, note: String) {
        self.at = at
        self.from = from
        self.to = to
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decodeIfPresent(String.self, forKey: .at) ?? ""
        from = try container.decodeIfPresent(TrendTrackingStatus.self, forKey: .from)
        to = try container.decodeIfPresent(TrendTrackingStatus.self, forKey: .to) ?? .observing
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case from
        case to
        case note
    }
}

/// 用户从「今日研判」主动加入跟踪的一条行动候选
struct TrendTrackingItem: Codable, Identifiable, Hashable {
    let id: UUID
    let sourceReportID: UUID
    let sourceGeneratedAt: String
    var assetKey: String?
    var assetName: String
    var assetCode: String?
    var action: TrendActionKind
    var reason: String
    var confidence: TrendConfidence
    var triggerConditions: [String]
    var invalidatingConditions: [String]
    var createdAt: String
    var status: TrendTrackingStatus
    var snoozeUntil: String?
    var statusHistory: [TrendTrackingStatusChange]

    init(
        id: UUID = UUID(),
        sourceReportID: UUID,
        sourceGeneratedAt: String,
        assetKey: String?,
        assetName: String,
        assetCode: String?,
        action: TrendActionKind,
        reason: String,
        confidence: TrendConfidence,
        triggerConditions: [String],
        invalidatingConditions: [String],
        createdAt: String,
        status: TrendTrackingStatus,
        snoozeUntil: String? = nil,
        statusHistory: [TrendTrackingStatusChange] = []
    ) {
        self.id = id
        self.sourceReportID = sourceReportID
        self.sourceGeneratedAt = sourceGeneratedAt
        self.assetKey = assetKey
        self.assetName = assetName
        self.assetCode = assetCode
        self.action = action
        self.reason = reason
        self.confidence = confidence
        self.triggerConditions = triggerConditions
        self.invalidatingConditions = invalidatingConditions
        self.createdAt = createdAt
        self.status = status
        self.snoozeUntil = snoozeUntil
        self.statusHistory = statusHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceReportID = try container.decodeIfPresent(UUID.self, forKey: .sourceReportID) ?? UUID()
        sourceGeneratedAt = try container.decodeIfPresent(String.self, forKey: .sourceGeneratedAt) ?? ""
        assetKey = try container.decodeIfPresent(String.self, forKey: .assetKey)
        assetName = try container.decodeIfPresent(String.self, forKey: .assetName) ?? ""
        assetCode = try container.decodeIfPresent(String.self, forKey: .assetCode)
        action = try container.decodeIfPresent(TrendActionKind.self, forKey: .action) ?? .watch
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        confidence = try container.decodeIfPresent(TrendConfidence.self, forKey: .confidence)
            ?? TrendConfidence(score: 0, label: "低")
        triggerConditions = try container.decodeIfPresent([String].self, forKey: .triggerConditions) ?? []
        invalidatingConditions = try container.decodeIfPresent([String].self, forKey: .invalidatingConditions) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        status = try container.decodeIfPresent(TrendTrackingStatus.self, forKey: .status) ?? .observing
        snoozeUntil = try container.decodeIfPresent(String.self, forKey: .snoozeUntil)
        statusHistory = try container.decodeIfPresent([TrendTrackingStatusChange].self, forKey: .statusHistory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceReportID, forKey: .sourceReportID)
        try container.encode(sourceGeneratedAt, forKey: .sourceGeneratedAt)
        try container.encodeIfPresent(assetKey, forKey: .assetKey)
        try container.encode(assetName, forKey: .assetName)
        try container.encodeIfPresent(assetCode, forKey: .assetCode)
        try container.encode(action, forKey: .action)
        try container.encode(reason, forKey: .reason)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(triggerConditions, forKey: .triggerConditions)
        try container.encode(invalidatingConditions, forKey: .invalidatingConditions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(snoozeUntil, forKey: .snoozeUntil)
        try container.encode(statusHistory, forKey: .statusHistory)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceReportID
        case sourceGeneratedAt
        case assetKey
        case assetName
        case assetCode
        case action
        case reason
        case confidence
        case triggerConditions
        case invalidatingConditions
        case createdAt
        case status
        case snoozeUntil
        case statusHistory
    }

    /// 是否仍占用「同一标的+动作」的去重位（ended 后可重新加入）
    var isActive: Bool {
        status != .ended
    }

    /// 去重键：assetKey 优先，否则用 name+code 兜底，再拼动作
    var dedupeKey: String {
        let asset: String
        if let key = assetKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            asset = key
        } else {
            asset = [assetName, assetCode]
                .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                .filter { !$0.isEmpty }
                .joined(separator: "|")
                .lowercased()
        }
        return "\(asset)|\(action.rawValue)"
    }
}
