import CryptoKit
import Foundation

enum TrendPrivacyMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case sanitized = "脱敏摘要"
    case fullDetail = "完整明细"

    var id: String { rawValue }
}

enum TrendGenerationState: String, Codable, Hashable {
    case idle
    case generating
    case succeeded
    case failed
    case rejected
}

enum TrendConnectionState: String, Codable, Hashable {
    case idle
    case checking
    case succeeded
    case failed
}

/// 研判运行中模型当前轮次的实时输出（仅 UI 实时展示；刻意不落运行日志）。
struct TrendLiveModelOutput: Equatable {
    let turn: Int
    var text: String
    /// 最近一次增量的种类（种类切换时插入分隔标记）。
    var lastKind: AgentStreamDeltaKind?
}

struct TrendProgressLog: Identifiable, Hashable {
    enum Level: String, Hashable {
        case info
        case activity
        case success
        case warning
        case error
    }

    let id: UUID
    let timestamp: String
    let message: String
    let detail: String?
    let level: Level

    init(
        id: UUID = UUID(),
        timestamp: String,
        message: String,
        detail: String? = nil,
        level: Level = .info
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.detail = detail
        self.level = level
    }
}

enum TrendExternalSignalStatus: String, Codable, Hashable {
    case available
    case unavailable
    case partial
    case stale
}

enum TrendRiskLevel: String, Codable, Hashable {
    case low
    case medium
    case high
    case unknown
}

enum TrendDirection: String, Codable, Hashable {
    case bullish
    case neutralPositive
    case neutral
    case neutralNegative
    case bearish
    case uncertain

    /// Agent 输出边界的容错解析。模型偶尔会忽略 schema，返回 up/down/flat
    /// 或 snake_case 同义词；这不应让整个分模块报告解码失败。明确同义词映射到
    /// 最接近的方向，无法识别的值保守降级为 uncertain。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "bullish", "strongbullish", "verybullish", "strongpositive",
             "strongup", "up", "看多", "上涨", "向上":
            self = .bullish
        case "neutralpositive", "slightlybullish", "mildlybullish", "positive",
             "positivebias", "upwardbias", "bullishbias", "偏强", "中性偏强":
            self = .neutralPositive
        case "neutral", "flat", "sideways", "rangebound", "mixed", "unchanged",
             "中性", "震荡", "横盘":
            self = .neutral
        case "neutralnegative", "slightlybearish", "mildlybearish", "negative",
             "negativebias", "downwardbias", "bearishbias", "偏弱", "中性偏弱":
            self = .neutralNegative
        case "bearish", "strongbearish", "verybearish", "strongnegative",
             "strongdown", "down", "看空", "下跌", "向下":
            self = .bearish
        case "uncertain", "unknown", "unclear", "inconclusive", "na", "none",
             "不确定", "未知":
            self = .uncertain
        default:
            self = .uncertain
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TrendHorizon: String, Codable, CaseIterable, Identifiable, Hashable {
    case short
    case medium
    case long

    var id: String { rawValue }
}


/// 面向用户的动作文案(原定义在视图层,Core 的决策案例写入也依赖,下沉至此)。
extension TrendActionKind {
    var displayText: String {
        switch self {
        case .watch:
            return "观察"
        case .waitForConfirmation:
            return "等待确认"
        case .observeInBatches:
            return "分批观察"
        case .pausePlan:
            return "暂停计划"
        case .considerIncrease:
            return "考虑增加"
        case .considerReduce:
            return "考虑降低"
        case .rebalanceReview:
            return "调仓复核"
        }
    }
}

enum TrendActionKind: String, Codable, Hashable {
    case watch
    case waitForConfirmation
    case observeInBatches
    case pausePlan
    case considerIncrease
    case considerReduce
    case rebalanceReview
}

enum TrendEvidencePolicyLevel: String, Codable, Hashable, Sendable {
    case informational
    case allocationReview
    case execution
}

enum TrendReportDisposition: String, Codable, Hashable, Sendable {
    case actionable
    case analysisOnly
    case insufficientEvidence
}

struct TrendClaimEvidence: Codable, Hashable, Sendable {
    let supportingEvidenceIDs: [String]
    let counterEvidenceIDs: [String]
    let contextEvidenceIDs: [String]
    let exemptionReason: String?

    static let empty = TrendClaimEvidence()

    init(
        supportingEvidenceIDs: [String] = [],
        counterEvidenceIDs: [String] = [],
        contextEvidenceIDs: [String] = [],
        exemptionReason: String? = nil
    ) {
        self.supportingEvidenceIDs = Self.unique(supportingEvidenceIDs)
        self.counterEvidenceIDs = Self.unique(counterEvidenceIDs)
        self.contextEvidenceIDs = Self.unique(contextEvidenceIDs)
        let trimmed = exemptionReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exemptionReason = trimmed?.isEmpty == false ? trimmed : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            supportingEvidenceIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .supportingEvidenceIDs
            ) ?? [],
            counterEvidenceIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .counterEvidenceIDs
            ) ?? [],
            contextEvidenceIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .contextEvidenceIDs
            ) ?? [],
            exemptionReason: try container.decodeIfPresent(
                String.self,
                forKey: .exemptionReason
            )
        )
    }

    var allEvidenceIDs: [String] {
        Self.unique(supportingEvidenceIDs + counterEvidenceIDs + contextEvidenceIDs)
    }

    var hasStructuredExemption: Bool {
        exemptionReason != nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case supportingEvidenceIDs
        case counterEvidenceIDs
        case contextEvidenceIDs
        case exemptionReason
    }
}

