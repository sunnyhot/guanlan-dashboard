import Foundation

// MARK: - TradingCalendars（SYNC-1：A 股交易日历 + 基金净值公布日历）
//
// 真实交易日历 = 当地日历周一~周五，减去交易所节假日休市表。
// 两个结构性事实由算法保证、不进数据表：
// 1. A 股/美股/港股周末从不开市——包括国务院「调休上班」的周末
//    （交易所不跟随调休开市，如 2025-01-26 周日上班但 A 股休市）；
// 2. 表只登记「落在周内的休市日」，周末条目在 init 即拒收（fail-closed：
//    数据源若给出周末休市日说明抓取/转录有错，不静默吞掉）。
//
// 数据可审计：每张表带 jurisdiction/year/version/provenance（官方公告标题）。
// 新一年安排由交易所年末公告后**追加**新表（对照 ADR-DATA008 的只追加精神，
// 已发布表不改写）。种子数据 2024–2026（SSE / NYSE）在 SeedHolidayTables。
//
// 覆盖缺口显式化：表未覆盖的年份退化为「仅周末」判断（isTradingDay 仍可用，
// sync 循环不崩），verifiedCoverageYears / hasVerifiedHolidayCoverage 把
// 「这段判断没有权威休市表背书」暴露给调用方（诊断 / 断言 / 测试用）。
// Artifact ValidityPolicy 的 exchangeScheduleDerived（Epic 9+）经
// Exchange.jurisdiction → 本日历取交易日边界。

// MARK: - 休市表

/// 休市表构造错误（fail-closed：非法数据抛错，不静默丢条目/换壳）。
enum MarketHolidayTableError: Error, Equatable, Sendable {
    /// 非法休市日期：格式不是 yyyy-MM-dd、年份与表不符、日历上不存在，
    /// 或落在周末（周末休市是结构性的，进表即数据源有错）
    case invalidClosedDate(String, jurisdiction: Jurisdiction, year: Int)
    /// 同 (jurisdiction, year) 出现两张表（配置错误，不静默择一）
    case duplicateTable(Jurisdiction, year: Int)
}

/// 单法域单年的交易所节假日休市表（周内休市日）。
struct MarketHolidayTable: Sendable, Codable, Hashable {

    /// 表版本（同法域同年表的修订递增；新一年休市安排 = 追加新表）
    let version: Int
    let jurisdiction: Jurisdiction
    /// 覆盖年份（如 2025）
    let year: Int
    /// 周内休市日，"yyyy-MM-dd"（当地日历日期），周末日期在 init 拒收
    let closedDates: Set<String>
    /// 数据来源（交易所官方公告标题，可审计）
    let provenance: String

    init(
        version: Int,
        jurisdiction: Jurisdiction,
        year: Int,
        closedDates: Set<String>,
        provenance: String
    ) throws {
        let validDates = try Set(
            closedDates.map { raw -> String in
                guard Self.isValid(raw, year: year) else {
                    throw MarketHolidayTableError.invalidClosedDate(
                        raw, jurisdiction: jurisdiction, year: year
                    )
                }
                return raw
            }
        )
        self.version = version
        self.jurisdiction = jurisdiction
        self.year = year
        self.closedDates = validDates
        self.provenance = provenance
    }

    /// 校验一个休市日期串：格式严格（round-trip 逐字节相等）、年份匹配、
    /// 日历上真实存在、落在周一~周五。
    private static func isValid(_ raw: String, year: Int) -> Bool {
        let formatter = strictDayFormatter
        guard let date = formatter.date(from: raw),
              formatter.string(from: date) == raw
        else { return false }
        let utc = Calendar(identifier: .gregorian)
        let parts = utc.dateComponents([.year], from: date)
        guard parts.year == year else { return false }
        let weekday = utc.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }

    private static let strictDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}

// MARK: - 种子休市表（2024–2026，官方公告核实）

/// 内置种子休市表。来源（核对于 2026-08-24）：
/// - CN：《关于上海证券交易所 2024/2025/2026 年部分节假日休市安排的通知》
///   （sse.com.cn，2023-12-26 / 2024-12-23 / 2025-12-22 发布）；
/// - US：NYSE/NASDAQ 法定节假日惯例（2026-07-04 为周六，7-3 周五补休）。
///
/// 种子表用 try!：数据正确性由 TradingCalendarTests 的全集冻结测试守护，
/// 坏种子 = 测试即红，force unwrap 的崩溃语义只作用于「明知不可能」路径。
enum SeedHolidayTables {

