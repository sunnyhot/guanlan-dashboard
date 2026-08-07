import XCTest
@testable import QiemanDashboard

@MainActor
final class EnhancementRoutingTests: XCTestCase {

    func testLegacyTradeSignalsDeepLinkOpensEnhancement() {
        let model = AppModel()
        let payload = NotificationDeepLinkPayload(type: .workbenchTrend, targetID: "trade-signals")
        model.handleNotificationDeepLink(payload)
        XCTAssertEqual(model.selectedSection, .enhancement)
    }

    func testUnknownTargetIDOpensEnhancement() {
        let model = AppModel()
        let payload = NotificationDeepLinkPayload(type: .workbenchTrend, targetID: "does-not-exist")
        model.handleNotificationDeepLink(payload)
        XCTAssertEqual(model.selectedSection, .enhancement)
    }

    func testTrackingUUIDDeepLinkSelectsItem() {
        let model = AppModel()
        model.dataDirectoryURL = temporaryDirectory()
        let action = TrendActionCandidate(
            id: "r1", kind: .considerIncrease, title: "加仓", detail: "理由",
            targetName: "基金X",
            confidence: TrendConfidence(score: 70, label: "中"),
            triggerConditions: [], invalidatingConditions: []
        )
        XCTAssertTrue(model.addTrackingItem(from: action, report: TrendAnalysisReport.fixture(generatedAt: "2026-07-23 10:00:00", externalSignalStatus: .available)))
        let id = model.trendTrackingItems[0].id

        let payload = NotificationDeepLinkPayload(type: .workbenchTrend, targetID: id.uuidString)
        model.handleNotificationDeepLink(payload)
        XCTAssertEqual(model.selectedSection, .enhancement)
        XCTAssertEqual(model.selectedTrendTrackingItemID, id)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