struct TrendConfidence: Codable, Hashable {
    let score: Int
    let label: String

    var normalizedScore: Int {
        min(100, max(0, score))
    }

    var appNormalized: TrendConfidence {
        TrendConfidence(
            score: normalizedScore,
            label: Self.label(for: normalizedScore)
        )
    }

    init(score: Int, label: String) {
        self.score = score
        self.label = label
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer() {
            if let score = try? singleValue.decode(Int.self) {
                self.score = score
                self.label = Self.label(for: score)
                return
            }
            if let ratio = try? singleValue.decode(Double.self) {
                let score = ratio <= 1 ? Int((ratio * 100).rounded()) : Int(ratio.rounded())
                self.score = score
                self.label = Self.label(for: score)
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decode(Int.self, forKey: .score)
        label = try container.decode(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(score, forKey: .score)
        try container.encode(label, forKey: .label)
    }

    private enum CodingKeys: String, CodingKey {
        case score
        case label
    }

    static func label(for score: Int) -> String {
        if score >= 75 { return "高" }
        if score >= 45 { return "中" }
        return "低"
    }
}

struct TrendAIProviderSettings: Codable, Hashable {
    var providerName: String
    var baseURL: String
    var model: String
    var apiKey: String
    var timeoutSeconds: Double

    static let defaultGenerationTimeoutSeconds: Double = 300

    static let empty = TrendAIProviderSettings(
        providerName: "",
        baseURL: "",
        model: "",
        apiKey: "",
        timeoutSeconds: defaultGenerationTimeoutSeconds
    )

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 基于 baseURL+model+apiKey 的稳定指纹（SHA256 截断），用于判断能力检测结果是否仍对当前配置有效。
    /// 不含 apiKey 明文，跨进程稳定。
    var fingerprint: String {
        let raw = "\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))|\(model.trimmingCharacters(in: .whitespacesAndNewlines))|\(apiKey)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    var redactedAPIKey: String {
        Self.mask(apiKey)
    }

    var upgradedForTrendGeneration: TrendAIProviderSettings {
        guard isConfigured, timeoutSeconds < Self.defaultGenerationTimeoutSeconds else { return self }
        var upgraded = self
        upgraded.timeoutSeconds = Self.defaultGenerationTimeoutSeconds
        return upgraded
    }

    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "" : "...." }
        return "\(trimmed.prefix(3))...\(trimmed.suffix(4))"
    }

    init(
        providerName: String,
        baseURL: String,
        model: String,
        apiKey: String,
        timeoutSeconds: Double
    ) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? Self.defaultGenerationTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case providerName
        case baseURL
        case model
        case apiKey
        case timeoutSeconds
    }
}

struct AlphaVantageSettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var apiKey: String
    var dailyRequestLimit: Int

    static let freeDailyRequestLimit = 25
    static let empty = AlphaVantageSettings(
        enabled: false,
        apiKey: "",
        dailyRequestLimit: freeDailyRequestLimit
    )

    var isConfigured: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedDailyRequestLimit: Int {
        min(10_000, max(1, dailyRequestLimit))
    }

    var redactedAPIKey: String {
        TrendAIProviderSettings.mask(apiKey)
    }

    init(
        enabled: Bool = false,
        apiKey: String,
        dailyRequestLimit: Int = freeDailyRequestLimit
    ) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.dailyRequestLimit = min(10_000, max(1, dailyRequestLimit))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        dailyRequestLimit = min(
            10_000,
            max(
                1,
                try container.decodeIfPresent(Int.self, forKey: .dailyRequestLimit)
                    ?? Self.freeDailyRequestLimit
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case apiKey
        case dailyRequestLimit
    }
}

/// W3.1 链路 A 通知偏好:默认只开「收盘复盘完成 + 自动失败」最小集,
/// 其余链路由用户在设置里显式打开,避免通知轰炸。
struct TrendNotificationPreferences: Codable, Hashable {
    var closeReviewSuccessEnabled: Bool
    var marketRadarSuccessEnabled: Bool
    var longTermSuccessEnabled: Bool
    var firstReportEnabled: Bool
    var autoFailureEnabled: Bool

    static let `default` = TrendNotificationPreferences()

