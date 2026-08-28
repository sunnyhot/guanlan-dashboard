import Foundation

/// A股市场阶段（7 态）。按北京时间交易日历判定，供 prompt 注入行为禁令与护栏降级。
///
/// 口径对拍 daily_stock_analysis `market_phase_prompt.py`：盘前不得描述今日走势已发生、
/// 盘中不得用盘后复盘口吻、输出含 next_check_time 等。
/// 节假日为内置近似表（法定调休以交易所公告为准），误差场景由下游数据新鲜度兜底。
enum MarketPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case premarket       // 交易日 <09:30（含 9:15-9:25 集合竞价）
    case intraday        // 09:30-11:30 / 13:00-14:57
    case lunchBreak      // 11:30-13:00
    case closingAuction  // 14:57-15:00
    case postmarket      // 交易日 ≥15:00
    case nonTrading      // 周末/节假日
    case unknown

    var displayName: String {
        switch self {
        case .premarket: return "盘前"
        case .intraday: return "盘中"
        case .lunchBreak: return "午间休市"
        case .closingAuction: return "尾盘集合竞价"
        case .postmarket: return "盘后"
        case .nonTrading: return "非交易日"
        case .unknown: return "未知"
        }
    }

    /// 是否允许立即交易类行动（盘前/非交易日/未知阶段禁止「立即买入/卖出」表述）。
    var allowsImmediateTradeActions: Bool {
        switch self {
        case .intraday, .closingAuction, .postmarket:
            return true
        case .premarket, .nonTrading, .unknown, .lunchBreak:
            return false
        }
    }

    /// 注入 prompt 的行为禁令（每态一组）。
    var behaviorConstraints: [String] {
        switch self {
        case .premarket:
            return [
                "当前尚未开盘，不得描述「今日走势已经发生」",
                "只能基于上一完整交易日和盘前信息生成开盘计划、观察价位与风险预案",
                "不得给出「立即买入/立即卖出」类行动，用「开盘后观察」替代",
            ]
        case .intraday:
            return [
                "聚焦当前盘中状态、观察条件与下一次检查点",
                "不得使用盘后复盘口吻（如「全天」「收盘总结」）",
                "结论必须给出下一次检查时间或触发条件",
            ]
        case .lunchBreak:
            return [
                "当前为午间休市，上午数据是最后一个完整时段",
                "下午走势未知，不得把上午节奏外推为全天结论",
            ]
        case .closingAuction:
            return [
                "当前为尾盘集合竞价（14:57-15:00），成交清淡、价格波动可能放大",
                "涉及「立即执行」的建议改为「收盘竞价观察」或顺延至次日",
            ]
        case .postmarket:
            return [
                "当前已收盘，生成盘后复盘与次日计划",
                "不得给出当日盘中操作建议，行动一律落到明日条件",
            ]
        case .nonTrading:
            return [
                "当前为非交易日，只有上一交易日与更早的数据",
                "禁止使用「今天」「当前价」指代上一交易日行情，必须显式标注日期",
                "行动建议以「下一交易日开盘条件」表述",
            ]
        case .unknown:
            return ["市场阶段未知，任何时效性表述（今日/当前）都必须降级为显式日期表述"]
        }
    }

    // MARK: - 判定

    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func current(_ date: Date = Date()) -> MarketPhase {
        phase(at: date)
    }

    static func phase(at date: Date) -> MarketPhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)

        guard let year = components.year, let month = components.month, let day = components.day else {
            return .unknown
        }
        // 周末（调休补班的周末按非交易处理——交易所周六日不开市，调休是工作日概念）
        if components.weekday == 7 || components.weekday == 1 {
            return .nonTrading
        }
        if isHoliday(year: year, month: month, day: day) {
            return .nonTrading
        }

        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        switch minutes {
        case ..<(9 * 60 + 30):
            return .premarket
        case ..<(11 * 60 + 30):
            return .intraday
        case ..<(13 * 60):
            return .lunchBreak
        case ..<(14 * 60 + 57):
            return .intraday
        case ..<(15 * 60):
            return .closingAuction
        default:
            return .postmarket
        }
    }

    /// 内置近似节假日表（元旦/春节/清明/五一/端午/中秋国庆，2025-2027）。
    /// 法定调休以交易所公告为准；漏判的节假日由数据新鲜度策略兜底（无行情→stale）。
    static let holidayDates: Set<String> = {
        var dates: Set<String> = []
        for year in 2025...2027 {
            dates.insert("\(year)-01-01")
            // 春节（approx：除夕-初七）
            dates.formUnion([
                "\(year)-02-\(year == 2025 ? "28" : year == 2026 ? "16" : "05")",
            ])
            dates.formUnion(festivalRange(year: year, month: 2, startDay: year == 2025 ? 28 : year == 2026 ? 16 : 5, days: 8))
            // 清明（4/4-4/6）
            dates.formUnion(festivalRange(year: year, month: 4, startDay: 4, days: 3))
            // 五一（5/1-5/5）
            dates.formUnion(festivalRange(year: year, month: 5, startDay: 1, days: 5))
            // 端午（6 月中下旬，approx 3 天）
            dates.formUnion(festivalRange(year: year, month: 6, startDay: year == 2026 ? 19 : 25, days: 3))
            // 中秋（approx 3 天）
            dates.formUnion(festivalRange(year: year, month: 9, startDay: year == 2026 ? 25 : 12, days: 3))
            // 国庆（10/1-10/7）
            dates.formUnion(festivalRange(year: year, month: 10, startDay: 1, days: 7))
        }
        return dates
    }()

    private static func festivalRange(year: Int, month: Int, startDay: Int, days: Int) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = startDay
        guard let start = calendar.date(from: components) else { return [] }
        return Set((0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        })
    }

    static func isHoliday(year: Int, month: Int, day: Int) -> Bool {
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return holidayDates.contains(key)
    }

    /// 是否 A股交易日（周一至周五且非节假日）。
    static func isTradingDay(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        if components.weekday == 7 || components.weekday == 1 { return false }
        return !isHoliday(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }

    /// 下一个交易日（自然日推进，跳过周末与节假日）。
    static func nextTradingDay(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var candidate = calendar.startOfDay(for: date).addingTimeInterval(86_400)
        var guardCounter = 0
        while !isTradingDay(candidate), guardCounter < 30 {
            candidate = candidate.addingTimeInterval(86_400)
            guardCounter += 1
        }
        return candidate
    }
}
