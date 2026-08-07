import Foundation
import XCTest
@testable import QiemanDashboard

// DecisionCase 研究 AppModel 集成测试。
//
// 验证 applyResearchReport 的本地 Policy 校验:
// - 强行动建议在 Profile 不允许时降级 watch
// - Evidence 防伪造(引用 Ledger 不存在的 ID 被丢弃)
// 见 Slice 3 设计。
@MainActor
final class DecisionCaseResearchActionsTests: XCTestCase {

    private func makeModel() -> AppModel {
        let model = AppModel()
        model.dataDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-test-\(UUID().uuidString)", isDirectory: true)
        return model
    }

    private func makeCase(state: PortfolioDecisionState = .watch) -> DecisionCase {
        DecisionCase(
            caseKey: "concentrationRisk|directHolding|001000",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "测试基金", subjectCode: "001000",
            lifecycle: .decisionReady,
            decisionState: state,
            metricValue: 42, metricLabel: "42.0%",
            metricDescription: "第一大标的占比",
            title: "集中度测试", detail: "测试",
            createdAt: "2026-08-05 10:00:00", updatedAt: "2026-08-05 10:00:00"
        )
    }

    // MARK: - 强行动建议降级

    func testApplyReportDowngradesAdjustReviewWhenProfileDisallows() {
        let model = makeModel()
        model.userDecisionProfile = .default  // 不允许强行动
        model.decisionCases = [makeCase(state: .prepare)]  // 初始 prepare,降级后有变化

        let report = DecisionCaseResearchReport(
            caseID: model.decisionCases[0].id,
            generatedAt: "2026-08-05 10:00:00",
            findings: [],
            counterFindings: [],
            uncertainties: [],
            evidence: [],
            suggestedState: .adjustReview,  // Agent 建议强行动
            rationale: "建议调整"
        )
        model.applyResearchReport(report, to: model.decisionCases[0].id)

        // Profile 不允许 → 降级 watch(prepare → watch,有变化)
        XCTAssertEqual(model.decisionCases[0].decisionState, .watch)
        let lastEvent = model.decisionCases[0].events.last
        XCTAssertEqual(lastEvent?.newDecisionState, .watch)
        XCTAssertTrue(lastEvent?.reason.contains("降级") ?? false, "应记录降级原因")
    }

    func testApplyReportKeepsAdjustReviewWhenProfileAllows() {
        let model = makeModel()
        model.userDecisionProfile = UserDecisionProfile(
            allowsActiveRebalancing: true, isCustomized: true
        )
        model.decisionCases = [makeCase(state: .watch)]

        let report = DecisionCaseResearchReport(
            caseID: model.decisionCases[0].id,
            generatedAt: "2026-08-05 10:00:00",
            suggestedState: .adjustReview,
            rationale: "建议调整"
        )
        model.applyResearchReport(report, to: model.decisionCases[0].id)

        XCTAssertEqual(model.decisionCases[0].decisionState, .adjustReview)
    }

    // MARK: - 状态不变时不追加事件

    func testApplyReportSavesEvenWhenStateUnchanged() {
        // Step 2:状态不变也保存研究报告 + 追加事件
        let model = makeModel()
        model.decisionCases = [makeCase(state: .watch)]
        let initialEventCount = model.decisionCases[0].events.count

        let report = DecisionCaseResearchReport(
            caseID: model.decisionCases[0].id,
            generatedAt: "2026-08-05 10:00:00",
            suggestedState: .watch,  // 与当前相同
            rationale: "维持观察"
        )
        model.applyResearchReport(report, to: model.decisionCases[0].id)

        // 状态不变,但仍追加事件 + 保存报告
        XCTAssertEqual(model.decisionCases[0].events.count, initialEventCount + 1, "状态不变也应记录研究完成事件")
        XCTAssertNotNil(model.lastDecisionCaseResearchReports[model.decisionCases[0].id], "研究报告应保存")
    }

    // MARK: - 研究报告存储

    func testApplyReportStoresReportForUI() {
        let model = makeModel()
        model.decisionCases = [makeCase(state: .watch)]
        let caseID = model.decisionCases[0].id

        let report = DecisionCaseResearchReport(
            caseID: caseID,
            generatedAt: "2026-08-05 10:00:00",
            findings: [ResearchFinding(claim: "发现1", direction: .supportive, significance: .high, evidenceIDs: [])],
            suggestedState: .watch,
            rationale: "测试"
        )
        model.applyResearchReport(report, to: caseID)

        XCTAssertNotNil(model.lastDecisionCaseResearchReports[caseID], "研究报告应存储供 UI 展示")
        XCTAssertEqual(model.lastDecisionCaseResearchReports[caseID]?.findings.count, 1)
    }
}