    init(
        closeReviewSuccessEnabled: Bool = true,
        marketRadarSuccessEnabled: Bool = false,
        longTermSuccessEnabled: Bool = false,
        firstReportEnabled: Bool = false,
        autoFailureEnabled: Bool = true
    ) {
        self.closeReviewSuccessEnabled = closeReviewSuccessEnabled
        self.marketRadarSuccessEnabled = marketRadarSuccessEnabled
        self.longTermSuccessEnabled = longTermSuccessEnabled
        self.firstReportEnabled = firstReportEnabled
        self.autoFailureEnabled = autoFailureEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        closeReviewSuccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .closeReviewSuccessEnabled) ?? true
        marketRadarSuccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .marketRadarSuccessEnabled) ?? false
        longTermSuccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .longTermSuccessEnabled) ?? false
        firstReportEnabled = try container.decodeIfPresent(Bool.self, forKey: .firstReportEnabled) ?? false
        autoFailureEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoFailureEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(closeReviewSuccessEnabled, forKey: .closeReviewSuccessEnabled)
        try container.encode(marketRadarSuccessEnabled, forKey: .marketRadarSuccessEnabled)
        try container.encode(longTermSuccessEnabled, forKey: .longTermSuccessEnabled)
        try container.encode(firstReportEnabled, forKey: .firstReportEnabled)
        try container.encode(autoFailureEnabled, forKey: .autoFailureEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case closeReviewSuccessEnabled
        case marketRadarSuccessEnabled
        case longTermSuccessEnabled
        case firstReportEnabled
        case autoFailureEnabled
    }

    /// 是否发送该通知。手动触发的成功只在「首份研判」偏好开启时发送;
    /// 自动调度不会请求 full scope,防御性关闭。
    func wants(_ notice: TrendCompletionNotification) -> Bool {
        switch notice.outcome {
        case .failed:
            return autoFailureEnabled && !notice.userInitiated
        case .succeeded:
            if notice.userInitiated {
                return notice.isFirstReport && firstReportEnabled
            }
            switch notice.scope {
            case .closeReview: return closeReviewSuccessEnabled
            case .marketRadar: return marketRadarSuccessEnabled
            case .longTerm: return longTermSuccessEnabled
            case .full: return false
            }
        }
    }
}

struct TrendAnalysisSettings: Codable, Hashable {
    var provider: TrendAIProviderSettings
    var alphaVantage: AlphaVantageSettings
    var defaultPrivacyMode: TrendPrivacyMode
    var dailyAutoAnalysisEnabled: Bool
    var dailyAutoAnalysisTimes: [String]
    var lastAutoAnalysisDay: String?
    var lastAutoAnalysisSlotKey: String?
    var lastModuleAutoAnalysisKeys: [String: String]
    var lastModuleGeneratedAt: [String: String]
    var notifications: TrendNotificationPreferences
    /// W3.5 连续失败升级:scope → 连续未成功的自动窗口数(成功即清零)。
    var autoFailureStreaks: [String: Int]
    /// W3.5:scope → 最近一次自动失败的错误文案(TodayBrief 人话化用)。
    var lastAutoFailureMessages: [String: String]

    static let `default` = TrendAnalysisSettings(
        provider: .empty,
        alphaVantage: .empty,
        defaultPrivacyMode: .sanitized,
        dailyAutoAnalysisEnabled: false,
        dailyAutoAnalysisTimes: TrendAutoAnalysisSchedule.default.timeStrings,
        lastAutoAnalysisDay: nil,
        lastAutoAnalysisSlotKey: nil,
        lastModuleAutoAnalysisKeys: [:],
        lastModuleGeneratedAt: [:],
        notifications: .default,
        autoFailureStreaks: [:],
        lastAutoFailureMessages: [:]
    )

