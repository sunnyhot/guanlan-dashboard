import XCTest
@testable import QiemanDashboard

// MARK: - 投资智能自动调度测试（审计 B1/C5）
//
// 覆盖：槽位到期判定（各模块时刻表 / 幂等 key / 跨日重置 / 周日研究窗口
// 不被交易日守卫挡住 / 分模块开关 / 总开关）、设置持久化回环。

final class IntelligenceScheduleTests: XCTestCase {

    /// 上海时区构造器。
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func evaluate(
        settings: IntelligenceScheduleSettings = IntelligenceScheduleSettings(
            isAutoRunEnabled: true),
        now: Date,
        isTradingDay: Bool = true,
        isSunday: Bool = false
    ) -> (slots: IntelligenceScheduleEvaluator.DueSlots,
          keys: IntelligenceScheduleEvaluator.AttemptKeys) {
        IntelligenceScheduleEvaluator.evaluate(
            settings: settings, now: now, isTradingDay: isTradingDay, isSunday: isSunday)
    }

    // MARK: - 时刻表

    func testMarketDiscoveryDueAt0900() {
        // 08:59 未到期；09:00 到期
        XCTAssertTrue(evaluate(now: date(2026, 8, 27, 8, 59)).slots.isEmpty)
        let due = evaluate(now: date(2026, 8, 27, 9, 0))
        XCTAssertTrue(due.slots.marketDiscovery)
        XCTAssertEqual(due.keys.marketDiscovery, "marketDiscovery|2026-08-27|09:00")
    }

    func testIntradayPicksLatestStartedSlot() {
        // 10:20 → 最近已开始槽位是 10:15
        let outcome = evaluate(now: date(2026, 8, 27, 10, 20))
        XCTAssertTrue(outcome.slots.intraday)
        XCTAssertEqual(outcome.keys.intraday, "intraday|2026-08-27|10:15")
        // 14:55 → 14:50 槽
        let late = evaluate(now: date(2026, 8, 27, 14, 55))
        XCTAssertEqual(late.keys.intraday, "intraday|2026-08-27|14:50")
        // 09:14（首个槽前）→ 无盘中
        XCTAssertFalse(evaluate(now: date(2026, 8, 27, 9, 14)).slots.intraday)
    }

    func testCloseReviewDueAt2100() {
        // 20:59：复盘未到期（发现/盘中槽此刻若全天未尝试过会补触发，
        // 属预期语义——这里只断言复盘自身）
        XCTAssertFalse(evaluate(now: date(2026, 8, 27, 20, 59)).slots.closeReview)
        XCTAssertTrue(evaluate(now: date(2026, 8, 27, 21, 0)).slots.closeReview)
    }

    func testPortfolioResearchOnlySundayEvening() {
        // 周六 20:30：不触发（研究窗口是周日）
        XCTAssertFalse(evaluate(now: date(2026, 8, 29, 20, 30), isSunday: false).slots.portfolioResearch)
        // 周日 19:59：未到
        XCTAssertFalse(evaluate(now: date(2026, 8, 30, 19, 59), isSunday: true).slots.portfolioResearch)
        // 周日 20:00：触发（周日 isTradingDay=false 也不挡——独立守卫）
        let outcome = evaluate(now: date(2026, 8, 30, 20, 0), isTradingDay: false, isSunday: true)
        XCTAssertTrue(outcome.slots.portfolioResearch)
        XCTAssertEqual(outcome.keys.portfolioResearch, "portfolioResearch|2026-08-30|sunday")
    }

    // MARK: - 幂等 / 跨日重置

    func testAttemptedKeySkipsSameWindow() {
        var settings = IntelligenceScheduleSettings(isAutoRunEnabled: true)
        settings.lastAttemptedKeys["closeReview"] = "closeReview|2026-08-27|21:00"
        // 同窗口第二次评估：不再触发
        let again = evaluate(settings: settings, now: date(2026, 8, 27, 21, 30))
        XCTAssertFalse(again.slots.closeReview)
        // 次日：新 key 触发
        let nextDay = evaluate(settings: settings, now: date(2026, 8, 28, 21, 5))
        XCTAssertTrue(nextDay.slots.closeReview)
        XCTAssertEqual(nextDay.keys.closeReview, "closeReview|2026-08-28|21:00")
    }

    func testIntradayEachSlotOnce() {
        var settings = IntelligenceScheduleSettings(isAutoRunEnabled: true)
        settings.lastAttemptedKeys["intraday"] = "intraday|2026-08-27|10:15"
        // 同槽内（10:40）：不再触发；进入 11:15 槽后触发新 key
        XCTAssertFalse(evaluate(settings: settings, now: date(2026, 8, 27, 10, 40)).slots.intraday)
        let nextSlot = evaluate(settings: settings, now: date(2026, 8, 27, 11, 16))
        XCTAssertTrue(nextSlot.slots.intraday)
        XCTAssertEqual(nextSlot.keys.intraday, "intraday|2026-08-27|11:15")
    }

    // MARK: - 开关

    func testMasterSwitchOffDisablesAll() {
        let settings = IntelligenceScheduleSettings(isAutoRunEnabled: false)
        XCTAssertTrue(evaluate(settings: settings, now: date(2026, 8, 27, 21, 30)).slots.isEmpty)
    }

    func testNonTradingDayDisablesTradingModules() {
        let outcome = evaluate(now: date(2026, 8, 29, 21, 30), isTradingDay: false)
        XCTAssertFalse(outcome.slots.closeReview)
        XCTAssertFalse(outcome.slots.marketDiscovery)
        XCTAssertFalse(outcome.slots.intraday)
    }

    func testModuleSwitchOffSkipsModule() {
        var settings = IntelligenceScheduleSettings(isAutoRunEnabled: true)
        settings.closeReviewEnabled = false
        settings.intradayEnabled = false
        let outcome = evaluate(settings: settings, now: date(2026, 8, 27, 21, 30))
        XCTAssertFalse(outcome.slots.closeReview)
        XCTAssertFalse(outcome.slots.intraday)
        XCTAssertTrue(outcome.slots.marketDiscovery, "其他模块不受影响")
    }

    // MARK: - 持久化

    func testSettingsPersistenceRoundtrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = IntelligenceScheduleSettings(isAutoRunEnabled: true)
        settings.closeReviewEnabled = false
        settings.lastAttemptedKeys["intraday"] = "intraday|2026-08-27|10:15"
        settings.save(dataDirectory: directory)

        let loaded = IntelligenceScheduleSettings.load(dataDirectory: directory)
        XCTAssertEqual(loaded, settings)

        // 无文件 → 默认（总开关关闭）
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-none-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(IntelligenceScheduleSettings.load(dataDirectory: empty).isAutoRunEnabled)
    }
}
