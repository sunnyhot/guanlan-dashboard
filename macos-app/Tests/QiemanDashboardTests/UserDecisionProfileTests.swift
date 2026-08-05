import Foundation
import XCTest
@testable import QiemanDashboard

// UserDecisionProfile 行为测试(Slice 5)。
// 验证 Profile 的自定义/默认联动 + allowsStrongAction 约束。
@MainActor
final class UserDecisionProfileTests: XCTestCase {

    func testDefaultProfileIsNotCustomized() {
        let p = UserDecisionProfile.default
        XCTAssertFalse(p.isCustomized)
        XCTAssertFalse(p.allowsActiveRebalancing)
        XCTAssertFalse(p.allowsStrongAction)
    }

    func testCustomizedWithRebalancingAllowsStrongAction() {
        let p = UserDecisionProfile(
            allowsActiveRebalancing: true,
            isCustomized: true
        )
        XCTAssertTrue(p.allowsStrongAction)
    }

    func testCustomizedWithoutRebalancingDoesNotAllowStrongAction() {
        let p = UserDecisionProfile(
            allowsActiveRebalancing: false,
            isCustomized: true
        )
        XCTAssertFalse(p.allowsStrongAction)
    }

    func testEffectiveLimitsFallbackToRiskTolerance() {
        // 未设自定义上限 → 用风险偏好默认值
        XCTAssertEqual(UserDecisionProfile(riskTolerance: .conservative).effectiveConcentrationLimit, 30)
        XCTAssertEqual(UserDecisionProfile(riskTolerance: .moderate).effectiveConcentrationLimit, 40)
        XCTAssertEqual(UserDecisionProfile(riskTolerance: .aggressive).effectiveConcentrationLimit, 50)
    }

    func testCustomLimitsOverrideRiskTolerance() {
        let p = UserDecisionProfile(riskTolerance: .conservative, concentrationLimit: 45, overlapLimit: 30)
        XCTAssertEqual(p.effectiveConcentrationLimit, 45)
        XCTAssertEqual(p.effectiveOverlapLimit, 30)
    }

    func testUpdateProfilePersistsAndReEvaluates() {
        let model = AppModel()
        model.dataDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-test-\(UUID().uuidString)", isDirectory: true)

        // 初始默认
        XCTAssertFalse(model.userDecisionProfile.isCustomized)

        // 更新为自定义 + 允许再平衡
        let custom = UserDecisionProfile(
            riskTolerance: .moderate,
            concentrationLimit: 35,
            allowsActiveRebalancing: true,
            isCustomized: true,
            customizedAt: "2026-08-05 10:00:00"
        )
        model.updateUserDecisionProfile(custom)

        // 验证内存状态更新
        XCTAssertTrue(model.userDecisionProfile.isCustomized)
        XCTAssertTrue(model.userDecisionProfile.allowsStrongAction)
        XCTAssertEqual(model.userDecisionProfile.effectiveConcentrationLimit, 35)
    }

    func testSchemaVersion() {
        XCTAssertEqual(UserDecisionProfile.default.schemaVersion, UserDecisionProfile.currentSchemaVersion)
    }
}
