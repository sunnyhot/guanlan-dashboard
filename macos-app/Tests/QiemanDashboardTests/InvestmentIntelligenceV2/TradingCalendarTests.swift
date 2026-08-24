import XCTest
@testable import QiemanDashboard

/// SYNC-1 单元测试：真实交易日历（休市表种子数据冻结 + 跨法域语义 +
/// 基金净值公布日历）。
///
/// 种子表断言用**全集相等**（不只是抽样）——把 2024–2026 三年 SSE 与 NYSE
/// 的休市日逐个冻结，任何转录漂移（含把周末误当休市日登记）都会被抓住。
final class TradingCalendarTests: XCTestCase {

    private var calendar: HolidayTableTradingCalendar { .bundled }

    // MARK: - 日期构造辅助（CST / EST 本地日界）

    private func cst(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func est(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func utcNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: - 种子数据冻结（SSE / NYSE 三年全量）

    func testSSE2024ClosuresExact() {
        XCTAssertEqual(
            SeedHolidayTables.sse2024.closedDates,
            [
                "2024-01-01",
                "2024-02-09", "2024-02-12", "2024-02-13", "2024-02-14", "2024-02-15", "2024-02-16",
                "2024-04-04", "2024-04-05",
                "2024-05-01", "2024-05-02", "2024-05-03",
                "2024-06-10",
                "2024-09-16", "2024-09-17",
                "2024-10-01", "2024-10-02", "2024-10-03", "2024-10-04", "2024-10-07",
            ]
        )
    }

    func testSSE2025ClosuresExact() {
        XCTAssertEqual(
            SeedHolidayTables.sse2025.closedDates,
            [
                "2025-01-01",
                "2025-01-28", "2025-01-29", "2025-01-30", "2025-01-31", "2025-02-03", "2025-02-04",
                "2025-04-04",
                "2025-05-01", "2025-05-02", "2025-05-05",
                "2025-06-02",
                "2025-10-01", "2025-10-02", "2025-10-03", "2025-10-06", "2025-10-07", "2025-10-08",
            ]
        )
    }

    func testSSE2026ClosuresExact() {
        XCTAssertEqual(
            SeedHolidayTables.sse2026.closedDates,
            [
                "2026-01-01", "2026-01-02",
                "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23",
                "2026-04-06",
                "2026-05-01", "2026-05-04", "2026-05-05",
                "2026-06-19",
                "2026-09-25",
                "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07",
            ]
        )
    }

    func testNYSE2024To2026ClosuresExact() {
        XCTAssertEqual(
            SeedHolidayTables.nyse2024.closedDates,
            [
                "2024-01-01", "2024-01-15", "2024-02-19", "2024-03-29",
                "2024-05-27", "2024-06-19", "2024-07-04", "2024-09-02",
                "2024-11-28", "2024-12-25",
            ]
        )
        XCTAssertEqual(
            SeedHolidayTables.nyse2025.closedDates,
            [
                "2025-01-01", "2025-01-20", "2025-02-17", "2025-04-18",
                "2025-05-26", "2025-06-19", "2025-07-04", "2025-09-01",
                "2025-11-27", "2025-12-25",
            ]
        )
        XCTAssertEqual(
            SeedHolidayTables.nyse2026.closedDates,
            [
                "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03",
                "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07",
                "2026-11-26", "2026-12-25",
            ]
        )
    }

    // MARK: - 交易日判断（节假日 / 调休周末 / 法域差异）

    func testCNHolidayDatesAreNotTradingDays() {
        // 三个节日抽样：元旦（周三）、国庆中秋连休中段（周二）、2026 劳动节（周五）
        XCTAssertFalse(calendar.isTradingDay(cst(2025, 1, 1), jurisdiction: .chinaMainland))
        XCTAssertFalse(calendar.isTradingDay(cst(2025, 10, 7), jurisdiction: .chinaMainland))
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 5, 1), jurisdiction: .chinaMainland))
        // 休市日前后紧邻的交易日不受影响
        XCTAssertTrue(calendar.isTradingDay(cst(2025, 9, 30), jurisdiction: .chinaMainland))
        XCTAssertTrue(calendar.isTradingDay(cst(2025, 10, 9), jurisdiction: .chinaMainland))
    }

    func testWeekendsNeverTrade_EvenMakeupWorkdays() {
        // 国务院调休上班的周末（2025 春节：01-26 周日、02-08 周六），
        // 交易所不跟随调休开市
        XCTAssertFalse(calendar.isTradingDay(cst(2025, 1, 26), jurisdiction: .chinaMainland))
        XCTAssertFalse(calendar.isTradingDay(cst(2025, 2, 8), jurisdiction: .chinaMainland))
        // 2026 春节调休：02-14 周六、02-28 周六
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 2, 14), jurisdiction: .chinaMainland))
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 2, 28), jurisdiction: .chinaMainland))
        // 2026 国庆调休：09-20 周日、10-10 周六
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 9, 20), jurisdiction: .chinaMainland))
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 10, 10), jurisdiction: .chinaMainland))
        // 普通周六同样休市
        XCTAssertFalse(calendar.isTradingDay(cst(2026, 8, 22), jurisdiction: .chinaMainland))
    }

    func testSameDateDifferentJurisdiction() {
        // 2025 耶稣受难日：美股休市，A 股开市（法域差异不是全局开关）。
        // 用 UTC 正午构造同一瞬时，保证两个法域的本地日历都读到同一日期
        // （CST 日界与 EST 日界相差 12-13 小时，用本地零点构造会读到不同日期）。
        let goodFriday = utcNoon(2025, 4, 18)
        XCTAssertFalse(calendar.isTradingDay(goodFriday, jurisdiction: .unitedStates))
        XCTAssertTrue(calendar.isTradingDay(goodFriday, jurisdiction: .chinaMainland))
        // 2025 春节首日：A 股休市，美股开市
        let cny = utcNoon(2025, 1, 29)
        XCTAssertFalse(calendar.isTradingDay(cny, jurisdiction: .chinaMainland))
        XCTAssertTrue(calendar.isTradingDay(cny, jurisdiction: .unitedStates))
    }

    // MARK: - tradingDay(after:) 跨假期跳日

    func testSpringFestival2025Gap() {
        // 2025 春节：01-27（周一）是节前最后交易日，02-05（周三）节后首个
        let last = calendar.tradingDay(after: cst(2025, 1, 24), offset: 1, jurisdiction: .chinaMainland)
        XCTAssertEqual(last, cst(2025, 1, 27))
        let first = calendar.tradingDay(after: cst(2025, 1, 27), offset: 1, jurisdiction: .chinaMainland)
        XCTAssertEqual(first, cst(2025, 2, 5))
    }

    func testSpringFestival2026LongGap() {
        // 2026 春节：02-13（周五）节前最后交易日，02-24（周二）节后首个
        // （02-16..02-20、02-23 休市，周末 02-14/15/21/22 结构性休市）
        XCTAssertEqual(
            calendar.tradingDay(after: cst(2026, 2, 13), offset: 1, jurisdiction: .chinaMainland),
            cst(2026, 2, 24)
        )
        XCTAssertEqual(
            calendar.tradingDay(after: cst(2026, 2, 20), offset: 1, jurisdiction: .chinaMainland),
            cst(2026, 2, 24)
        )
    }

    func testNationalDay2025Gap() {
        // 国庆中秋 8 天休市（10-01..10-08 周内 6 天 + 周末），09-30 → 10-09
        XCTAssertEqual(
            calendar.tradingDay(after: cst(2025, 9, 30), offset: 1, jurisdiction: .chinaMainland),
            cst(2025, 10, 9)
        )
    }

    func testUSIndependence2026ObservedOnFriday() {
        // 2026-07-04 独立日为周六 → NYSE 07-03（周五）补休，下一交易日 07-06（周一）
        XCTAssertEqual(
            calendar.tradingDay(after: est(2026, 7, 2), offset: 1, jurisdiction: .unitedStates),
            est(2026, 7, 6)
        )
        XCTAssertFalse(calendar.isTradingDay(est(2026, 7, 3), jurisdiction: .unitedStates))
        XCTAssertTrue(calendar.isTradingDay(est(2026, 7, 3), jurisdiction: .chinaMainland))
    }

    func testTradingDayAfterOffsetZeroReturnsSameDayBoundary() {
        // offset 0 = 不推进（与旧 WeekdayOnlyCalendar 桩语义一致：max(offset,0)）
        let base = cst(2026, 8, 19, hour: 15, minute: 30)
        XCTAssertEqual(
            calendar.tradingDay(after: base, offset: 0, jurisdiction: .chinaMainland),
            cst(2026, 8, 19)
        )
    }

    // MARK: - 时区语义

    func testTradingDayStartUsesJurisdictionTimezone() {
        // 同一时刻的日界：CST 次日凌晨 vs EST 当日凌晨
        let instant = cst(2026, 1, 2, hour: 10)   // = UTC 01-02 02:00 = EST 01-01 21:00
        XCTAssertEqual(
            calendar.tradingDayStart(instant, jurisdiction: .chinaMainland),
            cst(2026, 1, 2)
        )
        XCTAssertEqual(
            calendar.tradingDayStart(instant, jurisdiction: .unitedStates),
            est(2026, 1, 1)
        )
    }

    // MARK: - 覆盖缺口显式化

    func testVerifiedCoverageAPI() {
        XCTAssertEqual(
            calendar.verifiedCoverageYears(for: .chinaMainland),
            [2024, 2025, 2026]
        )
        XCTAssertEqual(
            calendar.verifiedCoverageYears(for: .unitedStates),
            [2024, 2025, 2026]
        )
        // HK 无种子表（本仓库无港股标的）：覆盖为空、判断退化为仅周末
        XCTAssertTrue(calendar.verifiedCoverageYears(for: .hongKong).isEmpty)
        XCTAssertFalse(calendar.hasVerifiedHolidayCoverage(cst(2026, 8, 24), jurisdiction: .hongKong))
        // 覆盖外年份（2027）：明确报告无背书，判断仍可用（仅周末）
        XCTAssertFalse(calendar.hasVerifiedHolidayCoverage(cst(2027, 5, 1), jurisdiction: .chinaMainland))
        XCTAssertTrue(calendar.isTradingDay(cst(2027, 5, 3), jurisdiction: .chinaMainland))   // 周一
        XCTAssertFalse(calendar.isTradingDay(cst(2027, 5, 1), jurisdiction: .chinaMainland))  // 周六
    }

    // MARK: - 与 AvailabilityPolicy 的集成（policy 换真日历后的行为）

    func testFundNAVPolicyWithRealCalendar_SpringFestival2026() {
        // T 日 = 2026-02-13（节前最后交易日）：availableAt 应为节后首个交易日
        // 02-24 的日界，而不是「下周一」02-16（无休市表时会算错成 02-16）
        let policy = AvailabilityPolicyV1.FundNAV()
        let available = policy.availableAt(
            effectiveAt: cst(2026, 2, 13),
            publishedAt: cst(2026, 2, 13, hour: 22),
            jurisdiction: .chinaMainland,
            calendar: calendar
        )
        XCTAssertEqual(available, cst(2026, 2, 24))
    }

    func testMarketClosePolicyWithRealCalendar_USGoodFriday() {
        // 美股 Listing 的 MarketClose policy：T = 2025-04-17（周四），
        // 次交易日跨耶稣受难日到 04-21（周一）——法域从 listing 推导生效
        let policy = AvailabilityPolicyV1.MarketClose()
        let available = policy.availableAt(
            effectiveAt: est(2025, 4, 17),
            publishedAt: est(2025, 4, 17, hour: 16),
            jurisdiction: .unitedStates,
            calendar: calendar
        )
        XCTAssertEqual(available, est(2025, 4, 21))
    }

    // MARK: - 导航辅助（SYNC-2..6 的窗口计算）

    func testLatestAndPreviousTradingDay() {
        // asOf 在 2026 春节休市中（02-18 周三）：所在/之前最近交易日 = 02-13
        XCTAssertEqual(
            calendar.latestTradingDayOnOrBefore(cst(2026, 2, 18), jurisdiction: .chinaMainland),
            cst(2026, 2, 13)
        )
        XCTAssertEqual(
            calendar.previousTradingDay(before: cst(2026, 2, 13), jurisdiction: .chinaMainland),
            cst(2026, 2, 12)
        )
        // 周六：所在/之前最近交易日 = 周五
        XCTAssertEqual(
            calendar.latestTradingDayOnOrBefore(cst(2026, 8, 22), jurisdiction: .chinaMainland),
            cst(2026, 8, 21)
        )
        // 周日：nextTradingDay = 周一
        XCTAssertEqual(
            calendar.nextTradingDay(after: cst(2026, 8, 23), jurisdiction: .chinaMainland),
            cst(2026, 8, 24)
        )
    }

    func testTradingDaysEndingAtCount_CrossesSpringFestival() {
        // 往回数 5 个交易日，结束于 2026-02-24（节后首个）：应跨春节缺口
        let days = calendar.tradingDays(endingAt: cst(2026, 2, 24), count: 5, jurisdiction: .chinaMainland)
        XCTAssertEqual(days, [
            cst(2026, 2, 10), cst(2026, 2, 11), cst(2026, 2, 12),
            cst(2026, 2, 13), cst(2026, 2, 24),
        ])
        // count 0 = 空窗口
        XCTAssertTrue(calendar.tradingDays(endingAt: cst(2026, 2, 24), count: 0, jurisdiction: .chinaMainland).isEmpty)
    }

    // MARK: - 基金净值公布日历

    func testNAVPublication_LatestGuaranteedOnTradingDay() {
        // 周三 20:00：保证已公布的最新净值是周二（T+1 日界 = 周三 00:00 已过）
        let nav = FundNAVPublicationCalendar(marketCalendar: calendar)
        XCTAssertEqual(
            nav.latestGuaranteedPublishedNAVDate(asOf: cst(2026, 8, 19, hour: 20)),
            cst(2026, 8, 18)
        )
        // 周三凌晨 05:00（T+1 日界刚过）：同样是周二
        XCTAssertEqual(
            nav.latestGuaranteedPublishedNAVDate(asOf: cst(2026, 8, 19, hour: 5)),
            cst(2026, 8, 18)
        )
    }

    func testNAVPublication_LatestGuaranteedDuringHoliday() {
        let nav = FundNAVPublicationCalendar(marketCalendar: calendar)
        // 2026 春节休市中（02-18）：最近交易日 02-13，保证已公布的是 02-12
        XCTAssertEqual(
            nav.latestGuaranteedPublishedNAVDate(asOf: cst(2026, 2, 18, hour: 12)),
            cst(2026, 2, 12)
        )
        // 节后首个交易日 02-24 当天：保证已公布的是节前最后交易日 02-13
        XCTAssertEqual(
            nav.latestGuaranteedPublishedNAVDate(asOf: cst(2026, 2, 24, hour: 21)),
            cst(2026, 2, 13)
        )
    }

    func testNAVPublication_LatestGuaranteedOnWeekend() {
        let nav = FundNAVPublicationCalendar(marketCalendar: calendar)
        // 周六：最近交易日 = 周五，保证已公布 = 周四
        XCTAssertEqual(
            nav.latestGuaranteedPublishedNAVDate(asOf: cst(2026, 8, 22, hour: 12)),
            cst(2026, 8, 20)
        )
    }

    func testNAVPublication_EffectiveDatesSkipHolidays() {
        let nav = FundNAVPublicationCalendar(marketCalendar: calendar)
        // 2026-02-09..02-24 窗口：跳过春节休市与周末，剩 6 个候选日
        let dates = nav.navEffectiveDates(from: cst(2026, 2, 9), through: cst(2026, 2, 24))
        XCTAssertEqual(dates, [
            cst(2026, 2, 9), cst(2026, 2, 10), cst(2026, 2, 11),
            cst(2026, 2, 12), cst(2026, 2, 13), cst(2026, 2, 24),
        ])
        // 反向区间 = 空
        XCTAssertTrue(nav.navEffectiveDates(from: cst(2026, 2, 24), through: cst(2026, 2, 9)).isEmpty)
    }

    // MARK: - 休市表数据结构与校验

    func testHolidayTableCodableRoundTrip() throws {
        let table = SeedHolidayTables.sse2025
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(MarketHolidayTable.self, from: data)
        XCTAssertEqual(decoded, table)
        XCTAssertEqual(decoded.provenance, table.provenance)
        XCTAssertEqual(decoded.year, 2025)
    }

    func testHolidayTableRejectsWeekendDate() {
        // 2026-08-22 是周六：结构性休市不该进表（说明数据源有错）
        XCTAssertThrowsError(
            _ = try MarketHolidayTable(
                version: 1, jurisdiction: .chinaMainland, year: 2026,
                closedDates: ["2026-08-22"], provenance: "test"
            )
        )
    }

    func testHolidayTableRejectsMalformedOrOutOfRangeDates() {
        // 格式非法 / 年份不匹配 / 不存在的日历日，全部拒收
        for bad in ["2026/01/01", "2026-1-1", "2025-01-01", "2026-02-30"] {
            XCTAssertThrowsError(
                _ = try MarketHolidayTable(
                    version: 1, jurisdiction: .chinaMainland, year: 2026,
                    closedDates: [bad], provenance: "test"
                ),
                "应拒收非法日期 \(bad)"
            )
        }
    }

    func testDuplicateTablesFailLoud() {
        // 同 (jurisdiction, year) 双表 = 配置错误，构造失败不静默择一
        XCTAssertThrowsError(
            _ = try HolidayTableTradingCalendar(tables: [
                SeedHolidayTables.sse2026,
                try MarketHolidayTable(
                    version: 2, jurisdiction: .chinaMainland, year: 2026,
                    closedDates: [], provenance: "conflicting"
                ),
            ])
        )
    }
}
