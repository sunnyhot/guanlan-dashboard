import Foundation

enum ManagerWatchIntervalOption: Int, CaseIterable, Identifiable, Codable {
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case twoHours = 120

    var id: Int { rawValue }

    var label: String {
        switch rawValue {
        case 60:
            return "1 小时"
        case 120:
            return "2 小时"
        default:
            return "\(rawValue) 分钟"
        }
    }
}

enum ManagerWatchAdjustmentSourceKind: String, Codable, Hashable {
    case longWin = "long_win"
    case alfa
}

struct ManagerWatchAdjustmentSource: Identifiable, Hashable {
    static let longWinID = ManagerWatchAdjustmentSourceKind.longWin.rawValue
    static let alfaIDPrefix = "\(ManagerWatchAdjustmentSourceKind.alfa.rawValue):"

    let kind: ManagerWatchAdjustmentSourceKind
    let code: String
    let name: String

    var id: String {
        switch kind {
        case .longWin:
            return Self.longWinID
        case .alfa:
            return "\(Self.alfaIDPrefix)\(code)"
        }
    }

    var displayName: String {
        switch kind {
        case .longWin:
            return "长赢调仓"
        case .alfa:
            return name.isEmpty ? code : name
        }
    }

    var detailText: String {
        switch kind {
        case .longWin:
            return code.isEmpty ? "请填写产品代码" : code
        case .alfa:
            return "投顾组合 · \(code)"
        }
    }

    var baselineTargetKey: String {
        "\(id)|\(code)"
    }

    static func longWin(prodCode: String) -> Self {
        Self(kind: .longWin, code: prodCode, name: "长赢调仓")
    }

    static func alfa(code: String, name: String) -> Self {
        Self(kind: .alfa, code: code, name: name)
    }

    static func alfaCode(from sourceID: String) -> String? {
        guard sourceID.hasPrefix(alfaIDPrefix) else { return nil }
        let code = String(sourceID.dropFirst(alfaIDPrefix.count))
        return code.isEmpty ? nil : code
    }
}

struct ManagerWatchSettings: Codable, Hashable {
    var isEnabled: Bool
    var notificationsEnabled: Bool
    var intervalMinutes: Int
    var prodCode: String
    var managerName: String
    var watchForum: Bool
    var selectedAdjustmentSourceIDs: Set<String>
    var latestSeenAdjustmentIDs: [String: String]
    var adjustmentBaselineTargetKeys: [String: String]
    var latestSeenForumRecordID: String?
    var forumBaselineTargetKey: String?
    var lastCheckedAt: String?
    var lastSuccessAt: String?
    var lastErrorMessage: String?
    var lastNotificationErrorMessage: String?
    var lastResultSummary: String?
    var lastHitAt: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case notificationsEnabled
        case intervalMinutes
        case prodCode
        case managerName
        case watchPlatform
        case watchForum
        case selectedAdjustmentSourceIDs
        case latestSeenAdjustmentIDs
        case adjustmentBaselineTargetKeys
        case latestSeenPlatformActionID
        case latestSeenForumRecordID
        case forumBaselineTargetKey
        case lastCheckedAt
        case lastSuccessAt
        case lastErrorMessage
        case lastNotificationErrorMessage
        case lastResultSummary
        case lastHitAt
    }

    init(
        isEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        intervalMinutes: Int = 10,
        prodCode: String = "LONG_WIN",
        managerName: String = "ETF拯救世界",
        watchPlatform: Bool = true,
        watchForum: Bool = true,
        selectedAdjustmentSourceIDs: Set<String>? = nil,
        latestSeenAdjustmentIDs: [String: String] = [:],
        adjustmentBaselineTargetKeys: [String: String] = [:],
        latestSeenPlatformActionID: String? = nil,
        latestSeenForumRecordID: String? = nil,
        forumBaselineTargetKey: String? = nil,
        lastCheckedAt: String? = nil,
        lastSuccessAt: String? = nil,
        lastErrorMessage: String? = nil,
        lastNotificationErrorMessage: String? = nil,
        lastResultSummary: String? = nil,
        lastHitAt: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.notificationsEnabled = notificationsEnabled
        self.intervalMinutes = intervalMinutes
        self.prodCode = prodCode
        self.managerName = managerName
        self.watchForum = watchForum
        self.selectedAdjustmentSourceIDs = selectedAdjustmentSourceIDs
            ?? (watchPlatform ? [ManagerWatchAdjustmentSource.longWinID] : [])
        self.latestSeenAdjustmentIDs = latestSeenAdjustmentIDs
        if let latestSeenPlatformActionID,
           self.latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] == nil {
            self.latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] = latestSeenPlatformActionID
        }
        self.adjustmentBaselineTargetKeys = adjustmentBaselineTargetKeys
        self.latestSeenForumRecordID = latestSeenForumRecordID
        self.forumBaselineTargetKey = forumBaselineTargetKey
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastErrorMessage = lastErrorMessage
        self.lastNotificationErrorMessage = lastNotificationErrorMessage
        self.lastResultSummary = lastResultSummary
        self.lastHitAt = lastHitAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 10
        prodCode = try container.decodeIfPresent(String.self, forKey: .prodCode) ?? "LONG_WIN"
        managerName = try container.decodeIfPresent(String.self, forKey: .managerName) ?? "ETF拯救世界"
        watchForum = try container.decodeIfPresent(Bool.self, forKey: .watchForum) ?? true

        let legacyWatchPlatform = try container.decodeIfPresent(Bool.self, forKey: .watchPlatform) ?? true
        let decodedSourceIDs = try container.decodeIfPresent([String].self, forKey: .selectedAdjustmentSourceIDs)
        selectedAdjustmentSourceIDs = Set(
            decodedSourceIDs ?? (legacyWatchPlatform ? [ManagerWatchAdjustmentSource.longWinID] : [])
        )

        latestSeenAdjustmentIDs = try container.decodeIfPresent(
            [String: String].self,
            forKey: .latestSeenAdjustmentIDs
        ) ?? [:]
        if let legacyID = try container.decodeIfPresent(String.self, forKey: .latestSeenPlatformActionID),
           latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] == nil {
            latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] = legacyID
        }
        adjustmentBaselineTargetKeys = try container.decodeIfPresent(
            [String: String].self,
            forKey: .adjustmentBaselineTargetKeys
        ) ?? [:]
        latestSeenForumRecordID = try container.decodeIfPresent(String.self, forKey: .latestSeenForumRecordID)
        forumBaselineTargetKey = try container.decodeIfPresent(String.self, forKey: .forumBaselineTargetKey)
        lastCheckedAt = try container.decodeIfPresent(String.self, forKey: .lastCheckedAt)
        lastSuccessAt = try container.decodeIfPresent(String.self, forKey: .lastSuccessAt)
        lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        lastNotificationErrorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .lastNotificationErrorMessage
        )
        lastResultSummary = try container.decodeIfPresent(String.self, forKey: .lastResultSummary)
        lastHitAt = try container.decodeIfPresent(String.self, forKey: .lastHitAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(prodCode, forKey: .prodCode)
        try container.encode(managerName, forKey: .managerName)
        try container.encode(watchPlatform, forKey: .watchPlatform)
        try container.encode(watchForum, forKey: .watchForum)
        try container.encode(selectedAdjustmentSourceIDs.sorted(), forKey: .selectedAdjustmentSourceIDs)
        try container.encode(latestSeenAdjustmentIDs, forKey: .latestSeenAdjustmentIDs)
        try container.encode(adjustmentBaselineTargetKeys, forKey: .adjustmentBaselineTargetKeys)
        try container.encodeIfPresent(latestSeenPlatformActionID, forKey: .latestSeenPlatformActionID)
        try container.encodeIfPresent(latestSeenForumRecordID, forKey: .latestSeenForumRecordID)
        try container.encodeIfPresent(forumBaselineTargetKey, forKey: .forumBaselineTargetKey)
        try container.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try container.encodeIfPresent(lastNotificationErrorMessage, forKey: .lastNotificationErrorMessage)
        try container.encodeIfPresent(lastResultSummary, forKey: .lastResultSummary)
        try container.encodeIfPresent(lastHitAt, forKey: .lastHitAt)
    }

    var watchPlatform: Bool {
        get { !selectedAdjustmentSourceIDs.isEmpty }
        set {
            if newValue {
                if selectedAdjustmentSourceIDs.isEmpty {
                    selectedAdjustmentSourceIDs.insert(ManagerWatchAdjustmentSource.longWinID)
                }
            } else {
                selectedAdjustmentSourceIDs.removeAll()
            }
        }
    }

    var latestSeenPlatformActionID: String? {
        get { latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] }
        set { latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID] = newValue }
    }

    static let `default` = ManagerWatchSettings()

    var intervalLabel: String {
        ManagerWatchIntervalOption(rawValue: intervalMinutes)?.label ?? "\(intervalMinutes) 分钟"
    }
}

