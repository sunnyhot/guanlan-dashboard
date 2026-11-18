import XCTest
@testable import QiemanDashboard

final class TrendModuleAutoAnalysisScheduleTests: XCTestCase {
    func testWeekdayMorningDoesNotRunCloseReviewWhenLongTermAlreadyDone() {
        let completed = [TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"]
        for timestamp in ["2026-08-10 08:59:00", "2026-08-10 09:00:00", "2026-08-10 15:30:00"] {
            XCTAssertNil(
                TrendModuleAutoAnalysisSchedule.dueSlot(
                    at: timestamp,
                    lastCompletedKeys: completed
                )
            )
        }
        XCTAssertEqual(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 21:00:00",
                lastCompletedKeys: completed
            )?.scope,
            .closeReview
        )
    }

    func testSundayLongTermWindowRunsBeforeCloseReview() {
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

    func testLongTermAutomaticallyCatchesUpOnNextLaunch() {
        let slot = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: "2026-08-10 08:30:00",
            lastCompletedKeys: [:]
        )
        XCTAssertEqual(slot?.scope, .longTerm)
        XCTAssertEqual(slot?.key, "2026-08-09 20:00")
    }

    func testSundayBeforeWindowCatchesUpPreviousWeek() {
        let slot = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: "2026-08-09 08:30:00",
            lastCompletedKeys: [:]
        )
        XCTAssertEqual(slot?.scope, .longTerm)
        XCTAssertEqual(slot?.key, "2026-08-02 20:00")
    }

    func testFailedLongTermWindowDoesNotAutomaticallyRetry() {
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-10 08:30:00",
                lastCompletedKeys: [
                    TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"
                ]
            )
        )
    }

    func testCloseReviewIsNotAutomaticallyCaughtUpNextMorning() {
        XCTAssertNil(
            TrendModuleAutoAnalysisSchedule.dueSlot(
                at: "2026-08-11 08:30:00",
                lastCompletedKeys: [
                    TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"
                ]
            )
        )
    }

    func testCompletedCloseReviewThenAllowsLongTermCatchUp() {
        let slot = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: "2026-08-10 21:30:00",
            lastCompletedKeys: [
                TrendResearchRunScope.closeReview.rawValue: "2026-08-10 21:00"
            ]
        )
        XCTAssertEqual(slot?.scope, .longTerm)
        XCTAssertEqual(slot?.key, "2026-08-09 20:00")
    }

    func testCompletedModuleSlotIsNotRepeated() {
        let timestamp = "2026-08-10 21:30:00"
        let first = TrendModuleAutoAnalysisSchedule.dueSlot(
            at: timestamp,
            lastCompletedKeys: [:]
        )
        XCTAssertNotNil(first)

        let completed = [
            TrendResearchRunScope.closeReview.rawValue: first?.key ?? "",
            TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00",
        ]
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
                lastCompletedKeys: [
                    TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"
                ],
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
                lastCompletedKeys: [
                    TrendResearchRunScope.longTerm.rawValue: "2026-08-09 20:00"
                ],
                lastGeneratedAtByScope: [
                    TrendResearchRunScope.closeReview.rawValue: "2026-08-10 21:11:52"
                ]
            )
        )
    }

    func testRetiredScopeIsNotInRunScopeCases() {
        XCTAssertEqual(
            Set(TrendResearchRunScope.allCases.map { $0.rawValue }),
            ["full", "closeReview", "longTerm"]
        )
    }

    func testFullGenerationUpdatesAllModuleFreshnessTimestamps() {
        var settings = TrendAnalysisSettings.default
        settings.markModuleGenerated(
            scope: .full,
            generatedAt: "2026-08-10 21:05:00"
        )

        XCTAssertEqual(settings.moduleGeneratedAt(.closeReview), "2026-08-10 21:05:00")
        XCTAssertEqual(settings.moduleGeneratedAt(.longTerm), "2026-08-10 21:05:00")
    }
}
