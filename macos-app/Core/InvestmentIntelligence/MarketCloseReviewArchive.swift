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

struct MarketCloseReviewArchiveStore {
    func load(from fileURL: URL) throws -> MarketCloseReviewArchive? {
        try JSONFilePersistence.load(MarketCloseReviewArchive.self, from: fileURL)
    }

    func save(_ archive: MarketCloseReviewArchive, to fileURL: URL) throws {
        try JSONFilePersistence.save(archive, to: fileURL)
    }
}
