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

    func testCloseReviewWindowPassedWithoutRunIsMissedAsNeverRan() {
        let windows = missed(now: "2026-08-27 10:00:00")
        let closeReview = windows.first { $0.scope == .closeReview }
        XCTAssertEqual(closeReview?.reason, .neverRan)
        XCTAssertEqual(closeReview?.windowKey, "2026-08-26 21:00")
    }

    func testAttemptedButFailedWindowIsMissedAsFailedAttempt() {
        let windows = missed(
            keys: ["closeReview": "2026-08-26 21:00"],
            now: "2026-08-27 10:00:00"
        )
        XCTAssertEqual(windows.first { $0.scope == .closeReview }?.reason, .failedAttempt)
    }

    func testGeneratedAfterWindowIsNotMissed() {
        let windows = missed(
            generated: ["closeReview": "2026-08-26 21:30:00"],
            now: "2026-08-27 10:00:00"
        )
        XCTAssertNil(windows.first { $0.scope == .closeReview })
    }

    func testLongTermUsesLastSundayWindow() {
        let windows = missed(now: "2026-08-27 10:00:00")
        XCTAssertEqual(windows.first { $0.scope == .longTerm }?.windowKey, "2026-08-23 20:00")
        let fresh = missed(generated: ["longTerm": "2026-08-23 20:10:00"], now: "2026-08-27 10:00:00")
        XCTAssertNil(fresh.first { $0.scope == .longTerm })
        let stale = missed(generated: ["longTerm": "2026-08-16 20:10:00"], now: "2026-08-27 10:00:00")
        XCTAssertEqual(stale.first { $0.scope == .longTerm }?.windowKey, "2026-08-23 20:00")
    }

    func testLegacyMarketRadarRecordsAreIgnored() {
        let windows = missed(
            keys: ["marketRadar": "2026-08-27 09:00"],
            generated: ["marketRadar": "2026-08-26 09:00"],
            now: "2026-08-27 10:00:00"
        )
        XCTAssertFalse(windows.contains { $0.scope.rawValue == "marketRadar" })
        XCTAssertEqual(Set(windows.map { $0.scope }), [.closeReview, .longTerm])
    }

    func testNeverRanLongTermDoesNotPromptWhenAutoWillCatchUp() {
        let missedWindow = TrendMissedWindow(
            scope: .longTerm,
            reason: .neverRan,
            windowKey: "2026-08-23 20:00"
        )
        XCTAssertFalse(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 10:00:00"
            )
        )
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: false,
                now: "2026-08-27 10:00:00"
            )
        )
    }

    func testSameDayCloseReviewDoesNotPromptBeforeAutomaticRun() {
        let missedWindow = TrendMissedWindow(
            scope: .closeReview,
            reason: .neverRan,
            windowKey: "2026-08-27 21:00"
        )
        XCTAssertFalse(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 22:00:00"
            )
        )
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-28 10:00:00"
            )
        )
    }

    func testPromptSuppressedWhenNextAutoRunWithinTwoHours() {
        let missedWindow = TrendMissedWindow(
            scope: .closeReview,
            reason: .neverRan,
            windowKey: "2026-08-26 21:00"
        )
        XCTAssertFalse(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 19:30:00"
            )
        )
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: true,
                now: "2026-08-27 22:00:00"
            )
        )
        XCTAssertTrue(
            TrendMissedWindowCheck.shouldPromptManualCatchUp(
                missedWindow,
                autoAnalysisEnabled: false,
                now: "2026-08-27 19:30:00"
            )
        )
    }
}
