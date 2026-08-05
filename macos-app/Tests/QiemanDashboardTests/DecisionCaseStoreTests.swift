import Foundation
import XCTest
@testable import QiemanDashboard

// DecisionCaseStore + UserDecisionProfileStore 持久化测试。
//
// 冻结:round-trip 一致、schemaVersion 存在、文件权限 0o600、向后兼容。
// 见 docs/ai-pipeline-baseline.md 第 5 节。
final class DecisionCaseStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-store-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - DecisionCaseStore

    func testDecisionCaseStoreRoundTrip() throws {
        let url = tempDir.appendingPathComponent("decision-cases.json")
        let store = DecisionCaseStore()

        var cs = DecisionCase(
            caseKey: "concentrationRisk|directHolding|001000",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "测试基金", subjectCode: "001000",
            lifecycle: .decisionReady,
            decisionState: .watch,
            metricValue: 42.5, metricLabel: "42.5%",
            metricDescription: "第一大标的占比",
            title: "集中度测试", detail: "测试",
            createdAt: "2026-08-05 10:00:00", updatedAt: "2026-08-05 10:00:00"
        )
        cs.applyTransition(to: .monitoring, decisionState: .watch, at: "2026-08-05 11:00:00",
                           type: .userAcknowledged, reason: "关注", actor: .user)

        try store.save([cs], to: url)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, cs.id)
        XCTAssertEqual(loaded.first?.caseKey, cs.caseKey)
        XCTAssertEqual(loaded.first?.decisionState, .watch)
        XCTAssertEqual(loaded.first?.lifecycle, .monitoring)
        XCTAssertEqual(loaded.first?.events.count, 1)
        XCTAssertEqual(loaded.first?.metricValue ?? 0, 42.5, accuracy: 0.01)
        XCTAssertEqual(loaded.first?.schemaVersion, DecisionCase.currentSchemaVersion)
    }

    func testDecisionCaseStoreLoadMissingFileReturnsEmpty() throws {
        let url = tempDir.appendingPathComponent("missing.json")
        let loaded = try DecisionCaseStore().load(from: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDecisionCaseStoreSetsRestrictedPermissions() throws {
        let url = tempDir.appendingPathComponent("perms.json")
        let store = DecisionCaseStore()
        try store.save([], to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "DecisionCaseStore 应设置 0o600 权限")
    }

    // MARK: - UserDecisionProfileStore

    func testProfileStoreRoundTrip() throws {
        let url = tempDir.appendingPathComponent("profile.json")
        let store = UserDecisionProfileStore()

        let profile = UserDecisionProfile(
            investmentHorizon: .mediumTerm,
            riskTolerance: .moderate,
            concentrationLimit: 35,
            overlapLimit: 18,
            allowsActiveRebalancing: true,
            isCustomized: true,
            customizedAt: "2026-08-05 10:00:00"
        )
        try store.save(profile, to: url)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded.investmentHorizon, .mediumTerm)
        XCTAssertEqual(loaded.riskTolerance, .moderate)
        XCTAssertEqual(loaded.concentrationLimit, 35)
        XCTAssertEqual(loaded.allowsActiveRebalancing, true)
        XCTAssertEqual(loaded.isCustomized, true)
        XCTAssertEqual(loaded.schemaVersion, UserDecisionProfile.currentSchemaVersion)
    }

    func testProfileStoreLoadMissingFileReturnsDefault() throws {
        let url = tempDir.appendingPathComponent("missing-profile.json")
        let loaded = try UserDecisionProfileStore().load(from: url)
        XCTAssertEqual(loaded, .default, "文件缺失应返回默认 Profile")
        XCTAssertFalse(loaded.isCustomized)
        XCTAssertFalse(loaded.allowsActiveRebalancing)
    }

    func testProfileStoreSetsRestrictedPermissions() throws {
        let url = tempDir.appendingPathComponent("profile-perms.json")
        let store = UserDecisionProfileStore()
        try store.save(.default, to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }
}
