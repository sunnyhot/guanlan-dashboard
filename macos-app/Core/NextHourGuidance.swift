import CryptoKit
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

    var displayName: String {
        switch self {
        case .buy:
            return "建议买入"
        case .sell:
            return "建议卖出"
        case .hold:
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

/// 全市场广度注入（2026-08-31，baseline 10.6 收尾）：
/// 由 App 预暖缓存直接带入（首算约 15-30s，注入后 Agent 无需等工具冷算）。
/// 证据 ID 与 get_market_breadth 工具同口径 `market:breadth:{date}`。
struct NextHourGuidanceBreadthContext: Codable, Hashable, Sendable {
    let evidenceID: String
    let summary: String
    let upCount: Int
    let downCount: Int
    let limitUpCount: Int
    let limitDownCount: Int
    let totalAmountYi: Double?
    let sampleCount: Int
    let computedAt: String
    let dataBoundary: String

    init?(stats: MarketBreadthStats) {
        guard stats.sampleCount > 0 else { return nil }
        let day = String(stats.computedAt.prefix(10))
        self.init(
            evidenceID: "market:breadth:\(day)",
            summary: "\(stats.advanceDeclineSummary)；\(stats.limitSummary)",
            upCount: stats.upCount,
            downCount: stats.downCount,
            limitUpCount: stats.limitUpCount,
            limitDownCount: stats.limitDownCount,
            totalAmountYi: stats.totalAmountYi,
            sampleCount: stats.sampleCount,
            computedAt: stats.computedAt,
            dataBoundary: stats.dataBoundary
        )
    }

    init(
        evidenceID: String,
        summary: String,
        upCount: Int,
        downCount: Int,
        limitUpCount: Int,
        limitDownCount: Int,
        totalAmountYi: Double?,
        sampleCount: Int,
        computedAt: String,
        dataBoundary: String
    ) {
        self.evidenceID = evidenceID
        self.summary = summary
        self.upCount = upCount
        self.downCount = downCount
        self.limitUpCount = limitUpCount
        self.limitDownCount = limitDownCount
        self.totalAmountYi = totalAmountYi
        self.sampleCount = sampleCount
        self.computedAt = computedAt
        self.dataBoundary = dataBoundary
    }
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
    /// 全市场广度(预暖注入)。nil 时行为与旧版完全一致。
    var marketBreadth: NextHourGuidanceBreadthContext? = nil
    /// 本地财经热榜(NewsNow 注入,2026-09-02 取代已下线联网搜索的新闻面)。
    /// nil 时行为与旧版完全一致。
    var marketNews: [NextHourGuidanceNewsItem]? = nil

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

/// 本地财经热榜条目(NewsNow 拉取,2026-09-02 取代已下线的联网搜索)。
/// 热榜条目没有跨请求稳定的 itemID,evidenceID 用「源|标题」哈希保持当日稳定;
/// entityNames 是标题与候选标的名字的确定性匹配结果,供证据关联校验使用
/// ——与标的无关的热榜条目 entityNames 为空,不会解锁买卖建议。
struct NextHourGuidanceNewsItem: Codable, Hashable, Sendable {
    let evidenceID: String
    let title: String
    let sourceName: String
    let publisherKey: String
    let sourceTier: TrendEvidenceSourceTier
    let url: String?
    let entityNames: [String]
}

/// 热榜源条目 → 注入条目的纯函数组装(测试锚定行为)。
enum NextHourGuidanceNewsAssembler {
    static let maxItems = 30

    static func items(
        feeds: [(sourceID: String, items: [NewsFeedItem])],
        assetNames: [String]
    ) -> [NextHourGuidanceNewsItem] {
        var seenTitles = Set<String>()
        var result: [NextHourGuidanceNewsItem] = []
        for feed in feeds {
            for item in feed.items {
                guard result.count < maxItems else { return result }
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seenTitles.insert(title).inserted else { continue }
                result.append(
                    NextHourGuidanceNewsItem(
                        evidenceID: "news:newsnow:\(feed.sourceID):\(stableHash("\(feed.sourceID)|\(title)"))",
                        title: title,
                        sourceName: item.sourceName,
                        publisherKey: feed.sourceID,
                        sourceTier: tier(forSourceID: feed.sourceID),
                        url: item.url,
                        entityNames: matchedEntityNames(title: title, assetNames: assetNames)
                    )
                )
            }
        }
        return result
    }

    /// 财联社/华尔街见闻按权威财经媒体计;其余热榜为二手聚合(secondary)。
    static func tier(forSourceID sourceID: String) -> TrendEvidenceSourceTier {
        switch sourceID {
        case "cls-hot", "wallstreetcn-quick": return .authoritative
        default: return .secondary
        }
    }

    /// 标题↔标的名单向包含匹配(标题包含标的名)。短名(少于 3 字)跳过防误匹配。
    static func matchedEntityNames(title: String, assetNames: [String]) -> [String] {
        let lowercasedTitle = title.lowercased()
        return assetNames.filter { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.count >= 3 else { return false }
            return lowercasedTitle.contains(trimmed)
        }
    }

    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }
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
    /// 3+1 子 Agent 编排（行情/新闻/持仓并行 → 汇总决策）。
    func run(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings
    ) async throws -> NextHourGuidanceReport
}

enum NextHourGuidanceAgentError: Error, LocalizedError {
    case missingConfiguration
    case invalidSubmission([String])

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "尚未配置趋势分析模型，无法生成下一小时买卖建议。"
        case .invalidSubmission(let errors):
            return "下一小时买卖建议校验失败：\(errors.joined(separator: "；"))"
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

    private static let submitToolName = "submit_next_hour_guidance"

    init(
        client: any TrendResearchAgentClient = GatewayAgentClient(purpose: "next-hour-guidance")
    ) {
        self.client = client
        self.registry = TrendResearchToolRegistry()
    }

    // MARK: - 3+1 子 Agent 编排

    /// 3 个并行分析子 Agent + 1 个汇总决策 Agent。
    /// 每个子 Agent 聚焦一个维度，汇总时综合三方结论生成操作参考。
    func run(
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings
    ) async throws -> NextHourGuidanceReport {
        guard settings.isConfigured else { throw NextHourGuidanceAgentError.missingConfiguration }

        let ledger = TrendEvidenceLedger()
        let orchestrator = NextHourGuidanceSubAgentOrchestrator(
            client: client,
            registry: registry,
            context: context,
            snapshot: researchSnapshot,
            evidenceLedger: ledger
        )

        // 1. 并行运行 3 个分析子 Agent
        let (marketAssessment, newsAssessment, portfolioAssessment) = try await orchestrator.runAnalysisAgents(
            settings: settings
        )

        // 1.5 把三方分析结论注入 Ledger 作为证据，供决策 Agent 引用 + 报告展示
        await injectAnalysisEvidence(
            ledger: ledger,
            market: marketAssessment,
            news: newsAssessment,
            portfolio: portfolioAssessment,
            context: context
        )

        // 决策 Agent 只拿到三方结论还不够，必须同时看到原始工具证据索引。
        let originalEvidence = await ledger.allEvidence().filter { !$0.id.hasPrefix("analysis:") }

        // 2. 汇总决策 Agent：综合三方结论，输出最终买卖建议
        var submission = try await runDecisionAgent(
            context: context,
            market: marketAssessment,
            news: newsAssessment,
            portfolio: portfolioAssessment,
            originalEvidence: originalEvidence,
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
            ledger: ledger,
            toolCalls: []
        )

        // 3.5 修复证据绑定：决策 Agent 可能编造了假 evidenceID（Ledger 里不存在）。
        // 用 targetID 从 Ledger 匹配真实的 analysis:* 证据 ID，替换无效 ID。
        let allLedgerEvidence = await ledger.allEvidence()
        if !allLedgerEvidence.isEmpty {
            report = Self.repairEvidenceBinding(report: report, ledgerEvidence: allLedgerEvidence)
        }
        // 证据修复可能减少真实 ID 数量，最终报告必须重新过门禁。
        return Self.enforceFinalEvidenceRequirements(
            report: report,
            context: context,
            researchSnapshot: researchSnapshot
        )
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
            var seen = Set<String>()
            let knownIDs = action.evidenceIDs.filter {
                validIDs.contains($0) && seen.insert($0).inserted
            }
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
                    .filter { seen.insert($0).inserted }
            } else {
                // targetID 也匹配不到，按 targetName 匹配
                matchedIDs = ledgerEvidence
                    .filter { $0.metadata.entityNames.contains(action.targetName) }
                    .map(\.id)
                    .filter { seen.insert($0).inserted }
            }
            return NextHourGuidanceAction(
                targetID: action.targetID, targetName: action.targetName,
                action: action.action, instruction: action.instruction,
                rationale: action.rationale, trigger: action.trigger,
                invalidation: action.invalidation, confidence: action.confidence,
                evidenceIDs: matchedIDs
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
            warnings: report.warnings,
            followupReviews: report.followupReviews
        )
    }

    /// 把三方分析结论注入 Ledger 作为证据。
    /// 每个标的的每个维度（行情/新闻/持仓）生成一条证据，让决策 Agent 可引用、报告可展示。
    private static func enforceFinalEvidenceRequirements(
        report: NextHourGuidanceReport,
        context: NextHourGuidanceContext,
        researchSnapshot: TrendResearchSnapshot
    ) -> NextHourGuidanceReport {
        let assetsByID = Dictionary(uniqueKeysWithValues: context.assets.map { ($0.id, $0) })
        let assetsByName = Dictionary(
            context.assets.map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let evidenceByID = Dictionary(
            (report.auditEvidence + report.evidence).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var didDowngrade = false
        let actions = report.actions.map { action -> NextHourGuidanceAction in
            guard action.action == .buy || action.action == .sell else { return action }
            var seen = Set<String>()
            let validIDs = action.evidenceIDs.filter {
                seen.insert($0).inserted && evidenceByID[$0] != nil
            }
            let asset = action.targetID.flatMap { assetsByID[$0] }
                ?? assetsByName[action.targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            var reasons: [String] = []
            if validIDs.count < 3 { reasons.append("真实证据不足 3 条") }
            if action.confidence < 55 { reasons.append("置信度低于 55") }
            if asset == nil {
                reasons.append("无法定位候选标的")
            } else if let asset {
                if !validIDs.contains(asset.evidenceID) {
                    reasons.append("缺少该标的原始行情证据")
                }
                if asset.assetType.contains("基金"),
                   let code = asset.code,
                   researchSnapshot.lookThrough?.disclosures[code] != nil,
                   !validIDs.contains(where: { $0.hasPrefix("fund:look-through:\(code):") }) {
                    reasons.append("缺少基金穿透证据")
                }
            }
            guard reasons.isEmpty else {
                didDowngrade = true
                return NextHourGuidanceAction(
                    targetID: action.targetID,
                    targetName: action.targetName,
                    action: .hold,
                    instruction: action.instruction,
                    rationale: reasons.joined(separator: "、") + "，已降级为持有：" + action.rationale,
                    trigger: action.trigger,
                    invalidation: action.invalidation,
                    confidence: min(action.confidence, 40),
                    evidenceIDs: validIDs
                )
            }
            return NextHourGuidanceAction(
                targetID: action.targetID,
                targetName: action.targetName,
                action: action.action,
                instruction: action.instruction,
                rationale: action.rationale,
                trigger: action.trigger,
                invalidation: action.invalidation,
                confidence: action.confidence,
                evidenceIDs: validIDs
            )
        }
        let hasTrade = actions.contains { $0.action == .buy || $0.action == .sell }
        let disposition: TrendReportDisposition = hasTrade
            ? .actionable
            : (didDowngrade || !context.marketDataIsFresh ? .insufficientEvidence : .analysisOnly)
        return NextHourGuidanceReport(
            runID: report.runID,
            generatedAt: report.generatedAt,
            validUntil: report.validUntil,
            slotKey: report.slotKey,
            scope: report.scope,
            headline: report.headline,
            posture: report.posture,
            summary: report.summary,
            actions: actions,
            riskChecks: report.riskChecks,
            assetCount: report.assetCount,
            disposition: disposition,
            sourceStatuses: report.sourceStatuses,
            evidence: report.evidence,
            auditToolCalls: report.auditToolCalls,
            auditEvidence: report.auditEvidence,
            warnings: report.warnings + (didDowngrade ? ["部分买卖建议因真实证据不足已降级为持有。"] : []),
            followupReviews: report.followupReviews
        )
    }

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
    /// 决策原则：综合三方结论，用置信度和证据数量分级标注把握程度。
    private func runDecisionAgent(
        context: NextHourGuidanceContext,
        market: MarketSignalAssessment,
        news: NewsEventAssessment,
        portfolio: PortfolioContextAssessment,
        originalEvidence: [TrendEvidence],
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

        【原始工具证据索引】
        \(originalEvidence.isEmpty
            ? "本轮没有原始工具证据，所有标的只能 hold。"
            : originalEvidence.map { "- [\($0.id)] \($0.title)：\($0.summary)" }.joined(separator: "\n"))

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
        buy/sell 必须包含该标的原始行情 ID；有基金穿透披露时还必须包含对应 fund:look-through 证据 ID。
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
                deadline: nil,
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
            riskChecks: submission.riskChecks,
            followupReviews: submission.followupReviews
        )
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
        let sourceStatuses = normalizedSourceStatuses(snapshot: researchSnapshot)
        warnings.append(contentsOf: sourceStatuses.compactMap(\.warningText))
        warnings.append("联网搜索已下线；外部事件参考本地财经热榜（NewsNow），买卖建议按当前研判规则生成。")
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
        snapshot: TrendResearchSnapshot
    ) -> [TrendSourceStatus] {
        var bySource = Dictionary(
            snapshot.sourceStatuses.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        bySource[.officialSource] = TrendSourceStatus(
            source: .officialSource,
            status: .notConfigured,
            receivedAt: snapshot.createdAt,
            detail: "SEC 官方源已下线（2026-08-28 移除）。"
        )
        bySource[.webSearch] = TrendSourceStatus(
            source: .webSearch,
            status: .notConfigured,
            receivedAt: snapshot.createdAt,
            detail: "联网搜索已下线；盘中新闻面改用本地财经热榜（NewsNow：财联社/华尔街见闻/雪球）。"
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
        evidence: [TrendEvidence]
    ) -> TrendReportDisposition {
        if submission.actions.contains(where: { $0.action == .buy || $0.action == .sell }) {
            return .actionable
        }
        // 联网搜索已下线：不再有外部研究证据维度，非行动报告统一 insufficientEvidence。
        if !context.marketDataIsFresh {
            return .insufficientEvidence
        }
        return .analysisOnly
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
