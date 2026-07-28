import XCTest
@testable import QiemanDashboard

final class UIEffectsTokenTests: XCTestCase {
    func testMotionDurationsStayShortForOperationalDashboard() {
        XCTAssertEqual(AppPalette.motionFastDuration, 0.12, accuracy: 0.001)
        XCTAssertEqual(AppPalette.motionStandardDuration, 0.18, accuracy: 0.001)
        XCTAssertEqual(AppPalette.motionSectionDuration, 0.20, accuracy: 0.001)
    }

    func testSelectionMetricsKeepSidebarReadable() {
        XCTAssertEqual(AppPalette.selectionRailWidth, 3, accuracy: 0.001)
        XCTAssertEqual(AppPalette.sidebarRowRadius, 9, accuracy: 0.001)
        XCTAssertEqual(AppPalette.hoverLift, 1.2, accuracy: 0.001)
        XCTAssertEqual(AppPalette.selectionStrokeOpacity, 0.76, accuracy: 0.001)
        XCTAssertEqual(AppPalette.selectionGlowOpacity, 0.16, accuracy: 0.001)
        XCTAssertEqual(AppPalette.selectionGlowRadius, 12, accuracy: 0.001)
    }
}
