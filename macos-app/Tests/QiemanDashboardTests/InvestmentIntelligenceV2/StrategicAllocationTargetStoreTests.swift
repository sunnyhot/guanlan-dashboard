import XCTest
@testable import QiemanDashboard

// P0 产品重构 §6.1：战略目标 append-only 文件事实源。
// 五类完备门禁 / 幂等 / 指针推进与恢复 / 重启恢复 / 伪 Target 不可导入。

final class StrategicAllocationTargetStoreTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("target-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeStore() -> StrategicAllocationTargetStore {
        StrategicAllocationTargetStore(workDirectory: workDirectory)
    }

    /// 五类完备目标（编辑器产品形态）。
    private func makeCompleteTarget(
        weights: [AssetClass: String], now: Date
    ) throws -> AllocationTarget {
        try StrategicAllocationPolicy().applyUserAllocation(
            entries: AssetClass.allCases.map { assetClass in
                AllocationTargetEntry(
                    assetClass: assetClass,
                    targetWeight: Ratio(value: Decimal(string: weights[assetClass] ?? "0")!)
                )
            },
            note: "测试目标", now: now
        )
    }

    // MARK: - 五类完备门禁

    func testValidatorCompleteCoverageAllowsZeroWeightButRejectsMissingClass() throws {
        let validator = StrategicAllocationValidator()
        // 允许某类权重 0，五类齐备即过
        XCTAssertNoThrow(try validator.validateCompleteCoverage(entries:
            AssetClass.allCases.map { assetClass in
                AllocationTargetEntry(
                    assetClass: assetClass,
                    targetWeight: Ratio(value: assetClass == .equity ? Decimal(1) : Decimal(0))
                )
            }
        ))
        // 缺类即拒（基础 validate 不拒——历史 artifact 解码兼容）
        let twoClasses: [AllocationTargetEntry] = [
            AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.6")!)),
            AllocationTargetEntry(assetClass: .fixedIncome, targetWeight: Ratio(value: Decimal(string: "0.4")!)),
        ]
        XCTAssertNoThrow(try validator.validate(entries: twoClasses))
        XCTAssertThrowsError(
            try validator.validateCompleteCoverage(entries: twoClasses)
        ) { error in
            guard case let .missingAssetClasses(missing) =
                error as? StrategicAllocationValidator.ValidationError else {
                return XCTFail("应为 missingAssetClasses，实得 \(error)")
            }
            XCTAssertEqual(Set(missing), Set([.commodity, .cash, .alternative]))
        }
    }

    func testStoreRejectsIncompleteCoverageTarget() throws {
        let now = Date(timeIntervalSince1970: 1_860_000_000)
        // 两类 target（旧「维持当前配置」自复制形态）不可入库
        let legacyShaped = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.6")!)),
                AllocationTargetEntry(assetClass: .alternative, targetWeight: Ratio(value: Decimal(string: "0.4")!)),
            ],
            note: "维持当前配置（对照检查漂移）", now: now
        )
        XCTAssertThrowsError(
            try makeStore().record(
                target: legacyShaped, supersedesTargetID: nil,
                changeReason: nil, now: now)
        ) { error in
            guard case let .incompleteCoverage(missing) =
                error as? StrategicAllocationTargetStore.StoreError else {
                return XCTFail("应为 incompleteCoverage，实得 \(error)")
            }
            XCTAssertEqual(Set(missing), Set([.fixedIncome, .commodity, .cash]))
        }
    }

    // MARK: - 写入纪律

    func testRecordWritesEventAndAdvancesPointer() throws {
        let store = makeStore()
        let day1 = Date(timeIntervalSince1970: 1_860_000_000)
        let first = try makeCompleteTarget(
            weights: [.equity: "0.6", .fixedIncome: "0.4"], now: day1)
        try store.record(
            target: first, supersedesTargetID: nil,
            changeReason: "初始配置", now: day1)

        XCTAssertEqual(try store.currentTarget()?.id, first.id)
        XCTAssertEqual(try store.currentTarget()?.targetWeight(for: .equity),
                       Ratio(value: Decimal(string: "0.6")!))
        let history = try store.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.changeReason, "初始配置")
        XCTAssertNil(history.first?.supersedesTargetID)

        // 第二个 target：supersedes 必须等于当前指针
        let day2 = day1.addingTimeInterval(3_600)
        let second = try makeCompleteTarget(
            weights: [.equity: "0.5", .fixedIncome: "0.5"], now: day2)
        try store.record(
            target: second, supersedesTargetID: first.id.rawValue,
            changeReason: "股债再平衡", now: day2)
        XCTAssertEqual(try store.currentTarget()?.id, second.id)
        XCTAssertEqual(try store.resolvableTargetIDs(),
                       [first.id.rawValue, second.id.rawValue])
    }

    func testRecordIdempotentOnSameIDAndFailsClosedOnConflict() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let target = try makeCompleteTarget(
            weights: [.equity: "0.6", .fixedIncome: "0.4"], now: day)
        try store.record(
            target: target, supersedesTargetID: nil, changeReason: nil, now: day)
        // 同 ID 同内容幂等（changeReason/recordedAt 不同也不算冲突——
        // target 内容才是身份，事件包装字段以首条为准）
        XCTAssertNoThrow(try store.record(
            target: target, supersedesTargetID: nil,
            changeReason: "重放", now: day.addingTimeInterval(60)))
        XCTAssertEqual(try store.history().count, 1)

        // 同 ID 不同内容 fail-closed：伪造「换内容保旧 ID」的 target 不可行
        //（AllocationTarget 构造封闭，ID 由内容派生——这里验证 store 层兜底：
        // 直接改事件文件内容后重写同 ID 事件）
        let eventURL = store.directory.appendingPathComponent("\(target.id.rawValue).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventURL.path))
        var tampered = try String(contentsOf: eventURL, encoding: .utf8)
        tampered = tampered.replacingOccurrences(of: ": 0.6", with: ": 0.7")
        try tampered.write(to: eventURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.currentTarget()) { error in
            // ID 防伪门禁在 AllocationTarget 解码点拒绝
            XCTAssertTrue(
                error is StrategicAllocationTargetStore.StoreError,
                "伪造事件应 fail-closed，实得 \(error)")
        }
    }

    func testSupersedesMismatchFailsClosed() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let first = try makeCompleteTarget(
            weights: [.equity: "0.6", .fixedIncome: "0.4"], now: day)
        try store.record(
            target: first, supersedesTargetID: nil, changeReason: nil, now: day)
        let second = try makeCompleteTarget(
            weights: [.equity: "0.5", .fixedIncome: "0.5"], now: day.addingTimeInterval(60))
        // 声明取代一个不存在的 target → fail-closed
        XCTAssertThrowsError(
            try store.record(
                target: second, supersedesTargetID: "at_fabricated",
                changeReason: nil, now: day.addingTimeInterval(60))
        ) { error in
            guard case let .supersedesMismatch(actual, expected) =
                error as? StrategicAllocationTargetStore.StoreError else {
                return XCTFail("应为 supersedesMismatch，实得 \(error)")
            }
            XCTAssertEqual(actual, second.id.rawValue)
            XCTAssertEqual(expected, first.id.rawValue)
        }
    }

    // MARK: - 指针恢复与重启恢复

    func testPointerCorruptionRecoversDeterministically() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let first = try makeCompleteTarget(
            weights: [.equity: "0.6", .fixedIncome: "0.4"], now: day)
        try store.record(
            target: first, supersedesTargetID: nil, changeReason: nil, now: day)
        let second = try makeCompleteTarget(
            weights: [.equity: "0.5", .fixedIncome: "0.5"],
            now: day.addingTimeInterval(3_600))
        try store.record(
            target: second, supersedesTargetID: first.id.rawValue,
            changeReason: nil, now: day.addingTimeInterval(3_600))

        // 指针损坏（写入垃圾）→ 按 createdAt + id 确定性恢复到最新事件
        try Data("not-json".utf8).write(
            to: store.directory.appendingPathComponent(
                StrategicAllocationTargetStore.currentPointerFileName))
        XCTAssertEqual(try store.currentTarget()?.id, second.id)

        // 指针指向不存在的事件 → dangling fail-closed
        struct BadPointer: Codable {
            let schemaVersion: Int
            let targetID: String
            let updatedAt: Date
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(
            BadPointer(schemaVersion: 1, targetID: "at_ghost", updatedAt: day)
        ).write(to: store.directory.appendingPathComponent(
            StrategicAllocationTargetStore.currentPointerFileName))
        XCTAssertThrowsError(try store.currentTarget()) { error in
            guard case let .danglingPointer(id) =
                error as? StrategicAllocationTargetStore.StoreError else {
                return XCTFail("应为 danglingPointer，实得 \(error)")
            }
            XCTAssertEqual(id, "at_ghost")
        }
    }

    func testRestartRestoresCurrentTargetAndHistory() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let first = try makeCompleteTarget(
            weights: [.equity: "0.6", .fixedIncome: "0.4"], now: day)
        try store.record(
            target: first, supersedesTargetID: nil, changeReason: nil, now: day)
        let second = try makeCompleteTarget(
            weights: [.equity: "0.5", .fixedIncome: "0.5"],
            now: day.addingTimeInterval(3_600))
        try store.record(
            target: second, supersedesTargetID: first.id.rawValue,
            changeReason: nil, now: day.addingTimeInterval(3_600))

        // 新实例（模拟 App 重启）
        let reopened = makeStore()
        XCTAssertEqual(try reopened.currentTarget()?.id, second.id)
        XCTAssertEqual(try reopened.history().count, 2)
        XCTAssertEqual(try reopened.history().map(\.target.id),
                       [first.id, second.id], "历史按 createdAt 确定性排序")
    }

    func testEmptyStoreReturnsNilCurrent() throws {
        XCTAssertNil(try makeStore().currentTarget())
        XCTAssertEqual(try makeStore().history().count, 0)
        XCTAssertTrue(try makeStore().resolvableTargetIDs().isEmpty)
    }
}
