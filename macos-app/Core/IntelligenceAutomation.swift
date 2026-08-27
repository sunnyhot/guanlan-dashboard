import Foundation

// MARK: - 投资智能自动调度（审计 B1/C5，V1 分模块调度的 V2 重建）
//
// 模块时刻表（上海时区，交易日）：
// - 市场发现 09:00（V1「市场雷达」）
// - 盘中评估 6 档：09:15 / 10:15 / 11:15 / 13:15 / 14:15 / 14:50（V1 槽位）
// - 收盘复盘 21:00（审计 A1 的冻结时刻）
// - 组合研究 周日 20:00（需 Provider 配置）
//
// 纪律（V1 对齐）：同一窗口至多自动尝试一次——**先落盘标记再启动**，
// 失败不跨窗口补跑、可手动；总开关默认关闭。

/// 自动调度设置（JSON 持久化于 App 数据目录）。
struct IntelligenceScheduleSettings: Codable, Equatable {
    /// 总开关（默认关——用户显式开启自动化）。
    var isAutoRunEnabled: Bool = false
    // 分模块开关（总开关开时才生效）
    var marketDiscoveryEnabled: Bool = true
    var intradayEnabled: Bool = true
    var closeReviewEnabled: Bool = true
    var portfolioResearchEnabled: Bool = true
    /// 模块 → 已尝试的槽位 key（"模块|日期|槽位"）——同窗口只尝试一次。
    var lastAttemptedKeys: [String: String] = [:]

    static let fileName = "intelligence-schedule.json"

    // MARK: - 持久化（原子写 JSON，损坏回默认）

    static func load(dataDirectory: URL) -> IntelligenceScheduleSettings {
        let url = dataDirectory.appendingPathComponent(IntelligenceScheduleSettings.fileName)
        guard let data = try? Data(contentsOf: url) else { return IntelligenceScheduleSettings() }
        let decoder = JSONDecoder()
        return (try? decoder.decode(IntelligenceScheduleSettings.self, from: data))
            ?? IntelligenceScheduleSettings()
    }

    func save(dataDirectory: URL) {
        let url = dataDirectory.appendingPathComponent(IntelligenceScheduleSettings.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? FileManager.default.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
}

// MARK: - 到期判定（纯函数）

/// 调度评估器：时刻表 + 幂等 key 推导。全部上海时区。
enum IntelligenceScheduleEvaluator {

    /// 各模块的到期货位（此刻应触发且本窗口未尝试过）。
    struct DueSlots: Equatable, Sendable {
        var marketDiscovery = false
        var intraday = false
        var closeReview = false
        var portfolioResearch = false
        var isEmpty: Bool {
            !marketDiscovery && !intraday && !closeReview && !portfolioResearch
        }
    }

    /// 本轮标记后应写入的 key（与 DueSlots 一一对应）。
    struct AttemptKeys: Equatable, Sendable {
        var marketDiscovery: String?
        var intraday: String?
        var closeReview: String?
        var portfolioResearch: String?
    }

    /// 盘中槽位（分钟数，V1 语义：每槽至多一次，14:50 是最后一档）。
    static let intradaySlotMinutes: [Int] = [
        9 * 60 + 15, 10 * 60 + 15, 11 * 60 + 15,
        13 * 60 + 15, 14 * 60 + 15, 14 * 60 + 50,
    ]
    static let marketDiscoveryMinute = 9 * 60
    static let closeReviewMinute = 21 * 60
    static let portfolioResearchMinute = 20 * 60

    /// 评估此刻到期的模块（已尝试过的 key 自动跳过）。
    ///
    /// - Parameters:
    ///   - settings: 调度设置（含 lastAttemptedKeys 幂等账本）
    ///   - now: 当前时刻
    ///   - isTradingDay: 今天是否交易日（调用方经交易日历判定）
    ///   - isSunday: 今天是否周日（组合研究窗口）
    static func evaluate(
        settings: IntelligenceScheduleSettings,
        now: Date,
        isTradingDay: Bool,
        isSunday: Bool
    ) -> (slots: DueSlots, keys: AttemptKeys) {
        guard settings.isAutoRunEnabled else {
            return (DueSlots(), AttemptKeys())
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dayKey = Self.dayKey(now, calendar: calendar)
        let minuteOfDay = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)

        var slots = DueSlots()
        var keys = AttemptKeys()

        // 交易日模块（发现 / 盘中 / 复盘）；组合研究走周日窗口（周日不是
        // 交易日——守卫独立，不被 isTradingDay 挡住）
        if isTradingDay {
            // 市场发现：09:00 起（错过即当日不再补，下一窗口是手动/次日）
            if settings.marketDiscoveryEnabled,
               minuteOfDay >= marketDiscoveryMinute {
                let key = attemptKey(module: "marketDiscovery", dayKey: dayKey, slot: "09:00")
                if settings.lastAttemptedKeys["marketDiscovery"] != key {
                    slots.marketDiscovery = true
                    keys.marketDiscovery = key
                }
            }

            // 盘中：最近一个已开始的槽位（每槽一次）
            if settings.intradayEnabled,
               let slotMinute = intradaySlotMinutes.last(where: { minuteOfDay >= $0 }) {
                let key = attemptKey(module: "intraday", dayKey: dayKey, slot: slotKey(slotMinute))
                if settings.lastAttemptedKeys["intraday"] != key {
                    slots.intraday = true
                    keys.intraday = key
                }
            }

            // 收盘复盘：21:00 起
            if settings.closeReviewEnabled,
               minuteOfDay >= closeReviewMinute {
                let key = attemptKey(module: "closeReview", dayKey: dayKey, slot: "21:00")
                if settings.lastAttemptedKeys["closeReview"] != key {
                    slots.closeReview = true
                    keys.closeReview = key
                }
            }
        }

        // 组合研究：周日 20:00 起
        if settings.portfolioResearchEnabled,
           isSunday,
           minuteOfDay >= portfolioResearchMinute {
            let key = attemptKey(module: "portfolioResearch", dayKey: dayKey, slot: "sunday")
            if settings.lastAttemptedKeys["portfolioResearch"] != key {
                slots.portfolioResearch = true
                keys.portfolioResearch = key
            }
        }

        return (slots, keys)
    }

    private static func attemptKey(module: String, dayKey: String, slot: String) -> String {
        "\(module)|\(dayKey)|\(slot)"
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func slotKey(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// 人话时刻表（设置面板展示）。
    static var scheduleSummaryText: String {
        "市场发现 每日 09:00 · 盘中评估 09:15/10:15/11:15/13:15/14:15/14:50 · 收盘复盘 21:00 · 组合研究 周日 20:00（交易日）"
    }
}