    init(
        provider: TrendAIProviderSettings,
        alphaVantage: AlphaVantageSettings = .empty,
        defaultPrivacyMode: TrendPrivacyMode,
        dailyAutoAnalysisEnabled: Bool,
        dailyAutoAnalysisTimes: [String] = TrendAutoAnalysisSchedule.default.timeStrings,
        lastAutoAnalysisDay: String? = nil,
        lastAutoAnalysisSlotKey: String? = nil,
        lastModuleAutoAnalysisKeys: [String: String] = [:],
        lastModuleGeneratedAt: [String: String] = [:],
        notifications: TrendNotificationPreferences = .default,
        autoFailureStreaks: [String: Int] = [:],
        lastAutoFailureMessages: [String: String] = [:]
    ) {
        self.provider = provider
        self.alphaVantage = alphaVantage
        self.defaultPrivacyMode = defaultPrivacyMode
        self.dailyAutoAnalysisEnabled = dailyAutoAnalysisEnabled
        self.dailyAutoAnalysisTimes = TrendAutoAnalysisSchedule(timeStrings: dailyAutoAnalysisTimes).timeStrings
        self.lastAutoAnalysisDay = lastAutoAnalysisDay
        self.lastAutoAnalysisSlotKey = lastAutoAnalysisSlotKey
        self.lastModuleAutoAnalysisKeys = lastModuleAutoAnalysisKeys
        self.lastModuleGeneratedAt = lastModuleGeneratedAt
        self.notifications = notifications
        self.autoFailureStreaks = autoFailureStreaks
        self.lastAutoFailureMessages = lastAutoFailureMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(TrendAIProviderSettings.self, forKey: .provider) ?? .empty
        alphaVantage = try container.decodeIfPresent(
            AlphaVantageSettings.self,
            forKey: .alphaVantage
        ) ?? .empty
        defaultPrivacyMode = try container.decodeIfPresent(TrendPrivacyMode.self, forKey: .defaultPrivacyMode) ?? .sanitized
        dailyAutoAnalysisEnabled = try container.decodeIfPresent(Bool.self, forKey: .dailyAutoAnalysisEnabled) ?? false
        if let times = try container.decodeIfPresent([String].self, forKey: .dailyAutoAnalysisTimes) {
            dailyAutoAnalysisTimes = TrendAutoAnalysisSchedule(timeStrings: times).timeStrings
        } else if let time = try container.decodeIfPresent(String.self, forKey: .dailyAutoAnalysisTime) {
            dailyAutoAnalysisTimes = TrendAutoAnalysisSchedule(timeString: time).timeStrings
        } else {
            dailyAutoAnalysisTimes = TrendAutoAnalysisSchedule.default.timeStrings
        }
        lastAutoAnalysisDay = try container.decodeIfPresent(String.self, forKey: .lastAutoAnalysisDay)
        lastAutoAnalysisSlotKey = try container.decodeIfPresent(String.self, forKey: .lastAutoAnalysisSlotKey)
        lastModuleAutoAnalysisKeys = try container.decodeIfPresent(
            [String: String].self,
            forKey: .lastModuleAutoAnalysisKeys
        ) ?? [:]
        lastModuleGeneratedAt = try container.decodeIfPresent(
            [String: String].self,
            forKey: .lastModuleGeneratedAt
        ) ?? [:]
        notifications = try container.decodeIfPresent(
            TrendNotificationPreferences.self,
            forKey: .notifications
        ) ?? .default
        autoFailureStreaks = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .autoFailureStreaks
        ) ?? [:]
        lastAutoFailureMessages = try container.decodeIfPresent(
            [String: String].self,
            forKey: .lastAutoFailureMessages
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(alphaVantage, forKey: .alphaVantage)
        try container.encode(defaultPrivacyMode, forKey: .defaultPrivacyMode)
        try container.encode(dailyAutoAnalysisEnabled, forKey: .dailyAutoAnalysisEnabled)
        try container.encode(dailyAutoAnalysisTimes, forKey: .dailyAutoAnalysisTimes)
        try container.encodeIfPresent(lastAutoAnalysisDay, forKey: .lastAutoAnalysisDay)
        try container.encodeIfPresent(lastAutoAnalysisSlotKey, forKey: .lastAutoAnalysisSlotKey)
        try container.encode(lastModuleAutoAnalysisKeys, forKey: .lastModuleAutoAnalysisKeys)
        try container.encode(lastModuleGeneratedAt, forKey: .lastModuleGeneratedAt)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(autoFailureStreaks, forKey: .autoFailureStreaks)
        try container.encode(lastAutoFailureMessages, forKey: .lastAutoFailureMessages)
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case alphaVantage
        case defaultPrivacyMode
        case dailyAutoAnalysisEnabled
        case dailyAutoAnalysisTimes
        case dailyAutoAnalysisTime
        case lastAutoAnalysisDay
        case lastAutoAnalysisSlotKey
        case lastModuleAutoAnalysisKeys
        case lastModuleGeneratedAt
        case notifications
        case autoFailureStreaks
        case lastAutoFailureMessages
    }

    var dailyAutoAnalysisSchedule: TrendAutoAnalysisSchedule {
        TrendAutoAnalysisSchedule(timeStrings: dailyAutoAnalysisTimes)
    }

    var dailyAutoAnalysisTimesText: String {
        dailyAutoAnalysisSchedule.text
    }

    mutating func updateDailyAutoAnalysisTimes(from text: String) {
        dailyAutoAnalysisTimes = TrendAutoAnalysisSchedule(text: text).timeStrings
    }

    mutating func normalizeDailyAutoAnalysisTimes() {
        dailyAutoAnalysisTimes = dailyAutoAnalysisSchedule.timeStrings
    }

    func hasAutoAnalyzed(on day: String) -> Bool {
        lastAutoAnalysisDay == day
    }

    func dueAutoAnalysisSlot(at timestamp: String) -> TrendAutoAnalysisSlot? {
        dailyAutoAnalysisSchedule.dueSlot(
            at: timestamp,
            lastCompletedSlotKey: lastAutoAnalysisSlotKey,
            legacyLastAutoAnalysisDay: lastAutoAnalysisDay
        )
    }

    func dueModuleAutoAnalysisSlot(at timestamp: String) -> TrendScheduledModuleSlot? {
        TrendModuleAutoAnalysisSchedule.dueSlot(
            at: timestamp,
            lastCompletedKeys: lastModuleAutoAnalysisKeys,
            lastGeneratedAtByScope: lastModuleGeneratedAt
        )
    }

    mutating func markModuleAutoAnalysisCompleted(_ slot: TrendScheduledModuleSlot) {
        lastModuleAutoAnalysisKeys[slot.scope.rawValue] = slot.key
    }

