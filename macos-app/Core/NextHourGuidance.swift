import Foundation

// MARK: - Trading schedule

enum NextHourGuidanceScope: String, Codable, Hashable, Sendable {
    case marketTrading = "market_trading"
    case closingWindow = "closing_window"
    case manual = "manual"

    var displayName: String {
        switch self {
        case .marketTrading:
            return "盘中交易"
        case .closingWindow:
            return "收盘前决策"
        case .manual:
            return "手动研判"
        }
    }

    var includesOffExchangeFunds: Bool {
        self == .closingWindow || self == .manual
    }
}

struct NextHourGuidanceSlot: Codable, Hashable, Sendable {
    let day: String
    let timeString: String
    let validUntil: String
    let scope: NextHourGuidanceScope

    var key: String {
        "\(day) \(timeString)"
    }

    var displayName: String {
        "\(timeString) · \(scope.displayName)"
    }
}

/// A 股交易日内的固定运行窗口。
///
/// 09:15 先生成开盘首小时指引，之后按小时刷新；午休不运行。
/// 14:50 是单独的收盘前窗口，只有该窗口会把场外基金纳入上下文。
struct NextHourGuidanceSchedule: Hashable, Sendable {
    private struct Window: Hashable, Sendable {
        let startMinute: Int
        let endMinute: Int
        let timeString: String
        let validUntil: String
        let scope: NextHourGuidanceScope
    }

    static let `default` = NextHourGuidanceSchedule()

    private static let windows: [Window] = [
        .init(startMinute: 9 * 60 + 15, endMinute: 10 * 60 + 14, timeString: "09:15", validUntil: "10:15", scope: .marketTrading),
        .init(startMinute: 10 * 60 + 15, endMinute: 11 * 60 + 14, timeString: "10:15", validUntil: "11:15", scope: .marketTrading),
        .init(startMinute: 11 * 60 + 15, endMinute: 11 * 60 + 30, timeString: "11:15", validUntil: "11:30", scope: .marketTrading),
        .init(startMinute: 13 * 60 + 15, endMinute: 14 * 60 + 14, timeString: "13:15", validUntil: "14:15", scope: .marketTrading),
        .init(startMinute: 14 * 60 + 15, endMinute: 14 * 60 + 49, timeString: "14:15", validUntil: "14:50", scope: .marketTrading),
        .init(startMinute: 14 * 60 + 50, endMinute: 15 * 60, timeString: "14:50", validUntil: "15:00", scope: .closingWindow),
    ]

    func dueSlot(at timestamp: String, lastAttemptedSlotKey: String?) -> NextHourGuidanceSlot? {
        guard let parts = Self.timestampParts(timestamp),
              Self.isWeekday(year: parts.year, month: parts.month, day: parts.day),
              let window = Self.windows.first(where: {
                  ($0.startMinute...$0.endMinute).contains(parts.minuteOfDay)
              }) else {
            return nil
        }

        let slot = NextHourGuidanceSlot(
            day: parts.dayString,
            timeString: window.timeString,
            validUntil: "\(parts.dayString) \(window.validUntil)",
            scope: window.scope
        )
        guard slot.key != lastAttemptedSlotKey else { return nil }
        return slot
    }

    /// 手动触发不受交易日和交易时段限制，有效期从点击时刻起算一小时。
    func manualSlot(at timestamp: String) -> NextHourGuidanceSlot? {
        guard let parts = Self.timestampParts(timestamp) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let hour = parts.minuteOfDay / 60
        let minute = parts.minuteOfDay % 60
        guard let start = calendar.date(
            from: DateComponents(
                year: parts.year,
                month: parts.month,
                day: parts.day,
                hour: hour,
                minute: minute
            )
        ), let end = calendar.date(byAdding: .hour, value: 1, to: start) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timeString = String(format: "%02d:%02d", hour, minute)
        return NextHourGuidanceSlot(
            day: parts.dayString,
            timeString: timeString,
            validUntil: formatter.string(from: end),
            scope: .manual
        )
    }

    private static func timestampParts(
        _ timestamp: String
    ) -> (year: Int, month: Int, day: Int, dayString: String, minuteOfDay: Int)? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        let dayString = String(trimmed.prefix(10))
        let dayParts = dayString.split(separator: "-", omittingEmptySubsequences: false)
        let timeStart = trimmed.index(trimmed.startIndex, offsetBy: 11)
        let timeParts = trimmed[timeStart...].prefix(5).split(separator: ":", omittingEmptySubsequences: false)
        guard dayParts.count == 3,
              timeParts.count == 2,
              let year = Int(dayParts[0]),
              let month = Int(dayParts[1]),
              let day = Int(dayParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (year, month, day, dayString, hour * 60 + minute)
    }

    private static func isWeekday(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let weekday = calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }
}

// MARK: - Guidance models

enum NextHourGuidancePosture: String, Codable, Hashable, Sendable {
    case defensive
    case balanced
    case selective
    case opportunistic

    var displayName: String {
        switch self {
        case .defensive:
            return "防守"
        case .balanced:
            return "均衡"
        case .selective:
            return "选择性交易"
        case .opportunistic:
            return "条件式进攻"
        }
    }
}

enum NextHourGuidanceActionKind: String, Codable, Hashable, Sendable {
    case buy
    case sell
    case hold
    // 旧版本兼容：历史报告仍可解码，新的 Agent 不再生成这些动作。
    case watch
    case wait
    case avoidChasing = "avoid_chasing"
    case buySmall = "buy_small"
    case reduceSmall = "reduce_small"

    var displayName: String {
        switch self {
        case .buy, .buySmall:
            return "建议买入"
        case .sell, .reduceSmall:
            return "建议卖出"
        case .hold:
            return "建议持有"
        case .watch, .wait, .avoidChasing:
            return "建议持有"
        }
    }
}

struct NextHourGuidanceAction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let targetID: String?
    let targetName: String
    let action: NextHourGuidanceActionKind
    let instruction: String
    let rationale: String
    let trigger: String
    let invalidation: String
    let confidence: Int
    let evidenceIDs: [String]

    init(
        id: UUID = UUID(),
        targetID: String? = nil,
        targetName: String,
        action: NextHourGuidanceActionKind,
        instruction: String,
        rationale: String,
        trigger: String,
        invalidation: String,
        confidence: Int,
        evidenceIDs: [String] = []
    ) {
        self.id = id
        self.targetID = targetID
        self.targetName = targetName
        self.action = action
        self.instruction = instruction
        self.rationale = rationale
        self.trigger = trigger
        self.invalidation = invalidation
        self.confidence = min(100, max(0, confidence))
        self.evidenceIDs = evidenceIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        targetID = try container.decodeIfPresent(String.self, forKey: .targetID)
        targetName = try container.decode(String.self, forKey: .targetName)
        action = try container.decode(NextHourGuidanceActionKind.self, forKey: .action)
        instruction = try container.decode(String.self, forKey: .instruction)
        rationale = try container.decode(String.self, forKey: .rationale)
        trigger = try container.decode(String.self, forKey: .trigger)
        invalidation = try container.decode(String.self, forKey: .invalidation)
        confidence = min(100, max(0, try container.decode(Int.self, forKey: .confidence)))
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case targetID
        case targetName
        case action
        case instruction
        case rationale
        case trigger
        case invalidation
        case confidence
        case evidenceIDs
    }
}

