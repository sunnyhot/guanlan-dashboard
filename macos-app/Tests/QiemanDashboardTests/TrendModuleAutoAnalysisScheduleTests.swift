import XCTest
@testable import QiemanDashboard

final class TrendModuleAutoAnalysisScheduleTests: XCTestCase {
    func testWeekdayHasNoMorningSlotAfterRadarRetirement() {
        // 2026-09-01 下线收编:marketRadar 09:00 槽移除,大盘强弱并入 21:00 收盘复盘。
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 08:59:00",
                lastCompletedKeys: [:]
            )
        )
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 09:00:00",
                lastCompletedKeys: [:]
            )
        )
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 15:30:00",
                lastCompletedKeys: [:]
            )
        )
        XCTAssertEqual(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 21:00:00",
                lastCompletedKeys: [:]
            )?.scope,
            .closeReview
        )
    }

    func testSundayLongTermWindowDoesNotRunMarketRadarBackToBack() {
        let slot = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: "2026-08-09 20:15:00",
            lastCompletedKeys: [:]
        )

        XCTAssertEqual(slot?.scope, .longTerm)
        XCTAssertEqual(slot?.key, "2026-08-09 20:00")
    }

    func testLongTermRunCatchesUpAfterSundayWithoutRepeatingInSameWeek() {
        let monday = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: "2026-08-10 20:15:00",
            lastCompletedKeys: [:]
        )
        XCTAssertEqual(monday?.scope, .longTerm)
        XCTAssertEqual(monday?.key, "2026-08-09 20:00")

        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-11 20:15:00",
                lastCompletedKeys: [
                    TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"
                ]
            )
        )
    }

    func testCompletedModuleSlotIsNotRepeated() {
        let timestamp = "2026-08-10 21:30:00"
        let first = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: timestamp,
            lastCompletedKeys: [:]
        )
        XCTAssertNotNil(first)

        let completed = [TrendResearchRunScope.closeReview.rawValue: first?.key ?? ""]
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: timestamp,
                lastCompletedKeys: completed
            )
        )
    }

    func testPersistedCloseReviewGenerationSuppressesDuplicateAutomaticScan() {
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 22:00:00",
                lastCompletedKeys: [:],
                lastGeneratedAtByScope: [
                    TrendResearchRunScope.closeReview.rawValue: "2026-08-10 21:11:52"
                ]
            )
        )
    }

    func testPreviousCloseReviewIsReusedNextMorningWithoutCatchUpScan() {
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-11 08:30:00",
                lastCompletedKeys: [:],
                lastGeneratedAtByScope: [
                    TrendResearchRunScope.closeReview.rawValue: "2026-08-10 21:11:52"
                ]
            )
        )
    }

    func testFullGenerationUpdatesAllModuleFreshnessTimestamps() {
        var settings = TrendAnalysisSettings.default
        settings.markModuleGenerated(
            scope: .full,
            generatedAt: "2026-08-10 21:05:00"
        )

        XCTAssertEqual(settings.moduleGeneratedAt(.marketRadar), "2026-08-10 21:05:00")
        XCTAssertEqual(settings.moduleGeneratedAt(.closeReview), "2026-08-10 21:05:00")
        XCTAssertEqual(settings.moduleGeneratedAt(.longTerm), "2026-08-10 21:05:00")
    }
}