    mutating func markModuleGenerated(
        scope: TrendResearchRunScope,
        generatedAt: String
    ) {
        let scopes = scope == .full
            ? [TrendResearchRunScope.marketRadar, .closeReview, .longTerm]
            : [scope]
        for moduleScope in scopes {
            lastModuleGeneratedAt[moduleScope.rawValue] = generatedAt
        }
    }

    func moduleGeneratedAt(_ scope: TrendResearchRunScope) -> String? {
        lastModuleGeneratedAt[scope.rawValue]
    }

    /// W3.5:成功生成后清零对应模块的连续失败计数(full 同时清三个模块)。
    mutating func clearAutoFailureStreak(scope: TrendResearchRunScope) {
        let scopes = scope == .full
            ? [TrendResearchRunScope.marketRadar, .closeReview, .longTerm]
            : [scope]
        for moduleScope in scopes {
            autoFailureStreaks[moduleScope.rawValue] = nil
            lastAutoFailureMessages[moduleScope.rawValue] = nil
        }
    }

    /// W3.5:自动运行失败后累加连击并记录错误文案;返回新的连击数。
    mutating func recordAutoFailure(scope: TrendResearchRunScope, message: String) -> Int {
        let key = scope.rawValue
        let next = (autoFailureStreaks[key] ?? 0) + 1
        autoFailureStreaks[key] = next
        lastAutoFailureMessages[key] = message
        return next
    }
}

struct TrendPortfolioSummary: Codable, Hashable {
    let headline: String
    let riskLevel: TrendRiskLevel
    let summary: String
    let claimEvidence: TrendClaimEvidence

    init(
        headline: String,
        riskLevel: TrendRiskLevel,
        summary: String,
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.headline = headline
        self.riskLevel = riskLevel
        self.summary = summary
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = try container.decode(String.self, forKey: .headline)
        riskLevel = try container.decode(TrendRiskLevel.self, forKey: .riskLevel)
        summary = try container.decode(String.self, forKey: .summary)
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case headline
        case riskLevel
        case summary
        case claimEvidence
    }
}

struct TrendHorizonView: Codable, Hashable {
    let horizon: TrendHorizon
    var direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
    /// W4.2:什么情况作废/升级(用户可读短句);旧报告解码为空,UI 降级用反证首条。
    let whatWouldChange: String
    let counterSignals: [String]
    let claimEvidence: TrendClaimEvidence

    init(
        horizon: TrendHorizon,
        direction: TrendDirection,
        confidence: TrendConfidence,
        rationale: String,
        whatWouldChange: String = "",
        counterSignals: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.horizon = horizon
        self.direction = direction
        self.confidence = confidence
        self.rationale = rationale
        self.whatWouldChange = whatWouldChange
        self.counterSignals = counterSignals
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        horizon = try container.decode(TrendHorizon.self, forKey: .horizon)
        direction = try container.decode(TrendDirection.self, forKey: .direction)
        confidence = try container.decode(TrendConfidence.self, forKey: .confidence)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        whatWouldChange = try container.decodeIfPresent(String.self, forKey: .whatWouldChange) ?? ""
        counterSignals = try container.decodeIfPresent([String].self, forKey: .counterSignals) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case horizon
        case direction
        case confidence
        case rationale
        case whatWouldChange
        case counterSignals
        case claimEvidence
    }
}

struct TrendSectorView: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let exposureText: String
    var direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
    /// W4.2:什么情况作废/升级;旧报告解码为空。
    let whatWouldChange: String
    let evidenceIDs: [String]
    let counterSignals: [String]
    let claimEvidence: TrendClaimEvidence

    init(
        id: String,
        name: String,
        exposureText: String,
        direction: TrendDirection,
        confidence: TrendConfidence,
        rationale: String,
        whatWouldChange: String = "",
        evidenceIDs: [String],
        counterSignals: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.id = id
        self.name = name
        self.exposureText = exposureText
        self.direction = direction
        self.confidence = confidence
        self.rationale = rationale
        self.whatWouldChange = whatWouldChange
        self.evidenceIDs = evidenceIDs
        self.counterSignals = counterSignals
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        exposureText = try container.decode(String.self, forKey: .exposureText)
        direction = try container.decode(TrendDirection.self, forKey: .direction)
        confidence = try container.decode(TrendConfidence.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
        whatWouldChange = try container.decodeIfPresent(String.self, forKey: .whatWouldChange) ?? ""
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        counterSignals = try container.decodeIfPresent([String].self, forKey: .counterSignals) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case exposureText
        case direction
        case confidence
        case rationale
        case whatWouldChange
        case evidenceIDs
        case counterSignals
        case claimEvidence
    }
}

