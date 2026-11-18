import Foundation

/// 一次趋势 Agent 只更新一个产品模块；未更新的内容从上一份已校验报告中复用。
enum TrendResearchRunScope: String, Codable, CaseIterable, Hashable, Sendable {
    case full
    case closeReview
    case longTerm

    var displayName: String {
        switch self {
        case .full: "完整 AI 分析"
        case .closeReview: "今日收盘复盘"
        case .longTerm: "组合长期研判"
        }
    }

    var triggerDescription: String {
        switch self {
        case .full: "手动完整分析"
        case .closeReview: "每日 21:00 收盘复盘"
        case .longTerm: "每周日 20:00 长期研判"
        }
    }

    var requiredModuleToolNames: [String] {
        switch self {
        case .full:
            [
                TrendReportModuleToolName.overview,
                TrendReportModuleToolName.market,
                TrendReportModuleToolName.assetBatch,
                TrendReportModuleToolName.actions,
            ]
        case .closeReview:
            // 收盘复盘同时更新大盘强弱与逐只持仓归因，复用同一行情上下文。
            [
                TrendReportModuleToolName.market,
                TrendReportModuleToolName.assetBatch,
            ]
        case .longTerm:
            [
                TrendReportModuleToolName.overview,
                TrendReportModuleToolName.assetBatch,
                TrendReportModuleToolName.actions,
            ]
        }
    }

    var requiredModuleToolNameSet: Set<String> {
        Set(requiredModuleToolNames)
    }

    var requiresPortfolioOverview: Bool {
        true
    }

    var requiresPortfolioAssets: Bool {
        true
    }

    var requiresFundLookThrough: Bool {
        true
    }

    var requiresMarketSnapshot: Bool {
        true
    }

    var usesVendorResearch: Bool {
        self == .full || self == .longTerm
    }

    var allowedResearchToolNames: Set<String> {
        var names: Set<String> = ["get_market_snapshot"]
        if requiresPortfolioOverview { names.insert("get_portfolio_overview") }
        if requiresPortfolioAssets { names.insert("get_portfolio_assets") }
        if requiresFundLookThrough { names.insert("get_fund_lookthrough") }
        if usesVendorResearch {
            names.insert("alpha_vantage_research")
        }
        return names
    }
}

struct TrendResearchModuleProgress: Hashable, Sendable {
    let completedSections: Int
    let totalSections: Int
    let nextToolName: String?

    static let idle = TrendResearchModuleProgress(
        completedSections: 0,
        totalSections: 0,
        nextToolName: nil
    )

    var fraction: Double {
        guard totalSections > 0 else { return 0 }
        return min(1, max(0, Double(completedSections) / Double(totalSections)))
    }

    var detailText: String {
        guard totalSections > 0 else { return "准备研究数据" }
        if completedSections >= totalSections { return "模块合并与校验" }
        return "已完成 \(completedSections)/\(totalSections) 个报告分块"
    }
}

struct TrendScheduledModuleSlot: Hashable, Sendable {
    let scope: TrendResearchRunScope
    let key: String
}

/// 收盘复盘仅在当天 21:00 后运行；长期研判错过周日窗口后，在下次启动或轮询自动补做。已尝试窗口不自动重试。
enum TrendModuleAutoAnalysisSchedule {
    static let closeReviewTime = "21:00"
    static let longTermTime = "20:00"

    static func dueSlot(
        at timestamp: String,
        lastCompletedKeys: [String: String],
        lastGeneratedAtByScope: [String: String] = [:]
    ) -> TrendScheduledModuleSlot? {
        guard let day = TrendAutoAnalysisSchedule.dayString(from: timestamp),
              let minute = minuteOfDay(from: timestamp) else { return nil }

        // 当天收盘复盘优先；已完成或已尝试后才调度长期补做，避免并发任务。
        if minute >= 21 * 60,
           let closeReview = uncompletedSlot(
               scope: .closeReview,
               key: "\(day) \(closeReviewTime)",
               lastCompletedKeys: lastCompletedKeys,
               lastGeneratedAtByScope: lastGeneratedAtByScope
           ) {
            return closeReview
        }

        // 长期研判只补「完全未执行」的最近窗口。attempt key 已存在的失败窗口
        // 会被 uncompletedSlot 拒绝，因此不会在启动或轮询中反复扣费重试。
        return uncompletedSlot(
            scope: .longTerm,
            key: "\(latestLongTermWindowDay(for: day, minute: minute)) \(longTermTime)",
            lastCompletedKeys: lastCompletedKeys,
            lastGeneratedAtByScope: lastGeneratedAtByScope
        )
    }

    private static func uncompletedSlot(
        scope: TrendResearchRunScope,
        key: String,
        lastCompletedKeys: [String: String],
        lastGeneratedAtByScope: [String: String]
    ) -> TrendScheduledModuleSlot? {
        guard lastCompletedKeys[scope.rawValue] != key else { return nil }
        if let generatedAt = lastGeneratedAtByScope[scope.rawValue],
           String(generatedAt.prefix(16)) >= key {
            return nil
        }
        return TrendScheduledModuleSlot(scope: scope, key: key)
    }

    private static func minuteOfDay(from timestamp: String) -> Int? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: 11)
        let parts = trimmed[start...].prefix(5).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }

    /// 最近一个已经到期的长期研判窗口。周日 20:00 前不回用当天未来窗口，
    /// 而是补上一周；其他日期直接使用本周刚过去的周日窗口。
    private static func latestLongTermWindowDay(for day: String, minute: Int) -> String {
        let sunday = mostRecentSunday(day)
        guard sunday == day, minute < 20 * 60,
              let date = dateFormatter.date(from: day),
              let previousSunday = calendar.date(byAdding: .day, value: -7, to: date) else {
            return sunday
        }
        return dateFormatter.string(from: previousSunday)
    }

    private static func mostRecentSunday(_ day: String) -> String {
        guard let date = dateFormatter.date(from: day) else { return day }
        let daysSinceSunday = max(0, calendar.component(.weekday, from: date) - 1)
        guard let sunday = calendar.date(byAdding: .day, value: -daysSinceSunday, to: date) else {
            return day
        }
        return dateFormatter.string(from: sunday)
    }

    private static let calendar: Calendar = {
        var value = Calendar(identifier: .iso8601)
        value.timeZone = .current
        return value
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
