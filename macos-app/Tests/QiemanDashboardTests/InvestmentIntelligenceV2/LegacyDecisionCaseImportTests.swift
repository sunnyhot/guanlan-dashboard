import XCTest
@testable import QiemanDashboard

// MARK: - LegacyDecisionCaseImport 测试（审计 A2/E）
//
// 覆盖：V1 JSON → V2 映射（trendAction→actionMigration / exitReview→
// adjustReview）、journals 手写复盘导入（原文件保留）、关闭案跳过、
// 幂等（标记文件）、无源文件 no-op。

final class LegacyDecisionCaseImportTests: XCTestCase {

    private var dataDirectory: URL!
    private var workDirectory: URL!
    private var store: DecisionCaseStore!

    override func setUpWithError() throws {
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-import-\(UUID().uuidString)", isDirectory: true)
        workDirectory = dataDirectory
            .appendingPathComponent("investment-intelligence-v2", isDirectory: true)
        store = DecisionCaseStore(workDirectory: workDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func writeLegacyCases(_ json: String, inBackup: Bool = true) throws {
        let directory: URL = inBackup
            ? dataDirectory.appendingPathComponent(
                LegacyAIDataMigration.backupDirectoryName, isDirectory: true)
            : dataDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(LegacyDecisionCaseImport.legacyCaseFileName))
    }

    private func writeLegacyJournalReview(caseID: String, reviewID: String, lessons: String) throws {
        let reviewsDirectory = dataDirectory
            .appendingPathComponent("investment-intelligence", isDirectory: true)
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent(caseID, isDirectory: true)
            .appendingPathComponent("reviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: reviewsDirectory, withIntermediateDirectories: true)
        let json = """
        {
          "id": "\(reviewID)",
          "schemaVersion": 1,
          "caseID": "\(caseID)",
          "reviewedAt": "2026-08-20 21:30:00",
          "reviewHorizon": "7天后",
          "originalDecisionState": "watch",
          "originalMetricValue": 55.3,
          "currentMetricValue": 48.2,
          "triggerResult": null,
          "invalidationResult": false,
          "claimOutcomes": [],
          "portfolioOutcome": "",
          "processQuality": "",
          "conclusion": "partiallySupported",
          "lessons": "\(lessons)"
        }
        """
        try Data(json.utf8).write(
            to: reviewsDirectory.appendingPathComponent("\(reviewID).json"))
    }

    /// 一条开放的 V1 集中度案 + 一条已关闭案。
    private var legacyJSON: String {
        """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "schemaVersion": 2,
            "caseKey": "concentrationRisk|directHolding|000011",
            "kind": "concentrationRisk",
            "dimension": "directHolding",
            "subjectName": "南方中证500",
            "subjectCode": "000011",
            "lifecycle": "monitoring",
            "decisionState": "watch",
            "metricValue": 42.5,
            "metricLabel": "42.5%",
            "metricDescription": "第一大持仓占比",
            "title": "单一持仓集中：南方中证500",
            "detail": "V1 时代的描述",
            "createdAt": "2026-08-01 09:00:00",
            "updatedAt": "2026-08-10 09:00:00",
            "lastEvaluatedAt": "2026-08-10 09:00:00",
            "reviewDueAt": "2026-08-17 09:00:00",
            "resolvedAt": null,
            "events": [
              {
                "id": "22222222-2222-2222-2222-222222222222",
                "at": "2026-08-01 09:00:00",
                "type": "created",
                "previousLifecycle": null,
                "newLifecycle": "decisionReady",
                "previousDecisionState": null,
                "newDecisionState": "watch",
                "reason": "集中度评估自动生成",
                "actor": "system"
              }
            ],
            "userDisposition": "acknowledged"
          },
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "schemaVersion": 2,
            "caseKey": "trendAction|directHolding|000300",
            "kind": "trendAction",
            "dimension": "directHolding",
            "subjectName": "沪深300",
            "subjectCode": "000300",
            "lifecycle": "closed",
            "decisionState": "exitReview",
            "metricValue": 0,
            "metricLabel": "",
            "metricDescription": "",
            "title": "旧跟踪项",
            "detail": "已关闭的旧案",
            "createdAt": "2026-07-01 09:00:00",
            "updatedAt": "2026-07-20 09:00:00",
            "events": [],
            "userDisposition": "closed"
          }
        ]
        """
    }

    func testImportFromBackupDirectory() throws {
        try writeLegacyCases(legacyJSON)
        let outcome = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)

        XCTAssertEqual(outcome.importedCases, 1, "只导入开放案")
        XCTAssertEqual(outcome.skippedClosedCases, 1, "关闭案跳过")

        let cases = try store.loadAll()
        XCTAssertEqual(cases.count, 1)
        let imported = cases[0]
        XCTAssertEqual(imported.kind, .concentrationRisk)
        XCTAssertEqual(imported.lifecycle, .monitoring)
        XCTAssertEqual(imported.userDisposition, .acknowledged)
        XCTAssertEqual(imported.metricValue, 42.5, accuracy: 0.001)
        XCTAssertEqual(imported.events.first?.type, .created)
        XCTAssertEqual(imported.events.last?.type, .migrated, "末尾追加迁移事件")
        XCTAssertEqual(imported.events.last?.actor, .migration)
    }

    func testImportFromRootWhenBackupMissing() throws {
        try writeLegacyCases(legacyJSON, inBackup: false)
        let outcome = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(outcome.importedCases, 1)
    }

    func testTrendActionMapsToActionMigration() throws {
        let json = """
        [{
          "id": "44444444-4444-4444-4444-444444444444",
          "schemaVersion": 2, "caseKey": "trendAction|directHolding|000300",
          "kind": "trendAction", "dimension": "directHolding",
          "subjectName": "沪深300", "subjectCode": "000300",
          "lifecycle": "monitoring", "decisionState": "exitReview",
          "metricValue": 0, "metricLabel": "", "metricDescription": "",
          "title": "行动跟踪", "detail": "",
          "createdAt": "2026-08-01 09:00:00",
          "events": [], "userDisposition": "acknowledged"
        }]
        """
        try writeLegacyCases(json)
        _ = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        let cases = try store.loadAll()
        XCTAssertEqual(cases[0].kind, .actionMigration, "trendAction → actionMigration")
        XCTAssertEqual(cases[0].decisionState, .adjustReview, "exitReview → adjustReview")
    }

    func testJournalReviewsImportedAndOriginalKept() throws {
        try writeLegacyCases(legacyJSON)
        try writeLegacyJournalReview(
            caseID: "11111111-1111-1111-1111-111111111111",
            reviewID: "55555555-5555-5555-5555-555555555555",
            lessons: "用户手写的宝贵经验")

        let outcome = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(outcome.importedReviews, 1)

        let imported = try store.loadAll()[0]
        XCTAssertEqual(imported.reviews.count, 1)
        XCTAssertEqual(imported.reviews[0].conclusion, .partiallySupported)
        XCTAssertEqual(imported.reviews[0].lessons, "用户手写的宝贵经验")
        XCTAssertEqual(imported.reviews[0].caseID, imported.id, "复盘换绑新确定性 caseID")
        XCTAssertTrue(imported.reviews[0].id.hasPrefix("drev_legacy_"))

        // 原文件保留（复制语义，不清理用户手写内容）
        let journalFile = dataDirectory
            .appendingPathComponent("investment-intelligence", isDirectory: true)
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent("11111111-1111-1111-1111-111111111111", isDirectory: true)
            .appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent("55555555-5555-5555-5555-555555555555.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalFile.path))
    }

    func testIdempotentMarker() throws {
        try writeLegacyCases(legacyJSON)
        let first = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(first.importedCases, 1)
        // 第二次：标记文件生效 → no-op
        let second = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(second.importedCases, 0)
        XCTAssertEqual(try store.loadAll().count, 1, "不重复导入")
    }

    func testNoSourceFileIsNoOpButWritesMarker() throws {
        let outcome = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(outcome.importedCases, 0)
        // 标记已写：补上源文件也不再导入（版本升级只导一次）
        try writeLegacyCases(legacyJSON)
        let again = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(again.importedCases, 0)
    }

    func testExistingCaseKeySkipped() throws {
        // 先放一个同 caseKey 的 V2 案
        var existingCase = DecisionCase(
            caseKey: DecisionCase.makeCaseKey(
                kind: .concentrationRisk, dimension: .directHolding,
                subjectCode: "000011", subjectName: "南方中证500"),
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "南方中证500",
            subjectCode: "000011",
            lifecycle: .monitoring,
            decisionState: .watch,
            metricValue: 42.5,
            metricLabel: "42.5%",
            metricDescription: "第一大持仓占比",
            title: "既有案",
            detail: "",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        existingCase.userDisposition = .acknowledged
        try store.save(existingCase)

        try writeLegacyCases(legacyJSON)
        let outcome = try LegacyDecisionCaseImport.run(store: store, dataDirectory: dataDirectory)
        XCTAssertEqual(outcome.importedCases, 0, "同 caseKey 已存在 → 跳过不覆盖")
        XCTAssertEqual(try store.loadAll().count, 1)
    }
}