struct TrendMarketOutlook: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    var direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
    let evidenceIDs: [String]
    let counterSignals: [String]
    let claimEvidence: TrendClaimEvidence

    var categoryDisplayName: String {
        switch category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "index":
            return "指数"
        case "assetclass", "asset_class", "asset class":
            return "大类资产"
        default:
            return category
        }
    }

    init(
        id: String,
        name: String,
        category: String,
        direction: TrendDirection,
        confidence: TrendConfidence,
        rationale: String,
        evidenceIDs: [String],
        counterSignals: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.direction = direction
        self.confidence = confidence
        self.rationale = rationale
        self.evidenceIDs = evidenceIDs
        self.counterSignals = counterSignals
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(category)-\(name)"
        direction = try container.decode(TrendDirection.self, forKey: .direction)
        confidence = try container.decode(TrendConfidence.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        counterSignals = try container.decodeIfPresent([String].self, forKey: .counterSignals) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case direction
        case confidence
        case rationale
        case evidenceIDs
        case counterSignals
        case claimEvidence
    }
}

struct TrendAssetView: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let code: String?
    let sector: String
    let impactText: String
    let horizons: [TrendHorizonView]
    let rationale: String
    let counterSignals: [String]
    let claimEvidence: TrendClaimEvidence

    init(
        id: String,
        name: String,
        code: String?,
        sector: String,
        impactText: String,
        horizons: [TrendHorizonView],
        rationale: String,
        counterSignals: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.id = id
        self.name = name
        self.code = code
        self.sector = sector
        self.impactText = impactText
        self.horizons = horizons
        self.rationale = rationale
        self.counterSignals = counterSignals
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 2026-09-01:文本字段缺失不再解码报废(2026-08-31 实证模型会提交纯元数据条目,
        // 「缺少字段 impactText」整批拒批直接烧掉修复预算)。统一落到保守占位,
        // 由 storeAssetBatch 的归一化链补前缀/补 horizons。
        code = try container.decodeIfPresent(String.self, forKey: .code)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? code ?? "未知基金"
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? code ?? name
        sector = try container.decodeIfPresent(String.self, forKey: .sector) ?? "未分类"
        impactText = try container.decodeIfPresent(String.self, forKey: .impactText) ?? ""
        horizons = try container.decodeIfPresent([TrendHorizonView].self, forKey: .horizons) ?? []
        rationale = try container.decodeIfPresent(
            String.self,
            forKey: .rationale
        ) ?? TrendDegradedAssetFactory.missingRationale
        counterSignals = try container.decodeIfPresent([String].self, forKey: .counterSignals) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case code
        case sector
        case impactText
        case horizons
        case rationale
        case counterSignals
        case claimEvidence
    }
}

enum TrendOpportunityScope: String, Codable, Hashable {
    /// 由独立于当前组合的全市场扫描产生，可展示在“值得关注的投资方向”。
    case marketWide

    /// 旧报告或围绕当前持仓产生的机会，只属于长期组合研判。
    case portfolioRelated
}

struct TrendOpportunity: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let scope: TrendOpportunityScope
    var direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
    /// W4.2:什么情况作废/升级;旧报告解码为空。
    let whatWouldChange: String
    let triggerConditions: [String]
    let invalidatingConditions: [String]
    let evidenceIDs: [String]
    let counterSignals: [String]
    let claimEvidence: TrendClaimEvidence

    init(
        id: String,
        name: String,
        category: String,
        scope: TrendOpportunityScope = .portfolioRelated,
        direction: TrendDirection,
        confidence: TrendConfidence,
        rationale: String,
        whatWouldChange: String = "",
        triggerConditions: [String],
        invalidatingConditions: [String],
        evidenceIDs: [String],
        counterSignals: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.scope = scope
        self.direction = direction
        self.confidence = confidence
        self.rationale = rationale
        self.whatWouldChange = whatWouldChange
        self.triggerConditions = triggerConditions
        self.invalidatingConditions = invalidatingConditions
        self.evidenceIDs = evidenceIDs
        self.counterSignals = counterSignals
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(category)-\(name)"
        // scope 是新增语义边界。旧报告缺少该字段时必须按“持仓相关”处理，
        // 防止历史 opportunities 被误展示成全市场扫描结果。
        scope = try container.decodeIfPresent(
            TrendOpportunityScope.self,
            forKey: .scope
        ) ?? .portfolioRelated
        direction = try container.decode(TrendDirection.self, forKey: .direction)
        confidence = try container.decode(TrendConfidence.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
        whatWouldChange = try container.decodeIfPresent(String.self, forKey: .whatWouldChange) ?? ""
        triggerConditions = try container.decodeIfPresent([String].self, forKey: .triggerConditions) ?? []
        invalidatingConditions = try container.decodeIfPresent([String].self, forKey: .invalidatingConditions) ?? []
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        counterSignals = try container.decodeIfPresent([String].self, forKey: .counterSignals) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case scope
        case direction
        case confidence
        case rationale
        case whatWouldChange
        case triggerConditions
        case invalidatingConditions
        case evidenceIDs
        case counterSignals
        case claimEvidence
    }
}

struct TrendActionCandidate: Codable, Identifiable, Hashable {
    let id: String
    let kind: TrendActionKind
    let title: String
    let detail: String
    let targetName: String?
    let confidence: TrendConfidence
    /// W4.2:什么情况作废/升级;旧报告解码为空。
    let whatWouldChange: String
    let triggerConditions: [String]
    let invalidatingConditions: [String]
    let claimEvidence: TrendClaimEvidence

