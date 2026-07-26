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
            return "精选观察"
        case .opportunistic:
            return "条件式进攻"
        }
    }
}

enum NextHourGuidanceActionKind: String, Codable, Hashable, Sendable {
    case hold
    case watch
    case wait
    case avoidChasing = "avoid_chasing"
    case buySmall = "buy_small"
    case reduceSmall = "reduce_small"

    var displayName: String {
        switch self {
        case .hold:
            return "持有"
        case .watch:
            return "观察"
        case .wait:
            return "等待"
        case .avoidChasing:
            return "不追涨"
        case .buySmall:
            return "小仓试探"
        case .reduceSmall:
            return "小幅降低"
        }
    }
}

struct NextHourGuidanceAction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let targetName: String
    let action: NextHourGuidanceActionKind
    let instruction: String
    let rationale: String
    let trigger: String
    let invalidation: String
    let confidence: Int

    init(
        id: UUID = UUID(),
        targetName: String,
        action: NextHourGuidanceActionKind,
        instruction: String,
        rationale: String,
        trigger: String,
        invalidation: String,
        confidence: Int
    ) {
        self.id = id
        self.targetName = targetName
        self.action = action
        self.instruction = instruction
        self.rationale = rationale
        self.trigger = trigger
        self.invalidation = invalidation
        self.confidence = min(100, max(0, confidence))
    }
}

struct NextHourGuidanceReport: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
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
    let disclaimer: String

    init(
        id: UUID = UUID(),
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
        disclaimer: String = "仅供条件式决策参考，不构成收益承诺或个性化投资建议。"
    ) {
        self.id = id
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
        self.disclaimer = disclaimer
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
    let name: String
    let code: String?
    let assetType: String
    let status: String
    let weightPct: Double?
    let currentPrice: Double?
    let profitPct: Double?
    let estimateChangePct: Double?
    let pendingTradeCount: Int
    let activePlanCount: Int
}

struct NextHourGuidanceMarketContext: Codable, Hashable, Sendable {
    let name: String
    let price: Double
    let changePct: Double?
    let quotedAt: String
}

struct NextHourGuidanceContext: Codable, Hashable, Sendable {
    let generatedAt: String
    let slot: NextHourGuidanceSlot
    let assets: [NextHourGuidanceAssetContext]
    let market: [NextHourGuidanceMarketContext]
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
        settings: TrendAIProviderSettings
    ) async throws -> NextHourGuidanceReport
}

enum NextHourGuidanceAgentError: Error, LocalizedError {
    case missingConfiguration
    case missingToolCall
    case invalidSubmission([String])

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "尚未配置趋势分析模型，无法生成下一小时操作指引。"
        case .missingToolCall:
            return "模型没有按要求提交下一小时操作指引。"
        case .invalidSubmission(let errors):
            return "下一小时操作指引校验失败：\(errors.joined(separator: "；"))"
        }
    }
}

struct NextHourGuidanceAgent: NextHourGuidanceAgentProtocol, Sendable {
    private struct Submission: Codable {
        let headline: String
        let posture: NextHourGuidancePosture
        let summary: String
        let actions: [ActionSubmission]
        let riskChecks: [String]
    }

    private struct ActionSubmission: Codable {
        let targetName: String
        let action: NextHourGuidanceActionKind
        let instruction: String
        let rationale: String
        let trigger: String
        let invalidation: String
        let confidence: Int
    }

    let client: any TrendResearchAgentClient

    init(client: any TrendResearchAgentClient = OpenAICompatibleAgentClient()) {
        self.client = client
    }