struct NextHourGuidanceReport: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let runID: UUID
    let generatedAt: String
    let validUntil: String
    let slotKey: String
    let scope: NextHourGuidanceScope
    let headline: String
    let posture: NextHourGuidancePosture
    let summary: String
    let actions: [NextHourGuidanceAction]
    let riskChecks: [String]
    let assetCount: Int
    let disposition: TrendReportDisposition
    let sourceStatuses: [TrendSourceStatus]
    let evidence: [TrendEvidence]
    let auditToolCalls: [TrendAgentToolCallAudit]
    let auditEvidence: [TrendEvidence]
    let warnings: [String]
    /// 昨晚「明日关注」的逐条回指(P5);旧存档解码为空数组。
    let followupReviews: [NextHourFollowupReview]
    let disclaimer: String

    /// 完整运行证据账本。`evidence` 只保存最终动作直接引用的证据，
    /// 三个分析团队的独立结论可能只存在于 `auditEvidence`。
    var completeEvidenceLedger: [TrendEvidence] {
        var seen = Set<String>()
        return (evidence + auditEvidence).filter { seen.insert($0.id).inserted }
    }

    /// 当前行动对应的行情、新闻和持仓三方判断，只在条目详情中展示。
    func teamEvidence(for action: NextHourGuidanceAction) -> [TrendEvidence] {
        completeEvidenceLedger
            .filter { item in
                isTeamAssessment(item) && evidence(item, relatesTo: action)
            }
            .sorted { lhs, rhs in
                let lhsRank = teamAssessmentRank(lhs)
                let rhsRank = teamAssessmentRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    private func teamAssessmentRank(_ evidence: TrendEvidence) -> Int {
        if evidence.id.hasPrefix("analysis:market:") || evidence.sourceName == "行情信号分析" {
            return 0
        }
        if evidence.id.hasPrefix("analysis:news:") || evidence.sourceName == "新闻事件分析" {
            return 1
        }
        if evidence.id.hasPrefix("analysis:portfolio:") || evidence.sourceName == "持仓结构分析" {
            return 2
        }
        return 3
    }

    /// 当前行动引用的其他研究依据，排除已经单独归入三方判断的结论。
    func supportingEvidence(for action: NextHourGuidanceAction) -> [TrendEvidence] {
        let ledger = completeEvidenceLedger
        let teamIDs = Set(teamEvidence(for: action).map(\.id))
        let nonTeamEvidence = ledger.filter { !teamIDs.contains($0.id) && !isTeamAssessment($0) }
        let referencedIDs = Set(action.evidenceIDs)
        let directlyReferenced = nonTeamEvidence.filter { referencedIDs.contains($0.id) }
        if !directlyReferenced.isEmpty { return directlyReferenced }

        let related = nonTeamEvidence.filter { evidence($0, relatesTo: action) }
        return related.isEmpty ? nonTeamEvidence : related
    }

    private func isTeamAssessment(_ evidence: TrendEvidence) -> Bool {
        evidence.id.hasPrefix("analysis:market:")
            || evidence.id.hasPrefix("analysis:news:")
            || evidence.id.hasPrefix("analysis:portfolio:")
            || evidence.sourceName == "行情信号分析"
            || evidence.sourceName == "新闻事件分析"
            || evidence.sourceName == "持仓结构分析"
    }

    private func evidence(
        _ evidence: TrendEvidence,
        relatesTo action: NextHourGuidanceAction
    ) -> Bool {
        if let targetID = action.targetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetID.isEmpty,
           evidence.id.hasSuffix(":\(targetID)") {
            return true
        }

        let normalizedTarget = action.targetName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTarget.isEmpty else { return false }
        if evidence.metadata.entityNames.contains(where: { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget
        }) {
            return true
        }

        // 兼容旧报告：早期三方证据可能没有 targetID 或结构化实体标签，
        // 但标题仍以标的名称开头。
        return evidence.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains(normalizedTarget)
    }

    init(
        id: UUID = UUID(),
        runID: UUID = UUID(),
        generatedAt: String,
        validUntil: String,
        slotKey: String,
        scope: NextHourGuidanceScope,
        headline: String,
        posture: NextHourGuidancePosture,
        summary: String,
        actions: [NextHourGuidanceAction],
        riskChecks: [String],
        assetCount: Int,
        disposition: TrendReportDisposition = .analysisOnly,
        sourceStatuses: [TrendSourceStatus] = [],
        evidence: [TrendEvidence] = [],
        auditToolCalls: [TrendAgentToolCallAudit] = [],
        auditEvidence: [TrendEvidence] = [],
        warnings: [String] = [],
        followupReviews: [NextHourFollowupReview] = [],
        disclaimer: String = "仅供条件式决策参考，不构成收益承诺或个性化投资建议。"
    ) {
        self.id = id
        self.runID = runID
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.slotKey = slotKey
        self.scope = scope
        self.headline = headline
        self.posture = posture
        self.summary = summary
        self.actions = actions
        self.riskChecks = riskChecks
        self.assetCount = assetCount
        self.disposition = disposition
        self.sourceStatuses = sourceStatuses
        self.evidence = evidence
        self.auditToolCalls = auditToolCalls
        self.auditEvidence = auditEvidence
        self.warnings = warnings
        self.followupReviews = followupReviews
        self.disclaimer = disclaimer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID) ?? id
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        validUntil = try container.decode(String.self, forKey: .validUntil)
        slotKey = try container.decode(String.self, forKey: .slotKey)
        scope = try container.decode(NextHourGuidanceScope.self, forKey: .scope)
        headline = try container.decode(String.self, forKey: .headline)
        posture = try container.decode(NextHourGuidancePosture.self, forKey: .posture)
        summary = try container.decode(String.self, forKey: .summary)
        actions = try container.decodeIfPresent([NextHourGuidanceAction].self, forKey: .actions) ?? []
        riskChecks = try container.decodeIfPresent([String].self, forKey: .riskChecks) ?? []
        assetCount = try container.decodeIfPresent(Int.self, forKey: .assetCount) ?? 0
        disposition = try container.decodeIfPresent(
            TrendReportDisposition.self,
            forKey: .disposition
        ) ?? .analysisOnly
        sourceStatuses = try container.decodeIfPresent(
            [TrendSourceStatus].self,
            forKey: .sourceStatuses
        ) ?? []
        evidence = try container.decodeIfPresent([TrendEvidence].self, forKey: .evidence) ?? []
        auditToolCalls = try container.decodeIfPresent(
            [TrendAgentToolCallAudit].self,
            forKey: .auditToolCalls
        ) ?? []
        auditEvidence = try container.decodeIfPresent(
            [TrendEvidence].self,
            forKey: .auditEvidence
        ) ?? evidence
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        followupReviews = try container.decodeIfPresent(
            [NextHourFollowupReview].self,
            forKey: .followupReviews
        ) ?? []
        disclaimer = try container.decodeIfPresent(String.self, forKey: .disclaimer)
            ?? "仅供条件式决策参考，不构成收益承诺或个性化投资建议。"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID
        case generatedAt
        case validUntil
        case slotKey
        case scope
        case headline
        case posture
        case summary
        case actions
        case riskChecks
        case assetCount
        case disposition
        case sourceStatuses
        case evidence
        case auditToolCalls
        case auditEvidence
        case warnings
        case followupReviews
        case disclaimer
    }
}

struct NextHourGuidanceArchive: Codable, Hashable, Sendable {
    var report: NextHourGuidanceReport?
    var lastAttemptedSlotKey: String?
    var lastCompletedSlotKey: String?

    static let empty = NextHourGuidanceArchive(
        report: nil,
        lastAttemptedSlotKey: nil,
        lastCompletedSlotKey: nil
    )
}

struct NextHourGuidanceStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> NextHourGuidanceArchive {
        try JSONFilePersistence.load(
            NextHourGuidanceArchive.self,
            from: fileURL,
            defaultValue: .empty,
            decoder: decoder
        )
    }

    func save(_ archive: NextHourGuidanceArchive, to fileURL: URL) throws {
        try JSONFilePersistence.save(archive, to: fileURL, encoder: encoder)
    }
}

// MARK: - Agent context

struct NextHourGuidanceAssetContext: Codable, Hashable, Sendable {
    let id: String
    let evidenceID: String
    let name: String
    let code: String?
    let assetType: String
    let status: String
    let weightPct: Double?
    let currentPrice: Double?
    let quoteTime: String?
    let quoteSource: String?
    let quoteAssessment: TrendQuoteAssessment
    let profitPct: Double?
    let estimateChangePct: Double?
    let pendingTradeCount: Int
    let activePlanCount: Int

    var quoteIsFresh: Bool {
        quoteAssessment.isFreshForExecution
    }
}

struct NextHourGuidanceMarketContext: Codable, Hashable, Sendable {
    let evidenceID: String
    let name: String
    let price: Double
    let changePct: Double?
    let quotedAt: String
    let sourceLabel: String
    let quoteAssessment: TrendQuoteAssessment
}

struct NextHourGuidanceContext: Codable, Hashable, Sendable {
    let generatedAt: String
    let slot: NextHourGuidanceSlot
    let assets: [NextHourGuidanceAssetContext]
    let market: [NextHourGuidanceMarketContext]
    let marketDataIsFresh: Bool
    let marketDataWarnings: [String]
    let latestTrendGeneratedAt: String?
    let latestTrendHeadline: String?
    let latestTrendActions: [String]
    let latestAssetConclusions: [String]
    let dataRules: [String]
    /// 昨晚复盘的「明日关注」(P5 回指注入)。nil 时行为与旧版完全一致。
    var lastCloseReview: LastCloseReviewContext? = nil

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 昨晚收盘复盘注入盘中研判的「明日关注」上下文(P5 回指)。
/// 来源是冻结快照 MarketCloseReviewArchive,不新增存储。
struct LastCloseReviewContext: Codable, Hashable, Sendable {
    let generatedAt: String
    let tomorrowWatch: [String]
}

/// 模型对单条「昨日关注」的回指结论。
struct NextHourFollowupReview: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Hashable, Sendable {
        case confirmed
        case notSeen
        case inconclusive

        var displayName: String {
            switch self {
            case .confirmed: return "已出现"
            case .notSeen: return "未出现"
            case .inconclusive: return "无法确认"
            }
        }
    }

    let itemIndex: Int
    /// 昨晚关注原文(净化时从 context 快照,报告自包含,UI 不依赖 context)。
    let itemText: String
    let status: Status
    let note: String
    let evidenceIDs: [String]

