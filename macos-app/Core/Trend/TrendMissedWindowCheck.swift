import Foundation

/// W3.5:错过的自动研判窗口(纯派生,供 TodayBrief 条目与 AI 页横幅共用)。
///
/// 「错过」= 上一个自动窗口时刻已过,而该模块在那之后没有成功生成:
/// - `failedAttempt`:窗口内已尝试(attempt key 在窗口时刻之后)但未成功——不会自动重试;
/// - `neverRan`:窗口过去了连尝试都没有(App 不在线),下一班才会再试。
struct TrendMissedWindow: Equatable, Hashable {
    enum Reason: Equatable, Hashable {
        case failedAttempt
        case neverRan
    }

    let scope: TrendResearchRunScope
    let reason: Reason
    /// 上一个错过的窗口时刻("yyyy-MM-dd HH:mm")。
    let windowKey: String
}

enum TrendMissedWindowCheck {
    /// 各模块的自动时刻,与 `TrendModuleAutoAnalysisSchedule` 保持同源。
    private static let slotTimes: [TrendResearchRunScope: String] = [
        .marketRadar: "09:00",
        .closeReview: "21:00",
        .longTerm: "20:00"
    ]

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 判定所有模块错过的最近一个自动窗口。
    /// - Parameters:
    ///   - lastModuleAutoAnalysisKeys: scope → 最后尝试的窗口 key(attempt key)。
    ///   - lastModuleGeneratedAt: scope → 最后成功生成时间戳。
    ///   - now: 当前时间戳("yyyy-MM-dd HH:mm:ss" 或带日期的任意前 16 位可比格式)。
    static func missedScopes(
        lastModuleAutoAnalysisKeys: [String: String],
        lastModuleGeneratedAt: [String: String],
        now: String
    ) -> [TrendMissedWindow] {
        let nowKey = String(now.prefix(16))
        guard let nowDate = date(from: nowKey) else { return [] }
        var result: [TrendMissedWindow] = []
        for (scope, slotTime) in slotTimes.sorted(by: { $0.value < $1.value }) {
            guard let windowKey = previousWindowKey(for: scope, slotTime: slotTime, before: nowDate),
                  let windowDate = date(from: windowKey),
                  windowDate < nowDate
            else { continue }
            // 窗口之后已成功生成 → 没有错过。
            if let generated = lastModuleGeneratedAt[scope.rawValue],
               String(generated.prefix(16)) >= windowKey {
                continue
            }
            // 窗口内是否尝试过(attempt key ≥ 窗口时刻即视为本窗口已尝试)。
            let attempted = lastModuleAutoAnalysisKeys[scope.rawValue]
                .map { $0 >= windowKey } ?? false
            result.append(
                TrendMissedWindow(
                    scope: scope,
                    reason: attempted ? .failedAttempt : .neverRan,
                    windowKey: windowKey
                )
            )
        }
        return result
    }

    /// W3.5 横幅时机:只有「错过了且下一班自动运行不会马上补上」时才提示,
    /// 避免怂恿用户手动做马上会自动发生的事。
    /// 自动分析未开启时没有「下一班」,错过只能靠手动补 → 恒可提示。
    static func shouldPromptManualCatchUp(
        _ missed: TrendMissedWindow,
        autoAnalysisEnabled: Bool,
        now: String
    ) -> Bool {
        guard autoAnalysisEnabled else { return true }
        guard let nowDate = date(from: String(now.prefix(16))) else { return false }
        guard let nextDate = nextWindowDate(for: missed.scope, after: nowDate) else { return true }
        // 距下一班 ≤ 2 小时:自动运行马上会补,不提示。
        return nextDate.timeIntervalSince(nowDate) > 2 * 3600
    }

    /// 上一个严格早于 `now` 的自动窗口 key;长期研判只在周日。
    private static func previousWindowKey(
        for scope: TrendResearchRunScope,
        slotTime: String,
        before now: Date
    ) -> String? {
        let calendar = Calendar(identifier: .gregorian)
        guard let todayKey = dayKey(for: now, calendar: calendar) else { return nil }
        // 今天窗口已过且现在晚于窗口 → 上一个就是今天;否则往前一天找。
        if let todayWindow = date(from: "\(todayKey) \(slotTime)"), todayWindow < now {
            if scope == .longTerm, !isSunday(todayWindow, calendar: calendar) {
                return previousSundayWindow(before: now, calendar: calendar)
            }
            return "\(todayKey) \(slotTime)"
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        guard let yesterdayKey = dayKey(for: yesterday, calendar: calendar) else { return nil }
        if scope == .longTerm {
            if let yesterdayWindow = date(from: "\(yesterdayKey) \(slotTime)"),
               isSunday(yesterdayWindow, calendar: calendar),
               yesterdayWindow < now {
                return "\(yesterdayKey) \(slotTime)"
            }
            return previousSundayWindow(before: yesterday, calendar: calendar)
        }
        return "\(yesterdayKey) \(slotTime)"
    }

    private static func previousSundayWindow(before date: Date, calendar: Calendar) -> String? {
        var cursor = date
        for _ in 0..<8 {
            guard let key = dayKey(for: cursor, calendar: calendar) else { return nil }
            if let window = self.date(from: "\(key) 20:00"),
               isSunday(window, calendar: calendar),
               window < date {
                return "\(key) 20:00"
            }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return nil
    }

    /// 下一个未来的自动窗口(横幅时机判定用)。
    private static func nextWindowDate(
        for scope: TrendResearchRunScope,
        after now: Date
    ) -> Date? {
        let slotTime = slotTimes[scope] ?? "09:00"
        let calendar = Calendar(identifier: .gregorian)
        var cursor = now
        for _ in 0..<8 {
            guard let key = dayKey(for: cursor, calendar: calendar) else { return nil }
            if let window = date(from: "\(key) \(slotTime)"), window > now {
                if scope == .longTerm, !isSunday(window, calendar: calendar) {
                    cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                    continue
                }
                return window
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return nil
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = components.year, let m = components.month, let d = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func isSunday(_ date: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    private static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }
}
