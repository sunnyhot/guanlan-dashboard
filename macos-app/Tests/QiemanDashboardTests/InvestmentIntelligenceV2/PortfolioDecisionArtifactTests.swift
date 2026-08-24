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

    func testReplayDeterministic_sameInputsSameDecision() {
        func score(_ id: String, _ v: Decimal) -> CriterionScore {
            CriterionScore(
                definition: CriterionDefinition(
                    id: id, version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .signalCardinal, referenceID: "\(id)-in", weight: 1)],
                    unit: .ratio),
                value: v, missingInputs: [], computation: "t")
        }
        // 两方案各有优势 → unresolvedTradeoff(mock signals 已按 ID 引用,
        // 重放不重跑 Research——inputs 由调用方按 artifact 引用取齐)
        let inputs = DecisionReplayer.ReplayInputs(
            plans: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:], allPlanKeys: ["A", "B"]
        )
        let replayer = DecisionReplayer()
        let first = replayer.replay(inputs: inputs)
        let second = replayer.replay(inputs: inputs)
        XCTAssertEqual(first, second, "same mock inputs → same decision(M7 验收)")
        XCTAssertEqual(first.status, .unresolvedTradeoff)
        XCTAssertEqual(first.admissiblePlans, ["A", "B"])
    }

    func testWhatIfReplayProducesNewDecisionWithoutTouchingBase() {
        func score(_ id: String, _ v: Decimal) -> CriterionScore {
            CriterionScore(
                definition: CriterionDefinition(
                    id: id, version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .factorMetric, referenceID: "\(id)-in", weight: 1)],
                    unit: .ratio),
                value: v, missingInputs: [], computation: "t")
        }
        let base = DecisionReplayer.ReplayInputs(
            plans: [
                "A": [score("momentum", d("0.05")), score("costScore", d("0.005"))],
                "B": [score("momentum", d("0.01")), score("costScore", d("0.03"))],
            ],
            band: band, higherIsBetter: [:], allPlanKeys: ["A", "B"]
        )
        let replayer = DecisionReplayer()
        let originalDecision = replayer.replay(inputs: base)

        // what-if:B 的 momentum 换成碾压值 → singlePreferred B
        let whatIf = replayer.replayWhatIf(base: base, replacing: [
            "B": [score("momentum", d("0.09")), score("costScore", d("0.03"))],
        ])
        XCTAssertEqual(whatIf.status, .singlePreferred)
        XCTAssertEqual(whatIf.admissiblePlans, ["B"])

        // 原决策不受影响(partial 重放是新 artifact 的素材,D004 §5)
        XCTAssertEqual(replayer.replay(inputs: base), originalDecision)
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
