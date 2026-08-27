import XCTest
@testable import QiemanDashboard

// MARK: - DecisionCaseStore 测试（审计 A2）
//
// 覆盖：一案一文件读写回环、确定性 ID 幂等、损坏文件跳过（原文件保留）。

final class DecisionCaseStoreTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-case-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeCase(subject: String = "基金A", code: String = "000001") -> DecisionCase {
        let caseKey = DecisionCase.makeCaseKey(
            kind: .concentrationRisk, dimension: .directHolding,
            subjectCode: code, subjectName: subject)
        var draft = DecisionCase(
            caseKey: caseKey,
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: subject,
            subjectCode: code,
            lifecycle: .decisionReady,
            decisionState: .watch,
            metricValue: 35,
            metricLabel: "35.0%",
            metricDescription: "第一大持仓占比",
            title: "单一持仓集中：\(subject)",
            detail: "测试案",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        draft.applyTransition(
            to: .decisionReady, decisionState: .watch,
            at: Date(timeIntervalSince1970: 1_800_000_000),
            type: .created, reason: "测试", actor: .system)
        return draft
    }

    func testSaveLoadRoundtrip() throws {
        let store = DecisionCaseStore(workDirectory: workDirectory)
        var testCase = makeCase()
        testCase.reviews = [DecisionReview(
            caseID: testCase.id,
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_100),
            originalDecisionState: .watch,
            originalMetricValue: 35,
            currentMetricValue: 33,
            conclusion: .supported,
            lessons: "手写复盘内容")]
        try store.save(testCase)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], testCase, "一案一文件应无损回环（含事件与复盘）")
    }

    func testSaveOverwritesWithLatestState() throws {
        let store = DecisionCaseStore(workDirectory: workDirectory)
        var testCase = makeCase()
        try store.save(testCase)
        testCase.userDisposition = .acknowledged
        testCase.applyTransition(
            to: .monitoring, decisionState: .watch,
            at: Date(timeIntervalSince1970: 1_800_000_200),
            type: .userAcknowledged, reason: "关注", actor: .user)
        try store.save(testCase)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1, "同 ID 覆盖写不产生重复文件")
        XCTAssertEqual(loaded[0].lifecycle, .monitoring)
        XCTAssertEqual(loaded[0].events.count, 2)
    }

    func testDeterministicIDAcrossStoreInstances() throws {
        let testCase = makeCase()
        // 同 caseKey 构造两次（不同进程/内存）→ 同 ID → 同文件名
        let again = makeCase()
        XCTAssertEqual(testCase.id, again.id)
        XCTAssertTrue(testCase.id.hasPrefix("dcase_"))

        let storeA = DecisionCaseStore(workDirectory: workDirectory)
        try storeA.save(testCase)
        let storeB = DecisionCaseStore(workDirectory: workDirectory)
        let loaded = try storeB.loadAll()
        XCTAssertEqual(loaded.first?.id, testCase.id)
    }

    func testLoadAllSkipsCorruptFileAndKeepsItOnDisk() throws {
        let store = DecisionCaseStore(workDirectory: workDirectory)
        try store.save(makeCase(subject: "好案"))
        // 写一个损坏文件
        let corruptURL = store.directory
            .appendingPathComponent("dcase_corrupt.json")
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: corruptURL)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1, "损坏文件跳过，不阻断其余读取")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path),
                      "损坏文件保留在盘（不删用户数据）")
    }

    func testLoadAllEmptyDirectory() throws {
        let store = DecisionCaseStore(workDirectory: workDirectory)
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    func testSaveAllPersistsEveryCase() throws {
        let store = DecisionCaseStore(workDirectory: workDirectory)
        let cases = [
            makeCase(subject: "A", code: "000001"),
            makeCase(subject: "B", code: "000002"),
            makeCase(subject: "C", code: "000003"),
        ]
        try store.saveAll(cases)
        XCTAssertEqual(try store.loadAll().count, 3)
    }
}
