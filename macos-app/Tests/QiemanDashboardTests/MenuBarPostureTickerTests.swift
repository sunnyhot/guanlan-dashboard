import XCTest
@testable import QiemanDashboard

// MARK: - 菜单栏 AI 姿态条目测试(P4 #7)
//
// 条目构建直接用内存 settings 调 menuBarTickerCandidateEntries,不经持久化;
// 有效期用「过去/未来的完整日期」避开真实时钟边界,保证确定性。

@MainActor
final class MenuBarPostureTickerTests: XCTestCase {
    private func postureSettings() -> MenuBarTickerSettings {
        MenuBarTickerSettings(
            isEnabled: true,
            maxVisibleItems: 2,
            selections: [.kind(.aiPosture)]
        )
    }

    private func report(validUntil: String) -> NextHourGuidanceReport {
        NextHourGuidanceReport(
            generatedAt: "2026-08-19 14:00:00",
            validUntil: validUntil,
            slotKey: "2026-08-19 14:00",
            scope: .closingWindow,
            headline: "收盘前以复核为主",
            posture: .balanced,
            summary: "场外基金只在此窗口参与。",
            actions: [],
            riskChecks: [],
            assetCount: 1
        )
    }

    func testKindHasLabelAndDetailAndIsOffByDefault() {
        XCTAssertFalse(MenuBarTickerKind.aiPosture.label.isEmpty)
        XCTAssertFalse(MenuBarTickerKind.aiPosture.detail.isEmpty)
        XCTAssertNil(MenuBarTickerKind.aiPosture.marketIndexRequest)
        XCTAssertFalse(
            MenuBarTickerSettings.default.selections.contains { $0.kindValue == .aiPosture },
            "AI 姿态默认关闭,由用户主动开启"
        )
    }

    func testNoReportShowsHonestPlaceholder() {
        let model = AppModel()
        let entries = model.menuBarTickerCandidateEntries(settings: postureSettings())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.compactText, "AI·暂无盘中研判")
        XCTAssertEqual(entries.first?.value, "暂无")
    }

    func testValidReportShowsPostureWithExpiry() {
        let model = AppModel()
        model.nextHourGuidanceArchive = NextHourGuidanceArchive(
            report: report(validUntil: "2099-01-01 23:00"),
            lastAttemptedSlotKey: nil,
            lastCompletedSlotKey: nil
        )
        let entries = model.menuBarTickerCandidateEntries(settings: postureSettings())
        XCTAssertEqual(entries.first?.value, "均衡")
        XCTAssertEqual(entries.first?.compactText, "AI·均衡·至23:00")
        XCTAssertTrue(entries.first?.detail.contains("收盘前以复核为主") ?? false)
    }

    func testExpiredReportIsMarkedInsteadOfPretendingCurrent() {
        let model = AppModel()
        model.nextHourGuidanceArchive = NextHourGuidanceArchive(
            report: report(validUntil: "2020-01-01 10:00"),
            lastAttemptedSlotKey: nil,
            lastCompletedSlotKey: nil
        )
        let entries = model.menuBarTickerCandidateEntries(settings: postureSettings())
        XCTAssertEqual(entries.first?.compactText, "AI·均衡·已过期")
        XCTAssertTrue(entries.first?.detail.contains("已过有效期") ?? false)
    }
}