enum NotificationDeepLinkType: String {
    case platformAction = "platform_action"
    case forumRecord = "forum_record"
    case workbenchTrend = "workbench_trend"
    case personalWatchlist = "personal_watchlist"
}

struct NotificationDeepLinkPayload: Hashable {
    let type: NotificationDeepLinkType
    let targetID: String
    let prodCode: String?
    let managerName: String?
    let adjustmentSourceKind: ManagerWatchAdjustmentSourceKind?
    let adjustmentSourceCode: String?

    var userInfo: [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            "deep_link_type": type.rawValue,
            "deep_link_target_id": targetID,
        ]
        if let prodCode, !prodCode.isEmpty {
            payload["deep_link_prod_code"] = prodCode
        }
        if let managerName, !managerName.isEmpty {
            payload["deep_link_manager_name"] = managerName
        }
        if let adjustmentSourceKind {
            payload["deep_link_adjustment_source_kind"] = adjustmentSourceKind.rawValue
        }
        if let adjustmentSourceCode, !adjustmentSourceCode.isEmpty {
            payload["deep_link_adjustment_source_code"] = adjustmentSourceCode
        }
        return payload
    }

    init(
        type: NotificationDeepLinkType,
        targetID: String,
        prodCode: String? = nil,
        managerName: String? = nil,
        adjustmentSourceKind: ManagerWatchAdjustmentSourceKind? = nil,
        adjustmentSourceCode: String? = nil
    ) {
        self.type = type
        self.targetID = targetID
        self.prodCode = prodCode
        self.managerName = managerName
        self.adjustmentSourceKind = adjustmentSourceKind
        self.adjustmentSourceCode = adjustmentSourceCode
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let rawType = userInfo["deep_link_type"] as? String,
            let type = NotificationDeepLinkType(rawValue: rawType),
            let targetID = userInfo["deep_link_target_id"] as? String,
            !targetID.isEmpty
        else {
            return nil
        }
        self.type = type
        self.targetID = targetID
        self.prodCode = userInfo["deep_link_prod_code"] as? String
        self.managerName = userInfo["deep_link_manager_name"] as? String
        self.adjustmentSourceKind = (userInfo["deep_link_adjustment_source_kind"] as? String)
            .flatMap(ManagerWatchAdjustmentSourceKind.init(rawValue:))
        self.adjustmentSourceCode = userInfo["deep_link_adjustment_source_code"] as? String
    }
}
