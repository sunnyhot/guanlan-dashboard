import XCTest
@testable import QiemanDashboard

/// DEC-9 单元测试：PortfolioDecisionArtifact / DecisionValidator / Replay
/// （ADR-D004：引用 IDs 重放不重跑 Research；same inputs → same decision）。
final class PortfolioDecisionArtifactTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private var band: IndifferenceBand {
        IndifferenceBand(policyID: "b", version: "v1", defaultBand: d("0.01"),
                         rationale: "test band")
    }

    private func makePlan(_ key: String, delta: String) -> PortfolioActionPlan {
        let planner = TargetRebalancePlanner()
        return planner.plan(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "listing|A", deltaWeight: Ratio(value: d(delta)),
                                   directiveID: "u-\(key)", note: nil)
            ],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "test",
                newSubjectBuyUpper: Ratio(value: d("1"))
            ),
            now: day
        )
    }

    /// 自洽 comparison(三轮 P1-6 可推导 + 四轮 P1-2 完整 pairwise 域):
    /// pairwise 覆盖全部无序对 C(n,2)(键为字典序 a|b);singlePreferred 时
    /// 唯一 admissible 支配其余、其余互不可比,unresolved 时全部互不可比
    /// ——前沿与 decision 均与 PartialDecisionPolicy 推导一致。
    private static func consistentComparison(
        for decision: PartialDecision, allPlans: [String]
    ) -> PlanComparisonResult {
        let sorted = allPlans.sorted()
        var pairwise: [String: PairwiseDominance] = [:]
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                let dominance: PairwiseDominance
                if decision.admissiblePlans.count == 1,
                   let winner = decision.admissiblePlans.first {
                    if a == winner { dominance = .aDominatesB }
                    else if b == winner { dominance = .bDominatesA }
                    else { dominance = .incomparable }
                } else {
                    dominance = .incomparable
                }
                pairwise["\(a)|\(b)"] = dominance
            }
        }
        var dominated = Set<String>()
        for (key, dominance) in pairwise {
            let parts = key.split(separator: "|").map(String.init)
            switch dominance {
            case .aDominatesB: dominated.insert(parts[1])
            case .bDominatesA: dominated.insert(parts[0])
            case .incomparable: break
            }
        }
        let front = sorted.filter { !dominated.contains($0) }
        return PlanComparisonResult(pairwise: pairwise, paretoFront: front, blockingUnknowns: [])
    }

    private func makeArtifact(
        decision: PartialDecision,
        plans: [String: PortfolioActionPlan],
        comparison: PlanComparisonResult? = nil
    ) -> PortfolioDecisionArtifact {
        let resolvedComparison = comparison ?? Self.consistentComparison(
            for: decision, allPlans: plans.keys.sorted()
        )
        return PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            bandVersion: "b@v1",
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: resolvedComparison,
            plans: plans,
            producedAt: day
        )
    }

    // MARK: - Validator(D004 §2 provenance 闭环)

    func testValidatorPassesOnCompleteArtifact() throws {
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"],
                                       explanation: "互不支配")
        let artifact = makeArtifact(decision: decision, plans: ["A": makePlan("A", delta: "0.05"),
                                                                "B": makePlan("B", delta: "-0.05")])
        try DecisionValidator().validate(artifact: artifact, resolvers: .everythingResolvable)
    }

    func testValidatorRejectsAdmissiblePlanNotInPlans() {
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["GHOST"],
                                       explanation: "x")
        let artifact = makeArtifact(decision: decision, plans: ["A": makePlan("A", delta: "0.05")])
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .admissiblePlanNotFound("GHOST"))
        }
    }

    func testValidatorRejectsEmptyCriterionVersions() {
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [], criterionVersions: [],
            factorSnapshotIDs: [], target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "", decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: ["A": makePlan("A", delta: "0.05")], producedAt: day
        )
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptyCriterionVersions)
        }
    }

    // MARK: - Replay(D004 §3:same IDs → same decision;不重跑 Research)

    private func score(_ id: String, _ v: Decimal, channel: CriterionDefinition.InputReference.Kind = .signalCardinal) -> CriterionScore {
        CriterionScore(
            definition: CriterionDefinition(
                id: id, version: "v1", evaluatorKind: .weightedSum,
                inputReferences: [CriterionDefinition.InputReference(
                    kind: channel, referenceID: "\(id)-in", weight: 1)],
                unit: .ratio),
            value: v, missingInputs: [], computation: "t")
    }

    /// 规划输入(审查 P1-1:重放覆盖 Planner→Compare→Decide 全链)。
    private func plannerRun(delta: String) -> DecisionReplayer.PlannerRun {
        DecisionReplayer.PlannerRun(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "listing|A", deltaWeight: Ratio(value: d(delta)),
                                   directiveID: "u-replay", note: nil)
            ],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "test",
                newSubjectBuyUpper: Ratio(value: d("1"))
            ),
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
    }

    /// 测试 resolver:返回预构 inputs(声明 artifact 引用的 signal/factor)。
    private struct TestResolver: DecisionReplayer.InputResolving {
        let inputs: DecisionReplayer.ReplayInputs
        func resolveInputs(for artifact: PortfolioDecisionArtifact) throws -> DecisionReplayer.ReplayInputs {
            inputs
        }
    }

    /// 与 plannerRun 相同输入直接产 plan(artifact plans 与重放 plans 同源,
    /// verify 的 plans 全等才有意义)。
    private func planFrom(_ run: DecisionReplayer.PlannerRun) -> PortfolioActionPlan {
        TargetRebalancePlanner(parameters: run.plannerParameters).plan(
            portfolio: run.portfolio, target: run.target,
            remediationTargets: run.remediationTargets, userDirectives: run.userDirectives,
            actionDomain: run.actionDomain, now: day
        )
    }

    func testReplayDeterministic_sameInputsSamePlansAndDecision() throws {
        // 完整重放覆盖 Planner——同 inputs 产出**相同行动计划**
        // (Δw 与 provenance),不只是相同方案键。criterion 声明与 scores
        // 实际 definition 一致(四轮 P1-1:曾自报不一致仍通过,现在
        // derivedReferences 从内容派生,不符即拒)。
        let inputs = DecisionReplayer.ReplayInputs(
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "-0.05")],
            scores: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:],
            resolvedReferences: .init(
                signalIDs: ["sig-1"], factorSnapshotIDs: ["fs_abc"],
                criterionVersions: [],   // criterion 由 derived 派生,自报被忽略
                targetID: nil, bandVersion: "X"   // band 同样由实例派生
            )
        )
        let resolver = TestResolver(inputs: inputs)
        // artifact 引用层与 scores 实际 definition 派生一致
        let artifact = makeArtifact(
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x"),
            plans: ["A": makePlan("A", delta: "0.05"), "B": makePlan("B", delta: "-0.05")],
            comparison: nil
        )
        // makeArtifact 的 criterionVersions 是 ["portfolio-momentum@v1"]——与
        // scores 派生(momentum@v1/costScore@v1)不一致 → 四轮校验拒绝
        XCTAssertThrowsError(try DecisionReplayer().replay(artifact: artifact, resolver: resolver, now: day)) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("派生 criterion 不符应拒,实际 \(error)")
            }
        }
        // criterion 一致的 artifact → 重放成功且确定性
        let consistent = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "test",
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x"),
                allPlans: ["A", "B"]),
            plans: ["A": makePlan("A", delta: "0.05"), "B": makePlan("B", delta: "-0.05")],
            producedAt: day
        )
        let replayer = DecisionReplayer()
        let first = try replayer.replay(artifact: consistent, resolver: resolver, now: day)
        let second = try replayer.replay(artifact: consistent, resolver: resolver, now: day)
        XCTAssertEqual(first, second, "same resolved inputs → same decision + same plans(M7/D004)")
        XCTAssertEqual(first.decision.status, .unresolvedTradeoff)
        XCTAssertEqual(first.plans["A"]?.actions.first?.action.deltaWeight.value, d("0.05"))
        guard case .userDirective = first.plans["A"]?.actions.first?.provenance else {
            return XCTFail("重放的 plan 保留 provenance")
        }
    }

    func testWhatIfReplayProducesNewDecisionWithoutTouchingBase() {
        let base = DecisionReplayer.ReplayInputs(
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "-0.05")],
            scores: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:]
        )
        let replayer = DecisionReplayer()
        // what-if:B 的 momentum 换成碾压值 → singlePreferred B
        let whatIf = replayer.replayWhatIf(base: base, replacingScores: [
            "B": [score("momentum", d("0.09")), score("costScore", d("0.03"))],
        ], now: day)
        XCTAssertEqual(whatIf.decision.status, .singlePreferred)
        XCTAssertEqual(whatIf.decision.admissiblePlans, ["B"])

        // what-if 确定性:同 base 同替换 → 同结果(原 artifact 不受影响——
        // what-if 产新决策素材,D004 §5)
        let whatIfAgain = replayer.replayWhatIf(base: base, replacingScores: [
            "B": [score("momentum", d("0.09")), score("costScore", d("0.03"))],
        ], now: day)
        XCTAssertEqual(whatIfAgain, whatIf)
    }

    func testValidatorRejectsInternallyContradictoryResults() throws {
        // 三轮 P1-6 回归:结果层内部矛盾拒收
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let plans = ["A": makePlan("A", delta: "0.05")]

        // ① 四轮 P1-2 回归:pairwise 不完整(缺失 pair)→ pairwiseDomainIncomplete
        let incompletePairwise = makeArtifact(
            decision: decision, plans: ["A": plans["A"]!, "B": makePlan("B", delta: "-0.05")],
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: ["A", "B"], blockingUnknowns: [])
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: incompletePairwise, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .pairwiseDomainIncomplete(expected: ["A|B"], actual: []),
                           "两个 plan + 空 pairwise 不再被接受")
        }

        // ② 前沿含 plans 外的 GHOST(域违规仍先拒)
        let ghostFront = makeArtifact(
            decision: decision, plans: plans,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: ["GHOST"], blockingUnknowns: [])
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: ghostFront, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .comparisonPlanDomainViolation(keys: ["GHOST"]))
        }

        // ③ 完整 pairwise 但前沿与推导矛盾(A dom B 却声称前沿含 B)
        let frontLie = makeArtifact(
            decision: decision, plans: ["A": plans["A"]!, "B": makePlan("B", delta: "-0.05")],
            comparison: PlanComparisonResult(
                pairwise: ["A|B": .aDominatesB], paretoFront: ["A", "B"], blockingUnknowns: [])
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: frontLie, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .paretoFrontInconsistent(derived: ["A"], declared: ["A", "B"]))
        }

        // ④ decision 与 comparison 推导矛盾(完整 pairwise 全 incomparable,
        // 前沿 [A,B],却声称 singlePreferred A)
        let contradictory = makeArtifact(
            decision: decision, plans: ["A": plans["A"]!, "B": makePlan("B", delta: "-0.05")],
            comparison: PlanComparisonResult(
                pairwise: ["A|B": .incomparable], paretoFront: ["A", "B"], blockingUnknowns: [])
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: contradictory, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .decisionNotDerivedFromComparison)
        }

        // 自洽对照(makeArtifact 的 consistentComparison 生成完整域)→ 通过
        XCTAssertNoThrow(try DecisionValidator().validate(
            artifact: makeArtifact(decision: decision, plans: plans),
            resolvers: .everythingResolvable
        ))
    }

    func testValidatorRejectsTargetProvenanceMismatch() throws {
        // 四轮 P1-3 回归:plan/action 的 Target 引用与 artifact.target 不一致拒收
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: d("1.0")))],
            note: nil, now: day
        )
        // planner 产自 target 的 plan
        let plan = TargetRebalancePlanner().plan(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: target, remediationTargets: [], userDirectives: [],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "t", newSubjectBuyUpper: Ratio(value: 1)),
            now: day
        )
        // artifact.target 是 target → plan.targetID 一致,自洽通过
        let consistent = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "s")], criterionVersions: ["c@v1"],
            factorSnapshotIDs: [], target: target, bandVersion: "b@v1",
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
                allPlans: ["A"]),
            plans: ["A": plan], producedAt: day
        )
        XCTAssertNoThrow(try DecisionValidator().validate(
            artifact: consistent, resolvers: .everythingResolvable
        ))

        // 换一个 target(不同 id)但保留旧 plan → provenance 不一致拒收
        let otherTarget = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [AllocationTargetEntry(assetClass: .cash, targetWeight: Ratio(value: d("1.0")))],
            note: nil, now: day.addingTimeInterval(3600)
        )
        let mismatched = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "s")], criterionVersions: ["c@v1"],
            factorSnapshotIDs: [], target: otherTarget, bandVersion: "b@v1",
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
                allPlans: ["A"]),
            plans: ["A": plan], producedAt: day
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: mismatched, resolvers: .everythingResolvable
        )) { error in
            guard case DecisionValidator.ValidationError.targetProvenanceMismatch = error else {
                return XCTFail("应为 target provenance 不一致,实际 \(error)")
            }
        }
    }

    func testArtifactBoundReplayVerifiesEndToEnd() throws {
        // 以 artifact + resolver 为入口的完整重放:绑定校验(criterion/band/
        // target 从内容派生 + resolver 声明 signal/factor)→ decision/
        // comparison/plans 三层全等验证(同 IDs → 同决策)
        let inputs = DecisionReplayer.ReplayInputs(
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "-0.05")],
            scores: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:],
            resolvedReferences: .init(
                signalIDs: ["sig-1"], factorSnapshotIDs: ["fs_abc"]
            )
        )
        // artifact 引用层与 inputs 一致:criterion 用派生集合、band 用 b@v1
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        let artifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "test",
            decision: decision,
            comparison: Self.consistentComparison(for: decision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: "0.05")),
                "B": planFrom(plannerRun(delta: "-0.05")),
            ],
            producedAt: day
        )
        let resolver = TestResolver(inputs: inputs)
        // verify 通过(绑定一致 + decision/comparison/plans 全等)
        XCTAssertNoThrow(try DecisionReplayer().verify(artifact: artifact, resolver: resolver, now: day))

        // resolver 声明的 signal 引用与 artifact 不一致 → referenceMismatch
        let wrongSignal = TestResolver(inputs: DecisionReplayer.ReplayInputs(
            plannerRuns: inputs.plannerRuns, scores: inputs.scores,
            band: inputs.band, higherIsBetter: inputs.higherIsBetter,
            resolvedReferences: .init(signalIDs: ["sig-OTHER"], factorSnapshotIDs: ["fs_abc"])
        ))
        XCTAssertThrowsError(try DecisionReplayer().verify(artifact: artifact, resolver: wrongSignal, now: day)) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为 referenceMismatch,实际 \(error)")
            }
        }

        // 键域不一致(plannerRuns 多了 C)→ planKeyDomainMismatch
        var badPlanner = inputs.plannerRuns
        badPlanner["C"] = plannerRun(delta: "0")
        let badKeys = TestResolver(inputs: DecisionReplayer.ReplayInputs(
            plannerRuns: badPlanner, scores: inputs.scores,
            band: inputs.band, higherIsBetter: inputs.higherIsBetter,
            resolvedReferences: .init(signalIDs: ["sig-1"], factorSnapshotIDs: ["fs_abc"])
        ))
        XCTAssertThrowsError(try DecisionReplayer().replay(artifact: artifact, resolver: badKeys, now: day)) { error in
            guard case DecisionReplayer.ReplayError.planKeyDomainMismatch = error else {
                return XCTFail("应为键域不一致,实际 \(error)")
            }
        }

        // artifact 域不一致(artifact 只含 A)→ artifactPlanDomainMismatch
        let singleDecision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let singleArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "test",
            decision: singleDecision,
            comparison: Self.consistentComparison(for: singleDecision, allPlans: ["A"]),
            plans: ["A": planFrom(plannerRun(delta: "0.05"))],
            producedAt: day
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(artifact: singleArtifact, resolver: resolver, now: day)) { error in
            guard case DecisionReplayer.ReplayError.artifactPlanDomainMismatch = error else {
                return XCTFail("应为 artifact 域不一致,实际 \(error)")
            }
        }

        // 内容漂移(artifact 的 decision 与重放不一致)→ replayMismatch
        let driftedDecision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "漂移")
        let drifted = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "test",
            decision: driftedDecision,
            comparison: Self.consistentComparison(for: driftedDecision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: "0.05")),
                "B": planFrom(plannerRun(delta: "-0.05")),
            ],
            producedAt: day
        )
        XCTAssertThrowsError(try DecisionReplayer().verify(artifact: drifted, resolver: resolver, now: day)) { error in
            guard case DecisionReplayer.ReplayError.replayMismatch = error else {
                return XCTFail("应为重放不一致,实际 \(error)")
            }
        }
    }

    func testValidatorFailsClosedOnUnresolvableReferences() {
        // 审查 P1-1 回归:任一类引用无法解析 → 抛错,不静默放行
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = makeArtifact(decision: decision, plans: ["A": makePlan("A", delta: "0.05")])

        // Signal 不可解析
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(signal: { _ in false })
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "signal", id: "sig-1"))
        }
        // FactorSnapshot 不可解析(其余项显式放行)
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(
                signal: { _ in true },
                factorSnapshot: { id in id.rawValue != "fs_abc" },
                criterion: { _ in true },
                indifferenceBand: { _ in true }
            )
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "factorSnapshot", id: "fs_abc"))
        }
        // Criterion 不可解析(其余项显式放行)
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(
                signal: { _ in true },
                factorSnapshot: { _ in true },
                criterion: { _ in false }
            )
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "criterion", id: "portfolio-momentum@v1"))
        }
        // Band 不可解析(其余项显式放行)
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(
                signal: { _ in true },
                factorSnapshot: { _ in true },
                criterion: { _ in true },
                indifferenceBand: { _ in false }
            )
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "indifferenceBand", id: "b@v1"))
        }
        // 二轮审查 P1-1:默认调用(不传 resolver)fail-closed 拒绝一切引用
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "signal", id: "sig-1"),
                           "默认无 resolver = 无法证明可解析 = 拒绝")
        }
        // 显式声明全部可解析 → 通过(调用方为引用真实性背书)
        XCTAssertNoThrow(try DecisionValidator().validate(
            artifact: artifact, resolvers: .everythingResolvable
        ))
    }

    // MARK: - Artifact 形态

    func testArtifactImmutableHistoricalAndDeterministicId() {
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let plans = ["A": makePlan("A", delta: "0.05")]
        let a = makeArtifact(decision: decision, plans: plans)
        let b = makeArtifact(decision: decision, plans: plans)
        XCTAssertEqual(a.validityPolicy, .immutableHistorical)
        XCTAssertEqual(a.id, b.id, "引用层+结果层相同 → 同 id(producedAt 不参与)")
        // dependencies 覆盖 signal + factorSnapshot 引用(D004 引用层)
        XCTAssertEqual(Set(a.dependencies.map(\.referenceID)), ["sig-1", "fs_abc"])
        XCTAssertTrue(a.dependencies.contains { $0.kind == .signal })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .factorSnapshot })

        // 引用层变化 → id 变化
        let differentSignals = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-2")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1", knowledgeContextSummary: "",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: plans, producedAt: day
        )
        XCTAssertNotEqual(a.id, differentSignals.id)
    }

    func testCodableRoundTrip() throws {
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"],
                                       explanation: "互不支配")
        let artifact = makeArtifact(decision: decision, plans: ["A": makePlan("A", delta: "0.05"),
                                                                "B": makePlan("B", delta: "-0.05")])
        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(PortfolioDecisionArtifact.self, from: data)
        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.signalIDs.map(\.rawValue), ["sig-1"])
        XCTAssertEqual(decoded.indifferenceBandVersion, "b@v1")
    }
}
