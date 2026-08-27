import XCTest
@testable import QiemanDashboard

// MARK: - DecisionCaseEngine 测试（审计 A2/A3）
//
// 覆盖：阈值判定（preliminaryState）、四类建案（集中度四维 / 回撤 /
// 目标偏离 / 覆盖不足降级）、合并状态机（墓碑 / 重开 / 自动关闭 /
// acknowledged 续期）、复盘流转（六选一）、行动候选建案。

final class DecisionCaseEngineTests: XCTestCase {

    private let engine = DecisionCaseEngine(policy: .default)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeInput(
        positions: [DecisionCaseEngine.PositionInput] = [],
        lookThrough: DecisionCaseEngine.LookThroughInput? = nil,
        deviations: [DecisionCaseEngine.DeviationInput] = []
    ) -> DecisionCaseEngine.Input {
        DecisionCaseEngine.Input(
            positions: positions, lookThrough: lookThrough,
            deviations: deviations, asOf: now)
    }

    // MARK: - 阈值判定

    func testPreliminaryStateTiers() {
        let policy = DecisionCasePolicy.default
        // 集中度默认：watch 30 / review 50 / proximity 5
        XCTAssertEqual(policy.preliminaryState(value: 55, watch: 30, review: 50, hasData: true), .adjustReview)
        XCTAssertEqual(policy.preliminaryState(value: 47, watch: 30, review: 50, hasData: true), .prepare)
        XCTAssertEqual(policy.preliminaryState(value: 31, watch: 30, review: 50, hasData: true), .watch)
        XCTAssertEqual(policy.preliminaryState(value: 12, watch: 30, review: 50, hasData: true), .stable)
        XCTAssertEqual(policy.preliminaryState(value: 99, watch: 30, review: 50, hasData: false), .insufficientEvidence)
    }

    // MARK: - 建案

