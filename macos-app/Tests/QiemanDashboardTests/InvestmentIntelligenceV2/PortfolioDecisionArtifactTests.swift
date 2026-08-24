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

    private func makeArtifact(
        decision: PartialDecision,
        plans: [String: PortfolioActionPlan]
    ) -> PortfolioDecisionArtifact {
        .assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            bandVersion: "b@v1",
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
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
        try DecisionValidator().validate(artifact: artifact)
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

    func testReplayDeterministic_sameInputsSamePlansAndDecision() {
        // 审查 P1-1 回归:完整重放覆盖 Planner——同 inputs 产出**相同行动计划**
        // (Δw 与 provenance),不只是相同方案键
        let inputs = DecisionReplayer.ReplayInputs(
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "-0.05")],
            scores: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:]
        )
        let replayer = DecisionReplayer()
        let first = replayer.replay(inputs: inputs, now: day)
        let second = replayer.replay(inputs: inputs, now: day)
        XCTAssertEqual(first, second, "same mock inputs → same decision + same plans(M7/D004)")
        XCTAssertEqual(first.decision.status, .unresolvedTradeoff)
        XCTAssertEqual(first.decision.admissiblePlans, ["A", "B"])
        // plans 是 Planner 重放的产物:动作与 provenance 完整
        XCTAssertEqual(first.plans["A"]?.actions.first?.action.deltaWeight.value, d("0.05"))
        XCTAssertEqual(first.plans["B"]?.actions.first?.action.deltaWeight.value, d("-0.05"))
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
        let original = replayer.replay(inputs: base, now: day)

        // what-if:B 的 momentum 换成碾压值 → singlePreferred B
        let whatIf = replayer.replayWhatIf(base: base, replacingScores: [
            "B": [score("momentum", d("0.09")), score("costScore", d("0.03"))],
        ], now: day)
        XCTAssertEqual(whatIf.decision.status, .singlePreferred)
        XCTAssertEqual(whatIf.decision.admissiblePlans, ["B"])

        // 原决策不受影响(partial 重放是新 artifact 的素材,D004 §5)
        XCTAssertEqual(replayer.replay(inputs: base, now: day), original)
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
        // FactorSnapshot 不可解析
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(factorSnapshot: { id in id.rawValue != "fs_abc" })
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "factorSnapshot", id: "fs_abc"))
        }
        // Criterion 不可解析
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(criterion: { _ in false })
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "criterion", id: "portfolio-momentum@v1"))
        }
        // Band 不可解析
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact,
            resolvers: .init(indifferenceBand: { _ in false })
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .unresolvableReference(kind: "indifferenceBand", id: "b@v1"))
        }
        // 全部可解析 → 通过
        XCTAssertNoThrow(try DecisionValidator().validate(artifact: artifact))
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
            decision: decision, plans: plans, producedAt: day
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
