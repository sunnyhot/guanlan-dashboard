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

    // MARK: - 强类型实例 fixture

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
            bandVersion: bandVersion,
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
            factorSnapshotIDs: [], target: nil, bandVersion: bandVersion,
            knowledgeContextSummary: "", decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: ["A": makePlan("A", delta: "0.05")],
            plannerRuns: ["A": plannerRun(delta: "0")], producedAt: day
        )
        XCTAssertThrowsError(try DecisionValidator().validate(artifact: artifact)) { error in
            XCTAssertEqual(error as? DecisionValidator.ValidationError, .emptyCriterionVersions)
        }
    }

    func testValidatorRejectsPlannerInputDomainViolation() {
        // 七轮 P1-3 回归:内嵌规划输入必须恰好覆盖 plans 域(缺 A → 拒)。
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

    // MARK: - Replay(D004 §3:same IDs → same decision;不重跑 Research)

    /// 规划输入(冻结内嵌进 artifact,重放重新产 Δw)。
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

    /// 测试 resolver:返回**材料**(criterion 定义 + factor 实例 + band)——
    /// 数值由 Replayer 从实例与 plan-scoped 指标提取、分数逐 plan 重算,
    /// resolver 无法注入任意数值(七轮 P1)。
    private struct TestResolver: DecisionReplayer.InputResolving {
        let materials: DecisionReplayer.ReplayMaterials
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> DecisionReplayer.ReplayMaterials {
            materials
        }
    }

    /// 标准材料:costIntensity(plan.turnover,低者优先——plan-scoped 指标)
    /// + momentum(fs_m 的 factor metric,决策级共享 cardinal)。
    /// A Δw=0.05 → turnover 0.05;B Δw=−0.15 → turnover 0.15:cost 差 0.1
    /// 超带,A 优;momentum 两 plan 同值 indifferent → A dominates B →
    /// singlePreferred A(七轮 P1-1:方案分数不再共享)。
    private func standardMaterials() -> DecisionReplayer.ReplayMaterials {
        DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                "costIntensity@v1": CriterionDefinition(
                    id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
                    unit: .ratio,
                    higherIsBetter: false),
                "momentum@v1": CriterionDefinition(
                    id: "momentum", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .factorMetric, referenceID: "fs_m#momentum.return60", weight: 1)],
                    unit: .ratio),
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
            criterionVersions: ["costIntensity@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_m")],
            target: nil, bandVersion: bandVersion,
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

        // 投影资产类权重指标( EQUITY:0.5+Δw )也可作为 criterion 输入——
        // 低 Equity 暴露优先,A(0.55) 优于 B(0.65)
        let projected = CriterionDefinition(
            id: "equityExposure", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric,
                referenceID: "\(PlanMetrics.projectedWeightPrefix)#EQUITY", weight: 1)],
            unit: .ratio,
            higherIsBetter: false)
        let materials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: ["equityExposure@v1": projected],
            factorSnapshots: [:], observations: [:], band: band)
        let projectedArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [], criterionVersions: ["equityExposure@v1"],
            factorSnapshotIDs: [], target: nil, bandVersion: bandVersion,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            comparison: Self.consistentComparison(
                for: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
                allPlans: ["A", "B"]),
            plans: ["A": planFrom(plannerRun(delta: "0.05")), "B": planFrom(plannerRun(delta: "0.15"))],
            plannerRuns: ["A": plannerRun(delta: "0.05"), "B": plannerRun(delta: "0.15")],
            producedAt: day)
        let projectedOutcome = try replayer.replay(
            artifact: projectedArtifact, resolver: TestResolver(materials: materials))
        XCTAssertEqual(projectedOutcome.decision.admissiblePlans, ["A"],
                       "投影 Equity 0.55 < 0.65,低暴露优先 → A")
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
        forgedDefinitions["momentum@v1"] = CriterionDefinition(
            id: "momentum", version: "v2", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .factorMetric, referenceID: "fs_m#momentum.return60", weight: 1)],
            unit: .ratio)
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
        let emptyArtifact = PortfolioDecisionArtifact.assemble(
            signalIDs: [], criterionVersions: ["c@v1"],
            factorSnapshotIDs: [], target: nil, bandVersion: bandVersion,
            knowledgeContextSummary: "",
            decision: PartialDecision(status: .unresolvedTradeoff, admissiblePlans: [], explanation: "x"),
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: [:], plannerRuns: [:], producedAt: day
        )
        let materials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                "c@v1": CriterionDefinition(
                    id: "c", version: "v1", evaluatorKind: .weightedSum,
                    inputReferences: [], unit: .ratio)
            ],
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
        let scenarioMaterials = DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [
                "costIntensity@v1": standardMaterials().criterionDefinitions["costIntensity@v1"]!,
                "momentum@v2": CriterionDefinition(
                    id: "momentum", version: "v2", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .factorMetric, referenceID: "fs_alt#momentum.return60", weight: 1)],
                    unit: .ratio),
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
        // 新 artifact 自身可过校验(决策由 comparison 推导、引用完备)
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
            factorSnapshotIDs: [], target: target, bandVersion: bandVersion,
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
            factorSnapshotIDs: [], target: otherTarget, bandVersion: bandVersion,
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
        // 以 artifact + resolver(材料)为入口:绑定校验(定义域/factor 实例/
        // band/内嵌规划输入 Target)→ 冻结时间重放 → decision/comparison/
        // plans 三层全等验证(同 IDs → 同决策)
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
                "costIntensity@v1": standardMaterials().criterionDefinitions["costIntensity@v1"]!,
                "momentum@v2": CriterionDefinition(
                    id: "momentum", version: "v2", evaluatorKind: .weightedSum,
                    inputReferences: [CriterionDefinition.InputReference(
                        kind: .factorMetric, referenceID: "fs_alt#momentum.return60", weight: 1)],
                    unit: .ratio),
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
            criterionVersions: ["costIntensity@v1", "momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_m")],
            target: nil, bandVersion: bandVersion,
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
        // 五轮 P1-2 回归(七轮内嵌形态):artifact 内嵌规划输入的 Target 与
        // artifact.target 冲突(run 带 target 而 artifact.target=nil)→ 拒
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
            factorSnapshotIDs: base.factorSnapshotIDs,
            target: nil,   // artifact.target = nil
            indifferenceBandVersion: base.indifferenceBandVersion,
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
        let plans = ["A": makePlan("A", delta: "0.05")]
        let a = makeArtifact(decision: decision, plans: plans)
        let b = makeArtifact(decision: decision, plans: plans)
        XCTAssertEqual(a.validityPolicy, .immutableHistorical)
        XCTAssertEqual(a.id, b.id, "引用层+冻结规划输入+结果层相同 → 同 id(producedAt 不参与)")
        // dependencies 覆盖 signal/factor/target + criterion/band 的 policy
        // 依赖(五轮 P1-3:失效传播索引完整)
        XCTAssertEqual(Set(a.dependencies.map(\.referenceID)),
                       ["sig-1", "fs_abc", "criterion@portfolio-momentum@v1", "band@b@v1"])
        XCTAssertTrue(a.dependencies.contains { $0.kind == .signal })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .factorSnapshot })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .policy && $0.referenceID.hasPrefix("criterion@") })
        XCTAssertTrue(a.dependencies.contains { $0.kind == .policy && $0.referenceID.hasPrefix("band@") })

        // 引用层变化 → id 变化
        let differentSignals = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-2")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: bandVersion,
            knowledgeContextSummary: "",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: plans,
            plannerRuns: ["A": plannerRun(delta: "0")],
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentSignals.id)

        // 七轮 P1-3:冻结规划输入参与 id——Planner 输入漂移 → id 变化
        let differentPlannerInputs = PortfolioDecisionArtifact.assemble(
            signalIDs: [SignalID(rawValue: "sig-1")],
            criterionVersions: ["portfolio-momentum@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_abc")],
            target: nil, bandVersion: bandVersion,
            knowledgeContextSummary: "economicKnowledge(2024-07-20)",
            decision: decision,
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: [], blockingUnknowns: []),
            plans: plans,
            plannerRuns: ["A": plannerRun(delta: "0.07")],   // 规划输入与 a 不同
            producedAt: day
        )
        XCTAssertNotEqual(a.id, differentPlannerInputs.id,
                          "冻结规划输入参与 id——重放材料自包含的身份域")
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
        XCTAssertEqual(decoded.indifferenceBandVersion, bandVersion)
        XCTAssertEqual(decoded.plannerInputs, artifact.plannerInputs,
                       "冻结规划输入随 artifact 完整往返")
    }
}
