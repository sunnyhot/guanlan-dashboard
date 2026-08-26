import XCTest
@testable import QiemanDashboard

// P0 产品重构 §6.2：持仓战略资产分类。
// 优先级（用户显式 > 股票规则 > 披露识别 ≥80% > unresolved）/ 事件幂等 /
// 重启恢复 / unresolved 阻断快照构建 / 估值陈旧 fail-closed / 权重精确归一。

final class StrategicAssetClassAssignmentTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assignment-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeStore() -> StrategicAssetClassAssignmentStore {
        StrategicAssetClassAssignmentStore(workDirectory: workDirectory)
    }

    private func makeCompleteTarget(
        equity: String = "0.5", fixedIncome: String = "0.5", now: Date
    ) throws -> AllocationTarget {
        try StrategicAllocationPolicy().applyUserAllocation(
            entries: AssetClass.allCases.map { assetClass in
                let weight: String
                switch assetClass {
                case .equity: weight = equity
                case .fixedIncome: weight = fixedIncome
                default: weight = "0"
                }
                return AllocationTargetEntry(
                    assetClass: assetClass,
                    targetWeight: Ratio(value: Decimal(string: weight)!)
                )
            },
            note: nil, now: now
        )
    }

    private func fundRow(
        code: String, marketValue: Double,
        priceTime: String? = "2028-12-09 15:00"
    ) -> PersonalAssetAggregateRow {
        IntelligenceV2RuntimeTests.valuedRow(
            code: code, marketValue: marketValue, priceTime: priceTime)
    }

    private func stockRow(code: String, marketValue: Double) -> PersonalAssetAggregateRow {
        IntelligenceV2RuntimeTests.valuedRow(
            code: code, assetType: .stock, marketValue: marketValue)
    }

    private func disclosure(
        code: String, stockPct: Double?, bondPct: Double?, cashPct: Double?,
        asOf: String = "2028-11-15"
    ) -> (code: String, disclosure: FundLookThroughDisclosure) {
        let value = FundLookThroughDisclosure(
            fundCode: code, fundName: code, asOf: asOf,
            holdings: [], industries: [],
            assetAllocation: FundAssetAllocation(
                stockPct: stockPct, bondPct: bondPct, cashPct: cashPct,
                otherPct: nil, disclosureDate: asOf),
            sourceLabel: "测试", sourceURL: "https://example.com", warnings: [])
        return (code, value)
    }

    // MARK: - 分类 Store

    func testAssignmentEventIdempotentAndRestartRestores() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let assignment = StrategicAssetClassAssignmentStore.makeAssignment(
            subjectKey: "fund|000001", assetClass: .equity,
            source: .user, recordedAt: day, note: "宽基")
        try store.record(assignment)
        // 同 ID 同内容幂等
        XCTAssertNoThrow(try store.record(assignment))
        XCTAssertEqual(try store.allEvents().count, 1)

        // 重启恢复（新实例同目录）
        let reopened = makeStore()
        XCTAssertEqual(
            try reopened.currentAssignments()["fund|000001"]?.assetClass, .equity)
        XCTAssertEqual(
            try reopened.currentAssignments()["fund|000001"]?.source, .user)
    }

    func testUserAssignmentOverridesSystemRegardlessOfRecency() throws {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        // 先用户、后系统（更晚）——用户意图不被系统识别覆盖
        try store.record(StrategicAssetClassAssignmentStore.makeAssignment(
            subjectKey: "fund|000001", assetClass: .equity,
            source: .user, recordedAt: day))
        try store.record(StrategicAssetClassAssignmentStore.makeAssignment(
            subjectKey: "fund|000001", assetClass: .fixedIncome,
            source: .systemInferred, recordedAt: day.addingTimeInterval(3_600),
            disclosureDate: "2028-11-15"))
        XCTAssertEqual(
            try store.currentAssignments()["fund|000001"]?.assetClass, .equity,
            "用户意图优先级恒高于系统识别（与时间无关）")
    }

    // MARK: - 解析优先级

    func testResolverPriorityUserOverStockOverDisclosure() {
        let now = Date(timeIntervalSince1970: 1_860_000_000)
        var assignments: [String: StrategicAssetClassAssignmentStore.Assignment] = [:]
        assignments["fund|600519"] = StrategicAssetClassAssignmentStore.makeAssignment(
            subjectKey: "fund|600519", assetClass: .fixedIncome,
            source: .user, recordedAt: now)

        let rows = [
            fundRow(code: "000001", marketValue: 100),   // 披露识别 equity
            stockRow(code: "600519", marketValue: 100),  // 用户覆盖（fixedIncome）
            stockRow(code: "300750", marketValue: 100),  // 股票规则 equity
            fundRow(code: "000009", marketValue: 100),   // 无披露无分类 → unresolved
        ]
        let result = StrategicAssetClassificationResolver.resolve(
            rows: rows, assignments: assignments,
            disclosures: [disclosure(code: "000001", stockPct: 92, bondPct: 5, cashPct: 3).code:
                            disclosure(code: "000001", stockPct: 92, bondPct: 5, cashPct: 3).disclosure],
            now: now)

        XCTAssertEqual(
            result.classification["fund|000001"],
            .resolved(.equity, origin: .systemInferred(disclosureDate: "2028-11-15")))
        XCTAssertEqual(
            result.classification["fund|600519"],
            .resolved(.fixedIncome, origin: .user),
            "用户显式分类优先于股票规则")
        XCTAssertEqual(
            result.classification["fund|300750"],
            .resolved(.equity, origin: .stockRule))
        XCTAssertEqual(result.classification["fund|000009"], .unresolved)
        XCTAssertEqual(result.unresolvedSubjectKeys, ["fund|000009"])
    }

    func testResolverRejectsMixedAndStaleDisclosures() {
        let now = Date(timeIntervalSince1970: 1_860_000_000) // ≈ 2028-12-10 CST
        let rows = [
            fundRow(code: "mixed", marketValue: 100),
            fundRow(code: "stale", marketValue: 100),
        ]
        let result = StrategicAssetClassificationResolver.resolve(
            rows: rows, assignments: [:],
            disclosures: [
                "mixed": disclosure(
                    code: "mixed", stockPct: 60, bondPct: 35, cashPct: 5).disclosure,
                "stale": disclosure(
                    code: "stale", stockPct: 95, bondPct: 3, cashPct: 2,
                    asOf: "2028-01-01").disclosure,   // 距基准 >150 天 → 过期
            ],
            now: now)
        XCTAssertEqual(result.classification["fund|mixed"], .unresolved,
                       "股债混合（无单一类 ≥80%）不可识别")
        XCTAssertEqual(result.classification["fund|stale"], .unresolved,
                       "披露过期不可识别")
        XCTAssertEqual(result.unresolvedSubjectKeys.count, 2)
    }

    // MARK: - 快照构建

    func testBuilderBlocksOnUnclassifiedPositiveWeight() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let rows = [
            fundRow(code: "000001", marketValue: 100),
            fundRow(code: "000009", marketValue: 100),
        ]
        let classification: [String: StrategicAssetClassification] = [
            "fund|000001": .resolved(.equity, origin: .user),
            "fund|000009": .unresolved,
        ]
        XCTAssertThrowsError(
            try LivePortfolioSnapshotBuilder.build(rows: rows, classification: classification, asOf: day)
        ) { error in
            XCTAssertEqual(
                error as? LivePortfolioSnapshotBuilder.BuildError,
                .unclassifiedHoldings(["fund|000009"]),
                "unresolved 正权重持仓阻断执行计划（不用 alternative 兜底）")
        }
    }

    func testBuilderBlocksOnStaleValuation() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000) // ≈ 2028-12-10 CST
        let rows = [
            fundRow(code: "000001", marketValue: 100, priceTime: "2028-12-01 15:00"),
        ]
        XCTAssertThrowsError(
            try LivePortfolioSnapshotBuilder.build(
                rows: rows,
                classification: ["fund|000001": .resolved(.equity, origin: .user)],
                asOf: day)
        ) { error in
            XCTAssertEqual(
                error as? LivePortfolioSnapshotBuilder.BuildError,
                .staleValuation(latestAsOf: date("2028-12-01")))
        }
    }

    func testBuilderNormalizesWeightsExactlyAndAggregatesClasses() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let rows = [
            fundRow(code: "000001", marketValue: 123_456.78),
            fundRow(code: "000002", marketValue: 876_543.21),
            stockRow(code: "600519", marketValue: 555_555.55),
        ]
        let build = try LivePortfolioSnapshotBuilder.build(
            rows: rows,
            classification: [
                "fund|000001": .resolved(.fixedIncome, origin: .user),
                "fund|000002": .resolved(.equity, origin: .user),
                "fund|600519": .resolved(.equity, origin: .stockRule),
            ],
            asOf: day)
        let weightSum = build.portfolio.positions.reduce(Decimal.zero) {
            $0 + $1.weight.value
        }
        XCTAssertEqual(weightSum, Decimal(1), "残差归最大仓后权重和恒精确 = 1")
        let classSum = build.currentClassWeights.values.reduce(Decimal.zero, +)
        XCTAssertEqual(classSum, Decimal(1))
        // subjectKey 只对应真实持仓（3 行 → 3 subject）
        XCTAssertEqual(build.portfolio.positions.count, 3)
        XCTAssertEqual(Set(build.actionDomain.perSubjectBounds.keys),
                       Set(["fund|000001", "fund|000002", "fund|600519"]))
    }

    // MARK: - 决策语义（60/40 vs 50/50 不再恒 HOLD）

    func testDeviationBeyondBandProducesTargetProvenanceActions() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        // 现状 60/40（股/债），目标 50/50 → 偏差 10% > 5% 容忍带
        let rows = [
            stockRow(code: "600519", marketValue: 600_000),
            fundRow(code: "000002", marketValue: 400_000),
        ]
        let target = try makeCompleteTarget(equity: "0.5", fixedIncome: "0.5", now: day)
        let materials = try LivePortfolioDecisionMaterials(
            rows: rows,
            classification: [
                "fund|600519": .resolved(.equity, origin: .stockRule),
                "fund|000002": .resolved(.fixedIncome, origin: .user),
            ],
            target: target, now: day
        ).materials(asOf: day)
        let run = try XCTUnwrap(materials.plannerRuns["current"])
        let plan = TargetRebalancePlanner().plan(
            portfolio: run.portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: run.actionDomain, now: day)
        XCTAssertFalse(plan.actions.isEmpty, "60/40 对 50/50 目标必须产出非零调整")
        XCTAssertTrue(
            plan.actions.allSatisfy {
                if case .targetRebalance = $0.provenance { return true }
                return false
            },
            "调整的 Δw 来源必须是 target provenance（D001）")
    }

    func testAlignedPortfolioWithinBandProducesHold() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        // 现状 52/48 对目标 50/50 → 偏差 2% < 5% 容忍带 → HOLD（无动作）
        let rows = [
            stockRow(code: "600519", marketValue: 520_000),
            fundRow(code: "000002", marketValue: 480_000),
        ]
        let target = try makeCompleteTarget(equity: "0.5", fixedIncome: "0.5", now: day)
        let materials = try LivePortfolioDecisionMaterials(
            rows: rows,
            classification: [
                "fund|600519": .resolved(.equity, origin: .stockRule),
                "fund|000002": .resolved(.fixedIncome, origin: .user),
            ],
            target: target, now: day
        ).materials(asOf: day)
        let run = try XCTUnwrap(materials.plannerRuns["current"])
        let plan = TargetRebalancePlanner().plan(
            portfolio: run.portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: run.actionDomain, now: day)
        XCTAssertTrue(plan.actions.isEmpty, "带内偏差不交易（HOLD）")
    }

    // MARK: - helpers

    private func date(_ yyyyMMdd: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: yyyyMMdd)!
    }
}
