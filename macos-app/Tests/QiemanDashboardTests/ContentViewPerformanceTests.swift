import XCTest
@testable import QiemanDashboard

final class ContentViewPerformanceTests: XCTestCase {
    func testSectionSwitchingDoesNotForceDetailPanelIdentityReset() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views_macOS/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains(".id(model.selectedSection)"))
        XCTAssertFalse(source.contains(".transition(.opacity.combined(with: .offset(y: 6)))"))
        XCTAssertFalse(source.contains(".animation(AppPalette.motionSection, value: model.selectedSection)"))
        XCTAssertFalse(source.contains("withAnimation(AppPalette.motionSpring) {\n                            model.selectedSection = section\n                        }"))
    }
}
