import Foundation

/// 收盘复盘的独立冻结快照。
///
/// 趋势总报告会被次日市场雷达增量覆盖，个人组合也会在启动时刷新；因此收盘复盘
/// 必须单独落盘，才能保证次日 21:00 前仍展示上一交易日的收盘数据，而不是盘中数据。
struct MarketCloseReviewArchive: Codable, Hashable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let generatedAt: String
    let snapshot: MarketCloseReviewSnapshot

    init(
        generatedAt: String,
        snapshot: MarketCloseReviewSnapshot,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.snapshot = snapshot
    }

    func displaySnapshot(
        at currentTimestamp: String,
        isUpdating: Bool
    ) -> MarketCloseReviewSnapshot {
        var value = snapshot
        let generatedText = String(generatedAt.prefix(16))

        if isUpdating {
            value.state = .scanning
            value.subtitle = "正在更新 · 暂时展示 \(generatedText) 的结果"
            value.eyebrow = "复盘中·展示旧结果"
            return value
        }

        guard Self.day(from: generatedAt) != Self.day(from: currentTimestamp) else {
            return value
        }
        value.state = .stale
        value.subtitle = value.marketPulse.isEmpty
            && value.strongThemes.isEmpty
            && value.weakThemes.isEmpty
            ? "最近一次组合收盘复盘 · \(generatedText)"
            : "最近一次市场与组合复盘 · \(generatedText)"
        value.eyebrow = "最近复盘"
        return value
    }

    static func displayTitle(
        generatedAt: String?,
        currentTimestamp: String
    ) -> String {
        guard let generatedAt,
              let generatedDate = date(from: generatedAt),
              let currentDate = date(from: currentTimestamp) else {
            return "今日收盘复盘"
        }
        if calendar.isDate(generatedDate, inSameDayAs: currentDate) {
            return "今日收盘复盘"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: currentDate),
           calendar.isDate(generatedDate, inSameDayAs: yesterday) {
            return "昨日收盘复盘"
        }
        return "最近收盘复盘"
    }

    private static func day(from timestamp: String) -> String? {
        let value = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 10 else { return nil }
        return String(value.prefix(10))
    }

    private static func date(from timestamp: String) -> Date? {
        guard let day = day(from: timestamp) else { return nil }
        return dateFormatter.date(from: day)
    }

    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return value
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 收盘复盘板块的新鲜度状态：把调度契约（每晚 `21:00`、同日至多自动尝试一次、
/// 错过不跨日补跑）翻译成用户可读的「状态 + 原因 + 动作」文案。
struct MarketCloseReviewFreshness: Hashable, Sendable {
    enum Phase: Hashable, Sendable {
        /// 今日复盘已生成（自动或手动）。
        case generatedToday(timeText: String)
        /// 21:00 前：正常展示上一份复盘，等今晚自动更新。
        case waitingForTonight
        /// 21:00 后今日仍未生成；`autoAttempted` 表示今晚自动窗口是否已尝试过（至多一次）。
        case tonightUnfinished(autoAttempted: Bool)
    }

    let phase: Phase
    /// 正在展示的历史复盘时间（`yyyy-MM-dd HH:mm`），nil 表示从未生成过。
    let lastGeneratedAtText: String?
    let autoAnalysisEnabled: Bool
    /// 自动窗口时间文案（与调度器共用同一常量）。
    let autoTimeText: String

