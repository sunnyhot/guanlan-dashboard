import Foundation
import XCTest
@testable import QiemanDashboard

// TrendTracking 行为冻结测试。
//
// 补充现有 TrendTrackingTests 未覆盖的契约(见 docs/ai-pipeline-baseline.md 第 4 节):
//   - 旧文件无 schemaVersion 的解码兼容(Codable 默认值兜底)
//   - dedupeKey 在 assetKey 为空时的 name|code 兜底
//   - triggerConditions/invalidatingConditions 是自然语言字符串(不做结构化求值)
//   - statusHistory 在每个状态转换时 append
//   - snoozeUntil 在 status≠.processed 时被清空
//
// 这些是投资智能改造迁移 TrendTrackingItem → DecisionCase 时的关键脆弱点:
// 任何字段重命名或类型变更都会静默吞掉旧数据。
@MainActor
final class TrendTrackingCharacterizationTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trend-track-char-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeReport() -> TrendAnalysisReport {
        TrendAnalysisReport.fixture(generatedAt: "2026-07-23 10:00:00", externalSignalStatus: .available)
    }

    private func addAction(
        to model: AppModel, name: String, action: TrendActionKind = .watch
    ) -> UUID {
        let candidate = TrendActionCandidate(
            id: "act-\(name)", kind: action, title: name, detail: "理由",
            targetName: name,
            confidence: TrendConfidence(score: 60, label: "中"),
            triggerConditions: ["自然语言触发条件"], invalidatingConditions: ["自然语言失效条件"]
        )
        _ = model.addTrackingItem(from: candidate, report: makeReport())
        return model.trendTrackingItems[0].id
    }

    // MARK: - 测试 13:旧文件无 schemaVersion 解码兼容

    func testLegacyTrackingItemDecodesWithoutSchemaVersion() throws {
        // 模拟早期版本的跟踪项 JSON:缺 sourceReportID/statusHistory/triggerConditions 等字段
        let legacyJSON = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "sourceGeneratedAt": "2025-06-01 10:00:00",
          "assetName": "旧基金",
          "action": "watch",
          "reason": "历史原因",
          "confidence": {"score": 50, "label": "中"},
          "createdAt": "2025-06-01 10:00:00",
          "status": "observing"
        }
        """
        let item = try JSONDecoder().decode(TrendTrackingItem.self, from: Data(legacyJSON.utf8))

        // 缺失字段应被默认值兜底,而非解码失败
        XCTAssertEqual(item.action, .watch)
        XCTAssertEqual(item.status, .observing)
        XCTAssertTrue(item.statusHistory.isEmpty, "缺 statusHistory 应默认空数组")
        XCTAssertTrue(item.triggerConditions.isEmpty, "缺 triggerConditions 应默认空数组")
        XCTAssertTrue(item.invalidatingConditions.isEmpty)
        XCTAssertNil(item.assetKey, "缺 assetKey 应为 nil")
        XCTAssertNil(item.assetCode)
        XCTAssertNil(item.snoozeUntil)
    }

    // MARK: - 测试 14:dedupeKey 在 assetKey 为空时用 name|code 兜底

    func testDedupeKeyFallbackUsesNameCodeWhenAssetKeyNil() {
        // assetKey 为 nil → dedupeKey 应回退到 name|code lowercased
        let itemWithNameCode = TrendTrackingItem(
            sourceReportID: UUID(), sourceGeneratedAt: "2026-07-23 10:00:00",
            assetKey: nil, assetName: "沪深300ETF", assetCode: "510300",
            action: .considerIncrease, reason: "r",
            confidence: TrendConfidence(score: 60, label: "中"),
            triggerConditions: [], invalidatingConditions: [],
            createdAt: "2026-07-23 10:00:00", status: .observing
        )
        XCTAssertTrue(itemWithNameCode.isActive)
        // dedupeKey 应基于 name|code(具体格式由实现决定,这里只验证不为空且稳定)
        XCTAssertFalse(itemWithNameCode.dedupeKey.isEmpty, "assetKey 为空时 dedupeKey 必须有兜底值")

        // 有 assetKey 时用 assetKey
        let itemWithKey = TrendTrackingItem(
            sourceReportID: UUID(), sourceGeneratedAt: "2026-07-23 10:00:00",
            assetKey: "F-KEY-1", assetName: "基金X", assetCode: "001000",
            action: .considerIncrease, reason: "r",
            confidence: TrendConfidence(score: 60, label: "中"),
            triggerConditions: [], invalidatingConditions: [],
            createdAt: "2026-07-23 10:00:00", status: .observing
        )
        XCTAssertNotEqual(itemWithNameCode.dedupeKey, itemWithKey.dedupeKey,
                          "不同标的的 dedupeKey 必须不同")
    }

    // MARK: - 测试 15:triggerConditions 是自然语言字符串(冻结:不做结构化求值)

    func testTriggerConditionsAreNaturalLanguageStrings() throws {
        let model = AppModel()
        model.dataDirectoryURL = temporaryDirectory()
        let id = addAction(to: model, name: "基金E")

        // triggerConditions 应原样存储为 [String],不做任何解析或求值
        let item = model.trendTrackingItems.first { $0.id == id }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.triggerConditions, ["自然语言触发条件"])
        XCTAssertEqual(item?.invalidatingConditions, ["自然语言失效条件"])

        // 关键不变量:没有任何自动条件求值逻辑。status 变更只能由用户手动触发。
        // recoverSnoozedTrackingItems 只处理 snoozeUntil 到期,不评估 triggerConditions。
        XCTAssertEqual(item?.status, .observing, "新加入的跟踪项状态必须是 observing,不自动触发")
    }

    // MARK: - 测试 16:statusHistory 在每个状态转换时 append

    func testStatusHistoryAppendsOnEveryTransition() {
        let model = AppModel()
        model.dataDirectoryURL = temporaryDirectory()
        let id = addAction(to: model, name: "基金F", action: .considerReduce)

        // 初始 add 应记录一条 statusHistory
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.count, 1)

        // mark → triggered
        model.markTrackingItem(id, status: .triggered, note: "触发1")
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.count, 2)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.last?.to, .triggered)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.last?.from, .observing)

        // mark → invalidated
        model.markTrackingItem(id, status: .invalidated, note: "失效")
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.count, 3)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.last?.to, .invalidated)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.last?.from, .triggered)

        // end
        model.endTrackingItem(id)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.count, 4)
        XCTAssertEqual(model.trendTrackingItems[0].statusHistory.last?.to, .ended)
    }

    // MARK: - 测试 17:snoozeUntil 在 status≠.processed 时被清空

    func testSnoozeUntilClearedOnNonProcessedStatus() {
        let model = AppModel()
        model.dataDirectoryURL = temporaryDirectory()
        let id = addAction(to: model, name: "基金G")

        // 先 snooze(→ processed + snoozeUntil)
        model.snoozeTrackingItem(id, days: 3)
        XCTAssertEqual(model.trendTrackingItems[0].status, .processed)
        XCTAssertNotNil(model.trendTrackingItems[0].snoozeUntil)

        // mark 到非 processed 状态 → snoozeUntil 必须被清空
        model.markTrackingItem(id, status: .observing, note: "手动恢复观察")
        XCTAssertEqual(model.trendTrackingItems[0].status, .observing)
        XCTAssertNil(model.trendTrackingItems[0].snoozeUntil,
                     "status≠.processed 时 snoozeUntil 必须被清空")

        // 再 mark 到另一个非 processed 状态,snoozeUntil 仍应为 nil
        model.markTrackingItem(id, status: .approaching, note: "接近触发")
        XCTAssertEqual(model.trendTrackingItems[0].status, .approaching)
        XCTAssertNil(model.trendTrackingItems[0].snoozeUntil)
    }
}
