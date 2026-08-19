import XCTest
@testable import QiemanDashboard

// MARK: - 收盘复盘新鲜度状态测试
//
// 状态必须与真实调度契约一致：每晚 21:00 自动窗口、同日至多自动尝试一次
// （启动前落盘 key）、错过不跨日补跑。attempted key 的格式
// `"<yyyy-MM-dd> 21:00"` 与 TrendModuleAutoAnalysisSchedule.dueSlot 生成的保持一致。

final class MarketCloseReviewFreshnessTests: XCTestCase {
    private let closeReviewTime = TrendModuleAutoAnalysisSchedule.closeReviewTime

    // MARK: 今日已生成

    func testGeneratedTodayShowsGenerationTimeAndNightlyContract() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-19 21:03:12",
            currentTimestamp: "2026-08-19 22:10:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: true
        )
        XCTAssertEqual(
            freshness.phase,
            .generatedToday(timeText: "21:03")
        )
        XCTAssertEqual(freshness.badgeText, "今日已复盘")
        XCTAssertTrue(freshness.subtitleText.contains("今日 21:03 生成"))
        XCTAssertTrue(freshness.subtitleText.contains("每晚 \(closeReviewTime) 自动更新"))
        XCTAssertEqual(freshness.actionTitle, "重新生成")
    }

    func testManualGenerationDuringDaytimeCountsAsToday() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-19 15:00:00",
            currentTimestamp: "2026-08-19 16:30:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: false
        )
        guard case .generatedToday = freshness.phase else {
            return XCTFail("白天手动生成过也应视为今日已生成")
        }
    }

    // MARK: 21:00 前：等待今晚

    func testDaytimeWithYesterdayArchiveExplainsWhyTitleIsYesterday() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-18 21:03:12",
            currentTimestamp: "2026-08-19 15:40:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: true
        )
        XCTAssertEqual(freshness.phase, .waitingForTonight)
        XCTAssertEqual(freshness.lastGeneratedAtText, "2026-08-18 21:03")
        XCTAssertEqual(freshness.badgeText, "今晚\(closeReviewTime)更新")
        XCTAssertTrue(freshness.subtitleText.contains("展示 2026-08-18 21:03 的复盘"))
        XCTAssertTrue(freshness.subtitleText.contains("今晚 \(closeReviewTime) 自动更新"))
        XCTAssertEqual(freshness.actionTitle, "现在生成")
    }

    func testDaytimeWithoutAnyGenerationSaysNeverGenerated() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: nil,
            currentTimestamp: "2026-08-19 10:00:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: true
        )
        XCTAssertNil(freshness.lastGeneratedAtText)
        XCTAssertTrue(freshness.subtitleText.contains("尚未生成过"))
        XCTAssertTrue(freshness.subtitleText.contains("今晚 \(closeReviewTime) 自动生成"))
    }

    func testDaytimeWithAutoDisabledMentionsManualFallback() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-18 21:03:12",
            currentTimestamp: "2026-08-19 15:40:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: false
        )
        XCTAssertEqual(freshness.badgeText, "未开启自动")
        XCTAssertTrue(freshness.subtitleText.contains("自动更新未开启"))
    }

    // MARK: 21:00 后今日未生成

    func testEveningAfterFailedAutoAttemptAsksForManualRetry() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-18 21:03:12",
            currentTimestamp: "2026-08-19 22:00:00",
            autoAttemptedKey: "2026-08-19 \(closeReviewTime)",
            autoAnalysisEnabled: true
        )
        XCTAssertEqual(
            freshness.phase,
            .tonightUnfinished(autoAttempted: true)
        )
        XCTAssertEqual(freshness.badgeText, "待手动补做")
        XCTAssertTrue(freshness.subtitleText.contains("今晚自动复盘未成功"))
        XCTAssertTrue(freshness.subtitleText.contains("正在展示 2026-08-18 21:03 的结果"))
        XCTAssertTrue(freshness.subtitleText.contains("可手动补做"))
        XCTAssertEqual(freshness.actionTitle, "补做今日复盘")
    }

    func testEveningBeforeAutoAttemptSaysAutoIsComing() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-18 21:03:12",
            currentTimestamp: "2026-08-19 21:00:30",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: true
        )
        XCTAssertEqual(
            freshness.phase,
            .tonightUnfinished(autoAttempted: false)
        )
        XCTAssertEqual(freshness.badgeText, "等待自动复盘")
        XCTAssertTrue(freshness.subtitleText.contains("自动复盘即将开始"))
    }

    func testEveningWithAutoDisabledDoesNotPromiseAutoRun() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-18 21:03:12",
            currentTimestamp: "2026-08-19 22:00:00",
            autoAttemptedKey: nil,
            autoAnalysisEnabled: false
        )
        XCTAssertEqual(freshness.badgeText, "未开启自动")
        XCTAssertTrue(freshness.subtitleText.contains("自动复盘未开启"))
        XCTAssertFalse(freshness.subtitleText.contains("即将开始"))
    }

    func testStaleAttemptedKeyFromEarlierDayDoesNotCountAsTonightAttempt() {
        let freshness = MarketCloseReviewFreshness.evaluate(
            generatedAt: "2026-08-17 21:03:12",
            currentTimestamp: "2026-08-19 22:00:00",
            autoAttemptedKey: "2026-08-18 \(closeReviewTime)",
            autoAnalysisEnabled: true
        )
        XCTAssertEqual(
            freshness.phase,
            .tonightUnfinished(autoAttempted: false)
        )
    }

    // MARK: 与标题的一致性

    func testFreshnessAgreesWithDisplayTitle() {
        // generatedAt=nil 不参与断言：displayTitle 对 nil 的既有默认值是
        // 「今日收盘复盘」（见 testCloseReviewTitleFollowsFrozenReviewDay 冻结的行为），
        // 与 freshness 的 waitingForTonight 判定天然不一致，属历史默认而非状态矛盾。
        let inputs: [(generatedAt: String?, now: String)] = [
            ("2026-08-19 21:03:12", "2026-08-19 22:00:00"),
            ("2026-08-18 21:03:12", "2026-08-19 15:00:00"),
            ("2026-08-18 21:03:12", "2026-08-19 22:00:00"),
            ("2026-08-17 21:03:12", "2026-08-19 22:00:00"),
        ]
        for input in inputs {
            let freshness = MarketCloseReviewFreshness.evaluate(
                generatedAt: input.generatedAt,
                currentTimestamp: input.now,
                autoAttemptedKey: nil,
                autoAnalysisEnabled: true
            )
            let title = MarketCloseReviewArchive.displayTitle(
                generatedAt: input.generatedAt,
                currentTimestamp: input.now
            )
            let isToday: Bool
            if case .generatedToday = freshness.phase {
                isToday = true
            } else {
                isToday = false
            }
            XCTAssertEqual(
                isToday,
                title == "今日收盘复盘",
                "generatedAt=\(input.generatedAt ?? "nil") now=\(input.now)"
            )
        }
    }
}
