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
    static let timeStrings = ["09:15", "10:15", "11:15", "13:15", "14:15", "14:50"]

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
    let disclaimer: String

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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        return try decoder.decode(NextHourGuidanceArchive.self, from: Data(contentsOf: fileURL))
    }

    func save(_ archive: NextHourGuidanceArchive, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
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

        private enum CodingKeys: String, CodingKey {
            case headline
            case posture
            case summary
            case actions
            case riskChecks = "risk_checks"
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
        webSearchCache: TrendWebSearchResponseCache = TrendWebSearchResponseCache(
            ttlSeconds: 10 * 60
        )
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
            cache: webSearchCache
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
                            lastErrors = ["提交 JSON 无法解码：\(Self.describeDecodeError(error))"]
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
        var warnings = context.marketDataWarnings + researchSnapshot.sourceWarnings
        warnings.append(contentsOf: researchSnapshot.lookThrough?.warnings ?? [])
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
            warnings: warnings
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

    private static func describeDecodeError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "缺少字段 \(key.stringValue)"
        case .valueNotFound(_, let context):
            return "缺少必要值（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .typeMismatch(_, let context):
            return "字段类型不匹配（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
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
