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

    private var bandVersion: String { "b@v1" }

    // MARK: - 强类型实例 / 定义 fixture

    /// 手工 FactorSnapshot(cardinal metric value;nil → 输入不足形态)
    private func factorSnapshot(id: String, value: Decimal?) -> FactorSnapshot {
        let definition = FactorDefinition(key: "momentum.return60", version: "v1", unit: .ratio)
        let metric = value.map { FactorMetric(definition: definition, value: $0) }
            ?? FactorMetric(definition: definition,
                            insufficiency: .init(reason: .emptySeries, requiredBars: nil, actualBars: 0))
        return FactorSnapshot(
            id: FactorSnapshotID(rawValue: id),
            producedAt: day,
            listingID: ListingID(rawValue: "L"),
            asOf: day,
            factorVersion: "test-engine-v1",
            metrics: [metric],
            sourceObservationIDs: [],
            assetSeries: [],
            benchmarkSeries: nil
        )
    }

    /// costIntensity(plan.turnover,低者优先——plan-scoped 指标)
    private func costIntensityDefinition(weight: Decimal = 1) -> CriterionDefinition {
        CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: weight)],
            unit: .ratio,
            higherIsBetter: false)
    }

    /// momentum(fs_m 的 factor metric,决策级共享 cardinal)
    private func momentumDefinition(snapshotID: String = "fs_m", version: String = "v1") -> CriterionDefinition {
        CriterionDefinition(
            id: "momentum", version: version, evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .factorMetric, referenceID: "\(snapshotID)#momentum.return60", weight: 1)],
            unit: .ratio)
    }

    /// makeArtifact 用的 criterion(引用 fs_abc,与 fixture 声明域一致)
    private var portfolioMomentumDefinition: CriterionDefinition {
        CriterionDefinition(
            id: "portfolio-momentum", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .factorMetric, referenceID: "fs_abc#momentum.return60", weight: 1)],
            unit: .ratio)
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

    /// makeArtifact 的 plans/plannerRuns 同源构造(八轮 P1-2:artifact 的
    /// plan 必须可由内嵌规划输入以冻结 asOf 重放——validator 会重跑核对)。
    private func makeArtifact(
        decision: PartialDecision,
        planDeltas: [String: String],
        comparison: PlanComparisonResult? = nil
    ) -> PortfolioDecisionArtifact {
        var plans: [String: PortfolioActionPlan] = [:]
        var plannerRuns: [String: DecisionReplayer.PlannerRun] = [:]
        for (key, delta) in planDeltas.sorted(by: { $0.key < $1.key }) {
            let run = plannerRun(delta: delta, directiveID: "u-\(key)")
            plannerRuns[key] = run
            plans[key] = planFrom(run)
        }
        return PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionDefinitions: [portfolioMomentumDefinition],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            band: band,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: comparison ?? Self.consistentComparison(
                for: decision, allPlans: plans.keys.sorted()),
            plans: plans,
            plannerRuns: plannerRuns,
            producedAt: day
        )
    }

    // MARK: - Validator(D004 §2 provenance 闭环)

    func testValidatorPassesOnCompleteArtifact() throws {
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"],
                                       explanation: "互不支配")
        let artifact = makeArtifact(decision: decision, planDeltas: ["A": "0.05", "B": "-0.05"])
        try DecisionValidator().validate(artifact: artifact, resolvers: .everythingResolvable)
    }

    func testValidatorRejectsAdmissiblePlanNotInPlans() {
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["GHOST"],
                                       explanation: "x")
        let artifact = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .admissiblePlanNotFound("GHOST"))
        }
    }

    func testValidatorRejectsEmptyCriterionVersions() {
        // assemble 拒绝空定义集,违规形态经 memberwise init 构造
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let complete = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        let emptyCriterion = PortfolioDecisionArtifact(
            id: complete.id, producedAt: complete.producedAt,
            validityPolicy: complete.validityPolicy,
            dependencies: complete.dependencies,
            signalIDs: complete.signalIDs,
            criterionVersions: [],
            criterionContentDigests: [:],
            factorSnapshotIDs: complete.factorSnapshotIDs,
            target: nil,
            indifferenceBandVersion: complete.indifferenceBandVersion,
            bandContentDigest: complete.bandContentDigest,
            plannerInputs: complete.plannerInputs,
            knowledgeContextSummary: complete.knowledgeContextSummary,
            decision: complete.decision,
            comparison: complete.comparison,
            plans: complete.plans
        )
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: emptyCriterion)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptyCriterionVersions)
        }
    }

    func testValidatorRejectsEmptyPlans() {
        // 八轮 P1-2 回归:空 plan 集是退化形态,validator 直接拒
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: [], explanation: "x")
        let emptyArtifact = makeArtifact(decision: decision, planDeltas: [:])
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: emptyArtifact, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptyPlans)
        }
    }

    func testValidatorRejectsPlannerInputDomainViolation() {
        // 七轮 P1-3 回归:内嵌规划输入必须恰好覆盖 plans 域(缺 A → 拒)。
        // assemble 强制键域一致,违规形态经 memberwise init 构造。
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let complete = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        let violated = PortfolioDecisionArtifact(
            id: complete.id,
            producedAt: complete.producedAt,
            validityPolicy: complete.validityPolicy,
            dependencies: complete.dependencies,
            signalIDs: complete.signalIDs,
            criterionVersions: complete.criterionVersions,
            criterionContentDigests: complete.criterionContentDigests,
            factorSnapshotIDs: complete.factorSnapshotIDs,
            target: complete.target,
            indifferenceBandVersion: complete.indifferenceBandVersion,
            bandContentDigest: complete.bandContentDigest,
            plannerInputs: [:],   // 缺 A 的规划输入
            knowledgeContextSummary: complete.knowledgeContextSummary,
            decision: complete.decision,
            comparison: complete.comparison,
            plans: complete.plans
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: violated, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .plannerInputDomainViolation(keys: ["A"]))
        }
    }

    func testValidatorRejectsNonReproduciblePlans() {
        // 八轮 P1-2 回归:已存 plan 与内嵌规划输入不同源(重跑 Planner 不
        // 等于已存 plan)→ 拒——「Validator 放行而 Replayer 拒绝」分裂关闭
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let complete = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        // 篡改内嵌输入(Δw 指令漂移)但保留原 plans
        let tampered = PortfolioDecisionArtifact(
            id: complete.id,
            producedAt: complete.producedAt,
            validityPolicy: complete.validityPolicy,
            dependencies: complete.dependencies,
            signalIDs: complete.signalIDs,
            criterionVersions: complete.criterionVersions,
            criterionContentDigests: complete.criterionContentDigests,
            factorSnapshotIDs: complete.factorSnapshotIDs,
            target: complete.target,
            indifferenceBandVersion: complete.indifferenceBandVersion,
            bandContentDigest: complete.bandContentDigest,
            plannerInputs: ["A": plannerRun(delta: "0.07", directiveID: "u-A")],
            knowledgeContextSummary: complete.knowledgeContextSummary,
            decision: complete.decision,
            comparison: complete.comparison,
            plans: complete.plans
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: tampered, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .frozenPlanMismatch(planKey: "A"))
        }
    }

    func testValidatorRejectsContentDigestDomainGap() {
        // 八轮 P1-4 回归:摘要未覆盖全部 criterion 版本 → 拒
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let complete = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        let noDigest = PortfolioDecisionArtifact(
            id: complete.id,
            producedAt: complete.producedAt,
            validityPolicy: complete.validityPolicy,
            dependencies: complete.dependencies,
            signalIDs: complete.signalIDs,
            criterionVersions: complete.criterionVersions,
            criterionContentDigests: [:],   // 摘要缺失
            factorSnapshotIDs: complete.factorSnapshotIDs,
            target: complete.target,
            indifferenceBandVersion: complete.indifferenceBandVersion,
            bandContentDigest: complete.bandContentDigest,
            plannerInputs: complete.plannerInputs,
            knowledgeContextSummary: complete.knowledgeContextSummary,
            decision: complete.decision,
            comparison: complete.comparison,
            plans: complete.plans
        )
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: noDigest, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .contentDigestIncomplete(keys: complete.criterionVersions))
        }
    }

    // MARK: - Replay(D004 §3:same IDs → same decision;不重跑 Research)

    /// 规划输入(冻结内嵌进 artifact,重放重新产 Δw)。
    private func plannerRun(delta: String, directiveID: String = "u-replay") -> DecisionReplayer.PlannerRun {
        DecisionReplayer.PlannerRun(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "listing|A", deltaWeight: Ratio(value: d(delta)),
                                   directiveID: directiveID, note: nil)
            ],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "test",
                newSubjectBuyUpper: Ratio(value: d("1"))
            ),
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
    }

    /// 测试 resolver:返回**材料**(criterion 定义 + factor 实例 + band)——
    /// 数值由 Replayer 从实例与 plan-scoped 指标提取、分数逐 plan 重算,
    /// resolver 无法注入任意数值(七轮 P1)。
    private struct TestResolver: DecisionReplayer.InputResolving {
        let materials: DecisionReplayer.ReplayMaterials
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> DecisionReplayer.ReplayMaterials {
            materials
        }
    }

    /// 标准材料:costIntensity(plan.turnover,低者优先)+ momentum(fs_m 的
    /// factor metric,共享)。A Δw=0.05 → turnover 0.05;B Δw=−0.15 →
    /// turnover 0.15:cost 差 0.1 超带,A 优;momentum 同值 indifferent →
    /// A dominates B → singlePreferred A(七轮 P1-1:逐 plan 求值)。
    private func standardMaterials() -> DecisionReplayer.ReplayMaterials {
        DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                costIntensityDefinition().fingerprint: costIntensityDefinition(),
                momentumDefinition().fingerprint: momentumDefinition(),
            ],
            factorSnapshots: ["fs_m": factorSnapshot(id: "fs_m", value: d("0.05"))],
            observations: [:],
            band: band
        )
    }

    /// 与材料一致引用层的 artifact(criterion/factor/band 全对齐;规划输入
    /// 与 plans 同源冻结内嵌)。
    private func materialsConsistentArtifact(
        decision: PartialDecision,
        deltaA: String = "0.05",
        deltaB: String = "-0.15"
    ) -> PortfolioDecisionArtifact {
        PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionDefinitions: [costIntensityDefinition(), momentumDefinition()],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_m")],
            target: nil,
            band: band,
            knowledgeContextSummary: "test",
            decision: decision,
            comparison: Self.consistentComparison(for: decision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: deltaA)),
                "B": planFrom(plannerRun(delta: deltaB)),
            ],
            plannerRuns: [
                "A": plannerRun(delta: deltaA),
                "B": plannerRun(delta: deltaB),
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
        // 同材料 → 同决策 + 同行动计划;确定性重放(规划输入取自 artifact
        // 冻结内嵌,重放时间从 artifact plans 冻结,不接受外部 now)
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let resolver = TestResolver(materials: standardMaterials())

        let replayer = DecisionReplayer()
        let first = try replayer.replay(artifact: artifact, resolver: resolver)
        let second = try replayer.replay(artifact: artifact, resolver: resolver)
        XCTAssertEqual(first, second, "same materials → same decision + same plans(M7/D004)")
        XCTAssertEqual(first.decision.status, .singlePreferred)
        XCTAssertEqual(first.decision.admissiblePlans, ["A"],
                       "A turnover 低 + momentum 持平 → A dominates B(逐 plan 求值)")
        XCTAssertEqual(first.plans["A"]?.actions.first?.action.deltaWeight.value, d("0.05"))
        guard case .userDirective = first.plans["A"]?.actions.first?.provenance else {
            return XCTFail("重放的 plan 保留 provenance")
        }
        // 冻结时间:重放 plan 的 asOf/id 与 artifact 的 plan 一致
        XCTAssertEqual(first.plans["A"]?.asOf, artifact.plans["A"]?.asOf)
        XCTAssertEqual(first.plans["A"]?.id, artifact.plans["A"]?.id)
        // 规划输入取自 artifact 内嵌(重放不依赖外部 PlannerRun Store)
        XCTAssertEqual(artifact.plannerInputs.keys.sorted(), ["A", "B"])

        // criterion 定义域不匹配(材料定义多一个)→ 拒
        let extraDefs = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: standardMaterials().criterionDefinitions.merging([
                "extra@v1": CriterionDefinition(
                    id: "extra", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
                    unit: .ratio)
            ]) { _, new in new },
            factorSnapshots: standardMaterials().factorSnapshots,
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: extraDefs)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("定义域不符应拒,实际 \(error)")
            }
        }

        // factor 实例域不符(定义引用 fs_m,材料实例为空)→ 拒
        let missingFactor = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: standardMaterials().criterionDefinitions,
            factorSnapshots: [:],
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: missingFactor)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("factor 实例域不符应拒,实际 \(error)")
            }
        }
    }

    func testReplayRejectsSameVersionDifferentContent() throws {
        // 八轮 P1-4 回归:同 id@version 但权重不同(或 band 同版本不同阈值)
        // 的材料 → 内容摘要不符 → 拒——版本字符串不绑定语义的通道关闭
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let replayer = DecisionReplayer()

        // criterion:同版本,weight 2(原 1)
        let tamperedWeight = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                costIntensityDefinition(weight: 2).fingerprint: costIntensityDefinition(weight: 2),
                momentumDefinition().fingerprint: momentumDefinition(),
            ],
            factorSnapshots: standardMaterials().factorSnapshots,
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: tamperedWeight)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为同版本不同内容拒绝,实际 \(error)")
            }
        }

        // band:同 policyID@version,defaultBand 收紧
        let tamperedBand = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: standardMaterials().criterionDefinitions,
            factorSnapshots: standardMaterials().factorSnapshots,
            observations: [:],
            band: IndifferenceBand(policyID: "b", version: "v1", defaultBand: d("0.001"),
                                   rationale: "tampered")
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: tamperedBand)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为 band 内容摘要不符拒绝,实际 \(error)")
            }
        }
    }

    func testPerPlanScoresDivergeViaPlanMetrics() throws {
        // 七轮 P1-1 回归:方案分数来自各自的 plan-scoped 指标——同引用 IDs
        // + 不同规划输入 → 不同决策;不再全 plan 共享一组分数
        let replayer = DecisionReplayer()
        let resolver = TestResolver(materials: standardMaterials())

        // turnover 相同(0.05 vs 0.05)+ momentum 持平 → 互不支配 → unresolved
        let equalTurnover = materialsConsistentArtifact(
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"], explanation: "x"),
            deltaA: "0.05", deltaB: "0.05"
        )
        let unresolved = try replayer.replay(artifact: equalTurnover, resolver: resolver)
        XCTAssertEqual(unresolved.decision.status, .unresolvedTradeoff)
        XCTAssertEqual(unresolved.comparison.pairwise["A|B"], .incomparable)

        // turnover 分歧(0.05 vs 0.15)→ singlePreferred A
        let divergent = materialsConsistentArtifact(
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            deltaA: "0.05", deltaB: "0.15"
        )
        let preferred = try replayer.replay(artifact: divergent, resolver: resolver)
        XCTAssertEqual(preferred.decision.status, .singlePreferred)
        XCTAssertEqual(preferred.decision.admissiblePlans, ["A"])
        XCTAssertEqual(preferred.comparison.pairwise["A|B"], .aDominatesB)
    }

    func testProjectedWeightsIncludeWhitelistedNewSubjects() throws {
        // 八轮 P1-1 回归:白名单新标的(eligibleNewSubjects 声明资产类)进入
        /// 投影资产类权重;合法但缺席的类别 = 已知 0(不是 unknown)
        let run = DecisionReplayer.PlannerRun(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: nil, remediationTargets: [],
            userDirectives: [
                UserDirectiveInput(subjectKey: "listing|NEW", deltaWeight: Ratio(value: d("0.1")),
                                   directiveID: "u-new", note: nil),
                UserDirectiveInput(subjectKey: "listing|A", deltaWeight: Ratio(value: d("-0.05")),
                                   directiveID: "u-trim", note: nil),
            ],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: ["listing|NEW": .commodity],
                builderVersion: "test",
                newSubjectBuyUpper: Ratio(value: d("1"))
            ),
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
        let plan = planFrom(run)
        let exposure = CriterionDefinition(
            id: "exposure", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [
                CriterionDefinition.InputReference(
                    kind: .planMetric,
                    referenceID: "\(PlanMetrics.projectedWeightPrefix)#COMMODITY", weight: 1),
                CriterionDefinition.InputReference(
                    kind: .planMetric,
                    referenceID: "\(PlanMetrics.projectedWeightPrefix)#FIXED_INCOME", weight: 1),
            ],
            unit: .ratio)
        let artifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [],
            criterionDefinitions: [exposure],
            factorSnapshotIDs: [],
            target: nil,
            band: band,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: ["A"], blockingUnknowns: []),
            plans: ["A": plan],
            plannerRuns: ["A": run],
            producedAt: day
        )
        // 材料:同一 run 的副本(可重放),无 factor/observation
        let materials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [exposure.fingerprint: exposure],
            factorSnapshots: [:], observations: [:], band: band)
        let outcome = try DecisionReplayer().replay(
            artifact: artifact, resolver: TestResolver(materials: materials))
        // COMMODITY = 新标的买入 0.1(白名单声明类别进入投影)
        // FIXED_INCOME = 合法但缺席 → 已知 0,非 unknown(决策不被阻断)
        XCTAssertEqual(outcome.decision.admissiblePlans, ["A"])
        let scores = outcome.comparison.pairwise   // 单 plan:pairwise 空,无阻断即证明两输入已知
        XCTAssertTrue(scores.isEmpty)
        XCTAssertTrue(outcome.comparison.blockingUnknowns.isEmpty,
                      "缺席类别返回已知 0,不产生 unknown 阻断")
    }

    func testReplayRejectsInstanceIdentityMismatch() throws {
        // 六/七轮 P1-2 回归:字典 key ≠ 实例自身 ID(复制 ID 给别的实例)→ 拒
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let replayer = DecisionReplayer()

        // factorSnapshots:key=fs_m 挂 id=fs_other 的实例
        let forgedFactor = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: standardMaterials().criterionDefinitions,
            factorSnapshots: ["fs_m": factorSnapshot(id: "fs_other", value: d("0.05"))],
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: forgedFactor)
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为实例身份不符,实际 \(error)")
            }
        }

        // criterionDefinitions:key=momentum@v1 挂 v2 定义的指纹
        var forgedDefinitions = standardMaterials().criterionDefinitions
        forgedDefinitions["momentum@v1"] = momentumDefinition(version: "v2")
        let forgedDefinition = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: forgedDefinitions,
            factorSnapshots: standardMaterials().factorSnapshots,
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try replayer.replay(
            artifact: artifact, resolver: TestResolver(materials: forgedDefinition)
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为定义指纹身份不符,实际 \(error)")
            }
        }
    }

    func testReplayWithoutPlansThrowsFrozenTimeUnavailable() throws {
        // 无 plans 的 artifact 无法取冻结时间 → 显式拒
        let definition = CriterionDefinition(
            id: "c", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [], unit: .ratio)
        let emptyArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [],
            criterionDefinitions: [definition],
            factorSnapshotIDs: [],
            target: nil,
            band: band,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: [], explanation: "x"),
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: [:], plannerRuns: [:], producedAt: day
        )
        let materials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [definition.fingerprint: definition],
            factorSnapshots: [:], observations: [:],
            band: band
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(
            artifact: emptyArtifact, resolver: TestResolver(materials: materials)
        )) { error in
            guard case DecisionReplayer.ReplayError.frozenTimeUnavailable = error else {
                return XCTFail("应为冻结时间不可得,实际 \(error)")
            }
        }
    }

    func testWhatIfProducesNewArtifactWithNewReferences() throws {
        // 七轮 P1-2 回归:what-if 用替换材料(新实例/新 criterion 版本)重算,
        // **产出新 artifact 记录新引用**——同 ID 换内容的通道不存在
        let base = materialsConsistentArtifact(
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        )
        XCTAssertEqual(base.factorSnapshotIDs.map(\.rawValue), ["fs_m"])

        // 情景:momentum 引用切换到新 snapshot 实例 fs_alt(metric 输入不足
        // → unknown);引用变更 = 新定义,版本纪律 bump 到 momentum@v2
        let scenarioDefinition = momentumDefinition(snapshotID: "fs_alt", version: "v2")
        let scenarioMaterials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                costIntensityDefinition().fingerprint: costIntensityDefinition(),
                scenarioDefinition.fingerprint: scenarioDefinition,
            ],
            factorSnapshots: ["fs_alt": factorSnapshot(id: "fs_alt", value: nil)],
            observations: [:],
            band: band
        )
        let whatIf = try DecisionReplayer().replayWhatIf(
            base: base,
            resolver: TestResolver(materials: scenarioMaterials),
            producedAt: day
        )
        // 新 artifact 记录新引用(fs_alt / momentum@v2),base 不受影响
        XCTAssertEqual(whatIf.factorSnapshotIDs.map(\.rawValue), ["fs_alt"])
        XCTAssertTrue(whatIf.criterionVersions.contains("momentum@v2"))
        XCTAssertFalse(whatIf.criterionVersions.contains("momentum@v1"))
        XCTAssertEqual(base.factorSnapshotIDs.map(\.rawValue), ["fs_m"])
        XCTAssertNotEqual(whatIf.id, base.id)
        // unknown 阻断(fs_alt metric 输入不足 → momentum unknown → 不判优)
        XCTAssertEqual(whatIf.comparison.blockingUnknowns, ["momentum"])
        XCTAssertEqual(whatIf.decision.status, .unresolvedTradeoff)
        // 新 artifact 自身可过校验(决策由 comparison 推导、引用完备、
        /// 内容摘要从定义实例派生)
        XCTAssertNoThrow(try DecisionValidator().validate(
            artifact: whatIf, resolvers: .everythingResolvable
        ))

        // 身份违规:实例 id ≠ 字典 key → 拒(复制 ID 给别的实例)
        let forged = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: scenarioMaterials.criterionDefinitions,
            factorSnapshots: ["fs_alt": factorSnapshot(id: "fs_wrong", value: nil)],
            observations: [:],
            band: band
        )
        XCTAssertThrowsError(try DecisionReplayer().replayWhatIf(
            base: base, resolver: TestResolver(materials: forged), producedAt: day
        )) { error in
            guard case DecisionReplayer.ReplayError.materialIdentityMismatch = error else {
                return XCTFail("应为 what-if 实例身份不符,实际 \(error)")
            }
        }
    }

    func testWhatIfRejectsCorruptedBase() throws {
        // 八轮 P2-6 回归:base 冻结规划输入损坏(域缺失/不可重放)→ what-if
        // 先过共享校验拒绝,不把损坏材料「洗成」新 artifact
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let base = materialsConsistentArtifact(decision: decision)
        let corrupted = PortfolioDecisionArtifact(
            id: base.id,
            producedAt: base.producedAt,
            validityPolicy: base.validityPolicy,
            dependencies: base.dependencies,
            signalIDs: base.signalIDs,
            criterionVersions: base.criterionVersions,
            criterionContentDigests: base.criterionContentDigests,
            factorSnapshotIDs: base.factorSnapshotIDs,
            target: base.target,
            indifferenceBandVersion: base.indifferenceBandVersion,
            bandContentDigest: base.bandContentDigest,
            plannerInputs: ["A": plannerRun(delta: "0.09")],   // B 缺 + A 与已存 plan 不同源
            knowledgeContextSummary: base.knowledgeContextSummary,
            decision: base.decision,
            comparison: base.comparison,
            plans: base.plans
        )
        XCTAssertThrowsError(try DecisionReplayer().replayWhatIf(
            base: corrupted,
            resolver: TestResolver(materials: standardMaterials()),
            producedAt: day
        )) { error in
            guard case DecisionReplayer.ReplayError.artifactPlanDomainMismatch = error else {
                return XCTFail("应为冻结规划一致性拒绝,实际 \(error)")
            }
        }
    }

    func testReplayAndWhatIfRejectEmptyCriterionDefinitions() throws {
        // 九轮 P1 回归:resolver 返回空 criterion 定义集(criterion store
        // 故障/维护的外部数据)→ fail-closed 抛错,不崩进程——此前 what-if
        // 会一路走到 assemble 的 precondition SIGTRAP
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let base = materialsConsistentArtifact(decision: decision)
        let emptyMaterials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [:],
            factorSnapshots: [:], observations: [:], band: band)
        let replayer = DecisionReplayer()

        XCTAssertThrowsError(try replayer.replayWhatIf(
            base: base, resolver: TestResolver(materials: emptyMaterials), producedAt: day
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("what-if 空定义集应 fail-closed 拒绝,实际 \(error)")
            }
        }
        XCTAssertThrowsError(try replayer.replay(
            artifact: base, resolver: TestResolver(materials: emptyMaterials)
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("replay 空定义集应 fail-closed 拒绝,实际 \(error)")
            }
        }
    }

    func testValidatorRejectsInternallyContradictoryResults() throws {
        // 三轮 P1-6 回归:结果层内部矛盾拒收
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")

        // ① 四轮 P1-2 回归:pairwise 不完整(缺失 pair)→ pairwiseDomainIncomplete
        let incompletePairwise = makeArtifact(
            decision: decision, planDeltas: ["A": "0.05", "B": "-0.05"],
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
            decision: decision, planDeltas: ["A": "0.05"],
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
            decision: decision, planDeltas: ["A": "0.05", "B": "-0.05"],
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
            decision: decision, planDeltas: ["A": "0.05", "B": "-0.05"],
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
            artifact: makeArtifact(decision: decision, planDeltas: ["A": "0.05"]),
            resolvers: .everythingResolvable
        ))
    }

    func testValidatorRejectsTargetProvenanceMismatch() throws {
        // 四轮 P1-3 回归:plan/action 的 Target 引用与 artifact.target 不一致拒收
        // (八轮 P1-2:plannerRun 与 plan 同源——run 带 target)
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: d("1.0")))],
            note: nil, now: day
        )
        // planner 产自 target 的 plan(内嵌 run 同源,可重放)
        let run = DecisionReplayer.PlannerRun(
            portfolio: PortfolioSnapshot(asOf: day, positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: target, remediationTargets: [], userDirectives: [],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "t", newSubjectBuyUpper: Ratio(value: 1)),
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
        let plan = planFrom(run)
        let preferred = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        // artifact.target 是 target → plan.targetID 一致,自洽通过
        let consistent = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "s")],
            criterionDefinitions: [portfolioMomentumDefinition],
            factorSnapshotIDs: [],
            target: target,
            band: band,
            knowledgeContextSummary: "",
            decision: preferred,
            comparison: Self.consistentComparison(for: preferred, allPlans: ["A"]),
            plans: ["A": plan],
            plannerRuns: ["A": run],
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
            signalIDs: [SignalID(rawValue: "s")],
            criterionDefinitions: [portfolioMomentumDefinition],
            factorSnapshotIDs: [],
            target: otherTarget,
            band: band,
            knowledgeContextSummary: "",
            decision: preferred,
            comparison: Self.consistentComparison(for: preferred, allPlans: ["A"]),
            plans: ["A": plan],
            plannerRuns: ["A": run],
            producedAt: day
        )
        // 八轮 P1-2:run.target(target)与 artifact.target(otherTarget)的冲突
        // 在冻结规划一致性校验中先于 plan 级 provenance 检查命中(更早更精确)
        XCTAssertThrowsError(try DecisionValidator().validate(
            artifact: mismatched, resolvers: .everythingResolvable
        )) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError,
                           .plannerTargetConflict(planKey: "A"))
        }
    }

    func testArtifactBoundReplayVerifiesEndToEnd() throws {
        // 以 artifact + resolver(材料)为入口:绑定校验(定义域+内容摘要/
        // factor 实例/band/冻结规划一致性)→ 冻结时间重放 → decision/
        // comparison/plans 三层全等验证(同 IDs → 同决策)
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = materialsConsistentArtifact(decision: decision)
        let resolver = TestResolver(materials: standardMaterials())
        let replayer = DecisionReplayer()

        // verify 通过(绑定一致 + 三层全等)
        let outcome = try replayer.verify(artifact: artifact, resolver: resolver)
        XCTAssertEqual(outcome.plans["A"]?.asOf, artifact.plans["A"]?.asOf,
                      "重放时间从 artifact plans 冻结")

        // band 版本不符 → 拒
        let otherBand = IndifferenceBand(policyID: "b2", version: "v1", defaultBand: d("0.01"),
                                         rationale: "other")
        let wrongBand = TestResolver(materials: DecisionReplayer.ReplayMaterials(
            criterionDefinitions: standardMaterials().criterionDefinitions,
            factorSnapshots: standardMaterials().factorSnapshots,
            observations: [:],
            band: otherBand
        ))
        XCTAssertThrowsError(try replayer.replay(artifact: artifact, resolver: wrongBand)) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为 band 版本不符,实际 \(error)")
            }
        }

        // factor 引用域不符(情景定义引用 fs_alt,artifact 声明 fs_m)→ 拒
        let scenarioRefs = TestResolver(materials: DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                costIntensityDefinition().fingerprint: costIntensityDefinition(),
                momentumDefinition(snapshotID: "fs_alt", version: "v2").fingerprint:
                    momentumDefinition(snapshotID: "fs_alt", version: "v2"),
            ],
            factorSnapshots: ["fs_alt": factorSnapshot(id: "fs_alt", value: d("0.05"))],
            observations: [:],
            band: band
        ))
        XCTAssertThrowsError(try replayer.replay(artifact: artifact, resolver: scenarioRefs)) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为 factor 引用域不符,实际 \(error)")
            }
        }

        // 内容漂移(artifact 的 decision 与重放不一致)→ replayMismatch
        let driftedDecision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"],
                                              explanation: "漂移")
        let drifted = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionDefinitions: [costIntensityDefinition(), momentumDefinition()],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_m")],
            target: nil,
            band: band,
            knowledgeContextSummary: "test",
            decision: driftedDecision,
            comparison: Self.consistentComparison(for: driftedDecision, allPlans: ["A", "B"]),
            plans: [
                "A": planFrom(plannerRun(delta: "0.05")),
                "B": planFrom(plannerRun(delta: "-0.15")),
            ],
            plannerRuns: [
                "A": plannerRun(delta: "0.05"),
                "B": plannerRun(delta: "-0.15"),
            ],
            producedAt: day
        )
        XCTAssertThrowsError(try replayer.verify(artifact: drifted, resolver: resolver)) { error in
            guard case DecisionReplayer.ReplayError.replayMismatch = error else {
                return XCTFail("应为重放不一致,实际 \(error)")
            }
        }
    }

    func testReplayRejectsInternalPlannerTargetInconsistency() throws {
        // 五轮 P1-2 回归(七轮内嵌 + 八轮共享校验):artifact 内嵌规划输入的
        // Target 与 artifact.target 冲突(run 带 target 而 artifact.target=nil)→ 拒
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
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let base = materialsConsistentArtifact(decision: decision)
        let inconsistent = PortfolioDecisionArtifact(
            id: base.id,
            producedAt: base.producedAt,
            validityPolicy: base.validityPolicy,
            dependencies: base.dependencies,
            signalIDs: base.signalIDs,
            criterionVersions: base.criterionVersions,
            criterionContentDigests: base.criterionContentDigests,
            factorSnapshotIDs: base.factorSnapshotIDs,
            target: nil,   // artifact.target = nil
            indifferenceBandVersion: base.indifferenceBandVersion,
            bandContentDigest: base.bandContentDigest,
            plannerInputs: ["A": run, "B": plannerRun(delta: "-0.15")],   // A 的 run 带 target
            knowledgeContextSummary: base.knowledgeContextSummary,
            decision: base.decision,
            comparison: base.comparison,
            plans: base.plans
        )
        XCTAssertThrowsError(try DecisionReplayer().replay(
            artifact: inconsistent, resolver: TestResolver(materials: standardMaterials())
        )) { error in
            guard case DecisionReplayer.ReplayError.referenceMismatch = error else {
                return XCTFail("应为内嵌规划输入 Target 冲突拒绝,实际 \(error)")
            }
        }
    }

    func testValidatorFailsClosedOnUnresolvableReferences() {
        // 审查 P1-1 回归:任一类引用无法解析 → 抛错,不静默放行
        let decision = PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x")
        let artifact = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])

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
                           .unresolvableReference(kind: "indifferenceBand", id: bandVersion))
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
        let a = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        let b = makeArtifact(decision: decision, planDeltas: ["A": "0.05"])
        XCTAssertEqual(a.validityPolicy, .immutableHistorical)
        XCTAssertEqual(a.id, b.id, "引用层+内容摘要+冻结规划输入+结果层相同 → 同 id(producedAt 不参与)")
        // dependencies 覆盖 signal/factor/target + criterion/band 的 policy
        // 依赖(五轮 P1-3;八轮 P1-4:policy 依赖携带内容摘要为 version)
        XCTAssertEqual(Set(a.dependencies.map(\.referenceID)),
                       ["sig-1", "fs_abc", "criterion@portfolio-momentum@v1", "band@b@v1"])
        XCTAssertTrue(a.dependencies.contains { $0.kind == .signal })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .factorSnapshot })
        XCTAssertTrue(a.dependencies.contains {
            $0.kind == .policy && $0.referenceID.hasPrefix("criterion@") && $0.version != nil
        }, "criterion 依赖携带内容摘要")
        XCTAssertTrue(a.dependencies.contains {
            $0.kind == .policy && $0.referenceID.hasPrefix("band@") && $0.version != nil
        }, "band 依赖携带内容摘要")

        // 引用层变化 → id 变化(同 id@version 但权重不同 → 摘要不同 → id 不同)
        let tamperedDefinition = CriterionDefinition(
            id: "portfolio-momentum", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .factorMetric, referenceID: "fs_abc#momentum.return60", weight: 2)],
            unit: .ratio)
        let differentContent = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionDefinitions: [tamperedDefinition],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            band: band,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: a.plans,
            plannerRuns: a.plannerInputs,
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentContent.id,
                          "同版本不同内容(权重 2)→ 摘要入 id → id 变化(八轮 P1-4)")

        // 冻结规划输入漂移 → id 变化(七轮 P1-3)
        let differentPlannerInputs = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionDefinitions: [portfolioMomentumDefinition],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil,
            band: band,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: ["A": planFrom(plannerRun(delta: "0.05", directiveID: "u-A"))],
            plannerRuns: ["A": plannerRun(delta: "0.07", directiveID: "u-A")],
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentPlannerInputs.id,
                          "冻结规划输入参与 id——重放材料自包含的身份域")
    }

    func testCodableRoundTrip() throws {
        let decision = PartialDecision(status: .unresolvedTradeoff, admissiblePlans: ["A", "B"],
                                       explanation: "互不支配")
        let artifact = makeArtifact(decision: decision, planDeltas: ["A": "0.05", "B": "-0.05"])
        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(PortfolioDecisionArtifact.self, from: data)
        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.signalIDs.map(\.rawValue), ["sig-1"])
        XCTAssertEqual(decoded.indifferenceBandVersion, bandVersion)
        XCTAssertEqual(decoded.criterionContentDigests, artifact.criterionContentDigests,
                       "内容摘要随 artifact 完整往返")
        XCTAssertEqual(decoded.plannerInputs, artifact.plannerInputs,
                       "冻结规划输入随 artifact 完整往返")
    }
}