    var id: String { "followup-\(itemIndex)" }
}

// MARK: - Focused AI agent

protocol NextHourGuidanceAgentProtocol: Sendable {
    func run(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings,
        officialSourceSettings: OfficialSourceSettings
    ) async throws -> NextHourGuidanceReport

    /// V2：3+1 子 Agent 编排（行情/新闻/持仓 并行 → 汇总决策）。
    /// 投资智能启用时优先使用，提升输出准确性。
    func runV2(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings,
        officialSourceSettings: OfficialSourceSettings
    ) async throws -> NextHourGuidanceReport
}

enum NextHourGuidanceAgentError: Error, LocalizedError {
    case missingConfiguration
    case missingToolCall
    case invalidSubmission([String])
    case turnLimitExceeded
    case toolCallLimitExceeded
    case totalTimeoutExceeded

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "尚未配置趋势分析模型，无法生成下一小时买卖建议。"
        case .missingToolCall:
            return "模型没有按要求提交下一小时买卖建议。"
        case .invalidSubmission(let errors):
            return "下一小时买卖建议校验失败：\(errors.joined(separator: "；"))"
        case .turnLimitExceeded:
            return "买卖建议 Agent 已达最大研究轮次，仍未提交有效结果。"
        case .toolCallLimitExceeded:
            return "买卖建议 Agent 已达最大工具调用次数。"
        case .totalTimeoutExceeded:
            return "买卖建议 Agent 研究超时，请稍后重试。"
        }
    }
}

struct NextHourGuidanceAgent: NextHourGuidanceAgentProtocol, Sendable {
    private struct Submission: Decodable {
        let headline: String
        let posture: NextHourGuidancePosture
        let summary: String
        let actions: [ActionSubmission]
        let riskChecks: [String]
        let followupReviews: [FollowupReviewSubmission]?

        private enum CodingKeys: String, CodingKey {
            case headline
            case posture
            case summary
            case actions
            case riskChecks = "risk_checks"
            case followupReviews = "followup_reviews"
        }

        /// 编程构造（供 enforceEvidenceFloor 用）。
        init(headline: String, posture: NextHourGuidancePosture, summary: String,
             actions: [ActionSubmission], riskChecks: [String],
             followupReviews: [FollowupReviewSubmission]? = nil) {
            self.headline = headline
            self.posture = posture
            self.summary = summary
            self.actions = actions
            self.riskChecks = riskChecks
            self.followupReviews = followupReviews
        }
    }

    /// 模型对「昨日关注」的单条回指提交(snake_case,容错解码;测试经 JSON 构造)。
    struct FollowupReviewSubmission: Decodable {
        let itemIndex: Int?
        let status: NextHourFollowupReview.Status?
        let note: String?
        let evidenceIDs: [String]?

        private enum CodingKeys: String, CodingKey {
            case itemIndex = "item_index"
            case status
            case note
            case evidenceIDs = "evidence_ids"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemIndex = try c.decodeIfPresent(Int.self, forKey: .itemIndex)
            // 未知状态容错为 inconclusive:回指宁保守,不猜。
            if let raw = try c.decodeIfPresent(String.self, forKey: .status),
               let parsed = NextHourFollowupReview.Status(rawValue: raw) {
                status = parsed
            } else {
                status = .inconclusive
            }
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        }
    }

    private struct ActionSubmission: Decodable {
        let targetID: String?
        let targetName: String
        let action: NextHourGuidanceActionKind?
        let instruction: String
        let rationale: String
        let trigger: String
        let invalidation: String
        let confidence: Int?
        let evidenceIDs: [String]
        /// 解码时记录的缺失必填字段（snake_case），供校验一次性报出。
        let missingFields: [String]

