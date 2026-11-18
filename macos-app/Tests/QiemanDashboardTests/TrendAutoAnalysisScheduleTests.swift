import XCTest
@testable import QiemanDashboard

final class TrendAutoAnalysisScheduleTests: XCTestCase {
    func testDayStringAcceptsFullTimestampAndRejectsShortInput() {
        XCTAssertEqual(TrendAutoAnalysisSchedule.dayString(from: "2026-06-22 09:30:00"), "2026-06-22")
        XCTAssertEqual(TrendAutoAnalysisSchedule.dayString(from: " 2026-06-22 "), "2026-06-22")
        XCTAssertNil(TrendAutoAnalysisSchedule.dayString(from: "2026-06"))
    }
}