    static let sse2024 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .chinaMainland,
        year: 2024,
        closedDates: [
            "2024-01-01",                                       // 元旦
            "2024-02-09", "2024-02-12", "2024-02-13",
            "2024-02-14", "2024-02-15", "2024-02-16",           // 春节（含除夕 02-09）
            "2024-04-04", "2024-04-05",                         // 清明
            "2024-05-01", "2024-05-02", "2024-05-03",           // 劳动节
            "2024-06-10",                                       // 端午
            "2024-09-16", "2024-09-17",                         // 中秋
            "2024-10-01", "2024-10-02", "2024-10-03",
            "2024-10-04", "2024-10-07",                         // 国庆
        ],
        provenance: "上交所《关于上海证券交易所2024年部分节假日休市安排的通知》2023-12-26"
    )

    static let sse2025 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .chinaMainland,
        year: 2025,
        closedDates: [
            "2025-01-01",                                       // 元旦
            "2025-01-28", "2025-01-29", "2025-01-30",
            "2025-01-31", "2025-02-03", "2025-02-04",           // 春节
            "2025-04-04",                                       // 清明
            "2025-05-01", "2025-05-02", "2025-05-05",           // 劳动节
            "2025-06-02",                                       // 端午
            "2025-10-01", "2025-10-02", "2025-10-03",
            "2025-10-06", "2025-10-07", "2025-10-08",           // 国庆中秋连休
        ],
        provenance: "上交所《关于上海证券交易所2025年部分节假日休市安排的通知》2024-12-23"
    )

    static let sse2026 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .chinaMainland,
        year: 2026,
        closedDates: [
            "2026-01-01", "2026-01-02",                         // 元旦
            "2026-02-16", "2026-02-17", "2026-02-18",
            "2026-02-19", "2026-02-20", "2026-02-23",           // 春节
            "2026-04-06",                                       // 清明
            "2026-05-01", "2026-05-04", "2026-05-05",           // 劳动节
            "2026-06-19",                                       // 端午
            "2026-09-25",                                       // 中秋
            "2026-10-01", "2026-10-02", "2026-10-05",
            "2026-10-06", "2026-10-07",                         // 国庆
        ],
        provenance: "上交所《关于上海证券交易所2026年部分节假日休市安排的通知》2025-12-22"
    )

    static let nyse2024 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .unitedStates,
        year: 2024,
        closedDates: [
            "2024-01-01", "2024-01-15", "2024-02-19", "2024-03-29",
            "2024-05-27", "2024-06-19", "2024-07-04", "2024-09-02",
            "2024-11-28", "2024-12-25",
        ],
        provenance: "NYSE 2024 holiday schedule（新年/MLK/总统日/耶稣受难日/阵亡将士/六月节/独立日/劳工节/感恩节/圣诞）"
    )

    static let nyse2025 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .unitedStates,
        year: 2025,
        closedDates: [
            "2025-01-01", "2025-01-20", "2025-02-17", "2025-04-18",
            "2025-05-26", "2025-06-19", "2025-07-04", "2025-09-01",
            "2025-11-27", "2025-12-25",
        ],
        provenance: "NYSE 2025 holiday schedule"
    )

    static let nyse2026 = try! MarketHolidayTable(
        version: 1,
        jurisdiction: .unitedStates,
        year: 2026,
        closedDates: [
            "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03",
            "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07",
            "2026-11-26", "2026-12-25",
        ],
        provenance: "NYSE 2026 holiday schedule（独立日 07-04 为周六，07-03 周五补休）"
    )

    /// 全部种子表（HolidayTableTradingCalendar 默认输入）。
    static let bundled: [MarketHolidayTable] = [
        sse2024, sse2025, sse2026,
        nyse2024, nyse2025, nyse2026,
    ]
}

// MARK: - 日历实现

/// 基于休市表的真实交易日历：实现 `TradingCalendar`（DOM-7 协议，
/// AvailabilityPolicy / TemporalNormalizer / Repository 的既有依赖面）与
/// `CalendarRepository`（八域之一，签名一致）。
///
/// 时区按法域：CN = Asia/Shanghai、US = America/New_York、HK = Asia/Hong_Kong。
/// `.platform` 不是真交易所（无市场日历），按 CN 时区仅周末判断、无权威覆盖。
/// HK 当前无种子表（本仓库无港股标的），同样退化为仅周末 + 无权威覆盖；
/// 引入港股数据前需按 DATA006 评审补 HKEX 休市表。
struct HolidayTableTradingCalendar: TradingCalendar, CalendarRepository {

