import Foundation

struct TrendAutoAnalysisSlot: Hashable {
    let day: String
    let timeString: String

    var key: String {
        "\(day) \(timeString)"
    }
}

struct TrendAutoAnalysisSchedule: Codable, Hashable {
    static let defaultTimeStrings = ["09:30", "14:30"]
    static let `default` = TrendAutoAnalysisSchedule(timeStrings: defaultTimeStrings)

    let timeStrings: [String]

    var text: String {
        timeStrings.joined(separator: ", ")
    }

    init(timeStrings: [String]) {
        let normalized = Self.normalizedTimeStrings(timeStrings)
        self.timeStrings = normalized.isEmpty ? Self.defaultTimeStrings : normalized
    }

    init(text: String) {
        let separators = CharacterSet(charactersIn: ",，、;； \n\t")
        let values = text
            .components(separatedBy: separators)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.init(timeStrings: values)
    }

    init(timeString: String) {
        self.init(timeStrings: [timeString])
    }

    func dueSlot(
        at timestamp: String,
        lastCompletedSlotKey: String?,
        legacyLastAutoAnalysisDay: String?
    ) -> TrendAutoAnalysisSlot? {
        guard let day = Self.dayString(from: timestamp),
              let currentMinute = Self.minuteOfDay(from: timestamp) else { return nil }
        if lastCompletedSlotKey == nil, legacyLastAutoAnalysisDay == day {
            return nil
        }

        let dueSlot = timeStrings
            .compactMap { timeString -> TrendAutoAnalysisSlot? in
                guard let minute = Self.minuteOfDay(fromTimeString: timeString), minute <= currentMinute else {
                    return nil
                }
                return TrendAutoAnalysisSlot(day: day, timeString: timeString)
            }
            .last

        guard let dueSlot else { return nil }
        if let lastCompletedSlotKey, dueSlot.key <= lastCompletedSlotKey {
            return nil
        }
        return dueSlot
    }

    static func dayString(from timestamp: String) -> String? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        return String(trimmed.prefix(10))
    }

    private static func normalizedTimeStrings(_ values: [String]) -> [String] {
        let normalized = values.compactMap(normalizedTimeString)
        return Array(Set(normalized)).sorted()
    }

    private static func normalizedTimeString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              isValid(hour: hour, minute: minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func minuteOfDay(from timestamp: String) -> Int? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        let timeStart = trimmed.index(trimmed.startIndex, offsetBy: 11)
        let timePrefix = trimmed[timeStart...].prefix(5)
        return minuteOfDay(fromTimeString: String(timePrefix))
    }

    private static func minuteOfDay(fromTimeString timeString: String) -> Int? {
        guard let normalized = normalizedTimeString(timeString) else { return nil }
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    private static func isValid(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }
}
