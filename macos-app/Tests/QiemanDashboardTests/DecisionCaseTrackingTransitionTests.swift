import XCTest
@testable import QiemanDashboard

// MARK: - 行动候选 → 决策案例转换测试(#12 sunset 方案 A)
//
// 写入切换的核心契约:
// 1. 按钮建案用 trend: 键,与旧迁移的 legacy: 键互为去重——同一动作只保留一案;
// 2. 自然语言条件进 detail 并标注人工复核,不预设复查时间;
// 3. 案例类型为 trendAction,把握档位用统一 ConfidenceGrade 文案。

@MainActor
final class DecisionCaseTrackingTransitionTests: XCTestCase {
    private func candidate(
        targetName: String = "沪深300增强",
        kind: TrendActionKind = .considerIncrease
    ) -> TrendActionCandidate {
        TrendActionCandidate(
            id: "r1",
            kind: kind,
            title: "加仓",
            detail: "估值回到低估区间",
            targetName: targetName,
            confidence: TrendConfidence(score: 78, label: "高"),
            triggerConditions: ["缩量企稳"],
            invalidatingConditions: ["跌破前低"]
        )
    }

    private func report() -> TrendAnalysisReport {
        TrendAnalysisReport.fixture(
            generatedAt: "2026-08-19 20:00:00",
            externalSignalStatus: .available
        )
    }

    func testAddDecisionCaseCreatesTrendActionCase() {
        let model = AppModel()
        XCTAssertTrue(model.addDecisionCase(from: candidate(), report: report()))
        XCTAssertEqual(model.decisionCases.count, 1)

        let created = model.decisionCases[0]
        XCTAssertEqual(created.kind, .trendAction)
        XCTAssertEqual(created.lifecycle, .monitoring)
        XCTAssertEqual(created.decisionState, .watch)
        XCTAssertEqual(created.userDisposition, .acknowledged)
        XCTAssertEqual(created.title, "沪深300增强 · \(TrendActionKind.considerIncrease.displayText)")
        XCTAssertEqual(created.metricLabel, "把握 较高 78")
        XCTAssertTrue(created.detail.contains("触发条件(人工复核):缩量企稳"))
        XCTAssertTrue(created.detail.contains("失效条件(人工复核):跌破前低"))
        XCTAssertTrue(created.detail.contains("不自动触发"))
        XCTAssertNil(created.reviewDueAt, "复查时间不预设,由用户在判断与复盘里设定")
        XCTAssertEqual(created.events.first?.type, .created)
        XCTAssertEqual(created.events.first?.actor, .user)
    }

    func testSameActionDeduplicates() {
        let model = AppModel()
        XCTAssertTrue(model.addDecisionCase(from: candidate(), report: report()))
        XCTAssertFalse(model.addDecisionCase(from: candidate(), report: report()))
        XCTAssertEqual(model.decisionCases.count, 1)
        XCTAssertTrue(model.hasDecisionCase(for: candidate(), report: report()))
    }

    func testNewKeyDeduplicatesAgainstMigratedLegacyKey() {
        // 场景:旧跟踪项已迁移成 legacy: 案例;用户再按同一动作的「加入关注」不得重复建案。
        let model = AppModel()
        let subjectID = "沪深300增强".lowercased()
        let legacyKey = "legacy:\(TrendActionKind.considerIncrease.rawValue)|\(subjectID)"
        model.decisionCases = [
            DecisionCase(
                caseKey: legacyKey,
                kind: .trendAction,
                dimension: .directHolding,
                subjectName: "沪深300增强",
                subjectCode: nil,
                lifecycle: .monitoring,
                decisionState: .watch,
                metricValue: 70,
                metricLabel: "把握 较高 70",
                metricDescription: "迁移自旧跟踪",
                title: "沪深300增强 · 考虑加仓",
                detail: "旧项",
                createdAt: "2026-08-01 21:00:00",
                updatedAt: "2026-08-01 21:00:00"
            )
        ]

        XCTAssertFalse(model.addDecisionCase(from: candidate(), report: report()))
        XCTAssertEqual(model.decisionCases.count, 1, "legacy 键命中时不得新建")
        XCTAssertTrue(model.hasDecisionCase(for: candidate(), report: report()))
    }

    func testDifferentActionOrSubjectCreatesSeparateCase() {
        let model = AppModel()
        XCTAssertTrue(model.addDecisionCase(from: candidate(), report: report()))
        XCTAssertTrue(
            model.addDecisionCase(
                from: candidate(targetName: "中证红利"),
                report: report()
            )
        )
        XCTAssertTrue(
            model.addDecisionCase(
                from: candidate(kind: .observeInBatches),
                report: report()
            )
        )
        XCTAssertEqual(model.decisionCases.count, 3)
    }
}
