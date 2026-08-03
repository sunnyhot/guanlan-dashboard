import XCTest
@testable import QiemanDashboard

final class MainWindowZoomPolicyTests: XCTestCase {
    func testMaximizedFrameKeepsMenuBarInsetAndFillsDockReservedBottom() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_200)
        let visibleFrame = CGRect(x: 0, y: 88, width: 1_920, height: 1_088)

        XCTAssertEqual(
            MainWindowZoomPolicy.maximizedFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame
            ),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_176)
        )
    }

    func testMaximizedFrameUsesWholeScreenWhenMenuBarIsHidden() {
        let screenFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)

        XCTAssertEqual(
            MainWindowZoomPolicy.maximizedFrame(
                screenFrame: screenFrame,
                visibleFrame: screenFrame
            ),
            screenFrame
        )
    }

    func testFrameMatchingAllowsSubpixelWindowRounding() {
        let target = CGRect(x: 0, y: 0, width: 1_920, height: 1_176)

        XCTAssertTrue(
            MainWindowZoomPolicy.framesMatch(
                CGRect(x: 0.4, y: -0.4, width: 1_919.6, height: 1_176.4),
                target
            )
        )
        XCTAssertFalse(
            MainWindowZoomPolicy.framesMatch(
                CGRect(x: 0, y: 0, width: 1_880, height: 1_176),
                target
            )
        )
    }

    func testBothDoubleClickEntryPointsUseWorkspaceFillingZoom() throws {
        let appSource = try String(contentsOf: sourceURL("QiemanDashboardApp.swift"), encoding: .utf8)
        let contentSource = try String(contentsOf: sourceURL("Views_macOS/ContentView.swift"), encoding: .utf8)

        XCTAssertTrue(appSource.contains("toggleMainWindowZoom(win)"))
        XCTAssertTrue(contentSource.contains("delegate.toggleMainWindowZoom(mainWin)"))
    }

    func testUnifiedToolbarBandAcceptsClicksBelowNativeTitlebarHeight() {
        let contentHeight: CGFloat = 800
        let nativeTitlebarHeight: CGFloat = 28

        XCTAssertTrue(
            MainWindowZoomPolicy.isInDoubleClickZoomBand(
                clickY: 730,
                contentHeight: contentHeight,
                nativeTitlebarHeight: nativeTitlebarHeight
            )
        )
    }

    func testContentAreaBelowToolbarBandIsNotZoomRegion() {
        XCTAssertFalse(
            MainWindowZoomPolicy.isInDoubleClickZoomBand(
                clickY: 680,
                contentHeight: 800,
                nativeTitlebarHeight: 28
            )
        )
    }

    private func sourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }
}
