import XCTest
@testable import QiemanDashboard

final class ManagerWatchTimelineTests: XCTestCase {
    func testLegacySettingsMigrateLongWinSelectionAndBaseline() throws {
        let data = Data(
            """
            {
              "isEnabled": true,
              "intervalMinutes": 10,
              "prodCode": "LONG_WIN",
              "managerName": "ETF拯救世界",
              "watchPlatform": true,
              "watchForum": true,
              "latestSeenPlatformActionID": "legacy-action",
              "latestSeenForumRecordID": "legacy-post"
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(ManagerWatchSettings.self, from: data)

        XCTAssertEqual(settings.selectedAdjustmentSourceIDs, [ManagerWatchAdjustmentSource.longWinID])
        XCTAssertEqual(
            settings.latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID],
            "legacy-action"
        )
        XCTAssertEqual(settings.latestSeenForumRecordID, "legacy-post")
        XCTAssertTrue(settings.notificationsEnabled)
    }

    func testSettingsRoundTripPreservesMultipleAdjustmentSources() throws {
        let sourceID = "\(ManagerWatchAdjustmentSource.alfaIDPrefix)SI000192"
        let original = ManagerWatchSettings(
            selectedAdjustmentSourceIDs: [
                ManagerWatchAdjustmentSource.longWinID,
                sourceID,
            ],
            latestSeenAdjustmentIDs: [
                ManagerWatchAdjustmentSource.longWinID: "long-win-action",
                sourceID: "alfa-action",
            ],
            adjustmentBaselineTargetKeys: [
                ManagerWatchAdjustmentSource.longWinID: "long_win|LONG_WIN",
                sourceID: "\(sourceID)|SI000192",
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ManagerWatchSettings.self, from: data)

        XCTAssertEqual(decoded.selectedAdjustmentSourceIDs, original.selectedAdjustmentSourceIDs)
        XCTAssertEqual(decoded.latestSeenAdjustmentIDs, original.latestSeenAdjustmentIDs)
        XCTAssertEqual(decoded.adjustmentBaselineTargetKeys, original.adjustmentBaselineTargetKeys)
    }

    @MainActor
    func testUnseenItemsRequiresBaselineAndCapsRecoveryWindow() {
        struct Item: Identifiable {
            let id: String
        }
        let model = AppModel()
        let items = (0..<30).map { Item(id: "\($0)") }

        XCTAssertTrue(
            model.unseenItems(items, previousID: "5", baselineEstablished: false).isEmpty
        )
        XCTAssertEqual(
            model.unseenItems(items, previousID: "5", baselineEstablished: true).map(\.id),
            ["0", "1", "2", "3", "4"]
        )
        XCTAssertEqual(
            model.unseenItems(items, previousID: "missing", baselineEstablished: true).count,
            20
        )
    }

    @MainActor
    func testChangingAdjustmentSelectionClearsOnlyThatSourceBaseline() {
        let model = AppModel()
        let alfa = ManagerWatchAdjustmentSource.alfa(code: "SI000192", name: "基金全磊打")
        model.managerWatchSettings.selectedAdjustmentSourceIDs = [
            ManagerWatchAdjustmentSource.longWinID,
            alfa.id,
        ]
        model.managerWatchSettings.latestSeenAdjustmentIDs = [
            ManagerWatchAdjustmentSource.longWinID: "long-win",
            alfa.id: "alfa",
        ]
        model.managerWatchSettings.adjustmentBaselineTargetKeys = [
            ManagerWatchAdjustmentSource.longWinID: "long-win-key",
            alfa.id: "alfa-key",
        ]

        model.updateManagerWatchAdjustmentSource(alfa, isSelected: false)

        XCTAssertEqual(
            model.managerWatchSettings.selectedAdjustmentSourceIDs,
            [ManagerWatchAdjustmentSource.longWinID]
        )
        XCTAssertEqual(
            model.managerWatchSettings.latestSeenAdjustmentIDs[ManagerWatchAdjustmentSource.longWinID],
            "long-win"
        )
        XCTAssertNil(model.managerWatchSettings.latestSeenAdjustmentIDs[alfa.id])
        XCTAssertNil(model.managerWatchSettings.adjustmentBaselineTargetKeys[alfa.id])
    }

    func testAdjustmentDeepLinkRoundTripsSourceIdentity() throws {
        let payload = NotificationDeepLinkPayload(
            type: .platformAction,
            targetID: "action-id",
            adjustmentSourceKind: .alfa,
            adjustmentSourceCode: "SI000192"
        )

        let decoded = try XCTUnwrap(NotificationDeepLinkPayload(userInfo: payload.userInfo))

        XCTAssertEqual(decoded.adjustmentSourceKind, .alfa)
        XCTAssertEqual(decoded.adjustmentSourceCode, "SI000192")
        XCTAssertEqual(decoded.targetID, "action-id")
    }

    func testTrendManagerSignalsDoNotDuplicateStructuredAdjustmentSignals() {
        let forum = event(kind: .forumHit, title: "论坛命中")
        let adjustment = event(kind: .platformHit, title: "调仓命中")

        let signals = TrendResearchSnapshotBuilder.managerSignals(from: [forum, adjustment])

        XCTAssertEqual(signals.map(\.title), ["论坛命中"])
    }

    func testSummaryOrdersEventsNewestFirst() {
        let old = event(kind: .pollStarted, occurredAt: date("2026-06-12T01:00:00Z"), title: "旧")
        let new = event(kind: .platformHit, occurredAt: date("2026-06-12T02:00:00Z"), title: "新")

        let summary = ManagerWatchTimelineSummary.make(events: [old, new])

        XCTAssertEqual(summary.events.map(\.title), ["新", "旧"])
        XCTAssertEqual(summary.latestStatusText, "新")
    }

    func testPruneKeepsMaxCountAndAge() {
        let now = date("2026-06-12T00:00:00Z")
        var events: [ManagerWatchTimelineEvent] = []
        for offset in 0..<205 {
            events.append(event(kind: .pollStarted, occurredAt: now.addingTimeInterval(TimeInterval(-offset * 60)), title: "\(offset)"))
        }
        events.append(event(kind: .failed, occurredAt: date("2026-02-01T00:00:00Z"), title: "过期"))

        let pruned = ManagerWatchTimelineStore.pruned(events, now: now, maxCount: 200, maxAgeDays: 90)

        XCTAssertEqual(pruned.count, 200)
        XCTAssertFalse(pruned.contains { $0.title == "过期" })
        XCTAssertEqual(pruned.first?.title, "0")
    }

    func testDuplicateSuppressionIsNotFailure() {
        let summary = ManagerWatchTimelineSummary.make(events: [
            event(kind: .duplicateSuppressed, title: "没有新发言")
        ])

        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(summary.events.first?.tone, .info)
    }

    func testFailureAndRecoveryAffectSummary() {
        let failed = event(kind: .failed, occurredAt: date("2026-06-12T01:00:00Z"), title: "巡检失败", errorMessage: "网络错误")
        let recovered = event(kind: .recovered, occurredAt: date("2026-06-12T02:00:00Z"), title: "巡检恢复")

        let summary = ManagerWatchTimelineSummary.make(events: [failed, recovered])

        XCTAssertEqual(summary.latestStatusText, "巡检恢复")
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.events.first?.tone, .positive)
        XCTAssertEqual(summary.events.last?.errorMessage, "网络错误")
    }

    func testStoreAppendPersistsAndPrunes() throws {
        let fileURL = try temporaryDirectory().appendingPathComponent("manager-watch-timeline.json")
        let store = ManagerWatchTimelineStore()

        try store.append(
            event(kind: .pollStarted, occurredAt: date("2026-06-12T00:00:00Z"), title: "开始"),
            to: fileURL,
            now: date("2026-06-12T00:00:00Z")
        )
        try store.append(
            event(kind: .platformHit, occurredAt: date("2026-06-12T00:01:00Z"), title: "命中调仓"),
            to: fileURL,
            now: date("2026-06-12T00:01:00Z")
        )

        let loaded = try store.load(from: fileURL)

        XCTAssertEqual(loaded.map(\.title), ["命中调仓", "开始"])
    }

    private func event(
        kind: ManagerWatchTimelineEventKind,
        occurredAt: Date = Date(timeIntervalSince1970: 1_781_217_600),
        title: String,
        errorMessage: String? = nil
    ) -> ManagerWatchTimelineEvent {
        ManagerWatchTimelineEvent(
            kind: kind,
            occurredAt: occurredAt,
            prodCode: "LONG_WIN",
            managerName: "ETF拯救世界",
            title: title,
            detail: "详情",
            targetID: nil,
            errorMessage: errorMessage
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-watch-timeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