    static func evaluate(
        generatedAt: String?,
        currentTimestamp: String,
        autoAttemptedKey: String?,
        autoAnalysisEnabled: Bool,
        autoTimeText: String = TrendModuleAutoAnalysisSchedule.closeReviewTime
    ) -> MarketCloseReviewFreshness {
        let currentDay = dayText(from: currentTimestamp)
        let generatedDay = generatedAt.flatMap(dayText(from:))
        let lastText = generatedAt.map { String($0.prefix(16)) }

        if let generatedDay, generatedDay == currentDay {
            return MarketCloseReviewFreshness(
                phase: .generatedToday(timeText: timeText(from: generatedAt ?? "")),
                lastGeneratedAtText: lastText,
                autoAnalysisEnabled: autoAnalysisEnabled,
                autoTimeText: autoTimeText
            )
        }

        let autoAttempted = currentDay.map { day in
            autoAttemptedKey == "\(day) \(autoTimeText)"
        } ?? false
        let minuteOfDay = minuteOfDay(fromTimestamp: currentTimestamp) ?? 0
        let autoMinute = minutes(ofTimeText: autoTimeText) ?? 21 * 60
        let phase: Phase = minuteOfDay >= autoMinute
            ? .tonightUnfinished(autoAttempted: autoAttempted)
            : .waitingForTonight
        return MarketCloseReviewFreshness(
            phase: phase,
            lastGeneratedAtText: lastText,
            autoAnalysisEnabled: autoAnalysisEnabled,
            autoTimeText: autoTimeText
        )
    }

    var badgeText: String {
        switch phase {
        case .generatedToday:
            return "今日已复盘"
        case .waitingForTonight:
            return autoAnalysisEnabled ? "今晚\(autoTimeText)更新" : "未开启自动"
        case .tonightUnfinished(autoAttempted: true):
            return "待手动补做"
        case .tonightUnfinished(autoAttempted: false):
            return autoAnalysisEnabled ? "等待自动复盘" : "未开启自动"
        }
    }

    var subtitleText: String {
        switch phase {
        case .generatedToday(let timeText):
            return "今日 \(timeText) 生成 · 每晚 \(autoTimeText) 自动更新"
        case .waitingForTonight:
            guard let lastGeneratedAtText else {
                return autoAnalysisEnabled
                    ? "尚未生成过 · 今晚 \(autoTimeText) 自动生成"
                    : "尚未生成过 · 可手动生成"
            }
            return autoAnalysisEnabled
                ? "展示 \(lastGeneratedAtText) 的复盘 · 今晚 \(autoTimeText) 自动更新"
                : "展示 \(lastGeneratedAtText) 的复盘 · 自动更新未开启"
        case .tonightUnfinished(let autoAttempted):
            guard let lastGeneratedAtText else {
                return autoAnalysisEnabled
                    ? "今晚复盘尚未完成 · 可手动生成"
                    : "自动复盘未开启 · 可手动生成"
            }
            if autoAttempted {
                return "今晚自动复盘未成功 · 正在展示 \(lastGeneratedAtText) 的结果，可手动补做"
            }
            return autoAnalysisEnabled
                ? "今晚 \(autoTimeText) 已过 · 自动复盘即将开始，正在展示 \(lastGeneratedAtText) 的结果"
                : "今晚 \(autoTimeText) 已过 · 自动复盘未开启，正在展示 \(lastGeneratedAtText) 的结果"
        }
    }

    var actionTitle: String {
        switch phase {
        case .generatedToday:
            return "重新生成"
        case .waitingForTonight:
            return "现在生成"
        case .tonightUnfinished:
            return "补做今日复盘"
        }
    }

    private static func dayText(from timestamp: String) -> String? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        return String(trimmed.prefix(10))
    }

    private static func timeText(from timestamp: String) -> String {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return timestamp }
        return String(trimmed.dropFirst(11).prefix(5))
    }

    private static func minuteOfDay(fromTimestamp timestamp: String) -> Int? {
        minutes(ofTimeText: timeText(from: timestamp))
    }

    private static func minutes(ofTimeText text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }
}

struct MarketCloseReviewArchiveStore {
    func load(from fileURL: URL) throws -> MarketCloseReviewArchive? {
        try JSONFilePersistence.load(MarketCloseReviewArchive.self, from: fileURL)
    }

    func save(_ archive: MarketCloseReviewArchive, to fileURL: URL) throws {
        try JSONFilePersistence.save(archive, to: fileURL)
    }
}
