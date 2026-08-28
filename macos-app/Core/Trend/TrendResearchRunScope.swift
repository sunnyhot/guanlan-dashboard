import Foundation

/// 一次趋势 Agent 只更新一个产品模块；未更新的内容从上一份已校验报告中复用。
enum TrendResearchRunScope: String, Codable, CaseIterable, Hashable, Sendable {
    case full
    case marketRadar
    case closeReview
    case longTerm

    var displayName: String {
        switch self {
        case .full: "完整 AI 分析"
        case .marketRadar: "全市场机会雷达"
        case .closeReview: "今日收盘复盘"
        case .longTerm: "组合长期研判"
        }
    }

    var triggerDescription: String {
        switch self {
        case .full: "手动完整分析"
        case .marketRadar: "每日 09:00 市场雷达"
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
        case .marketRadar:
            [TrendReportModuleToolName.market]
        case .closeReview:
            [TrendReportModuleToolName.assetBatch]
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
        self != .marketRadar
    }

    var requiresPortfolioAssets: Bool {
        self != .marketRadar
    }

    var requiresFundLookThrough: Bool {
        self != .marketRadar
    }

    var requiresMarketSnapshot: Bool {
        true
    }

    var usesOfficialAndVendorResearch: Bool {
        self == .full || self == .longTerm
    }

    var allowedResearchToolNames: Set<String> {
        var names: Set<String> = ["get_market_snapshot"]
        if requiresPortfolioOverview { names.insert("get_portfolio_overview") }
        if requiresPortfolioAssets { names.insert("get_portfolio_assets") }
        if requiresFundLookThrough { names.insert("get_fund_lookthrough") }
        if usesOfficialAndVendorResearch {
            names.insert("official_sec_research")
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

/// 固定错峰运行：市场雷达早晨、收盘复盘晚上、长期研判每周一次。
enum TrendModuleAutoAnalysisSchedule {
    static let marketRadarTime = "09:00"
    static let closeReviewTime = "21:00"
    static let longTermTime = "20:00"

    static func dueSlot(
        at timestamp: String,
        lastCompletedKeys: [String: String],
        lastGeneratedAtByScope: [String: String] = [:]
    ) -> TrendScheduledModuleSlot? {
        guard let day = TrendAutoAnalysisSchedule.dayString(from: timestamp),
              let minute = minuteOfDay(from: timestamp) else { return nil }

        if minute >= 21 * 60 {
            return uncompletedSlot(
                scope: .closeReview,
                key: "\(day) \(closeReviewTime)",
                lastCompletedKeys: lastCompletedKeys,
                lastGeneratedAtByScope: lastGeneratedAtByScope
            )
        }

        if minute >= 20 * 60 {
            return uncompletedSlot(
                scope: .longTerm,
                key: "\(mostRecentSunday(day)) \(longTermTime)",
                lastCompletedKeys: lastCompletedKeys,
                lastGeneratedAtByScope: lastGeneratedAtByScope
            )
        }

        if minute >= 9 * 60 {
            return uncompletedSlot(
                scope: .marketRadar,
                key: "\(day) \(marketRadarTime)",
                lastCompletedKeys: lastCompletedKeys,
                lastGeneratedAtByScope: lastGeneratedAtByScope
            )
        }

        return nil
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