    func testDirectHoldingConcentrationCreatesCase() {
        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 5),
            .init(name: "基金B", code: "000002", weightPct: 45, profitPct: 3),
        ]))
        let direct = drafts.first { $0.dimension == .directHolding && $0.kind == .concentrationRisk }
        XCTAssertNotNil(direct, "top1=55% ≥ review50 应建直接持仓集中案")
        XCTAssertEqual(direct?.decisionState, .adjustReview)
        XCTAssertEqual(direct?.metricValue ?? 0, 55, accuracy: 0.001)
        XCTAssertEqual(direct?.lifecycle, .decisionReady)
        XCTAssertNotNil(direct?.triggerCondition)
        XCTAssertNotNil(direct?.invalidationCondition)
        XCTAssertEqual(direct?.events.last?.type, .created)
    }

    func testStablePortfolioCreatesNoCases() {
        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 25, profitPct: 5),
            .init(name: "基金B", code: "000002", weightPct: 25, profitPct: 3),
            .init(name: "基金C", code: "000003", weightPct: 25, profitPct: 1),
            .init(name: "基金D", code: "000004", weightPct: 25, profitPct: 2),
        ]))
        XCTAssertTrue(drafts.isEmpty, "全部指标在阈值内不应建案")
    }

    func testLookThroughDimensions() {
        let lookThrough = DecisionCaseEngine.LookThroughInput(
            coverage: 0.9,
            topUnderlyings: [
                .init(name: "贵州茅台", code: "600519", weightPct: 22, contributorCount: 1),
                .init(name: "宁德时代", code: "300750", weightPct: 18, contributorCount: 3),
            ],
            industries: [.init(label: "白酒", weightPct: 28)])
        let drafts = engine.evaluate(makeInput(
            positions: [
                .init(name: "基金A", code: "F1", weightPct: 60, profitPct: 2),
                .init(name: "基金B", code: "F2", weightPct: 40, profitPct: 2),
            ],
            lookThrough: lookThrough))
        // 直接持仓 60% → adjustReview；穿透单标的 22% ≥ watch20 → watch；
        // 重叠 18% ≥ watch15 → watch；行业 28% ≥ watch25 → watch
        XCTAssertEqual(drafts.filter { $0.kind == .concentrationRisk }.count, 4)
        XCTAssertTrue(drafts.contains { $0.dimension == .lookThrough && $0.metricValue == 22 })
        XCTAssertTrue(drafts.contains { $0.dimension == .lookThroughOverlap && $0.metricValue == 18 })
        XCTAssertTrue(drafts.contains { $0.dimension == .sector && $0.metricValue == 28 })
    }

    func testLowCoverageDowngradesToInsufficientEvidence() {
        let lookThrough = DecisionCaseEngine.LookThroughInput(
            coverage: 0.4,
            topUnderlyings: [.init(name: "X", code: "X1", weightPct: 30, contributorCount: 2)],
            industries: [])
        let drafts = engine.evaluate(makeInput(
            positions: [.init(name: "基金A", code: "F1", weightPct: 100, profitPct: 0)],
            lookThrough: lookThrough))
        XCTAssertEqual(
            drafts.filter { $0.kind == .concentrationRisk && $0.dimension == .lookThrough }.count, 1)
        let insufficient = drafts.first { $0.decisionState == .insufficientEvidence }
        XCTAssertNotNil(insufficient, "覆盖 40% < 70% 下限应产出占位案")
        // 占位案垫底
        XCTAssertEqual(drafts.last?.decisionState, .insufficientEvidence)
    }

    func testDrawdownExpansionCase() {
        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "F1", weightPct: 20, profitPct: -18),
            .init(name: "基金B", code: "F2", weightPct: 80, profitPct: 3),
        ]))
        let drawdown = drafts.first { $0.kind == .drawdownExpansion }
        XCTAssertNotNil(drawdown, "|−18%| ≥ watch15 应建回撤案")
        XCTAssertEqual(drawdown?.decisionState, .watch)
    }

    func testTargetDeviationCase() {
        let drafts = engine.evaluate(makeInput(deviations: [
            .init(assetClassLabel: "股票", currentPct: 55, targetPct: 40),
        ]))
        let deviation = drafts.first { $0.kind == .targetDeviation }
        XCTAssertNotNil(deviation, "偏离 15pp ≥ review15 应建目标偏离案")
        XCTAssertEqual(deviation?.decisionState, .adjustReview)
        XCTAssertEqual(deviation?.metricValue ?? 0, 15, accuracy: 0.001)
    }

    // MARK: - 合并状态机

    func testMergeNewDraftAppendedAndPendingAutoClosed() {
        let existingCase = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
            .init(name: "基金B", code: "000002", weightPct: 45, profitPct: 2),
        ])).first!
        // 风险消退：新评估无案 → pending 自动关闭
        let merged = DecisionCaseEngine.merge(
            existing: [existingCase], incoming: [], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].lifecycle, .closed)
        XCTAssertEqual(merged[0].events.last?.reason, "风险指标已回到阈值内，自动关闭")

        // 风险再现 → 重开（保留 id / createdAt / events）
        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
            .init(name: "基金B", code: "000002", weightPct: 45, profitPct: 2),
        ]))
        let reopened = DecisionCaseEngine.merge(existing: merged, incoming: drafts, now: now)
        XCTAssertEqual(reopened[0].lifecycle, .decisionReady)
        XCTAssertEqual(reopened[0].id, existingCase.id)
        XCTAssertEqual(reopened[0].createdAt, existingCase.createdAt)
        XCTAssertGreaterThan(reopened[0].events.count, existingCase.events.count)
    }

    func testMergeUserClosedIsTombstone() {
        var closedByUser = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
        ])).first!
        closedByUser.userDisposition = .closed
        closedByUser.lifecycle = .closed

        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
        ]))
        let merged = DecisionCaseEngine.merge(existing: [closedByUser], incoming: drafts, now: now)
        XCTAssertEqual(merged.count, 1, "墓碑事项不复活、也不重复建案")
        XCTAssertEqual(merged[0].lifecycle, .closed)
        XCTAssertEqual(merged[0].userDisposition, .closed)
    }

    func testMergeAcknowledgedKeepsMonitoringAndRenews() {
        var acknowledged = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 35, profitPct: 2),
        ])).first!
        acknowledged.userDisposition = .acknowledged
        acknowledged.lifecycle = .monitoring
        acknowledged.reviewDueAt = now.addingTimeInterval(3600)

        // 指标显著变化（35% → 36%）→ acknowledged 案复查时钟重置
        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 36, profitPct: 2),
        ]))
        let merged = DecisionCaseEngine.merge(existing: [acknowledged], incoming: drafts, now: now)
        XCTAssertEqual(merged[0].lifecycle, .monitoring)
        XCTAssertNotNil(merged[0].reviewDueAt)
        // watch 状态 7 天复查
        XCTAssertEqual(
            merged[0].reviewDueAt?.timeIntervalSince(now) ?? 0,
            7 * 86400, accuracy: 60)
    }

    func testMergeMonitoringPastDueBecomesReviewDue() {
        var monitored = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 35, profitPct: 2),
        ])).first!
        monitored.userDisposition = .acknowledged
        monitored.lifecycle = .monitoring
        monitored.reviewDueAt = now.addingTimeInterval(-10)

        let drafts = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 35, profitPct: 2),
        ]))
        let merged = DecisionCaseEngine.merge(existing: [monitored], incoming: drafts, now: now)
        XCTAssertEqual(merged[0].lifecycle, .reviewDue)
    }

    // MARK: - 复盘流转

    func testApplyReviewSupportedReturnsToMonitoring() {
        var monitored = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 35, profitPct: 2),
        ])).first!
        monitored.lifecycle = .reviewDue
        let review = DecisionReview(
            caseID: monitored.id, reviewedAt: now,
            originalDecisionState: monitored.decisionState,
            originalMetricValue: monitored.metricValue,
            currentMetricValue: 34,
            conclusion: .supported, lessons: "验证了观察")
        let updated = DecisionCaseEngine.applyReview(review, to: monitored, now: now)
        XCTAssertEqual(updated.lifecycle, .monitoring)
        XCTAssertEqual(updated.reviews.count, 1)
        XCTAssertNotNil(updated.reviewDueAt)
    }

    func testApplyReviewContradictedCloses() {
        let pending = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
        ])).first!
        let review = DecisionReview(
            caseID: pending.id, reviewedAt: now,
            originalDecisionState: pending.decisionState,
            originalMetricValue: pending.metricValue,
            currentMetricValue: 20,
            conclusion: .contradicted, lessons: "")
        let updated = DecisionCaseEngine.applyReview(review, to: pending, now: now)
        XCTAssertEqual(updated.lifecycle, .closed)
        XCTAssertEqual(updated.userDisposition, .resolved)
        XCTAssertNil(updated.reviewDueAt)
    }

    func testApplyReviewInsufficientDataShortensReview() {
        let pending = engine.evaluate(makeInput(positions: [
            .init(name: "基金A", code: "000001", weightPct: 55, profitPct: 2),
        ])).first!
        let review = DecisionReview(
            caseID: pending.id, reviewedAt: now,
            originalDecisionState: pending.decisionState,
            originalMetricValue: pending.metricValue,
            currentMetricValue: pending.metricValue,
            conclusion: .insufficientData)
        let updated = DecisionCaseEngine.applyReview(review, to: pending, now: now)
        XCTAssertEqual(updated.lifecycle, .monitoring)
        XCTAssertEqual(
            updated.reviewDueAt?.timeIntervalSince(now) ?? 0, 3 * 86400, accuracy: 60)
    }

    // MARK: - 行动候选建案（B3）

    func testMakeActionMigrationCase() {
        let draft = DecisionCaseEngine.makeActionMigrationCase(
            subjectName: "沪深300",
            subjectCode: "000300",
            directionText: "增持",
            rationale: "动量与估值双修复",
            trigger: "突破年线",
            invalidation: "跌破前低",
            sourceArtifactID: "dec_abc",
            at: now)
        XCTAssertEqual(draft.kind, .actionMigration)
        XCTAssertEqual(draft.lifecycle, .monitoring)
        XCTAssertEqual(draft.userDisposition, .acknowledged)
        XCTAssertTrue(draft.detail.contains("dec_abc"))
        XCTAssertTrue(draft.detail.contains("人工复核"))
        // 确定性：同输入同 ID
        let again = DecisionCaseEngine.makeActionMigrationCase(
            subjectName: "沪深300",
            subjectCode: "000300",
            directionText: "增持",
            rationale: "动量与估值双修复",
            trigger: "突破年线",
            invalidation: "跌破前低",
            sourceArtifactID: "dec_abc",
            at: now)
        XCTAssertEqual(draft.id, again.id)
    }

    // MARK: - caseKey / 复查时间

    func testCaseKeyStability() {
        let byCode = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: "000001", subjectName: "基金A")
        let byName = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: nil, subjectName: "基金A")
        XCTAssertEqual(byCode, "concentrationRisk|directHolding|000001")
        XCTAssertEqual(byName, "concentrationRisk|directHolding|基金a")
        // 同 caseKey → 同 ID
        XCTAssertEqual(
            DecisionCase.makeCaseID(caseKey: byCode),
            DecisionCase.makeCaseID(caseKey: byCode))
    }

    func testComputeReviewDueAtTiers() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .watch, from: base)?
                .timeIntervalSince(base) ?? 0, 7 * 86400, accuracy: 60)
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .prepare, from: base)?
                .timeIntervalSince(base) ?? 0, 3 * 86400, accuracy: 60)
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .insufficientEvidence, from: base)?
                .timeIntervalSince(base) ?? 0, 3 * 86400, accuracy: 60)
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .adjustReview, from: base)?
                .timeIntervalSince(base) ?? 0, 1 * 86400, accuracy: 60)
        XCTAssertNil(DecisionCase.computeReviewDueAt(decisionState: .stable, from: base))
    }
}