    private let tables: [Jurisdiction: [Int: MarketHolidayTable]]
    /// 各法域本地日历（不可变，Sendable）
    private let localCalendars: [Jurisdiction: Calendar]

    /// 每法域最多回看天数（找「上一个交易日」的安全上界）。
    /// 实际最长休市跨度 ~11 天（2026 春节 02-14..02-23），60 天余量充足，
    /// 只防数据表整年全是休市日这类病态输入导致的死循环。
    private static let lookbackLimit = 60

    init(tables: [MarketHolidayTable]) throws {
        var byJurisdiction: [Jurisdiction: [Int: MarketHolidayTable]] = [:]
        for table in tables {
            // 同 (jurisdiction, year) 双表 = 配置错误（fail-closed，不静默择一）
            if byJurisdiction[table.jurisdiction]?[table.year] != nil {
                throw MarketHolidayTableError.duplicateTable(table.jurisdiction, year: table.year)
            }
            byJurisdiction[table.jurisdiction, default: [:]][table.year] = table
        }
        self.tables = byJurisdiction
        self.localCalendars = [
            .chinaMainland: Self.makeCalendar(timeZone: "Asia/Shanghai"),
            .unitedStates: Self.makeCalendar(timeZone: "America/New_York"),
            .hongKong: Self.makeCalendar(timeZone: "Asia/Hong_Kong"),
            .platform: Self.makeCalendar(timeZone: "Asia/Shanghai"),
        ]
    }

    /// 内置种子表构造（生产默认）。种子正确性由全集冻结测试守护。
    static let bundled = try! HolidayTableTradingCalendar(tables: SeedHolidayTables.bundled)

    private static func makeCalendar(timeZone identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    func localCalendar(for jurisdiction: Jurisdiction) -> Calendar {
        localCalendars[jurisdiction] ?? localCalendars[.chinaMainland]!
    }

    // MARK: TradingCalendar / CalendarRepository

    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
        let cal = localCalendar(for: jurisdiction)
        let weekday = cal.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }   // 周末结构性休市
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let key = String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        if let table = tables[jurisdiction]?[comps.year!] {
            return !table.closedDates.contains(key)
        }
        // 覆盖缺口：仅周末判断（见文件头），调用方可经 hasVerifiedHolidayCoverage 区分
        return true
    }

    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
        let cal = localCalendar(for: jurisdiction)
        var current = date
        var remaining = max(offset, 0)
        while remaining > 0 {
            current = cal.date(byAdding: .day, value: 1, to: current)!
            if isTradingDay(current, jurisdiction: jurisdiction) {
                remaining -= 1
            }
        }
        // 归一化到当地日界：返回值语义 = 「第 N 个交易日的 00:00（当地）」。
        // 与 AvailabilityPolicy 的二次 tradingDayStart 幂等；旧桩实现返回
        // 带 time-of-day 的瞬时，调用方（policy / repository）本就归一化，行为不变。
        return tradingDayStart(current, jurisdiction: jurisdiction)
    }

    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
        localCalendar(for: jurisdiction).startOfDay(for: date)
    }

    // MARK: 审计面（覆盖缺口显式化）

    /// 该法域有权威休市表背书的年份集合。
    func verifiedCoverageYears(for jurisdiction: Jurisdiction) -> Set<Int> {
        guard let years = tables[jurisdiction]?.keys else { return [] }
        return Set(years)
    }

    /// 某时刻所在当地日期是否有权威休市表背书（false = 仅周末推断）。
    func hasVerifiedHolidayCoverage(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
        let year = localCalendar(for: jurisdiction)
            .component(.year, from: date)
        return tables[jurisdiction]?[year] != nil
    }

    // MARK: 导航辅助（SYNC-2..6 增量窗口计算用）

    /// d 所在（或之前最近的）交易日。d 本身不是交易日时向前找。
    func latestTradingDayOnOrBefore(_ date: Date, jurisdiction: Jurisdiction) -> Date {
        let cal = localCalendar(for: jurisdiction)
        var current = tradingDayStart(date, jurisdiction: jurisdiction)
        for _ in 0..<Self.lookbackLimit {
            if isTradingDay(current, jurisdiction: jurisdiction) { return current }
            current = cal.date(byAdding: .day, value: -1, to: current)!
        }
        // 病态输入（连续 60 天无交易日）不属于真实日历，明确失败优于静默错值
        preconditionFailure("60 天内找不到交易日（\(jurisdiction.rawValue)）")
    }

    /// d 之前的最近一个交易日（不含 d 当日）。
    func previousTradingDay(before date: Date, jurisdiction: Jurisdiction) -> Date {
        let cal = localCalendar(for: jurisdiction)
        var current = tradingDayStart(date, jurisdiction: jurisdiction)
        for _ in 0..<Self.lookbackLimit {
            current = cal.date(byAdding: .day, value: -1, to: current)!
            if isTradingDay(current, jurisdiction: jurisdiction) { return current }
        }
        preconditionFailure("60 天内找不到交易日（\(jurisdiction.rawValue)）")
    }

    /// d 之后的最近一个交易日（不含 d 当日）。
    func nextTradingDay(after date: Date, jurisdiction: Jurisdiction) -> Date {
        tradingDay(after: date, offset: 1, jurisdiction: jurisdiction)
    }

    /// 结束于 end（含）往回数的 count 个交易日，升序返回。
    /// end 非交易日时从 end 前最近交易日起算（backfill 窗口的自然语义）。
    func tradingDays(endingAt end: Date, count: Int, jurisdiction: Jurisdiction) -> [Date] {
        guard count > 0 else { return [] }
        var result: [Date] = []
        var current = latestTradingDayOnOrBefore(end, jurisdiction: jurisdiction)
        result.append(current)
        let cal = localCalendar(for: jurisdiction)
        for _ in 1..<count {
            var stepped = false
            for _ in 0..<Self.lookbackLimit {
                current = cal.date(byAdding: .day, value: -1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    result.append(current)
                    stepped = true
                    break
                }
            }
            if !stepped { break }
        }
        return result.reversed()
    }
}

