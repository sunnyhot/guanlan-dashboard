import Foundation
import XCTest
@testable import QiemanDashboard

// DecisionCase 状态机与事件历史测试。
//
// 冻结状态转换的合法性和事件历史的追加语义。
// 见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 1 设计。
final class DecisionCaseStateMachineTests: XCTestCase {

    private let timestamp = "2026-08-05 10:00:00"

    // MARK: - caseKey 稳定性

    func testCaseKeyIsStableAndDedupable() {
        let key1 = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: "001000", subjectName: "基金A"
        )
        let key2 = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: "001000", subjectName: "不同名称"
        )
        // 同 code → 同 key(名称不影响)
        XCTAssertEqual(key1, key2)

        let key3 = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: nil, subjectName: "基金A"
        )
        let key4 = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: nil, subjectName: "基金A"
        )
        // 无 code 时用 name,同 name → 同 key
        XCTAssertEqual(key3, key4)
        XCTAssertNotEqual(key1, key3, "有 code 和无 code 的 key 应不同")
    }

    // MARK: - 状态转换 + 事件追加

    func testApplyTransitionAppendsEventAndUpdatesState() {
        var cs = makeCase(state: .watch, lifecycle: .decisionReady)
        XCTAssertEqual(cs.events.count, 0)

        cs.applyTransition(
            to: .monitoring,
            decisionState: .watch,
            at: timestamp,
            type: .userAcknowledged,
            reason: "用户确认关注",
            actor: .user
        )

        XCTAssertEqual(cs.lifecycle, .monitoring)
        XCTAssertEqual(cs.decisionState, .watch)
        XCTAssertEqual(cs.events.count, 1)
        XCTAssertEqual(cs.events.first?.type, .userAcknowledged)
        XCTAssertEqual(cs.events.first?.previousLifecycle, .decisionReady)
        XCTAssertEqual(cs.events.first?.newLifecycle, .monitoring)
        XCTAssertEqual(cs.events.first?.previousDecisionState, .watch)
        XCTAssertEqual(cs.events.first?.actor, .user)
        XCTAssertEqual(cs.updatedAt, timestamp)
    }

    func testMultipleTransitionsAppendInOrder() {
        var cs = makeCase(state: .watch, lifecycle: .decisionReady)

        cs.applyTransition(to: .monitoring, decisionState: .watch, at: "2026-08-05 10:00:00",
                           type: .userAcknowledged, reason: "关注", actor: .user)
        cs.applyTransition(to: .reviewDue, decisionState: .adjustReview, at: "2026-08-06 10:00:00",
                           type: .reassessed, reason: "阈值持续超标", actor: .system)
        cs.applyTransition(to: .closed, decisionState: .stable, at: "2026-08-07 10:00:00",
                           type: .userResolved, reason: "已减仓", actor: .user)

        XCTAssertEqual(cs.events.count, 3)
        // 验证事件按时间顺序追加
        XCTAssertEqual(cs.events.map(\.type), [.userAcknowledged, .reassessed, .userResolved])
        // 链式 previous/new 状态正确衔接
        XCTAssertEqual(cs.events[1].previousDecisionState, .watch)
        XCTAssertEqual(cs.events[1].newDecisionState, .adjustReview)
        XCTAssertEqual(cs.events[2].previousDecisionState, .adjustReview)
        XCTAssertEqual(cs.events[2].newDecisionState, .stable)
    }

    // MARK: - PortfolioDecisionState 约束

    func testStrongActionStatesRequireCompleteProfile() {
        XCTAssertTrue(PortfolioDecisionState.adjustReview.requiresCompleteProfile)
        XCTAssertTrue(PortfolioDecisionState.exitReview.requiresCompleteProfile)
        XCTAssertFalse(PortfolioDecisionState.stable.requiresCompleteProfile)
        XCTAssertFalse(PortfolioDecisionState.watch.requiresCompleteProfile)
        XCTAssertFalse(PortfolioDecisionState.prepare.requiresCompleteProfile)
        XCTAssertFalse(PortfolioDecisionState.insufficientEvidence.requiresCompleteProfile)
    }

    // MARK: - schemaVersion

    func testNewCaseHasCurrentSchemaVersion() {
        let cs = makeCase(state: .stable, lifecycle: .decisionReady)
        XCTAssertEqual(cs.schemaVersion, DecisionCase.currentSchemaVersion)
    }

    // MARK: - UserDecisionProfile 默认值与约束

    func testDefaultProfileDoesNotAllowStrongAction() {
        let profile = UserDecisionProfile.default
        XCTAssertFalse(profile.allowsStrongAction, "默认(未自定义)Profile 不得允许强行动")
        XCTAssertFalse(profile.isCustomized)
        XCTAssertFalse(profile.allowsActiveRebalancing)
    }

    func testCustomizedProfileWithRebalancingAllowsStrongAction() {
        let profile = UserDecisionProfile(
            allowsActiveRebalancing: true,
            isCustomized: true
        )
        XCTAssertTrue(profile.allowsStrongAction)
    }

    func testEffectiveLimitsRespectCustomValues() {
        // 自定义值优先于风险偏好默认值
        let profile = UserDecisionProfile(
            riskTolerance: .conservative,
            concentrationLimit: 45,
            overlapLimit: 30
        )
        XCTAssertEqual(profile.effectiveConcentrationLimit, 45)
        XCTAssertEqual(profile.effectiveOverlapLimit, 30)

        // 未自定义时用风险偏好默认值
        let defaultProfile = UserDecisionProfile(riskTolerance: .conservative)
        XCTAssertEqual(defaultProfile.effectiveConcentrationLimit, 30)
        XCTAssertEqual(defaultProfile.effectiveOverlapLimit, 15)

        let aggressive = UserDecisionProfile(riskTolerance: .aggressive)
        XCTAssertEqual(aggressive.effectiveConcentrationLimit, 50)
        XCTAssertEqual(aggressive.effectiveOverlapLimit, 25)
    }

    // MARK: - PortfolioDecisionPolicy 阈值

    func testPolicyDefaultThresholds() {
        let policy = PortfolioDecisionPolicy.default
        XCTAssertEqual(policy.concentrationWatchThreshold, 30)
        XCTAssertEqual(policy.concentrationReviewThreshold, 50)
        XCTAssertEqual(policy.prepareProximity, 5)
        XCTAssertEqual(policy.sectorWatchThreshold, 25)
        XCTAssertEqual(policy.sectorReviewThreshold, 40)
        XCTAssertEqual(policy.minLookThroughCoverage, 70)
    }

    func testPreliminaryStateDerivation() {
        let policy = PortfolioDecisionPolicy.default

        // 数据不足 → insufficientEvidence
        XCTAssertEqual(policy.preliminaryState(value: 60, watch: 30, review: 50, hasData: false), .insufficientEvidence)

        // 超过 review → adjustReview
        XCTAssertEqual(policy.preliminaryState(value: 55, watch: 30, review: 50, hasData: true), .adjustReview)
        XCTAssertEqual(policy.preliminaryState(value: 50, watch: 30, review: 50, hasData: true), .adjustReview)

        // 接近 review(45-50)→ prepare
        XCTAssertEqual(policy.preliminaryState(value: 47, watch: 30, review: 50, hasData: true), .prepare)
        XCTAssertEqual(policy.preliminaryState(value: 45, watch: 30, review: 50, hasData: true), .prepare)

        // 超过 watch 但不接近 review → watch
        XCTAssertEqual(policy.preliminaryState(value: 40, watch: 30, review: 50, hasData: true), .watch)
        XCTAssertEqual(policy.preliminaryState(value: 30, watch: 30, review: 50, hasData: true), .watch)

        // 阈值内 → stable
        XCTAssertEqual(policy.preliminaryState(value: 20, watch: 30, review: 50, hasData: true), .stable)
    }

    // MARK: - 辅助

    private func makeCase(state: PortfolioDecisionState, lifecycle: DecisionCaseLifecycle) -> DecisionCase {
        DecisionCase(
            caseKey: "concentrationRisk|directHolding|001000",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "测试基金",
            subjectCode: "001000",
            lifecycle: lifecycle,
            decisionState: state,
            metricValue: 55.0,
            metricLabel: "55.0%",
            metricDescription: "第一大标的占比",
            title: "集中度测试",
            detail: "测试用例",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }
}