    init(
        id: String,
        kind: TrendActionKind,
        title: String,
        detail: String,
        targetName: String?,
        confidence: TrendConfidence,
        whatWouldChange: String = "",
        triggerConditions: [String],
        invalidatingConditions: [String],
        claimEvidence: TrendClaimEvidence = .empty
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.targetName = targetName
        self.confidence = confidence
        self.whatWouldChange = whatWouldChange
        self.triggerConditions = triggerConditions
        self.invalidatingConditions = invalidatingConditions
        self.claimEvidence = claimEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(TrendActionKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(kind.rawValue)-\(title)"
        detail = try container.decode(String.self, forKey: .detail)
        targetName = try container.decodeIfPresent(String.self, forKey: .targetName)
        confidence = try container.decode(TrendConfidence.self, forKey: .confidence)
        whatWouldChange = try container.decodeIfPresent(String.self, forKey: .whatWouldChange) ?? ""
        triggerConditions = try container.decodeIfPresent([String].self, forKey: .triggerConditions) ?? []
        invalidatingConditions = try container.decodeIfPresent([String].self, forKey: .invalidatingConditions) ?? []
        claimEvidence = try container.decodeIfPresent(
            TrendClaimEvidence.self,
            forKey: .claimEvidence
        ) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case detail
        case targetName
        case confidence
        case whatWouldChange
        case triggerConditions
        case invalidatingConditions
        case claimEvidence
    }
}

struct TrendEvidence: Codable, Identifiable, Hashable {
    let id: String
    let sourceName: String
    let title: String
    let url: String?
    let publishedAt: String?
    let retrievedAt: String
    let summary: String
    let metadata: TrendEvidenceMetadata

    init(
        id: String,
        sourceName: String,
        title: String,
        url: String?,
        publishedAt: String?,
        retrievedAt: String,
        summary: String,
        metadata: TrendEvidenceMetadata = .unknown
    ) {
        self.id = id
        self.sourceName = sourceName
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.retrievedAt = retrievedAt
        self.summary = summary
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        title = try container.decode(String.self, forKey: .title)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(sourceName)-\(title)"
        url = try container.decodeIfPresent(String.self, forKey: .url)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        retrievedAt = try container.decode(String.self, forKey: .retrievedAt)
        summary = try container.decode(String.self, forKey: .summary)
        metadata = try container.decodeIfPresent(
            TrendEvidenceMetadata.self,
            forKey: .metadata
        ) ?? .unknown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceName
        case title
        case url
        case publishedAt
        case retrievedAt
        case summary
        case metadata
    }
}

struct TrendWarning: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String

    init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? title
        // 2026-08-31 实证：模型把 detail 写成 impact——解码容错而不是整模块拒批
        if let text = try? container.decode(String.self, forKey: .detail), !text.isEmpty {
            detail = text
        } else if let text = try? container.decode(String.self, forKey: .impact), !text.isEmpty {
            detail = text
        } else {
            detail = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case impact
    }
}

struct TrendAnalysisReport: Codable, Identifiable, Hashable {
    static let currentSchemaVersion = 2

    let id: UUID
    let schemaVersion: Int
    var generatedAt: String
    var dataAsOf: String
    let disposition: TrendReportDisposition
    let privacyMode: TrendPrivacyMode
    let externalSignalStatus: TrendExternalSignalStatus
    let sourceStatuses: [TrendSourceStatus]
    let portfolio: TrendPortfolioSummary
    let horizons: [TrendHorizonView]
    let marketOutlook: [TrendMarketOutlook]
    let sectors: [TrendSectorView]
    let opportunities: [TrendOpportunity]
    let keyAssets: [TrendAssetView]
    let assetTrends: [TrendAssetView]
    let actions: [TrendActionCandidate]
    let evidence: [TrendEvidence]
    let warnings: [TrendWarning]
    let disclaimer: String

    /// 报告引用的全部 evidence ID，去重并保持首次出现顺序。
    var referencedEvidenceIDs: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let append: (String) -> Void = { id in
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        sectors.forEach { $0.evidenceIDs.forEach(append) }
        marketOutlook.forEach { $0.evidenceIDs.forEach(append) }
        opportunities.forEach { $0.evidenceIDs.forEach(append) }
        portfolio.claimEvidence.allEvidenceIDs.forEach(append)
        horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        sectors.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        marketOutlook.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        opportunities.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        (keyAssets + assetTrends).forEach { asset in
            asset.claimEvidence.allEvidenceIDs.forEach(append)
            asset.horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        }
        actions.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        return ids
    }

    /// 只支撑个人组合结论的证据，不包含全市场扫描产生的板块与机会证据。
    var portfolioReferencedEvidenceIDs: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let append: (String) -> Void = { id in
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        portfolio.claimEvidence.allEvidenceIDs.forEach(append)
        horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        (keyAssets + assetTrends).forEach { asset in
            asset.claimEvidence.allEvidenceIDs.forEach(append)
            asset.horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        }
        actions.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        return ids
    }

