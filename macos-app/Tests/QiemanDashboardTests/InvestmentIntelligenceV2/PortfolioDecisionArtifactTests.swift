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

    /// 六轮 P1-1:signal→cardinal 转换走 versioned policy(artifact 引用其版本)
    private let signalPolicy = SignalCardinalPolicy.symmetricV1()

    /// 强类型 signal 实例(ID 锁定身份;ordinal 内容由实例携带)
    private func signal(_ id: String, direction: SignalDirection,
                        strength: SignalStrength = .moderate) -> InvestmentSignal {
        InvestmentSignal(
            id: SignalID(rawValue: id),
            subjectCanonical: .listing(ListingID(rawValue: "L")),
            dimension: .momentum,
            direction: direction,
            strength: strength,
            derivedFromEvidenceIDs: [],
            effectiveAt: day,
            producer: .factorEngine,
            rationale: nil
        )
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
        var plannerRuns: [String: DecisionReplayer.PlannerRun] = [:]
        for key in plans.keys.sorted() {
            plannerRuns[key] = plannerRun(delta: "0")
        }
        return PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: resolvedComparison,
            plans: plans,
            plannerRuns: plannerRuns,
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
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "", decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: ["A": makePlan("A", delta: "0.05")],
            plannerRuns: ["A": plannerRun(delta: "0")], producedAt: day
        )
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptyCriterionVersions)
        }
    }

    func testValidatorRejectsEmptySignalPolicyVersion() {
        // 六轮 P1-1 回归:signal cardinal 转换 policy 未被 artifact 引用 → 拒
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")], criterionVersions: ["c@v1"],
            factorSnapshotIDs: [], target: nil, bandVersion: "b@v1",
            signalPolicyVersion: "",
            knowledgeContextSummary: "", decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: ["A": makePlan("A", delta: "0.05")],
            plannerRuns: ["A": plannerRun(delta: "0")], producedAt: day
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: artifact, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptySignalPolicyVersion)
        }
    }

    func testValidatorRejectsPlannerFingerprintDomainViolation() {
        // 六轮 P1-3 回归:指纹域必须恰好覆盖 plans 域(少一个 plan 的指纹 → 拒)。
        // assemble 强制键域一致,违规形态经 memberwise init 构造。
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let complete = makeArtifact(decision: decision, plans: ["A": makePlan("A", delta: "0.05")])
        let violated = PortfolioDecisionArtifact(
            id: complete.id,
            producedAt: complete.producedAt,
            validityPolicy: complete.validityPolicy,
            dependencies: complete.dependencies,
            signalIDs: complete.signalIDs,
            criterionVersions: complete.criterionVersions,
            factorSnapshotIDs: complete.factorSnapshotIDs,
            target: complete.target,
            indifferenceBandVersion: complete.indifferenceBandVersion,
            signalCardinalPolicyVersion: complete.signalCardinalPolicyVersion,
            plannerInputFingerprints: [:],   // 缺 A 的规划输入指纹
            knowledgeContextSummary: complete.knowledgeContextSummary,
            decision: complete.decision,
            comparison: complete.comparison,
            plans: complete.plans
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: violated, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .plannerFingerprintDomainViolation(keys: ["A"]))
        }
    }

    // MARK: - Replay(D004 §3:same IDs → same decision;不重跑 Research)

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

    /// 测试 resolver:返回**材料**(强类型实例 + criterion 定义 + 转换
    /// policy)——数值由 Replayer 从实例提取、分数重算,resolver 无法注入
    /// 任意数值(六轮 P1-1)。
    private struct TestResolver: DecisionReplayer.InputResolving {
        let materials: DecisionReplayer.ReplayMaterials
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> DecisionReplayer.ReplayMaterials {
            materials
        }
    }

    /// 标准材料:momentum / costScore 两个 criterion(signalCardinal 引用
    /// sig-momentum / sig-cost 的强类型实例)。六轮 P1-1 后提取源是决策级
    /// 共享实例——同一 signal ID 锁定唯一数值,所有 plan 取同一组分数
    /// (plan 间差异由 Planner 输入体现)→ momentum=+1 / costScore=−0.2
    /// 均已知 → 无阻断 → 全 incomparable → unresolvedTradeoff。
    private func standardMaterials() -> DecisionReplayer.ReplayMaterials {
        DecisionReplayer.ReplayMaterials(
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "-0.05")],
            criterionDefinitions: [
                "momentum@v1": CriterionDefinition(
                    id: "momentum", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .signalCardinal, referenceID: "sig-momentum", weight: 1)],
                    unit: .ratio),
                "costScore@v1": CriterionDefinition(
                    id: "costScore", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .signalCardinal, referenceID: "sig-cost", weight: 1)],
                    unit: .ratio),
            ],
            signals: [
                "sig-momentum": signal("sig-momentum", direction: .bullish, strength: .strong),
                "sig-cost": signal("sig-cost", direction: .bearish, strength: .weak),
            ],
            factorSnapshots: [:],
            observations: [:],
            band: band,
            signalPolicy: signalPolicy
        )
    }

    /// 与材料一致引用层的 artifact(criterion/signal/band/signalPolicy/
    /// planner 指纹全对齐)。
    private func materialsConsistentArtifact(decision: PartialDecision) -> PortfolioDecisionArtifact {
        PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-momentum"), SignalID(rawValue: "sig-cost")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [],
            target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "test",
            decision: decision,
            comparison: Self.consistentComparison(for: decision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: "0.05")),
                "B": planFrom(plannerRun(delta: "-0.05")),
            ],
            plannerRuns: [
                "A": plannerRun(delta: "0.05"),
                "B": plannerRun(delta: "-0.05"),
            ],
            producedAt: day
        )
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

    func testReplayDeterministic_sameMaterialsSamePlansAndDecision() throws {
        // 六轮 P1-1:resolver 只给强类型实例,数值由 Replayer 提取重算——
        // 同材料 → 同决策 + 同行动计划;确定性重放(重放时间从 artifact
        // plans 冻结,不接受外部 now)
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let resolver = TestResolver(materials: standardMaterials())

        let replayer = DecisionReplayer()
        let first = try replayer.replay(artifact: artifact, resolver: resolver)
        let second = try replayer.replay(artifact: artifact, resolver: resolver)
        XCTAssertEqual(first, second, "same materials → same decision + same plans(M7/D004)")
        XCTAssertEqual(first.decision.status, .unresolvedTradeoff,
                       "提取源共享:两 plan 分数相同 → 互不支配(数值分叉通道已不存在)")
        XCTAssertEqual(first.plans["A"]?.actions.first?.action.deltaWeight.value, d("0.05"))
        guard case .userDirective = first.plans["A"]?.actions.first?.provenance else {
            return XCTFail("重放的 plan 保留 provenance")
        }
        // 冻结时间:重放 plan 的 asOf 与 artifact 的 plan 一致(plan id 含
        // 时间,漂移会在 verify 的 plans 全等中暴露)
        XCTAssertEqual(first.plans["A"]?.asOf, artifact.plans["A"]?.asOf)
        XCTAssertEqual(first.plans["A"]?.id, artifact.plans["A"]?.id)

        // criterion 定义域不匹配(材料定义多一个)→ 拒
        let extraDefs = DecisionReplayer.ReplayMaterials(
            plannerRuns: standardMaterials().plannerRuns,
            criterionDefinitions: standardMaterials().criterionDefinitions.merging([
                "extra@v1": CriterionDefinition(
                    id: "extra", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .signalCardinal, referenceID: "sig-momentum", weight: 1)],
                    unit: .ratio)
            ]) { _, new in new },
            signals: standardMaterials().signals,
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: extraDefs)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("定义域不符应拒,实际 \(error)")
            }
        }

        // signal 实例域不符(定义引用两个 signal,材料实例缺 sig-cost)→ 拒
        let missingSignalMaterials = DecisionReplayer.ReplayMaterials(
            plannerRuns: standardMaterials().plannerRuns,
            criterionDefinitions: standardMaterials().criterionDefinitions,
            signals: ["sig-momentum": signal("sig-momentum", direction: .bullish, strength: .strong)],
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: missingSignalMaterials)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("signal 实例域不符应拒,实际 \(error)")
            }
        }
    }

    func testReplayRejectsInstanceIdentityMismatch() throws {
        // 六轮 P1-2 回归:字典 key ≠ 实例自身 ID(复制 ID 给别的实例)→ 拒
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let replayer = DecisionReplayer()

        // signals:key=sig-momentum 挂 id=sig-other 的实例
        let forgedSignal = DecisionReplayer.ReplayMaterials(
            plannerRuns: standardMaterials().plannerRuns,
            criterionDefinitions: standardMaterials().criterionDefinitions,
            signals: [
                "sig-momentum": signal("sig-other", direction: .bullish, strength: .strong),
                "sig-cost": signal("sig-cost", direction: .bearish, strength: .weak),
            ],
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: forgedSignal)
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为实例身份不符,实际 \(error)")
            }
        }

        // criterionDefinitions:key=momentum@v1 挂 v2 定义的指纹
        var forgedDefinitions = standardMaterials().criterionDefinitions
        forgedDefinitions["momentum@v1"] = CriterionDefinition(
            id: "momentum", version: "v2", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .signalCardinal, referenceID: "sig-momentum", weight: 1)],
            unit: .ratio)
        let forgedDefinition = DecisionReplayer.ReplayMaterials(
            plannerRuns: standardMaterials().plannerRuns,
            criterionDefinitions: forgedDefinitions,
            signals: standardMaterials().signals,
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: forgedDefinition)
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为定义指纹身份不符,实际 \(error)")
            }
        }
    }

    func testReplayLocksPlannerInputsByFingerprint() throws {
        // 六轮 P1-3 回归:规划输入(portfolio/directives/actionDomain/
        // parameters 任一)漂移 → 与 artifact 锚定指纹不符 → 拒
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        var runs = standardMaterials().plannerRuns
        runs["A"] = plannerRun(delta: "0.10")   // A 的用户指令漂移
        let drifted = DecisionReplayer.ReplayMaterials(
            plannerRuns: runs,
            criterionDefinitions: standardMaterials().criterionDefinitions,
            signals: standardMaterials().signals,
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(
            artifact: artifact, resolver: TestResolver(materials: drifted)
        )) { error in
            XCTAssertEqual(error as? DecisionReplayer.ReplayError,
                           .plannerInputMismatch(planKey: "A"))
        }
    }

    func testReplayWithoutPlansThrowsFrozenTimeUnavailable() throws {
        // 六轮 P1-3:无 plans 的 artifact 无法取冻结时间 → 显式拒
        let emptyArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [], criterionVersions: ["c@v1"],
            factorSnapshotIDs: [], target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: [], explanation: "x"),
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: [:], plannerRuns: [:], producedAt: day
        )
        let materials = DecisionReplayer.ReplayMaterials(
            plannerRuns: [:],
            criterionDefinitions: [
                "c@v1": CriterionDefinition(
                    id: "c", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [], unit: .ratio)
            ],
            signals: [:], factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(
            artifact: emptyArtifact, resolver: TestResolver(materials: materials)
        )) { error in
            guard case DecisionReplayer.ReplayError.frozenTimeUnavailable = error else {
                return XCTFail("应为冻结时间不可得,实际 \(error)")
            }
        }
    }

    func testWhatIfReplacesSignalInstancesAndRecomputes() throws {
        // 六轮 P1-1:what-if 换强类型 signal 实例(假想情景改实例内容,ID
        // 身份不变)→ 数值仍由 Replayer 从实例提取重算——uncertain 实例
        // 让 momentum 变 unknown 阻断;what-if 也不接受注入数值
        let base = standardMaterials()
        let replayer = DecisionReplayer()
        let baseline = try replayer.replayWhatIf(base: base, now: day)
        XCTAssertEqual(baseline.comparison.blockingUnknowns, [], "基线两 criterion 均已知")

        let scenario = try replayer.replayWhatIf(
            base: base,
            replacingSignals: ["sig-momentum": signal("sig-momentum", direction: .uncertain)],
            now: day
        )
        XCTAssertEqual(scenario.comparison.blockingUnknowns, ["momentum"],
                       "uncertain 实例 → cardinal 缺失 → unknown 阻断(DATA006)")
        XCTAssertEqual(scenario.decision.status, .unresolvedTradeoff)

        // 确定性:同 what-if 材料再跑 → 全等
        let again = try replayer.replayWhatIf(
            base: base,
            replacingSignals: ["sig-momentum": signal("sig-momentum", direction: .uncertain)],
            now: day
        )
        XCTAssertEqual(again, scenario)

        // 身份违规:替换实例的 id ≠ 字典 key → 拒(复制 ID 给别的实例)
        XCTAssertThrowsError(try replayer.replayWhatIf(
            base: base,
            replacingSignals: ["sig-momentum": signal("sig-other", direction: .bearish)],
            now: day
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为 what-if 实例身份不符,实际 \(error)")
            }
        }
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
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
                allPlans: ["A"]),
            plans: ["A": plan],
            plannerRuns: ["A": plannerRun(delta: "0")],
            producedAt: day
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
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
                allPlans: ["A"]),
            plans: ["A": plan],
            plannerRuns: ["A": plannerRun(delta: "0")],
            producedAt: day
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
        // 以 artifact + resolver(材料)为入口:绑定校验(定义域/signal 域/
        // factor 实例/逐 run target/band/signalPolicy/规划输入指纹)→
        // 冻结时间重放 → decision/comparison/plans 三层全等验证
        // (同 IDs → 同决策)
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let resolver = TestResolver(materials: standardMaterials())
        let replayer = DecisionReplayer()

        // verify 通过(绑定一致 + 三层全等)
        let outcome = try replayer.verify(artifact: artifact, resolver: resolver)
        XCTAssertEqual(outcome.plans["A"]?.asOf, artifact.plans["A"]?.asOf,
                      "重放时间从 artifact plans 冻结")

        // 键域不一致(plannerRuns 多了 C)→ artifactPlanDomainMismatch
        var badPlanner = standardMaterials().plannerRuns
        badPlanner["C"] = plannerRun(delta: "0")
        let badKeys = TestResolver(materials: DecisionReplayer.ReplayMaterials(
            plannerRuns: badPlanner,
            criterionDefinitions: standardMaterials().criterionDefinitions,
            signals: standardMaterials().signals,
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        ))
        XCTAssertThrowsError(try replayer.replay(artifact: artifact, resolver: badKeys)) { error in
            guard case DecisionReplayer.ReplayError.artifactPlanDomainMismatch = error else {
                return XCTFail("应为键域不一致,实际 \(error)")
            }
        }

        // artifact 域不一致(artifact 只含 A)→ artifactPlanDomainMismatch
        let singleDecision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let singleArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-momentum"), SignalID(rawValue: "sig-cost")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [],
            target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "test",
            decision: singleDecision,
            comparison: Self.consistentComparison(for: singleDecision, allPlans: ["A"]),
            plans: ["A": planFrom(plannerRun(delta: "0.05"))],
            plannerRuns: ["A": plannerRun(delta: "0.05")],
            producedAt: day
        )
        XCTAssertThrowsError(try replayer.replay(artifact: singleArtifact, resolver: resolver)) { error in
            guard case DecisionReplayer.ReplayError.artifactPlanDomainMismatch = error else {
                return XCTFail("应为 artifact 域不一致,实际 \(error)")
            }
        }

        // 内容漂移(artifact 的 decision 与重放不一致)→ replayMismatch
        let driftedDecision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "漂移")
        let drifted = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-momentum"), SignalID(rawValue: "sig-cost")],
            criterionVersions: ["costScore@v1", "momentum@v1"],
            factorSnapshotIDs: [],
            target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "test",
            decision: driftedDecision,
            comparison: Self.consistentComparison(for: driftedDecision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: "0.05")),
                "B": planFrom(plannerRun(delta: "-0.05")),
            ],
            plannerRuns: [
                "A": plannerRun(delta: "0.05"),
                "B": plannerRun(delta: "-0.05"),
            ],
            producedAt: day
        )
        XCTAssertThrowsError(try replayer.verify(artifact: drifted, resolver: resolver)) { error in
            guard case DecisionReplayer.ReplayError.replayMismatch = error else {
                return XCTFail("应为重放不一致,实际 \(error)")
            }
        }
    }

    func testMultiTargetMaterialsRejected() throws {
        // 五轮 P1-2 回归:多个冲突 Target 的 plannerRuns 不再折叠成 nil——
        // 逐 run 严格校验拒收(artifact.target nil + run 有 target)
        let targetA = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: 1))],
            note: nil, now: day
        )
        var run = plannerRun(delta: "0.05")
        run = DecisionReplayer.PlannerRun(
            portfolio: run.portfolio, target: targetA,
            remediationTargets: run.remediationTargets,
            userDirectives: run.userDirectives,
            actionDomain: run.actionDomain, plannerParameters: run.plannerParameters
        )
        let materials = DecisionReplayer.ReplayMaterials(
            plannerRuns: ["A": run, "B": plannerRun(delta: "-0.05")],
            criterionDefinitions: standardMaterials().criterionDefinitions,
            signals: standardMaterials().signals,
            factorSnapshots: [:], observations: [:],
            band: band, signalPolicy: signalPolicy
        )
        // artifact.target = nil,但 A 的 run 带 target → 逐 run 校验拒
        let artifact = materialsConsistentArtifact(
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x")
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(
            artifact: artifact, resolver: TestResolver(materials: materials)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为逐 run target 校验拒绝,实际 \(error)")
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
        // dependencies 覆盖 signal/factor/target + criterion/band/signalPolicy
        // 的 policy 依赖(五轮 P1-3 + 六轮 P1-1:失效传播索引完整)
        XCTAssertEqual(Set(a.dependencies.map(\.referenceID)),
                       ["sig-1", "fs_abc", "criterion@portfolio-momentum@v1", "band@b@v1",
                        "signalPolicy@\(signalPolicy.versionedID)"])
        XCTAssertTrue(a.dependencies.contains { $0.kind == .signal })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .factorSnapshot })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .policy && $0.referenceID.hasPrefix("criterion@") })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .policy && $0.referenceID.hasPrefix("band@") })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .policy && $0.referenceID.hasPrefix("signalPolicy@") })

        // 引用层变化 → id 变化
        let differentSignals = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-2")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: plans,
            plannerRuns: ["A": plannerRun(delta: "0")],
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentSignals.id)

        // 六轮 P1-3:规划输入指纹入 id——Planner 输入漂移 → id 变化
        let differentPlannerInputs = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: "b@v1",
            signalPolicyVersion: signalPolicy.versionedID,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: plans,
            plannerRuns: ["A": plannerRun(delta: "0.07")],   // 规划输入与 a 不同
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentPlannerInputs.id,
                          "Planner 输入(指纹)参与 id——重放自包含的身份域")
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
        XCTAssertEqual(decoded.signalCardinalPolicyVersion, signalPolicy.versionedID)
        XCTAssertEqual(decoded.plannerInputFingerprints.keys.sorted(), artifact.plans.keys.sorted())
    }
}
