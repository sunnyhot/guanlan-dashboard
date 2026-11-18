import Foundation

/// 自动模块调度共用的日期工具。
enum TrendAutoAnalysisSchedule {
    static func dayString(from timestamp: String) -> String? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        return String(trimmed.prefix(10))
    }
}