    func run(
        context: NextHourGuidanceContext,
        settings: TrendAIProviderSettings
    ) async throws -> NextHourGuidanceReport {
        guard settings.isConfigured else { throw NextHourGuidanceAgentError.missingConfiguration }

        let tool = Self.submitTool()
        var messages: [AgentChatMessage] = [
            .init(
                role: .system,
                content: """
                你是中国市场盘中风控助手。任务是根据提供的本地持仓和行情快照，生成“下一小时操作指引”。
                只讨论当前有效时段；不得编造未提供的新闻、价格或成交量。建议必须是条件式的，明确触发条件和失效条件。
                没有清晰优势时，必须建议持有、观察、等待或不追涨，不能为了凑动作而建议交易。
                单次最多给 5 条动作。场外基金只会在 14:50 收盘前窗口出现在输入中；不要把它描述为可盘中实时成交。
                必须调用 submit_next_hour_guidance 工具提交结果，不要输出普通文本。
                """
            ),
            .init(
                role: .user,
                content: "请基于以下 JSON 快照生成下一小时操作指引：\n\(context.jsonString())"
            ),
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var lastErrors: [String] = []

        for _ in 0..<2 {
            try Task.checkCancellation()
            let result = try await client.complete(
                messages: messages,
                tools: [tool],
                toolChoice: .function(name: "submit_next_hour_guidance"),
                temperature: 0.1,
                settings: settings,
                timeout: min(120, settings.timeoutSeconds),
                streamProgress: nil
            )

            guard let call = result.toolCalls.first(where: {
                $0.function.name == "submit_next_hour_guidance"
            }) else {
                messages.append(result.assistantMessage)
                messages.append(.init(
                    role: .user,
                    content: "没有收到工具提交。请立即调用 submit_next_hour_guidance。"
                ))
                lastErrors = ["模型未调用提交工具"]
                continue
            }

            do {
                let submission = try decoder.decode(
                    Submission.self,
                    from: Data(call.function.arguments.utf8)
                )
                let errors = Self.validate(submission)
                guard errors.isEmpty else {
                    lastErrors = errors
                    messages.append(result.assistantMessage)
                    messages.append(.init(
                        role: .tool,
                        content: "提交无效：\(errors.joined(separator: "；"))。请修正后重新提交。",
                        toolCallID: call.id
                    ))
                    continue
                }
                return Self.makeReport(submission: submission, context: context)
            } catch {
                lastErrors = ["JSON 参数无法解码：\(error.localizedDescription)"]
                messages.append(result.assistantMessage)
                messages.append(.init(
                    role: .tool,
                    content: "提交参数无法解码，请严格按 schema 重新提交。",
                    toolCallID: call.id
                ))
            }
        }

        if lastErrors == ["模型未调用提交工具"] {
            throw NextHourGuidanceAgentError.missingToolCall
        }
        throw NextHourGuidanceAgentError.invalidSubmission(lastErrors)
    }

    private static func makeReport(
        submission: Submission,
        context: NextHourGuidanceContext
    ) -> NextHourGuidanceReport {
        NextHourGuidanceReport(
            generatedAt: context.generatedAt,
            validUntil: context.slot.validUntil,
            slotKey: context.slot.key,
            scope: context.slot.scope,
            headline: submission.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            posture: submission.posture,
            summary: submission.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: submission.actions.map {
                NextHourGuidanceAction(
                    targetName: $0.targetName,
                    action: $0.action,
                    instruction: $0.instruction,
                    rationale: $0.rationale,
                    trigger: $0.trigger,
                    invalidation: $0.invalidation,
                    confidence: $0.confidence
                )
            },
            riskChecks: submission.riskChecks,
            assetCount: context.assets.count
        )
    }

    private static func validate(_ submission: Submission) -> [String] {
        var errors: [String] = []
        if submission.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("headline 不能为空")
        }
        if submission.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("summary 不能为空")
        }
        if submission.actions.isEmpty || submission.actions.count > 5 {
            errors.append("actions 必须为 1 到 5 条")
        }
        for (index, action) in submission.actions.enumerated() {
            let values = [
                action.targetName,
                action.instruction,
                action.rationale,
                action.trigger,
                action.invalidation,
            ]
            if values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                errors.append("第 \(index + 1) 条动作字段不完整")
            }
            if !(0...100).contains(action.confidence) {
                errors.append("第 \(index + 1) 条动作置信度超出 0 到 100")
            }
        }
        return errors
    }

    private static func submitTool() -> AgentToolDefinition {
        AgentToolDefinition.function(
            name: "submit_next_hour_guidance",
            description: "提交下一小时操作指引。所有动作必须是条件式建议。",
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
                                "target_name": ["type": "string"],
                                "action": [
                                    "type": "string",
                                    "enum": ["hold", "watch", "wait", "avoid_chasing", "buy_small", "reduce_small"]
                                ],
                                "instruction": ["type": "string"],
                                "rationale": ["type": "string"],
                                "trigger": ["type": "string"],
                                "invalidation": ["type": "string"],
                                "confidence": ["type": "integer", "minimum": 0, "maximum": 100],
                            ],
                            "required": [
                                "target_name", "action", "instruction", "rationale",
                                "trigger", "invalidation", "confidence",
                            ],
                            "additionalProperties": false,
                        ],
                    ],
                    "risk_checks": [
                        "type": "array",
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
