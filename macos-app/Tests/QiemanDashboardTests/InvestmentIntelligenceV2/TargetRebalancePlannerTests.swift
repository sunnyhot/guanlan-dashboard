import XCTest
@testable import QiemanDashboard

/// DEC-5 单元测试：TargetRebalancePlanner——pro-rata 分配 + SizingProvenance。
final class TargetRebalancePlannerTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func makeTarget(_ entries: [(AssetClass, String)]) throws -> AllocationTarget {
        try StrategicAllocationPolicy().applyUserAllocation(
            entries: entries.map { AllocationTargetEntry(assetClass: $0.0, targetWeight: r($0.1)) },
            note: nil, now: day
        )
    }

    /// 组合:equity 0.7(A 0.5 + L1 0.2)+ fixedIncome 0.3(B)
    private var portfolio: PortfolioSnapshot {
        PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(subjectKey: "fund|A", assetClass: .equity, weight: r("0.5")),
            PortfolioPosition(subjectKey: "listing|L1", assetClass: .equity, weight: r("0.2")),
            PortfolioPosition(subjectKey: "fund|B", assetClass: .fixedIncome, weight: r("0.3")),
        ])
    }

    /// 宽域(卖到 0 / 买到 1)——域约束在专门用例测。
    private var wideDomain: ActionDomain {
        ActionDomain(
            perSubjectBounds: [
                "fund|A": .init(lower: r("-1"), upper: r("1")),
                "listing|L1": .init(lower: r("-1"), upper: r("1")),
                "fund|B": .init(lower: r("-1"), upper: r("1")),
            ],
            eligibleNewSubjects: [:],
            builderVersion: "test",
            newSubjectBuyUpper: r("1")
        )
    }

    private func actionsBySubject(_ plan: PortfolioActionPlan) -> [String: [PlannedAction]] {
        Dictionary(grouping: plan.actions, by: { $0.action.subjectKey })
    }

    // MARK: - Target 跟随(pro-rata golden)

    func testTargetRebalanceProRata() throws {
        // target: equity 0.6 / fixedIncome 0.4(带 0.05)
        // equity 0.7 → 0.6:Δ = −0.1 → A(5/7)−0.0714285714286,L1(2/7)−0.0285714285714
        // fixedIncome 0.3 → 0.4:B +0.1
        let target = try makeTarget([(.equity, "0.6"), (.fixedIncome, "0.4")])
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: wideDomain, now: day
        )

        XCTAssertEqual(plan.targetID, target.id)
        XCTAssertEqual(plan.notes.isEmpty, true)
        let bySubject = actionsBySubject(plan)
        XCTAssertEqual(bySubject["fund|A"]?.first?.action.deltaWeight.value ?? 0, d("-0.071428571428"), accuracy: d("0.000000000001"))
        XCTAssertEqual(bySubject["listing|L1"]?.first?.action.deltaWeight.value ?? 0, d("-0.028571428571"), accuracy: d("0.000000000001"))
        XCTAssertEqual(bySubject["fund|B"]?.first?.action.deltaWeight.value ?? 0, d("0.1"))
        // 全部 provenance = target
        XCTAssertTrue(plan.actions.allSatisfy {
            if case .targetRebalance(let t) = $0.provenance { return t.targetID == target.id }
            return false
        })
    }

    func testToleranceBandSkipsSmallDeviation() throws {
        // target: equity 0.72 / fixedIncome 0.28(偏差 0.02 ≤ 0.05)→ 无动作
        let target = try makeTarget([(.equity, "0.72"), (.fixedIncome, "0.28")])
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: wideDomain, now: day
        )
        XCTAssertTrue(plan.actions.isEmpty, "带内偏差不交易")
    }

    func testZeroTargetClassLiquidated() throws {
        // target: equity 1.0 / fixedIncome 0(清仓 B)
        let target = try makeTarget([(.equity, "1.0")])
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: wideDomain, now: day
        )
        let bySubject = actionsBySubject(plan)
        XCTAssertEqual(bySubject["fund|B"]?.first?.action.deltaWeight.value ?? 0, d("-0.3"), "目标 0 的类整类清仓")
        // equity 0.7 → 1.0:偏差 0.3(≤ 带? 0.3 > 0.05 交易)
        XCTAssertEqual(bySubject["fund|A"]?.first?.action.deltaWeight.value ?? 0, d("0.214285714286"), accuracy: d("0.000000000001"))
    }

    func testTargetClassWithoutPositionProducesNoteNotGuess() throws {
        // target 含 cash 0.1 但组合无 cash 持仓 → note,不引入新标的
        let target = try makeTarget([(.equity, "0.7"), (.fixedIncome, "0.2"), (.cash, "0.1")])
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: wideDomain, now: day
        )
        XCTAssertTrue(plan.notes.contains { $0.contains("CASH") && $0.contains("不引入新标的") })
        // 其他类正常调整(equity 0.7→0.7 带内;fixedIncome 0.3→0.2 交易)
        let bySubject = actionsBySubject(plan)
        XCTAssertEqual(bySubject["fund|B"]?.first?.action.deltaWeight.value ?? 0, d("-0.1"))
    }

    // MARK: - remediation / user 来源

    func testRemediationSellsDownToCap() throws {
        let target = try makeTarget([(.equity, "0.7"), (.fixedIncome, "0.3")])  // 带内,无 target 动作
        let requirement = RemediationRequirement(
            directive: "将标的 fund|A 的组合暴露降至 10% 以下",
            relatedKey: "fund|A", constraintID: "c-single"
        )
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [
                RemediationTargetInput(subjectKey: "fund|A", maxWeight: r("0.1"), requirement: requirement)
            ],
            userDirectives: [], actionDomain: wideDomain, now: day
        )
        let bySubject = actionsBySubject(plan)
        XCTAssertEqual(bySubject["fund|A"]?.count, 1)
        XCTAssertEqual(bySubject["fund|A"]?.first?.action.deltaWeight.value, d("-0.4"), "0.5 → cap 0.1")
        guard case .remediation(let rem) = bySubject["fund|A"]?.first?.provenance else {
            return XCTFail("remediation 来源必须保留 requirement")
        }
        XCTAssertEqual(rem.requirement.constraintID, "c-single")

        // 已在 cap 内 → 无动作
        let ok = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [
                RemediationTargetInput(subjectKey: "fund|B", maxWeight: r("0.5"), requirement: requirement)
            ],
            userDirectives: [], actionDomain: wideDomain, now: day
        )
        XCTAssertTrue(actionsBySubject(ok)["fund|B"] == nil)
    }

    func testUserDirectivePassesThroughWithEventReference() throws {
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: nil,
            remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "fund|B", deltaWeight: r("0.05"),
                                   directiveID: "user-op-123", note: "手动加仓")
            ],
            actionDomain: wideDomain, now: day
        )
        XCTAssertNil(plan.targetID, "纯 user 计划无 target")
        let user = plan.actions.first {
            if case .userDirective = $0.provenance { return true }
            return false
        }
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.action.deltaWeight.value, d("0.05"))
        guard case .userDirective(let detail) = user?.provenance else { return XCTFail() }
        XCTAssertEqual(detail.directiveID, "user-op-123")
        XCTAssertEqual(detail.note, "手动加仓")
    }

    func testMultipleSourcesCoexistPerSubject() throws {
        // A 同时有 target 动作 + remediation 动作 → 两条各自留证(投影层合并)
        let target = try makeTarget([(.equity, "0.6"), (.fixedIncome, "0.4")])
        let requirement = RemediationRequirement(
            directive: "降 A", relatedKey: "fund|A", constraintID: "c"
        )
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [RemediationTargetInput(subjectKey: "fund|A", maxWeight: r("0.3"), requirement: requirement)],
            userDirectives: [], actionDomain: wideDomain, now: day
        )
        XCTAssertEqual(actionsBySubject(plan)["fund|A"]?.count, 2, "同标的多来源并存")
        let projected = ProjectedPortfolio.project(base: portfolio, applying: plan.actions.map(\.action))
        let aWeight = projected.positions.first { $0.subjectKey == "fund|A" }!.weight.value
        // 0.5 + (−0.0714…) + (−0.2) = 0.2285…
        XCTAssertEqual(aWeight, d("0.228571428571"), accuracy: d("0.000000000001"), "投影合并后权重正确")
    }

    // MARK: - 动作域门禁 + 确定性

    func testOutOfDomainActionsPrunedWithNotes() throws {
        let target = try makeTarget([(.equity, "0.4"), (.fixedIncome, "0.6")])
        // 窄域:A 只能卖 0.05,L1 禁卖,B 无限制
        let narrow = ActionDomain(
            perSubjectBounds: [
                "fund|A": .init(lower: r("-0.05"), upper: r("0")),
                "listing|L1": .init(lower: r("0"), upper: r("0")),
                "fund|B": .init(lower: r("-1"), upper: r("1")),
            ],
            eligibleNewSubjects: [:], builderVersion: "test", newSubjectBuyUpper: r("0")
        )
        let plan = TargetRebalancePlanner().plan(
            portfolio: portfolio, target: target,
            remediationTargets: [], userDirectives: [],
            actionDomain: narrow, now: day
        )
        // equity 0.7 → 0.4:A −0.214…(超 −0.05 被剔除)、L1 −0.085…(禁卖被剔除)
        // fixedIncome 0.3 → 0.6:B +0.3 保留
        let bySubject = actionsBySubject(plan)
        XCTAssertNil(bySubject["fund|A"])
        XCTAssertNil(bySubject["listing|L1"])
        XCTAssertEqual(bySubject["fund|B"]?.first?.action.deltaWeight.value, d("0.3"))
        XCTAssertEqual(plan.notes.filter { $0.contains("超出动作域被剔除") }.count, 2, "剔除不静默")
    }

    func testDeterministicPlanIdAndCodable() throws {
        let target = try makeTarget([(.equity, "0.6"), (.fixedIncome, "0.4")])
        let planner = TargetRebalancePlanner()
        let a = planner.plan(portfolio: portfolio, target: target,
                             remediationTargets: [], userDirectives: [],
                             actionDomain: wideDomain, now: day)
        let b = planner.plan(portfolio: portfolio, target: target,
                             remediationTargets: [], userDirectives: [],
                             actionDomain: wideDomain, now: day)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.plannerVersion, "v1")

        // 输入顺序不同的 userDirectives → 同 plan(排序确定)
        let c = planner.plan(
            portfolio: portfolio, target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "fund|A", deltaWeight: r("0.01"), directiveID: "1", note: nil),
                UserDirectiveInput(subjectKey: "fund|B", deltaWeight: r("0.02"), directiveID: "2", note: nil),
            ],
            actionDomain: wideDomain, now: day
        )
        let d2 = planner.plan(
            portfolio: portfolio, target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "fund|B", deltaWeight: r("0.02"), directiveID: "2", note: nil),
                UserDirectiveInput(subjectKey: "fund|A", deltaWeight: r("0.01"), directiveID: "1", note: nil),
            ],
            actionDomain: wideDomain, now: day
        )
        XCTAssertEqual(c.actions.map(\.action.subjectKey), d2.actions.map(\.action.subjectKey), "动作排序与输入顺序无关")

        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(PortfolioActionPlan.self, from: data)
        XCTAssertEqual(decoded, a)
    }
}

private func XCTAssertEqual(_ lhs: Decimal, _ rhs: Decimal, accuracy: Decimal,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(lhs - rhs) <= accuracy, "\(lhs) ≠ \(rhs) (±\(accuracy))", file: file, line: line)
}