    var portfolioEvidence: [TrendEvidence] {
        let referencedIDs = Set(portfolioReferencedEvidenceIDs)
        return evidence.filter { referencedIDs.contains($0.id) }
    }

    init(
        id: UUID,
        generatedAt: String,
        dataAsOf: String,
        privacyMode: TrendPrivacyMode,
        externalSignalStatus: TrendExternalSignalStatus,
        portfolio: TrendPortfolioSummary,
        horizons: [TrendHorizonView],
        marketOutlook: [TrendMarketOutlook] = [],
        sectors: [TrendSectorView],
        opportunities: [TrendOpportunity] = [],
        keyAssets: [TrendAssetView],
        assetTrends: [TrendAssetView] = [],
        actions: [TrendActionCandidate],
        evidence: [TrendEvidence],
        warnings: [TrendWarning],
        disclaimer: String,
        schemaVersion: Int = 1,
        disposition: TrendReportDisposition = .analysisOnly,
        sourceStatuses: [TrendSourceStatus] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.dataAsOf = dataAsOf
        self.disposition = disposition
        self.privacyMode = privacyMode
        self.externalSignalStatus = externalSignalStatus
        self.sourceStatuses = sourceStatuses
        self.portfolio = portfolio
        self.horizons = horizons
        self.marketOutlook = marketOutlook
        self.sectors = sectors
        self.opportunities = opportunities
        self.keyAssets = keyAssets
        self.assetTrends = assetTrends
        self.actions = actions
        self.evidence = evidence
        self.warnings = warnings
        self.disclaimer = disclaimer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        dataAsOf = try container.decodeIfPresent(String.self, forKey: .dataAsOf) ?? ""
        disposition = try container.decodeIfPresent(
            TrendReportDisposition.self,
            forKey: .disposition
        ) ?? .analysisOnly
        privacyMode = try container.decode(TrendPrivacyMode.self, forKey: .privacyMode)
        externalSignalStatus = try container.decode(TrendExternalSignalStatus.self, forKey: .externalSignalStatus)
        sourceStatuses = try container.decodeIfPresent(
            [TrendSourceStatus].self,
            forKey: .sourceStatuses
        ) ?? []
        portfolio = try container.decode(TrendPortfolioSummary.self, forKey: .portfolio)
        horizons = try container.decode([TrendHorizonView].self, forKey: .horizons)
        marketOutlook = try container.decodeIfPresent([TrendMarketOutlook].self, forKey: .marketOutlook) ?? []
        sectors = try container.decodeIfPresent([TrendSectorView].self, forKey: .sectors) ?? []
        opportunities = try container.decodeIfPresent([TrendOpportunity].self, forKey: .opportunities) ?? []
        keyAssets = try container.decodeIfPresent([TrendAssetView].self, forKey: .keyAssets) ?? []
        assetTrends = try container.decodeIfPresent([TrendAssetView].self, forKey: .assetTrends) ?? []
        actions = try container.decodeIfPresent([TrendActionCandidate].self, forKey: .actions) ?? []
        evidence = try container.decodeIfPresent([TrendEvidence].self, forKey: .evidence) ?? []
        warnings = try container.decodeIfPresent([TrendWarning].self, forKey: .warnings) ?? []
        disclaimer = try container.decode(String.self, forKey: .disclaimer)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case generatedAt
        case dataAsOf
        case disposition
        case privacyMode
        case externalSignalStatus
        case sourceStatuses
        case portfolio
        case horizons
        case marketOutlook
        case sectors
        case opportunities
        case keyAssets
        case assetTrends
        case actions
        case evidence
        case warnings
        case disclaimer
    }
}

struct TrendAnalysisContext: Codable, Hashable {
    let createdAt: String
    let privacyMode: TrendPrivacyMode
    let portfolio: TrendContextPortfolio
    let assets: [TrendContextAsset]
    let sectors: [TrendContextSector]
    let platformSignals: [String]
    let watchSummary: String
    let insightHeadline: String

    func debugJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct TrendContextPortfolio: Codable, Hashable {
    let assetCount: Int
    let holdingCount: Int
    let activePlanCount: Int
    let pendingAssetCount: Int
    let totalMarketValue: Double?
    let totalPendingCashAmount: Double?
    let totalEstimatedNextPlanAmount: Double?
    let totalEffectiveHoldingAmount: Double?
}

struct TrendContextAsset: Codable, Hashable {
    let id: String
    let name: String
    let code: String?
    let assetType: String
    let sector: String
    let statusText: String
    let weightText: String?
    let profitPct: Double?
    let estimateChangePct: Double?
    let pendingTradeCount: Int
    let activePlanCount: Int
    let pausedPlanCount: Int
    let endedPlanCount: Int
    let marketValue: Double?
    let costValue: Double?
    let profitAmount: Double?
    let pendingCashAmount: Double?
    let estimatedNextPlanAmount: Double?
    let totalCumulativePlanAmount: Double?
}

struct TrendContextSector: Codable, Hashable {
    let name: String
    let assetCount: Int
    let exposureText: String
    let exposureAmount: Double?
}
