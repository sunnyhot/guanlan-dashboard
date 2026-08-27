import XCTest
@testable import QiemanDashboard

/// W3.5:错过的自动窗口判定测试。
/// 参照日期:2026-08-27 为周四,上一个周日是 2026-08-23。
final class TrendMissedWindowCheckTests: XCTestCase {
    private func missed(
        keys: [String: String] = [:],
        generated: [String: String] = [:],
        now: String
    ) -> [TrendMissedWindow] {
        TrendMissedWindowCheck.missedScopes(
            lastModuleAutoAnalysisKeys: keys,
            lastModuleGeneratedAt: generated,
            now: now
        )
    }

    func testRadarWindowPassedWithoutRunIsMissedAsNeverRan() {
        // 周四 10:00,今天 09:00 的雷达窗口已过,没运行也没生成。
        let windows = missed(generated: ["marketRadar": "2026-08-26 09:00"], now: "2026-08-27 10:00:00")
        let radar = windows.first { $0.scope == .marketRadar }
        XCTAssertEqual(radar?.reason, .neverRan)
        XCTAssertEqual(radar?.windowKey, "2026-08-27 09:00")
    }

    func testAttemptedButFailedWindowIsMissedAsFailedAttempt() {
        let windows = missed(
            keys: ["marketRadar": "2026-08-27 09:00"],
            generated: ["marketRadar": "2026-08-26 09:00"],
            now: "2026-08-27 10:00:00"
        )
        XCTAssertEqual(windows.first { $0.scope == .marketRadar }?.reason, .failedAttempt)
    }

    func testGeneratedAfterWindowIsNotMissed() {
        let windows = missed(generated: ["marketRadar": "2026-08-27 09:30:00"], now: "2026-08-27 10:00:00")
        XCTAssertNil(windows.first { $0.scope == .marketRadar }, "窗口后已生成则该模块不算错过")
    }

    func testCloseReviewUsesYesterdayEveningWindow() {
        // 周四上午:上一个收盘复盘窗口是昨天(周三)21:00。
        let windows = missed(now: "2026-08-27 10:00:00")
        XCTAssertEqual(windows.first { $0.scope == .closeReview }?.windowKey, "2026-08-26 21:00")
        let fresh = missed(generated: ["closeReview": "2026-08-26 21:05:00"], now: "2026-08-27 10:00:00")
        XCTAssertNil(fresh.first { $0.scope == .closeReview })
    }

    func testLongTermUsesLastSundayWindow() {
        // 周四:上一个长期研判窗口是 2026-08-23(周日)20:00。
        let windows = missed(now: "2026-08-27 10:00:00")
        XCTAssertEqual(windows.first { $0.scope == .longTerm }?.windowKey, "2026-08-23 20:00")
        // 上周日生成过 → 不算错过;只更早的周日生成才算。
        let fresh = missed(generated: ["longTerm": "2026-08-23 20:10:00"], now: "2026-08-27 10:00:00")
        XCTAssertNil(fresh.first { $0.scope == .longTerm })
        let stale = missed(generated: ["longTerm": "2026-08-16 20:10:00"], now: "2026-08-27 10:00:00")
        XCTAssertEqual(stale.first { $0.scope == .longTerm }?.windowKey, "2026-08-23 20:00")
    }

    func testWindowNotYetReachedTodayIsNotMissed() {
        // 周四 08:00:今天 09:00 雷达窗口未到,上一个窗口是昨天 09:00,昨天 09:30 已生成。
        let windows = missed(generated: ["marketRadar": "2026-08-26 09:30:00"], now: "2026-08-27 08:00:00")
        XCTAssertNil(windows.first { $0.scope == .marketRadar })
    }

    func testPromptSuppressedWhenNextAutoRunWithinTwoHours() {
        let missedWindow = TrendMissedWindow(scope: .marketRadar, reason: .neverRan, windowKey: "2026-08-27 09:00")
        // 周四 07:30,下一班雷达 09:00(1.5 小时后)→ 不提示,自动会补。
        XCTAssertFalse(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 07:30:00"
            )
        )
        // 周四 11:00,下一班是明天 09:00 → 提示。
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 11:00:00"
            )
        )
        // 自动分析关了:没有「下一班」,只能手动补 → 恒提示。
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: false,
                now: "2026-08-27 07:30:00"
            )
        )
    }
}