// MARK: - 基金净值公布日历

/// 基金净值公布日历（SYNC-1 后半：给 SYNC-3 NAV Sync 的抓取锚点）。
///
/// 语义锚点 = `AvailabilityPolicyV1.FundNAV`（T 日净值 T+1 交易日才可知，
/// availableAt = startOfDay(next(T))）。「保证已公布」的最新净值 effectiveDate：
/// 满足 availableAt(T) ≤ asOf 的最大交易日 T —— 即 asOf 所在（或之前最近）
/// 交易日的**前一个**交易日。
///
/// QDII 的 T+2 公布节奏不单独建模：保守 +1 只意味着「这轮抓不到就下一轮
/// 增量补齐」，不会伪造或提前认定数据（DATA006 降级语义），需要时以新
/// availability policy version 表达。
struct FundNAVPublicationCalendar: Sendable {

    let marketCalendar: HolidayTableTradingCalendar

    init(marketCalendar: HolidayTableTradingCalendar = .bundled) {
        self.marketCalendar = marketCalendar
    }

    /// asOf 时刻「保证已公布」的最新净值 effectiveDate（T 日语义见类型注释）。
    func latestGuaranteedPublishedNAVDate(asOf: Date) -> Date {
        let anchor = marketCalendar.latestTradingDayOnOrBefore(asOf, jurisdiction: .chinaMainland)
        return marketCalendar.previousTradingDay(before: anchor, jurisdiction: .chinaMainland)
    }

    /// [from, through] 区间内的净值 effectiveDate 候选（升序，两端含）。
    /// 非交易日自动跳过；backfill 与增量窗口共用。
    func navEffectiveDates(from: Date, through: Date) -> [Date] {
        guard from <= through else { return [] }
        var result: [Date] = []
        var current = marketCalendar.tradingDayStart(from, jurisdiction: .chinaMainland)
        let end = marketCalendar.tradingDayStart(through, jurisdiction: .chinaMainland)
        let cal = marketCalendar.localCalendar(for: .chinaMainland)
        // 上界防病态区间（正常 backfill ≤ 数百天）
        var iterations = 0
        while current <= end && iterations < 10_000 {
            if marketCalendar.isTradingDay(current, jurisdiction: .chinaMainland) {
                result.append(current)
            }
            current = cal.date(byAdding: .day, value: 1, to: current)!
            iterations += 1
        }
        return result
    }
}
