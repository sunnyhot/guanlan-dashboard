import XCTest
@testable import QiemanDashboard

/// W3.1:链路 A 通知偏好与载荷测试——默认最小集、手动失败不打扰、旧设置宽容解码。
final class TrendNotificationPreferencesTests: XCTestCase {
    private func notice(
        scope: TrendResearchRunScope,
        outcome: TrendCompletionNotification.Outcome,
        userInitiated: Bool = false,
        isFirstReport: Bool = false,
        failureSummary: String? = nil
    ) -> TrendCompletionNotification {
        TrendCompletionNotification(
            scope: scope,
            outcome: outcome,
            userInitiated: userInitiated,
            isFirstReport: isFirstReport,
            opportunityCount: 3,
            failureSummary: failureSummary
        )
    }

    func testDefaultPrefsOnlyAllowCloseReviewSuccessAndAutoFailure() {
        let prefs = TrendNotificationPreferences.default
        XCTAssertTrue(prefs.wants(notice(scope: .closeReview, outcome: .succeeded)))
        XCTAssertTrue(prefs.wants(notice(scope: .marketRadar, outcome: .failed)))
        XCTAssertFalse(prefs.wants(notice(scope: .marketRadar, outcome: .succeeded)))
        XCTAssertFalse(prefs.wants(notice(scope: .longTerm, outcome: .succeeded)))
        XCTAssertFalse(prefs.wants(notice(scope: .full, outcome: .succeeded)))
    }

    func testManualRunsOnlyNotifyFirstReportWhenEnabled() {
        let allOff = TrendNotificationPreferences(
            closeReviewSuccessEnabled: false,
            autoFailureEnabled: false
        )
        XCTAssertFalse(allOff.wants(notice(scope: .marketRadar, outcome: .failed, userInitiated: true)))
        XCTAssertFalse(allOff.wants(notice(scope: .full, outcome: .succeeded, userInitiated: true)))

        let firstReportOn = TrendNotificationPreferences(firstReportEnabled: true)
        XCTAssertTrue(
            firstReportOn.wants(notice(scope: .full, outcome: .succeeded, userInitiated: true, isFirstReport: true))
        )
        // 同样手动、但已有旧报告 → 不再是「第一份」,不打扰。
        XCTAssertFalse(
            firstReportOn.wants(notice(scope: .full, outcome: .succeeded, userInitiated: true, isFirstReport: false))
        )
    }

    func testDecodeOldSettingsWithoutNotificationsUsesDefaults() throws {
        let settings = TrendAnalysisSettings(
            provider: .empty,
            defaultPrivacyMode: .sanitized,
            dailyAutoAnalysisEnabled: false
        )
        let data = try JSONEncoder().encode(settings)
        // 模拟旧版本落盘:去掉 notifications 键后应回退默认最小集。
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "notifications")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TrendAnalysisSettings.self, from: stripped)
        XCTAssertEqual(decoded.notifications, .default)
        XCTAssertTrue(decoded.notifications.closeReviewSuccessEnabled)
        XCTAssertTrue(decoded.notifications.autoFailureEnabled)
        XCTAssertFalse(decoded.notifications.marketRadarSuccessEnabled)
    }

    func testPartialNotificationsDecodeKeepsSpecifiedValues() throws {
        let settings = TrendAnalysisSettings(
            provider: .empty,
            defaultPrivacyMode: .sanitized,
            dailyAutoAnalysisEnabled: false
        )
        let data = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["notifications"] = ["marketRadarSuccessEnabled": true]
        let patched = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TrendAnalysisSettings.self, from: patched)
        XCTAssertTrue(decoded.notifications.marketRadarSuccessEnabled)
        XCTAssertTrue(decoded.notifications.autoFailureEnabled, "未写的键回退默认值")
    }

    func testPayloadTitleBodyAndAnchor() {
        let radar = notice(scope: .marketRadar, outcome: .succeeded)
        XCTAssertEqual(radar.title, "今日市场机会已更新")
        XCTAssertTrue(radar.body.contains("3 个方向"))
        XCTAssertEqual(radar.sectionAnchor, .marketRadar)

        let failed = notice(scope: .closeReview, outcome: .failed, failureSummary: "Key 无效")
        XCTAssertTrue(failed.title.contains("未完成"))
        XCTAssertTrue(failed.body.contains("手动补做"))
        XCTAssertTrue(failed.body.contains("Key 无效"))
        XCTAssertEqual(failed.sectionAnchor, .closeReview)

        let first = notice(scope: .full, outcome: .succeeded, userInitiated: true, isFirstReport: true)
        XCTAssertEqual(first.title, "你的第一份研判已生成")
    }
}
