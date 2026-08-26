import XCTest
@testable import QiemanDashboard

// WF-3：Intraday Workflow 测试。
//
// 锁定：D001 纪律（Δw 唯一来源是 planner 的三类 provenance，signal 只作
// 叙述层引用）、Eligibility 前置（非交易日 / 快照陈旧 / 无来源 → hold
// 显式理由）、带内 hold（不交易是决策）、约束门拒绝 → hold、确定性 ID、
// GRDB 落库读回。

private let intradaySubject = try! CanonicalRef(
    entityType: "fundShareClass", entityIDRawValue: "sc_itd"
)
/// 2024-11-06 周三（TestWeekdayCalendar 下是交易日）。
private let intradayDay = Date(timeIntervalSince1970: 1_730_851_200)

final class IntradayWorkflowTests: XCTestCase {

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    /// equity 0.5 + fixedIncome 0.5 的组合。
    private var portfolio: PortfolioSnapshot {
        PortfolioSnapshot(asOf: intradayDay, positions: [
            PortfolioPosition(
                subjectKey: "listing|E", assetClass: .equity,
                weight: Ratio(value: d("0.5"))
            ),
            PortfolioPosition(
                subjectKey: "listing|B", assetClass: .fixedIncome,
                weight: Ratio(value: d("0.5"))
            ),
        ])
    }

