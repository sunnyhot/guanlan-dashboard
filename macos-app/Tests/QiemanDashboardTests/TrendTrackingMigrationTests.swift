import Foundation
import XCTest
@testable import QiemanDashboard

// TrendTracking → DecisionCase 迁移测试(Slice 6)。
// 验证字段映射 + 自然语言条件标记 + 去重 + ended 不迁移。
final class TrendTrackingMigrationTests: XCTestCase {

    // MARK: - 单项迁移

    func testMigrateMapsFields() {
        let item = makeItem(
            name: "沪深300ETF", code: "510300", action: .considerIncrease,
            status: .observing, trigger: ["成交量放大"], invalidating: ["跌破支撑位"]
        )
        let cs = TrendTrackingMigration.migrate(item)

        XCTAssertEqual(cs.subjectName, "沪深300ETF")
        XCTAssertEqual(cs.subjectCode, "510300")
        XCTAssertEqual(cs.decisionState, .watch)  // observing → watch
        XCTAssertEqual(cs.lifecycle, .monitoring)
        XCTAssertEqual(cs.userDisposition, .acknowledged)  // 旧项在跟踪 → 已确认
        XCTAssertEqual(cs.id, item.id)  // ID 保持稳定
        XCTAssertTrue(cs.caseKey.hasPrefix("legacy:"))
        XCTAssertTrue(cs.detail.contains("[迁移自旧跟踪清单"))
        XCTAssertTrue(cs.detail.contains("触发条件(人工复核)"))  // 自然语言标记
    }

    func testMigrateNaturalLanguageConditionsNotStructured() {
        // 复核方案硬约束:自然语言条件不得迁移为自动触发规则
        let item = makeItem(trigger: ["MACD 金叉", "成交量突破 1 亿"], invalidating: ["跌破 4000 点"])
        let cs = TrendTrackingMigration.migrate(item)

        // 条件只在 detail 文本里,不应有任何结构化触发逻辑
        XCTAssertTrue(cs.detail.contains("人工复核"))
        XCTAssertTrue(cs.detail.contains("MACD 金叉"))
        XCTAssertTrue(cs.detail.contains("跌破 4000 点"))
    }

    func testMigrateStatusMappings() {
        // 各 status → decisionState 映射
        XCTAssertEqual(migrateStatus(.observing), .watch)
        XCTAssertEqual(migrateStatus(.approaching), .prepare)
        XCTAssertEqual(migrateStatus(.triggered), .adjustReview)
        XCTAssertEqual(migrateStatus(.invalidated), .exitReview)
        XCTAssertEqual(migrateStatus(.staleData), .insufficientEvidence)
        XCTAssertEqual(migrateStatus(.processed), .watch)
        XCTAssertEqual(migrateStatus(.ended), .stable)
    }

    func testMigrateStatusHistoryToEvents() {
        var item = makeItem(status: .triggered)
        item.statusHistory = [
            TrendTrackingStatusChange(at: "2026-07-01 10:00:00", from: nil, to: .observing, note: "加入跟踪"),
            TrendTrackingStatusChange(at: "2026-07-05 10:00:00", from: .observing, to: .triggered, note: "触发")
        ]
        let cs = TrendTrackingMigration.migrate(item)

        XCTAssertEqual(cs.events.count, 2)
        XCTAssertEqual(cs.events.first?.actor, .migration)
        XCTAssertEqual(cs.events.first?.type, .migrated)
        XCTAssertEqual(cs.events.last?.newDecisionState, .adjustReview)  // triggered → adjustReview
    }

    // MARK: - 批量迁移 + 去重

    func testMergeMigratedSkipsEnded() {
        let active = makeItem(name: "基金A", code: "001000", status: .observing)
        let ended = makeItem(name: "基金B", code: "001001", status: .ended)

        let result = TrendTrackingMigration.mergeMigrated(
            existingCases: [],
            trackingItems: [active, ended]
        )
        // ended 不迁移
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.subjectName, "基金A")
    }

    func testMergeMigratedDoesNotOverwriteExisting() {
        // 已有 Case(同 caseKey)不被迁移覆盖
        let existing = DecisionCase(
            caseKey: "legacy:considerIncrease|001000",
            kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "已有 Case", subjectCode: "001000",
            lifecycle: .monitoring, decisionState: .watch,
            metricValue: 50, metricLabel: "50%", metricDescription: "测试",
            title: "已有", detail: "用户已操作",
            createdAt: "2026-07-01 10:00:00", updatedAt: "2026-07-01 10:00:00"
        )
        let trackingItem = makeItem(name: "基金A", code: "001000", action: .considerIncrease, status: .observing)

        let result = TrendTrackingMigration.mergeMigrated(
            existingCases: [existing],
            trackingItems: [trackingItem]
        )
        // 同 caseKey → 不重复添加
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "已有")  // 保留原有
    }

    func testMergeMigratedDedupesByCaseKey() {
        // 同标的+同 action 的多个旧项 → 只迁移一个
        let item1 = makeItem(name: "基金A", code: "001000", action: .considerIncrease, status: .observing)
        let item2 = makeItem(name: "基金A不同名", code: "001000", action: .considerIncrease, status: .approaching)
        // 同 code + 同 action → 同 caseKey

        let result = TrendTrackingMigration.mergeMigrated(
            existingCases: [],
            trackingItems: [item1, item2]
        )
        XCTAssertEqual(result.count, 1, "同 caseKey 应去重")
    }

    // MARK: - 辅助

    private func makeItem(
        name: String = "测试基金",
        code: String? = "001000",
        action: TrendActionKind = .watch,
        status: TrendTrackingStatus = .observing,
        trigger: [String] = [],
        invalidating: [String] = []
    ) -> TrendTrackingItem {
        TrendTrackingItem(
            sourceReportID: UUID(),
            sourceGeneratedAt: "2026-07-01 10:00:00",
            assetKey: code, assetName: name, assetCode: code,
            action: action, reason: "测试理由",
            confidence: TrendConfidence(score: 65, label: "中"),
            triggerConditions: trigger, invalidatingConditions: invalidating,
            createdAt: "2026-07-01 10:00:00", status: status
        )
    }

    private func migrateStatus(_ status: TrendTrackingStatus) -> PortfolioDecisionState {
        let item = TrendTrackingItem(
            sourceReportID: UUID(), sourceGeneratedAt: "",
            assetKey: nil, assetName: "x", assetCode: nil,
            action: .watch, reason: "", confidence: TrendConfidence(score: 0, label: "低"),
            triggerConditions: [], invalidatingConditions: [],
            createdAt: "", status: status
        )
        return TrendTrackingMigration.migrate(item).decisionState
    }
}