        private enum CodingKeys: String, CodingKey {
            case targetID = "target_id"
            case targetName = "target_name"
            case action
            case instruction
            case rationale
            case trigger
            case invalidation
            case confidence
            case evidenceIDs = "evidence_ids"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
            targetName = try c.decodeIfPresent(String.self, forKey: .targetName) ?? ""
            action = try c.decodeIfPresent(NextHourGuidanceActionKind.self, forKey: .action)
            instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
            rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
            trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
            invalidation = try c.decodeIfPresent(String.self, forKey: .invalidation) ?? ""
            confidence = try c.decodeIfPresent(Int.self, forKey: .confidence)
            evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
            var missing: [String] = []
            if targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("target_name") }
            if action == nil { missing.append("action") }
            if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("instruction") }
            if rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("rationale") }
            if trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("trigger") }
            if invalidation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("invalidation") }
            if confidence == nil { missing.append("confidence") }
            missingFields = missing
        }

        /// 编程构造（供 enforceEvidenceFloor 降级用）。
        init(
            targetID: String?, targetName: String, action: NextHourGuidanceActionKind?,
            instruction: String, rationale: String, trigger: String, invalidation: String,
            confidence: Int?, evidenceIDs: [String], missingFields: [String] = []
        ) {
            self.targetID = targetID
            self.targetName = targetName
            self.action = action
            self.instruction = instruction
            self.rationale = rationale
            self.trigger = trigger
            self.invalidation = invalidation
            self.confidence = confidence
            self.evidenceIDs = evidenceIDs
            self.missingFields = missingFields
        }
    }

    let client: any TrendResearchAgentClient
    let registry: TrendResearchToolRegistry
    let webSearchCache: TrendWebSearchResponseCache

    private static let contextToolName = "get_live_market_context"
    private static let lookThroughToolName = "get_fund_lookthrough"
    private static let officialSourceToolName = "official_sec_research"
    private static let webSearchToolName = "web_search"
    private static let submitToolName = "submit_next_hour_guidance"
    private static let maxTurns = 10
    private static let maxToolCalls = 20
    private static let maxWebSearches = 4
    private static let minimumWebSearchAttempts = 2
    private static let totalTimeoutSeconds: Double = 300

    init(
        client: any TrendResearchAgentClient = OpenAICompatibleAgentClient(),
        webSearchClient: any TavilySearchClientProtocol = TavilySearchClient(),
        officialSourceClient: any SECOfficialSourceClientProtocol = SECOfficialSourceClient(),
        officialSourceCache: SECOfficialSourceCache = .shared,
        webSearchCache: TrendWebSearchResponseCache = .shared
    ) {
        self.client = client
        self.registry = TrendResearchToolRegistry(
            webSearchClient: webSearchClient,
            officialSourceClient: officialSourceClient,
            officialSourceCache: officialSourceCache
        )
        self.webSearchCache = webSearchCache
    }

    func run(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings = .empty,
        officialSourceSettings: OfficialSourceSettings = .empty
    ) async throws -> NextHourGuidanceReport {
        guard settings.isConfigured else { throw NextHourGuidanceAgentError.missingConfiguration }

        let ledger = TrendEvidenceLedger()
        let webSearchGovernor = TrendWebSearchGovernor(
            maxNetworkSearches: Self.maxWebSearches,
            cache: webSearchCache,
            cacheMaxAgeSeconds: 10 * 60
        )
        let requiresLookThrough = researchSnapshot.lookThrough != nil
        let requiresOfficialSource = officialSourceSettings.isSECConfigured
            && !researchSnapshot.eligibleSECResearchTickers.isEmpty
        let commonToolNames: Set<String> = [
            Self.lookThroughToolName,
            Self.officialSourceToolName,
            Self.webSearchToolName,
        ]
        let commonDefinitions = registry.definitions.filter { definition in
            let name = definition.function.name
            guard commonToolNames.contains(name) else { return false }
            if name == Self.lookThroughToolName { return requiresLookThrough }
            if name == Self.officialSourceToolName { return requiresOfficialSource }
            if name == Self.webSearchToolName { return webSearchSettings.isConfigured }
            return true
        }
        let tools = [Self.contextTool()] + commonDefinitions + [Self.submitTool()]
        let started = Date()
        var messages: [AgentChatMessage] = [
            .init(
                role: .system,
                content: """
                你是中国市场盘中交易研究 Agent，任务是生成有证据约束的“下一小时买卖建议”。这是真实资金决策，宁可持有，也不能猜测。
                必须先调用 get_live_market_context 读取刚刷新的持仓、报价时间、大盘行情和旧研判边界。
                如果提供 get_fund_lookthrough，提交前必须调用它；基金判断必须基于底层股票、行业、资产配置和披露日期，不能只看基金名称。
                如果提供 official_sec_research，必须先针对相关美股或基金底层美股查询 SEC 官方披露，再使用 web_search 补充新闻和宏观信息。申报存在本身不等于利好或利空。
                如果提供 web_search，提交前至少调用两次：一次检索最近一天的市场/政策消息，一次针对候选标的、底层行业或核心证券。每次必须填写经过快照校验的 research_target；搜索词不得包含用户金额或组合隐私。
                搜索失败或没有返回新的有效证据时，不得把它算作证据；在完成两次尝试后可安全提交，但所有标的只能 hold，并明确证据不足。
                只引用工具实际返回的 evidence_id；不得编造新闻、价格、成交量、资金流或证据编号。
                每条标的必须明确给出 buy（买入）、sell（卖出）、hold（持有）三选一，不得用观察、等待、不追涨等模糊动作替代结论。
                买入或卖出必须同时引用该标的本地行情证据和至少两个最新外部事件证据，至少一个来源为官方或权威来源且来源彼此独立；基金还必须引用该基金的穿透证据。缺少任一项时只能 hold。
                买入或卖出时，instruction 必须说明小仓/分批方式或大致仓位比例，并给出触发和失效条件。没有清晰优势时明确 hold，不能为了凑交易强行买卖。
                从工具返回的持仓中选择最需要决策的 1 到 5 个标的。场外基金不可描述为盘中实时成交。
                若上下文含 lastCloseReview(昨晚复盘的明日关注):这些是昨晚承诺今天要核实的事项,必须先取证再回答,不许不查就答。对每条关注——先核对相关标的/指数在实时行情中的表现,并复用当日已完成的外部检索结论;仍无法判断且搜索预算允许时,针对该关注本身补一次检索(如「红利板块 今日成交量」)。然后必须在 followup_reviews 中逐条回指,item_index 对应其数组下标:confirmed 必须引用上述今日证据(行情/检索/本日结论),仅凭记忆或推断一律不允许;确实查证不到才用 inconclusive,明确查过但未出现用 not_seen。没有 lastCloseReview 时不要提交 followup_reviews。
                必须调用 submit_next_hour_guidance 工具提交结果，不要输出普通文本。
                """
            ),
            .init(
                role: .user,
                content: """
                研究窗口：\(context.slot.displayName)，有效至 \(context.slot.validUntil)，候选标的 \(context.assets.count) 个。
                SEC 官方源：\(requiresOfficialSource ? "已配置且存在可查询标的，必须优先查询" : "本次没有已配置且可查询的美股标的")。
                联网搜索：\(webSearchSettings.isConfigured ? "已配置，必须完成至少两次最新搜索" : "未配置，任何标的都不得给出 buy/sell，只能 hold")。
                请先调用只读工具取证，再提交买入/卖出/持有建议。
                """
            ),
        ]
        let decoder = JSONDecoder()
        var lastErrors: [String] = []
        var turnCount = 0
        var toolCallCount = 0
        var plainTextResponses = 0
        var invalidSubmissions = 0
        var didReadContext = false
        var didReadLookThrough = !requiresLookThrough
        var didAttemptOfficialSource = !requiresOfficialSource
        var webSearchAttemptQueries = Set<String>()
        var successfulSearchQueries = Set<String>()
        var toolCallAudits: [TrendAgentToolCallAudit] = []

        while turnCount < Self.maxTurns {
            try Task.checkCancellation()
            let remainingTotal = Self.totalTimeoutSeconds - Date().timeIntervalSince(started)
            guard remainingTotal > 0 else {
                throw NextHourGuidanceAgentError.totalTimeoutExceeded
            }
            turnCount += 1
            let result = try await client.complete(
                messages: messages,
                tools: tools,
                toolChoice: .auto,
                temperature: 0.1,
                maxOutputTokens: nil,
                settings: settings,
                timeout: min(90, settings.timeoutSeconds, remainingTotal),
                streamProgress: nil
            )
            messages.append(result.assistantMessage)

            if case .length = result.stopReason {
                messages.append(.init(
                    role: .user,
                    content: "上次响应被截断。不要执行不完整参数，请重新发出完整工具调用。"
                ))
                continue
            }

            guard !result.toolCalls.isEmpty else {
                plainTextResponses += 1
                if plainTextResponses > 2 {
                    throw NextHourGuidanceAgentError.missingToolCall
                }
                messages.append(.init(
                    role: .user,
                    content: "普通文本不会被接收。请调用取证工具，最后通过 submit_next_hour_guidance 提交。"
                ))
                continue
            }

            for call in result.toolCalls {
                guard toolCallCount < Self.maxToolCalls else {
                    throw NextHourGuidanceAgentError.toolCallLimitExceeded
                }
                toolCallCount += 1
                let toolName = call.function.name
                let toolResult: TrendResearchToolResult

                switch toolName {
                case Self.contextToolName:
                    toolResult = await Self.contextToolResult(context: context, ledger: ledger)
                    didReadContext = !toolResult.isError

                case Self.lookThroughToolName:
                    var toolContext = TrendResearchToolContext(
                        snapshot: researchSnapshot,
                        evidenceLedger: ledger,
                        webSearchSettings: webSearchSettings,
                        webSearchGovernor: webSearchGovernor,
                        officialSourceSettings: officialSourceSettings
                    )
                    toolContext.invalidSubmissionBudget = 2
                    toolContext.invalidSubmissionsUsed = invalidSubmissions
                    toolResult = await registry.execute(call, context: toolContext)
                    if !toolResult.isError { didReadLookThrough = true }

                case Self.officialSourceToolName:
                    didAttemptOfficialSource = true
                    var toolContext = TrendResearchToolContext(
                        snapshot: researchSnapshot,
                        evidenceLedger: ledger,
                        webSearchSettings: webSearchSettings,
                        webSearchGovernor: webSearchGovernor,
                        officialSourceSettings: officialSourceSettings
                    )
                    toolContext.invalidSubmissionBudget = 2
                    toolContext.invalidSubmissionsUsed = invalidSubmissions
                    toolResult = await registry.execute(call, context: toolContext)

                case Self.webSearchToolName:
                    let query = Self.recentDaySearchQuery(call)
                    if let query { webSearchAttemptQueries.insert(query) }
                    let evidenceBefore = await ledger.allIDs()
                    var toolContext = TrendResearchToolContext(
                        snapshot: researchSnapshot,
                        evidenceLedger: ledger,
                        webSearchSettings: webSearchSettings,
                        webSearchGovernor: webSearchGovernor,
                        officialSourceSettings: officialSourceSettings
                    )
                    toolContext.invalidSubmissionBudget = 2
                    toolContext.invalidSubmissionsUsed = invalidSubmissions
                    toolResult = await registry.execute(call, context: toolContext)
                    let evidenceAfter = await ledger.allIDs()
                    let newWebEvidence = evidenceAfter
                        .subtracting(evidenceBefore)
                        .contains { $0.hasPrefix("web:tavily:") }
                    if !toolResult.isError, newWebEvidence, let query {
                        successfulSearchQueries.insert(query)
                    }

                case Self.submitToolName:
                    let missingResearch = Self.missingResearchRequirements(
                        didReadContext: didReadContext,
                        didReadLookThrough: didReadLookThrough,
                        didAttemptOfficialSource: didAttemptOfficialSource,
                        officialSourceRequired: requiresOfficialSource,
                        webSearchConfigured: webSearchSettings.isConfigured,
                        webSearchAttemptCount: webSearchAttemptQueries.count
                    )
                    if !missingResearch.isEmpty {
                        lastErrors = missingResearch
                        toolResult = .content(
                            TrendResearchToolEnvelope.submitValidationError(
                                code: "missing_required_research",
                                message: "提交前的取证步骤尚未完成。",
                                errors: missingResearch,
                                remainingRepairAttempts: max(0, 2 - invalidSubmissions)
                            ),
                            isError: true
                        )
                        invalidSubmissions += 1
                    } else {
                        do {
                            let submission = try decoder.decode(
                                Submission.self,
                                from: Data(call.function.arguments.utf8)
                            )
                            let errors = await Self.validate(
                                submission,
                                context: context,
                                researchSnapshot: researchSnapshot,
                                webSearchConfigured: webSearchSettings.isConfigured,
                                recentSearchQueries: Array(successfulSearchQueries),
                                ledger: ledger
                            )
                            if errors.isEmpty {
                                let acceptedResult = TrendResearchToolResult.content(
                                    TrendResearchToolEnvelope.success([
                                        "accepted": true
                                    ])
                                )
                                let completedToolCalls = toolCallAudits + [
                                    TrendAgentToolCallAudit(
                                        sequence: toolCallCount,
                                        call: call,
                                        result: acceptedResult
                                    )
                                ]
                                await AIAgentDiagnosticLog.recordToolResult(
                                    turn: turnCount,
                                    call: call,
                                    contentJSON: acceptedResult.contentJSON,
                                    modelContentJSON: acceptedResult.contentJSON,
                                    isError: false
                                )
                                return await Self.makeReport(
                                    submission: submission,
                                    context: context,
                                    researchSnapshot: researchSnapshot,
                                    officialSourceConfigured: requiresOfficialSource,
                                    webSearchConfigured: webSearchSettings.isConfigured,
                                    ledger: ledger,
                                    toolCalls: completedToolCalls
                                )
                            }
                            lastErrors = errors
                            invalidSubmissions += 1
                            toolResult = .content(
                                TrendResearchToolEnvelope.submitValidationError(
                                    code: "invalid_guidance",
                                    message: "买卖建议没有通过证据与风控校验。",
                                    errors: errors,
                                    remainingRepairAttempts: max(0, 2 - invalidSubmissions)
                                ),
                                isError: true
                            )
                        } catch {
                            lastErrors = ["提交 JSON 无法解码：\(AgentDecodingErrorFormatter.describe(error))"]
                            invalidSubmissions += 1
                            toolResult = .content(
                                TrendResearchToolEnvelope.submitValidationError(
                                    code: "invalid_json",
                                    message: "提交参数无法解码。",
                                    errors: lastErrors,
                                    remainingRepairAttempts: max(0, 2 - invalidSubmissions)
                                ),
                                isError: true
                            )
                        }
                    }

                default:
                    toolResult = .content(
                        TrendResearchToolEnvelope.error(
                            code: "unknown_tool",
                            message: "未知工具：\(toolName)"
                        ),
                        isError: true
                    )
                }

                toolCallAudits.append(
                    TrendAgentToolCallAudit(
                        sequence: toolCallCount,
                        call: call,
                        result: toolResult
                    )
                )
                await AIAgentDiagnosticLog.recordToolResult(
                    turn: turnCount,
                    call: call,
                    contentJSON: toolResult.contentJSON,
                    modelContentJSON: toolResult.contentJSON,
                    isError: toolResult.isError
                )
                messages.append(.init(
                    role: .tool,
                    content: toolResult.contentJSON,
                    toolCallID: call.id
                ))
                if invalidSubmissions > 2 {
                    throw NextHourGuidanceAgentError.invalidSubmission(lastErrors)
                }
            }
        }

        throw NextHourGuidanceAgentError.turnLimitExceeded
    }

    // MARK: - V2：3+1 子 Agent 编排

    /// V2 入口：3 个并行分析子 Agent + 1 个汇总决策 Agent。
    ///
    /// 替代原单体 run() 的多轮循环。拆分动机：原循环注意力分散 + 11 个 AND 风控门槛
    /// 导致默认退回 hold。V2 每个子 Agent 聚焦一个维度，汇总时用分级标注替代强制 hold。
    func runV2(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        webSearchSettings: TavilySearchSettings = .empty,
        officialSourceSettings: OfficialSourceSettings = .empty
    ) async throws -> NextHourGuidanceReport {
        guard settings.isConfigured else { throw NextHourGuidanceAgentError.missingConfiguration }

        let ledger = TrendEvidenceLedger()
        let orchestrator = NextHourGuidanceSubAgentOrchestrator(client: client, registry: registry)

        // 1. 并行运行 3 个分析子 Agent
        let (marketAssessment, newsAssessment, portfolioAssessment) = try await orchestrator.runAnalysisAgents(
            context: context,
            snapshot: researchSnapshot,
            settings: settings,
            webSearchSettings: webSearchSettings,
            officialSourceSettings: officialSourceSettings
        )

        // 1.5 把三方分析结论注入 Ledger 作为证据，供决策 Agent 引用 + 报告展示
        await injectAnalysisEvidence(
            ledger: ledger,
            market: marketAssessment,
            news: newsAssessment,
            portfolio: portfolioAssessment,
            context: context
        )

        // 2. 汇总决策 Agent：综合三方结论，输出最终买卖建议
        var submission = try await runDecisionAgent(
            context: context,
            market: marketAssessment,
            news: newsAssessment,
            portfolio: portfolioAssessment,
            settings: settings
        )

        // 2.5 本地风控：依据不足的买卖建议强制降级为 hold
        // 规则：buy/sell 但 evidenceIDs < 3 或 confidence < 55 → 降为 hold
        submission = enforceEvidenceFloor(submission)

        // 3. 用现有 makeReport 组装报告
        var report = await Self.makeReport(
            submission: submission,
            context: context,
            researchSnapshot: researchSnapshot,
            officialSourceConfigured: officialSourceSettings.isSECConfigured,
            webSearchConfigured: webSearchSettings.isConfigured,
            ledger: ledger,
            toolCalls: []
        )

        // 3.5 修复证据绑定：决策 Agent 可能编造了假 evidenceID（Ledger 里不存在）。
        // 用 targetID 从 Ledger 匹配真实的 analysis:* 证据 ID，替换无效 ID。
        let allLedgerEvidence = await ledger.allEvidence()
        if !allLedgerEvidence.isEmpty {
            report = Self.repairEvidenceBinding(report: report, ledgerEvidence: allLedgerEvidence)
        }
        return report
    }

    /// 修复报告里的证据绑定：
    /// 1. 检查每个 action 的 evidenceIDs 是否在 ledgerEvidence 里真实存在
    /// 2. 不存在的（假 ID）用 targetID 匹配真实的 analysis:* 证据替换
    /// 3. 把真实证据补进 report.evidence（makeReport 按假 ID 匹配会得到空）
    static func repairEvidenceBinding(
        report: NextHourGuidanceReport,
        ledgerEvidence: [TrendEvidence]
    ) -> NextHourGuidanceReport {
        let validIDs = Set(ledgerEvidence.map(\.id))

        let repairedActions = report.actions.map { action -> NextHourGuidanceAction in
            // 检查现有 evidenceIDs 是否都真实
            let knownIDs = action.evidenceIDs.filter { validIDs.contains($0) }
            if !knownIDs.isEmpty {
                // 有真实 ID，只保留真实的
                return NextHourGuidanceAction(
                    targetID: action.targetID, targetName: action.targetName,
                    action: action.action, instruction: action.instruction,
                    rationale: action.rationale, trigger: action.trigger,
                    invalidation: action.invalidation, confidence: action.confidence,
                    evidenceIDs: knownIDs
                )
            }
            // 全是假 ID 或为空：用 targetID 匹配真实的 analysis:* 证据
            let matchedIDs: [String]
            if let targetID = action.targetID {
                matchedIDs = ledgerEvidence
                    .filter { $0.id.contains(":\(targetID):") || $0.id.hasSuffix(":\(targetID)") }
                    .map(\.id)
            } else {
                // targetID 也匹配不到，按 targetName 匹配
                matchedIDs = ledgerEvidence
                    .filter { $0.metadata.entityNames.contains(action.targetName) }
                    .map(\.id)
            }
            return NextHourGuidanceAction(
                targetID: action.targetID, targetName: action.targetName,
                action: action.action, instruction: action.instruction,
                rationale: action.rationale, trigger: action.trigger,
                invalidation: action.invalidation, confidence: action.confidence,
                evidenceIDs: matchedIDs.isEmpty ? action.evidenceIDs : matchedIDs
            )
        }

        // 把所有真实证据补进 report.evidence
        let reportEvidenceIDs = Set(repairedActions.flatMap(\.evidenceIDs))
        let matchedEvidence = ledgerEvidence.filter { reportEvidenceIDs.contains($0.id) }
        let finalEvidence = matchedEvidence.isEmpty ? ledgerEvidence : matchedEvidence

        return NextHourGuidanceReport(
            runID: report.runID, generatedAt: report.generatedAt,
            validUntil: report.validUntil, slotKey: report.slotKey, scope: report.scope,
            headline: report.headline, posture: report.posture, summary: report.summary,
            actions: repairedActions, riskChecks: report.riskChecks,
            assetCount: report.assetCount,
            disposition: report.disposition,
            sourceStatuses: report.sourceStatuses, evidence: finalEvidence,
            auditToolCalls: report.auditToolCalls, auditEvidence: report.auditEvidence,
            warnings: report.warnings
        )
    }

    /// 把三方分析结论注入 Ledger 作为证据。
    /// 每个标的的每个维度（行情/新闻/持仓）生成一条证据，让决策 Agent 可引用、报告可展示。
    private func injectAnalysisEvidence(
        ledger: TrendEvidenceLedger,
        market: MarketSignalAssessment,
        news: NewsEventAssessment,
        portfolio: PortfolioContextAssessment,
        context: NextHourGuidanceContext
    ) async {
        var evidence: [TrendEvidence] = []
        for asset in context.assets {
            // 行情信号
            if let signal = market.perAssetSignals.first(where: { $0.targetID == asset.id }) {
                evidence.append(TrendEvidence(
                    id: "analysis:market:\(asset.id)",
                    sourceName: "行情信号分析",
                    title: "\(signal.targetName)：\(signal.trend)",
                    url: nil, publishedAt: nil, retrievedAt: context.generatedAt,
                    summary: signal.rationale,
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .portfolioSnapshot,
                        sourceTier: .primary,
                        entityNames: [signal.targetName],
                        metadataConfidence: .deterministic
                    )
                ))
            }
            // 新闻事件
            if let event = news.perAssetEvents.first(where: { $0.targetID == asset.id }) {
                evidence.append(TrendEvidence(
                    id: "analysis:news:\(asset.id)",
                    sourceName: "新闻事件分析",
                    title: "\(event.targetName)：\(event.sentiment)（\(event.keyEvents.joined(separator: "、"))）",
                    url: event.sources.first, publishedAt: nil, retrievedAt: context.generatedAt,
                    summary: "来源：\(event.sources.isEmpty ? "未取得" : event.sources.joined(separator: "、"))",
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .webSearch,
                        sourceTier: .secondary,
                        entityNames: [event.targetName],
                        metadataConfidence: .semanticDerived
                    )
                ))
            }
            // 持仓结构
            if let ctx = portfolio.perAssetContext.first(where: { $0.targetID == asset.id }) {
                evidence.append(TrendEvidence(
                    id: "analysis:portfolio:\(asset.id)",
                    sourceName: "持仓结构分析",
                    title: "\(ctx.targetName)：\(ctx.position)（\(ctx.riskExposure)）",
                    url: nil, publishedAt: nil, retrievedAt: context.generatedAt,
                    summary: ctx.recommendation + (ctx.overlapNote.map { "；\($0)" } ?? ""),
                    metadata: TrendEvidenceMetadata(
                        sourceKind: .portfolioSnapshot,
                        sourceTier: .primary,
                        entityNames: [ctx.targetName],
                        metadataConfidence: .deterministic
                    )
                ))
            }
        }
        await ledger.record(evidence)
    }

    /// 汇总决策 Agent：拿三个分析团队的结论，综合判断每个标的的买卖持有。
    ///
    /// 与原 run() 的关键差异：
    /// - prompt 重平衡：不再单边倒"宁可持有"，而是"有明确信号就给建议，标注把握程度"
    /// - 风控分级：不再用 11 个 AND 门槛强制退回 hold，改为让模型自行标注 confidence
    /// - 温度 0.2（原 0.1），让模型更愿意给出明确判断
    private func runDecisionAgent(
        context: NextHourGuidanceContext,
        market: MarketSignalAssessment,
        news: NewsEventAssessment,
        portfolio: PortfolioContextAssessment,
        settings: TrendAIProviderSettings
    ) async throws -> NextHourGuidanceAgent.Submission {
        let marketJSON = jsonString(market) ?? "{}"
        let newsJSON = jsonString(news) ?? "{}"
        let portfolioJSON = jsonString(portfolio) ?? "{}"

        let systemMessage = """
        你是中国市场投资决策专家。以下是三个分析团队的独立结论，请综合判断每个标的下一小时的操作建议。

        【行情信号团队结论】
        \(marketJSON)

        【新闻事件团队结论】
        \(newsJSON)

        【持仓结构团队结论】
        \(portfolioJSON)

        决策原则：
        1. 综合三个维度的信号做判断，不要只看一个维度。
        2. 有明确正向信号（行情强势+新闻利好+适合加仓）时，给出 buy 建议。
        3. 有明确负向信号（行情弱势+新闻利空+适合减仓）时，给出 sell 建议。
        4. 信号矛盾或不足时，给出 hold 并说明原因。
        5. instruction 必须说明仓位方式（如"小仓试水""减仓1/3"）和触发/失效条件。

        confidence（把握度）必须和依据数量挂钩——依据越多把握越高，依据少就老实标低：
        - 85-95：三个维度都有明确信号且方向一致，至少引用 5 条以上证据
        - 70-85：两个维度有明确信号且一致，至少引用 4 条证据
        - 55-70：一个维度有明确信号，引用 3 条证据，其他维度证据不足
        - 40-55：证据少于 3 条，信号矛盾或微弱，倾向 hold
        - 低于 40：几乎没有可靠证据，必须 hold

        重要：买卖建议（buy/sell）的 confidence 低于 55 时，改为 hold。
        依据不足 3 条时不要给买卖建议，先 hold。
        不要在依据只有 2 条的情况下给出中等偏高的把握度。
        """

        let userMessage = """
        研究窗口：\(context.slot.displayName)，有效至 \(context.slot.validUntil)。
        候选标的 \(context.assets.count) 个，选择最需要决策的 1-5 个。
        \(context.lastCloseReview.map { review in
            "昨晚复盘的明日关注(逐条回指到 followup_reviews,item_index 为下标;confirmed 必须引用今日证据——三个分析团队已替你核实的结论就是合格证据,查证不到才用 inconclusive):" +
            review.tomorrowWatch.enumerated()
                .map { "\($0.offset): \($0.element)" }
                .joined(separator: "；")
        } ?? "本次没有昨晚复盘的明日关注,不要提交 followup_reviews。")
        请综合三方分析结论，提交买卖持有建议。
        """

        let tools: [AgentToolDefinition] = [Self.submitTool()]
        var messages: [AgentChatMessage] = [
            .init(role: .system, content: systemMessage),
            .init(role: .user, content: userMessage)
        ]

        let decoder = JSONDecoder()
        let maxTurns = 4
        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            let result = try await client.complete(
                messages: messages,
                tools: tools,
                toolChoice: .required,
                temperature: 0.2,
                maxOutputTokens: nil,
                settings: settings,
                timeout: min(90, settings.timeoutSeconds),
                streamProgress: nil
            )
            messages.append(result.assistantMessage)

            if let submitCall = result.toolCalls.first(where: { $0.function.name == Self.submitToolName }) {
                if let data = submitCall.function.arguments.data(using: .utf8),
                   let submission = try? decoder.decode(NextHourGuidanceAgent.Submission.self, from: data) {
                    return submission
                }
                messages.append(.init(
                    role: .user,
                    content: "提交参数解码失败，请检查字段完整性后重新提交。"
                ))
            }
        }
        throw NextHourGuidanceAgentError.invalidSubmission(["决策 Agent 多次未通过校验"])
    }

    /// 把 Codable 对象编码为 JSON 字符串（给决策 Agent 注入子结论）。
    private func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 本地风控：依据不足的买卖建议降级为 hold。
    /// 规则：action 是 buy/sell 但 evidenceIDs < 3 或 confidence < 55 → 改为 hold。
    /// 防止模型在证据不充分时给出不可靠的买卖建议。
    private func enforceEvidenceFloor(_ submission: Submission) -> Submission {
        let minEvidenceCount = 3
        let minConfidenceForTrade = 55
        let downgradedActions = submission.actions.map { action -> ActionSubmission in
            let isTrade = action.action == .buy || action.action == .sell
            let evidenceTooFew = action.evidenceIDs.count < minEvidenceCount
            let confidenceTooLow = (action.confidence ?? 0) < minConfidenceForTrade
            if isTrade && (evidenceTooFew || confidenceTooLow) {
                return ActionSubmission(
                    targetID: action.targetID,
                    targetName: action.targetName,
                    action: .hold,
                    instruction: action.instruction,
                    rationale: "依据不足（\(action.evidenceIDs.count)条证据），降级为持有：" + action.rationale,
                    trigger: action.trigger,
                    invalidation: action.invalidation,
                    confidence: action.confidence,
                    evidenceIDs: action.evidenceIDs
                )
            }
            return action
        }
        return Submission(
            headline: submission.headline,
            posture: submission.posture,
            summary: submission.summary,
            actions: downgradedActions,
            riskChecks: submission.riskChecks
        )
    }

    private static func missingResearchRequirements(
        didReadContext: Bool,
        didReadLookThrough: Bool,
        didAttemptOfficialSource: Bool,
        officialSourceRequired: Bool,
        webSearchConfigured: Bool,
        webSearchAttemptCount: Int
    ) -> [String] {
        var errors: [String] = []
        if !didReadContext {
            errors.append("必须先调用 get_live_market_context 读取实时行情上下文")
        }
        if !didReadLookThrough {
            errors.append("必须先调用 get_fund_lookthrough 读取基金底层资产")
        }
        if officialSourceRequired, !didAttemptOfficialSource {
            errors.append("存在可查询的美股标的，必须先调用 official_sec_research 查询 SEC 官方披露")
        }
        if webSearchConfigured, webSearchAttemptCount < minimumWebSearchAttempts {
            errors.append("已配置联网搜索，提交前必须至少尝试两次 time_range=day 且带 research_target 的 web_search；搜索失败后可以提交 hold")
        }
        return errors
    }

    private static func recentDaySearchQuery(_ call: AgentToolCall) -> String? {
        guard let data = call.function.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timeRange = object["time_range"] as? String,
              timeRange == "day",
              let query = object["query"] as? String,
              let target = object["research_target"] as? [String: Any],
              let targetKind = target["kind"] as? String,
              !targetKind.isEmpty,
              let targetKey = target["key"] as? String,
              !targetKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// 回指净化(P5):序号越界/重复丢弃;confirmed 必须挂**当日**有效证据,
    /// 否则强制降级 inconclusive。回指是增强不是门槛——任何问题都不影响 actions。
    /// (internal:测试需要直接构造提交验证规则)
    static func sanitizeFollowupReviews(
        _ submissions: [FollowupReviewSubmission],
        context: NextHourGuidanceContext,
        evidence: [TrendEvidence],
        currentTimestamp: String
    ) -> (reviews: [NextHourFollowupReview], warnings: [String]) {
        guard let watch = context.lastCloseReview?.tomorrowWatch, !watch.isEmpty else {
            return ([], [])
        }
        var warnings: [String] = []
        var reviews: [NextHourFollowupReview] = []
        var seenIndexes = Set<Int>()
        let evidenceByID = Dictionary(
            evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let today = String(currentTimestamp.prefix(10))

        for submission in submissions {
            guard let index = submission.itemIndex, (0..<watch.count).contains(index) else {
                warnings.append("回指条目序号越界,已丢弃")
                continue
            }
            guard seenIndexes.insert(index).inserted else {
                warnings.append("回指条目序号重复(\(index + 1)),已丢弃后一条")
                continue
            }
            var status = submission.status ?? .inconclusive
            if status == .confirmed {
                let cited = (submission.evidenceIDs ?? []).compactMap { evidenceByID[$0] }
                // 本地行情/三方结论无 publishedAt,采集即当日;外部证据看发布日。
                let hasTodayEvidence = cited.contains { item in
                    guard let publishedAt = item.publishedAt, !publishedAt.isEmpty else { return true }
                    return String(publishedAt.prefix(10)) >= today
                }
                if !hasTodayEvidence {
                    status = .inconclusive
                    warnings.append("「\(watch[index])」回指为已出现但缺少当日有效证据,已降级为无法确认")
                }
            }
            reviews.append(
                NextHourFollowupReview(
                    itemIndex: index,
                    itemText: watch[index],
                    status: status,
                    note: submission.note ?? "",
                    evidenceIDs: (submission.evidenceIDs ?? []).filter { evidenceByID[$0] != nil }
                )
            )
        }
        reviews.sort { $0.itemIndex < $1.itemIndex }
        return (reviews, warnings)
    }

    private static func makeReport(
        submission: Submission,
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        officialSourceConfigured: Bool,
        webSearchConfigured: Bool,
        ledger: TrendEvidenceLedger,
        toolCalls: [TrendAgentToolCallAudit]
    ) async -> NextHourGuidanceReport {
        var seenEvidenceIDs = Set<String>()
        let orderedEvidenceIDs = submission.actions
            .flatMap(\.evidenceIDs)
            .filter { seenEvidenceIDs.insert($0).inserted }
        var evidence: [TrendEvidence] = []
        for evidenceID in orderedEvidenceIDs {
            if let item = await ledger.canonical(for: evidenceID) {
                evidence.append(item)
            }
        }
        let auditEvidence = await ledger.allEvidence()
        let followup = sanitizeFollowupReviews(
            submission.followupReviews ?? [],
            context: context,
            evidence: auditEvidence,
            currentTimestamp: context.generatedAt
        )
        var warnings = context.marketDataWarnings + researchSnapshot.sourceWarnings
        warnings.append(contentsOf: researchSnapshot.lookThrough?.warnings ?? [])
        warnings.append(contentsOf: followup.warnings)
        let sourceStatuses = await normalizedSourceStatuses(
            snapshot: researchSnapshot,
            officialSourceConfigured: officialSourceConfigured,
            webSearchConfigured: webSearchConfigured,
            ledger: ledger
        )
        warnings.append(contentsOf: sourceStatuses.compactMap(\.warningText))
        if !webSearchConfigured {
            warnings.append("未配置 Tavily 联网搜索，本次风控规则禁止输出买入或卖出。")
        } else if !orderedEvidenceIDs.contains(where: { $0.hasPrefix("web:tavily:") }) {
            warnings.append("联网搜索未形成可引用证据，本次只允许持有建议。")
        }
        warnings = Array(Set(warnings.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })).sorted()

        return NextHourGuidanceReport(
            runID: researchSnapshot.runID,
            generatedAt: context.generatedAt,
            validUntil: context.slot.validUntil,
            slotKey: context.slot.key,
            scope: context.slot.scope,
            headline: submission.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            posture: submission.posture,
            summary: submission.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: submission.actions.map {
                NextHourGuidanceAction(
                    targetID: $0.targetID,
                    targetName: $0.targetName,
                    action: $0.action ?? .hold,
                    instruction: $0.instruction,
                    rationale: $0.rationale,
                    trigger: $0.trigger,
                    invalidation: $0.invalidation,
                    confidence: $0.confidence ?? 0,
                    evidenceIDs: $0.evidenceIDs
                )
            },
            riskChecks: submission.riskChecks,
            assetCount: context.assets.count,
            disposition: Self.reportDisposition(
                submission: submission,
                context: context,
                webSearchConfigured: webSearchConfigured,
                evidence: evidence
            ),
            sourceStatuses: sourceStatuses,
            evidence: evidence,
            auditToolCalls: toolCalls,
            auditEvidence: auditEvidence,
            warnings: warnings,
            followupReviews: followup.reviews
        )
    }

    private static func normalizedSourceStatuses(
        snapshot: TrendResearchSnapshot,
        officialSourceConfigured: Bool,
        webSearchConfigured: Bool,
        ledger: TrendEvidenceLedger
    ) async -> [TrendSourceStatus] {
        var bySource = Dictionary(
            snapshot.sourceStatuses.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allEvidence = await ledger.allEvidence()
        let officialEvidence = allEvidence.filter {
            $0.metadata.sourceKind.isOfficialPrimary || $0.id.hasPrefix("official:sec:")
        }
        if snapshot.eligibleSECResearchTickers.isEmpty {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: .notRequested,
                receivedAt: snapshot.createdAt,
                detail: "当前快照没有可映射到 SEC 的美国股票代码。"
            )
        } else {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: officialSourceConfigured
                    ? (officialEvidence.isEmpty ? .failed : .success)
                    : .notConfigured,
                asOf: officialEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: officialEvidence.map(\.retrievedAt).max() ?? snapshot.createdAt,
                errorCode: officialSourceConfigured && officialEvidence.isEmpty
                    ? "no_usable_official_evidence"
                    : nil,
                itemCount: officialEvidence.count
            )
        }
        let webEvidence = allEvidence.filter {
            $0.metadata.sourceKind == .webSearch || $0.id.hasPrefix("web:tavily:")
        }
        bySource[.webSearch] = TrendSourceStatus(
            source: .webSearch,
            status: webSearchConfigured
                ? (webEvidence.isEmpty ? .failed : .success)
                : .notConfigured,
            asOf: webEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
            receivedAt: webEvidence.map(\.retrievedAt).max() ?? snapshot.createdAt,
            errorCode: webSearchConfigured && webEvidence.isEmpty
                ? "no_usable_web_evidence"
                : nil,
            itemCount: webEvidence.count
        )
        for source in TrendDataSource.allCases where bySource[source] == nil {
            bySource[source] = TrendSourceStatus(
                source: source,
                status: .notRequested,
                receivedAt: snapshot.createdAt
            )
        }
        return TrendDataSource.allCases.compactMap { bySource[$0] }
    }

    private static func reportDisposition(
        submission: Submission,
        context: NextHourGuidanceContext,
        webSearchConfigured: Bool,
        evidence: [TrendEvidence]
    ) -> TrendReportDisposition {
        if submission.actions.contains(where: { $0.action == .buy || $0.action == .sell }) {
            return .actionable
        }
        let hasWebEvidence = evidence.contains {
            $0.metadata.sourceKind == .webSearch || $0.id.hasPrefix("web:tavily:")
        }
        if !context.marketDataIsFresh || !webSearchConfigured || !hasWebEvidence {
            return .insufficientEvidence
        }
        return .analysisOnly
    }

    private static func validate(
        _ submission: Submission,
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        webSearchConfigured: Bool,
        recentSearchQueries: [String],
        ledger: TrendEvidenceLedger
    ) async -> [String] {
        var errors: [String] = []
        let assetsByID = Dictionary(uniqueKeysWithValues: context.assets.map { ($0.id, $0) })
        let assetsByName = Dictionary(
            context.assets.compactMap {
                let key = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return key.isEmpty ? nil : (key, $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let allEvidence = await ledger.allEvidence()
        let evidenceByID = Dictionary(
            allEvidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let availableEvidenceIDs = Set(evidenceByID.keys)
        var seenTargetIDs = Set<String>()
        if submission.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("headline 不能为空")
        }
        if submission.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("summary 不能为空")
        }
        if submission.actions.isEmpty || submission.actions.count > 5 {
            errors.append("actions 必须为 1 到 5 条")
        }
        if !(2...4).contains(submission.riskChecks.count) {
            errors.append("risk_checks 必须提供 2 到 4 条执行前复核项")
        }
        for (index, action) in submission.actions.enumerated() {
            // 一次性报出该动作所有缺失的必填字段，避免逐字段往返。
            if !action.missingFields.isEmpty {
                errors.append("第 \(index + 1) 条动作缺少字段：\(action.missingFields.joined(separator: "、"))")
            }
            let trimmedID = action.targetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let asset: NextHourGuidanceAssetContext?
            if !trimmedID.isEmpty {
                asset = assetsByID[trimmedID]
            } else if !action.targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                asset = assetsByName[action.targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            } else {
                asset = nil
            }
            guard let asset else {
                if !trimmedID.isEmpty {
                    errors.append("第 \(index + 1) 条动作的 target_id(\(trimmedID)) 不属于本次候选持仓")
                } else if !action.targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("第 \(index + 1) 条动作无法根据 target_name「\(action.targetName)」定位标的；请使用 get_live_market_context 返回的 target_id")
                }
                // target_name 也缺时，missingFields 已报过，不重复
                continue
            }
            if !seenTargetIDs.insert(asset.id).inserted {
                errors.append("同一标的不能重复给出多条互相冲突的动作：\(asset.name)")
            }
            if let actionKind = action.action, ![NextHourGuidanceActionKind.buy, .sell, .hold].contains(actionKind) {
                errors.append("第 \(index + 1) 条动作必须是 buy、sell 或 hold")
            }
            if let confidence = action.confidence, !(0...100).contains(confidence) {
                errors.append("第 \(index + 1) 条动作置信度超出 0 到 100")
            }
            let missingEvidence = Set(action.evidenceIDs).subtracting(availableEvidenceIDs)
            if !missingEvidence.isEmpty {
                errors.append("第 \(index + 1) 条动作引用了不存在的证据：\(missingEvidence.sorted().joined(separator: "、"))")
            }
            if !action.evidenceIDs.contains(asset.evidenceID) {
                errors.append("第 \(index + 1) 条动作必须引用该标的的本地行情证据 \(asset.evidenceID)")
            }

            let isTrade = action.action == .buy || action.action == .sell
            if isTrade {
                let disclosure = asset.code.flatMap {
                    researchSnapshot.lookThrough?.disclosures[$0]
                }
                errors.append(contentsOf: TrendClaimEvidencePolicy().validateExecution(
                    actionKind: action.action ?? .hold,
                    targetName: asset.name,
                    targetCode: asset.code,
                    instruction: action.instruction,
                    trigger: action.trigger,
                    invalidation: action.invalidation,
                    quoteAssessment: asset.quoteAssessment,
                    marketDataIsFresh: context.marketDataIsFresh,
                    webSearchConfigured: webSearchConfigured,
                    evidenceIDs: action.evidenceIDs,
                    evidenceByID: evidenceByID,
                    relatedEntityCodes: disclosure?.holdings.map(\.code) ?? [],
                    relatedEntityNames: disclosure?.holdings.map(\.name) ?? [],
                    relatedSectorKeys: disclosure?.industries.map(\.name) ?? [],
                    requiresFundDisclosure: asset.assetType.contains("基金"),
                    fundDisclosureEvidencePrefix: asset.code.flatMap { code in
                        disclosure == nil ? nil : "fund:look-through:\(code):"
                    }
                ))
                if !hasTargetedSearch(
                    asset: asset,
                    researchSnapshot: researchSnapshot,
                    queries: recentSearchQueries
                ) {
                    errors.append("\(asset.name) 的买卖动作缺少针对标的、底层证券或行业的最近一天搜索")
                }
            }
        }
        return errors
    }

    private static func hasTargetedSearch(
        asset: NextHourGuidanceAssetContext,
        researchSnapshot: TrendResearchSnapshot,
        queries: [String]
    ) -> Bool {
        var terms = [asset.name, asset.code].compactMap { value -> String? in
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return normalized.count >= 2 ? normalized : nil
        }
        if let code = asset.code,
           let disclosure = researchSnapshot.lookThrough?.disclosures[code] {
            terms.append(contentsOf: disclosure.holdings.prefix(12).flatMap {
                [$0.name.lowercased(), $0.code.lowercased()]
            })
            terms.append(contentsOf: disclosure.industries.prefix(8).map {
                $0.name.lowercased()
            })
        }
        return queries.contains { query in
            terms.contains { term in
                term.count >= 2 && query.contains(term)
            }
        }
    }

    private static func contextToolResult(
        context: NextHourGuidanceContext,
        ledger: TrendEvidenceLedger
    ) async -> TrendResearchToolResult {
        var evidence: [TrendEvidence] = context.assets.map { asset in
            TrendEvidence(
                id: asset.evidenceID,
                sourceName: asset.quoteSource ?? "本地持仓行情",
                title: "\(asset.name) 行情与持仓快照",
                url: nil,
                publishedAt: asset.quoteTime,
                retrievedAt: context.generatedAt,
                summary: "\(asset.name)（\(asset.code ?? "无代码")）价格 \(asset.currentPrice.map { String($0) } ?? "未知")，涨跌 \(asset.estimateChangePct.map { String(format: "%+.2f%%", $0) } ?? "未知")，组合权重 \(asset.weightPct.map { String(format: "%.2f%%", $0) } ?? "未知")。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .portfolioSnapshot,
                    sourceTier: .primary,
                    entityCodes: [asset.code].compactMap { $0 },
                    entityNames: [asset.name],
                    quoteType: asset.quoteAssessment.quoteType,
                    freshnessStatus: asset.quoteAssessment.freshnessStatus,
                    metadataConfidence: .deterministic
                )
            )
        }
        evidence.append(contentsOf: context.market.map { quote in
            TrendEvidence(
                id: quote.evidenceID,
                sourceName: quote.sourceLabel,
                title: quote.name,
                url: nil,
                publishedAt: quote.quotedAt,
                retrievedAt: context.generatedAt,
                summary: "\(quote.name) \(quote.price)，涨跌 \(quote.changePct.map { String(format: "%+.2f%%", $0) } ?? "未知")。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .marketQuote,
                    sourceTier: .primary,
                    entityNames: [quote.name],
                    quoteType: quote.quoteAssessment.quoteType,
                    freshnessStatus: quote.quoteAssessment.freshnessStatus,
                    metadataConfidence: .deterministic
                )
            )
        })
        await ledger.record(evidence)

        guard let data = try? JSONEncoder().encode(context),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .content(
                TrendResearchToolEnvelope.error(
                    code: "context_serialization_failed",
                    message: "实时行情上下文序列化失败。"
                ),
                isError: true
            )
        }
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "context": object,
                    "fresh_market_data": context.marketDataIsFresh,
                    "trade_gate": context.marketDataIsFresh
                        ? "行情时效满足；买卖仍需网页与基金穿透证据"
                        : "行情时效不足；所有标的只能 hold",
                ],
                warnings: context.marketDataWarnings,
                evidenceIDs: evidence.map(\.id)
            )
        )
    }

    private static func contextTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: contextToolName,
            description: "读取刚刷新的持仓报价、报价时间、指数行情、数据新鲜度、旧研判边界和本次候选标的。提交前必须调用。",
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ]
        )
    }

    private static func submitTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: "submit_next_hour_guidance",
            description: "提交有可核验证据的下一小时买卖建议。每条动作必须明确为买入、卖出或持有。",
            parameters: [
                "type": "object",
                "properties": [
                    "headline": [
                        "type": "string",
                        "description": "不超过 24 个汉字的核心结论"
                    ],
                    "posture": [
                        "type": "string",
                        "enum": ["defensive", "balanced", "selective", "opportunistic"]
                    ],
                    "summary": [
                        "type": "string",
                        "description": "两到三句话，说明下一小时的总体策略"
                    ],
                    "actions": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 5,
                        "items": [
                            "type": "object",
                            "properties": [
                                "target_id": [
                                    "type": "string",
                                    "description": "必须原样使用 get_live_market_context 返回的资产 id"
                                ],
                                "target_name": ["type": "string"],
                                "action": [
                                    "type": "string",
                                    "enum": ["buy", "sell", "hold"]
                                ],
                                "instruction": ["type": "string"],
                                "rationale": ["type": "string"],
                                "trigger": ["type": "string"],
                                "invalidation": ["type": "string"],
                                "confidence": ["type": "integer", "minimum": 0, "maximum": 100],
                                "evidence_ids": [
                                    "type": "array",
                                    "minItems": 1,
                                    "maxItems": 8,
                                    "items": ["type": "string"],
                                    "description": "只能引用本次工具结果实际返回的 evidence_id"
                                ],
                            ],
                            "required": [
                                "target_id", "target_name", "action", "instruction",
                                "rationale", "trigger", "invalidation", "confidence",
                                "evidence_ids",
                            ],
                            "additionalProperties": false,
                        ],
                    ],
                    "risk_checks": [
                        "type": "array",
                        "minItems": 2,
                        "items": ["type": "string"],
                        "maxItems": 4,
                    ],
                ],
                "required": ["headline", "posture", "summary", "actions", "risk_checks"],
                "additionalProperties": false,
            ]
        )
    }
}