    /// equity 0.7 + fixedIncome 0.3（与组合偏差 0.2 > 0.05 容忍带）。
    private var target: AllocationTarget {
        try! StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: d("0.7"))),
                AllocationTargetEntry(assetClass: .fixedIncome, targetWeight: Ratio(value: d("0.3"))),
            ],
            note: "测试目标",
            now: intradayDay
        )
    }

    private var actionDomain: ActionDomain {
        ActionDomain(
            perSubjectBounds: [
                "listing|E": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1"))),
                "listing|B": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1"))),
            ],
            eligibleNewSubjects: [:],
            builderVersion: "itd-test",
            newSubjectBuyUpper: Ratio(value: d("1"))
        )
    }

    private func makeInput(
        portfolio snapshotOverride: PortfolioSnapshot? = nil,
        target targetOverride: AllocationTarget? = nil
    ) -> IntradayWorkflow.Input {
        IntradayWorkflow.Input(
            subject: intradaySubject,
            portfolio: snapshotOverride ?? portfolio,
            target: targetOverride ?? target,
            actionDomain: actionDomain,
            exchange: .nasdaq
        )
    }

    private func makeWorkflow(
        signalStore: InMemorySignalStore = InMemorySignalStore(),
        actionRules: [ConstraintGate.ActionRule] = [],
        portfolioRules: [ConstraintGate.PortfolioRule] = []
    ) -> IntradayWorkflow {
        IntradayWorkflow(
            signalStore: signalStore,
            calendar: TestWeekdayCalendar(),
            actionRules: actionRules,
            portfolioRules: portfolioRules
        )
    }

    /// 预写一条组合信号（叙述层引用验证用）。
    private func seededSignalStore() throws -> InMemorySignalStore {
        let store = InMemorySignalStore()
        try store.write(
            InvestmentSignal(
                id: SignalID(rawValue: "sig_itd_1"),
                subjectCanonical: intradaySubject,
                dimension: .momentum,
                direction: .bullish,
                strength: .moderate,
                derivedFromEvidenceIDs: [EvidenceID(rawValue: "EV-ITD")],
                effectiveAt: intradayDay,
                producer: .llmDefault,
                rationale: "盘中信号（叙述层，不进 Δw）"
            )
        )
        return store
    }

    // MARK: - 执行路径

    func testExecuteRebalanceOnDeviationBeyondBand() throws {
        let signalStore = try seededSignalStore()
        let outcome = makeWorkflow(signalStore: signalStore).run(
            input: makeInput(), asOf: intradayDay, now: intradayDay
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorDetail ?? "")
        let report = try XCTUnwrap(outcome.report)

        XCTAssertEqual(report.decision, .executeRebalance)
        // D001：全部动作 provenance = targetRebalance（本输入只有 target 来源）
        let plan = try XCTUnwrap(report.plan)
        XCTAssertFalse(plan.actions.isEmpty)
        for action in plan.actions {
            guard case .targetRebalance = action.provenance else {
                return XCTFail("盘中执行动作出现非 target provenance：\(action.provenance)")
            }
        }
        // 偏差 0.2 → equity 加仓、bond 减仓
        let equityDelta = plan.actions
            .first { $0.action.subjectKey == "listing|E" }?.action.deltaWeight.value
        XCTAssertNotNil(equityDelta)
        XCTAssertTrue(equityDelta! > 0, "equity 目标 0.7 > 当前 0.5 → 加仓")

        // signal 只作叙述层引用（不进 Δw 数学）
        XCTAssertEqual(report.referencedSignalIDs, [SignalID(rawValue: "sig_itd_1")])
        XCTAssertTrue(
            report.dependencies.contains {
                $0.kind == .signal && $0.referenceID == "sig_itd_1"
            }
        )
        XCTAssertTrue(
            report.dependencies.contains {
                $0.kind == .target && $0.referenceID == target.id.rawValue
            }
        )
        // 盘口语义：本交易时段有效
        if case .tradingSession(let exchange, _) = report.validityPolicy {
            XCTAssertEqual(exchange, .nasdaq)
        } else {
            XCTFail("盘中报告 validity 应为 tradingSession")
        }
        XCTAssertEqual(report.gateVerdict?.passed, true)
    }

    // MARK: - Eligibility hold 路径

    func testHoldOnNonTradingDay() throws {
        // 2024-11-09 周六（非交易日）
        let saturday = intradayDay.addingTimeInterval(3 * 86400)
        // 快照同日构造避免触发陈旧检查
        let freshSnapshot = PortfolioSnapshot(asOf: saturday, positions: portfolio.positions)
        let outcome = makeWorkflow().run(
            input: makeInput(portfolio: freshSnapshot),
            asOf: saturday, now: saturday
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorDetail ?? "")
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.first?.contains("非交易日") ?? false
        )
    }

    func testHoldOnStaleSnapshot() throws {
        // 快照 3 天前（> 26h）
        let staleSnapshot = PortfolioSnapshot(
            asOf: intradayDay.addingTimeInterval(-3 * 86400),
            positions: portfolio.positions
        )
        let outcome = makeWorkflow().run(
            input: makeInput(portfolio: staleSnapshot),
            asOf: intradayDay, now: intradayDay
        )
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.first?.contains("快照陈旧") ?? false
        )
        XCTAssertNil(outcome.report?.plan)
    }

    func testHoldWithoutProvenanceSource() throws {
        let noSourceInput = IntradayWorkflow.Input(
            subject: intradaySubject,
            portfolio: portfolio,
            target: nil,
            actionDomain: actionDomain,
            exchange: .nasdaq
        )
        let outcome = makeWorkflow().run(
            input: noSourceInput, asOf: intradayDay, now: intradayDay
        )
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.contains {
                $0.contains("无 provenance 来源")
            } ?? false
        )
        XCTAssertNil(outcome.report?.plan, "D001：无来源不产 Δw")
    }

    func testHoldWithinToleranceBand() throws {
        // 目标与组合一致（偏差 0 < 容忍带 0.05）→ hold（不交易是决策）
        let alignedTarget = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: d("0.5"))),
                AllocationTargetEntry(assetClass: .fixedIncome, targetWeight: Ratio(value: d("0.5"))),
            ],
            note: nil, now: intradayDay
        )
        let outcome = makeWorkflow().run(
            input: makeInput(target: alignedTarget),
            asOf: intradayDay, now: intradayDay
        )
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.first?.contains("容忍带内") ?? false
        )
    }

    // MARK: - 约束门路径

    func testHoldWhenPortfolioRuleViolated() throws {
        // noNegativeWeights：卖出超过持仓的指令（userDirective provenance）
        // → 投影负权重 → gate 拒绝 → hold（violations 显式）
        let input = IntradayWorkflow.Input(
            subject: intradaySubject,
            portfolio: portfolio,
            target: nil,
            remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(
                    subjectKey: "listing|E",
                    deltaWeight: Ratio(value: d("-0.6")),
                    directiveID: "u-sell-too-much",
                    note: "超额卖出"
                )
            ],
            actionDomain: ActionDomain(
                perSubjectBounds: [
                    "listing|E": .init(
                        lower: Ratio(value: d("-1")), upper: Ratio(value: d("1"))
                    ),
                ],
                eligibleNewSubjects: [:],
                builderVersion: "itd-test",
                newSubjectBuyUpper: Ratio(value: d("1"))
            ),
            exchange: .nasdaq
        )
        let outcome = makeWorkflow(portfolioRules: [.noNegativeWeights]).run(
            input: input, asOf: intradayDay, now: intradayDay
        )
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.contains { $0.contains("noNegativeWeights") } ?? false
        )
        // gate 结论随报告留证
        XCTAssertEqual(outcome.report?.gateVerdict?.passed, false)
    }

    func testActionRulePrunesSmallDeltas() throws {
        // 最小交易量 0.3：偏差 0.2 的 pro-rata 动作（每标的 0.1）全部被裁 → hold
        let outcome = makeWorkflow(actionRules: [.minTradeSize(d("0.3"))]).run(
            input: makeInput(), asOf: intradayDay, now: intradayDay
        )
        XCTAssertEqual(outcome.report?.decision, .hold)
        XCTAssertTrue(
            outcome.report?.holdReasons.first?.contains("约束裁剪") ?? false
        )
    }

    // MARK: - 确定性与落库

    func testDeterminismAndGRDBRoundTrip() throws {
        let signalStore = try seededSignalStore()
        let first = try XCTUnwrap(makeWorkflow(signalStore: signalStore).run(
            input: makeInput(), asOf: intradayDay, now: intradayDay
        ).report)
        let second = try XCTUnwrap(makeWorkflow(signalStore: signalStore).run(
            input: makeInput(), asOf: intradayDay, now: intradayDay
        ).report)
        XCTAssertEqual(first.id, second.id)

        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        try databaseRoundTrip(repository, report: first)
    }

    private func databaseRoundTrip(
        _ repository: GRDBRepository, report: IntradayExecutionReport
    ) throws {
        try repository.database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(report), into: db)
        }
        let readBack = try repository.database.queue.read { db in
            try ArtifactRow.fetchIntradayExecutionReport(id: report.id.rawValue, from: db)
        }
        XCTAssertEqual(readBack, report)
    }
}
