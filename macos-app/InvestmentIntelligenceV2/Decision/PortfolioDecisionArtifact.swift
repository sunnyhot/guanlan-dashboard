import Foundation

// MARK: - PortfolioDecisionArtifact + DecisionValidator + Replay（DEC-9，ADR-D004）
//
// Decision artifact 引用上游 IDs（Signal / Criterion version / Factor
// snapshot / Target / IndifferenceBand）；重放按引用取，不重跑 Research。
// 引用 IDs 一旦写入永不更改（supersede 不改旧引用——DATA008 vintage 精神）。
//
// M7 验收：same mock inputs → same decision——由 DecisionReplayTests
// 之外的单测（PortfolioDecisionTests）用确定性 planner 闭环覆盖。

/// 决策 artifact（DEC-9）。
struct PortfolioDecisionArtifact: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 决策一经产出即历史事实（重放产新 artifact，不改旧）
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    // 引用层（D004 §1：重放按这些 IDs 取，不重跑 Research）
    /// 引用的 Signal IDs（经 SignalPolicy 转换的 cardinal 通道；Epic 11 产出）
    let signalIDs: [SignalID]
    /// 参与决策的 criterion 版本指纹
    let criterionVersions: [String]
    /// 底层 FactorSnapshot 引用
    let factorSnapshotIDs: [ArtifactID]
    /// 参照 Target（D000 provenance 闭环）
    let target: AllocationTarget?
    /// 比较用的 IndifferenceBand 版本
    let indifferenceBandVersion: String

    // 结果层
    /// 决策上下文（DATA002：当时的可知口径）
    let knowledgeContextSummary: String
    /// 胜出 / 可采纳的 plan（unresolvedTradeoff 时多个 plan 由 Presentation 裁决,
    /// artifact 记录比较结论而非强行选一）
    let decision: PartialDecision
    /// 比较结论（D004 §1 结果层：pairwise / Pareto 前沿 / unknown 阻断——
    /// 二轮审查 P1-2 补，重放一致性验证的对照物）
    let comparison: PlanComparisonResult
    /// 参与比较的 plans（key 与 decision.admissiblePlans 对应域）
    let plans: [String: PortfolioActionPlan]
}

/// 决策校验器（DEC-9，D004 §2）。
struct DecisionValidator: Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        /// plan 动作缺 provenance（D001 闭环断裂）
        case actionMissingSizingProvenance(planID: String)
        /// admissible plan 不在 plans 集合内
        case admissiblePlanNotFound(String)
        /// comparison 引用的 band 版本与 artifact 不一致
        case bandVersionMismatch(artifact: String, referenced: String)
        /// criterion 版本指纹为空（criterion 不可追溯，D002）
        case emptyCriterionVersions
        /// 引用无法解析到具体实例（审查 P1-1：fail-closed，不静默放行）
        case unresolvableReference(kind: String, id: String)
        /// comparison 的 plan 域越界（pairwise 键或前沿含 plans 外的 plan）
        case comparisonPlanDomainViolation(keys: [String])
        /// decision 不是从 comparison 推导的结果（结果层内部矛盾——三轮 P1-6）
        case decisionNotDerivedFromComparison
        /// pairwise 不是完整无序对域（缺失 pair / A|A / 反序重复——四轮 P1-2）
        case pairwiseDomainIncomplete(expected: [String], actual: [String])
        /// paretoFront 与 pairwise dominance 推导不一致（四轮 P1-2）
        case paretoFrontInconsistent(derived: [String], declared: [String])
        /// plan / action 的 Target 引用与 artifact.target 不一致（四轮 P1-3）
        case targetProvenanceMismatch(planID: String, detail: String)
        /// dependencies 引用集合与 signal/factor/target 引用不一致（四轮 P1-3）
        case dependencySetInconsistent
    }

    /// 各类引用的可解析性检查（D004 §2「所有引用 ID 都能解析到具体实例」）。
    /// 生产接 Signal Store（RES-6）/ Repository / Artifact Store；测试传 stub。
    /// **默认全拒绝（二轮审查 P1-1：fail-closed）**——不传 resolver 的调用
    /// 无法证明引用可解析，validate 直接拒绝：调用方必须显式给出能真正
    /// 查证的四类 resolver（测试用 .everythingResolvable 显式声明）。
    struct ReferenceResolvers {
        var signal: (SignalID) -> Bool
        var factorSnapshot: (ArtifactID) -> Bool
        var criterion: (String) -> Bool
        var indifferenceBand: (String) -> Bool

        init(
            signal: @escaping (SignalID) -> Bool = { _ in false },
            factorSnapshot: @escaping (ArtifactID) -> Bool = { _ in false },
            criterion: @escaping (String) -> Bool = { _ in false },
            indifferenceBand: @escaping (String) -> Bool = { _ in false }
        ) {
            self.signal = signal
            self.factorSnapshot = factorSnapshot
            self.criterion = criterion
            self.indifferenceBand = indifferenceBand
        }

        /// 显式声明「全部可解析」（测试 / 上游确已核验引用时的便捷形态）。
        static let everythingResolvable = ReferenceResolvers(
            signal: { _ in true },
            factorSnapshot: { _ in true },
            criterion: { _ in true },
            indifferenceBand: { _ in true }
        )
    }

    /// 校验 artifact 完备性与 provenance 闭环。
    ///
    /// 审查 P1-1 修复：**全部引用 fail-closed**——Signal / FactorSnapshot /
    /// Criterion / Band 任一无法解析立即抛错，不再静默放行（D004 §2）。
    func validate(
        artifact: PortfolioDecisionArtifact,
        resolvers: ReferenceResolvers = ReferenceResolvers()
    ) throws {
        // D002：criterion 可追溯
        guard !artifact.criterionVersions.isEmpty else {
            throw ValidationError.emptyCriterionVersions
        }
        // D003：band 版本闭环
        guard artifact.indifferenceBandVersion != "" else {
            throw ValidationError.bandVersionMismatch(
                artifact: "", referenced: "")
        }
        // D001：provenance 实校验（四轮 P1-3：原实现是空操作枚举）——
        // plan 与 targetRebalance 动作引用的 Target 必须 == artifact.target；
        // remediation / userDirective 的标识非空
        for (planKey, plan) in artifact.plans {
            // 五轮 P1-2:无条件严格相等(含双 nil)——多 Target 冲突的方案
            // 不再因「artifact.target 非 nil 才查」的旁路通过
            guard plan.targetID == artifact.target?.id else {
                throw ValidationError.targetProvenanceMismatch(
                    planID: plan.id,
                    detail: "plan.targetID \(plan.targetID?.rawValue ?? "nil") ≠ artifact.target \(artifact.target?.id.rawValue ?? "nil")")
            }
            for item in plan.actions {
                switch item.provenance {
                case .targetRebalance(let provenance):
                    guard provenance.targetID == artifact.target?.id,
                          plan.targetID == artifact.target?.id
                    else {
                        throw ValidationError.targetProvenanceMismatch(
                            planID: plan.id,
                            detail: "targetRebalance 动作引用的 Target 与 artifact.target 不一致")
                    }
                case .remediation(let remediation):
                    guard !remediation.requirement.constraintID.isEmpty else {
                        throw ValidationError.actionMissingSizingProvenance(planID: plan.id)
                    }
                case .userDirective(let directive):
                    guard !directive.directiveID.isEmpty else {
                        throw ValidationError.actionMissingSizingProvenance(planID: plan.id)
                    }
                }
            }
        }
        // dependencies 与引用层**完整规范化**比较（五轮 P1-3:kind/version/
        // 重复都参与——交换 signal/factor kind 曾可通过;criterion/band 的
        // policy 依赖也纳入）
        let expectedDeps: [ArtifactDependency] =
            artifact.signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + artifact.factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (artifact.target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue)] } ?? [])
            + artifact.criterionVersions.map { ArtifactDependency(kind: .policy, referenceID: "criterion@\($0)") }
            + [ArtifactDependency(kind: .policy, referenceID: "band@\(artifact.indifferenceBandVersion)")]
        let canonical = { (deps: [ArtifactDependency]) -> [String] in
            deps.map { "\($0.kind.rawValue)|\($0.referenceID)|\($0.version ?? "-")" }.sorted()
        }
        guard canonical(artifact.dependencies) == canonical(expectedDeps) else {
            throw ValidationError.dependencySetInconsistent
        }
        // admissible ∈ plans
        for admissible in artifact.decision.admissiblePlans {
            guard artifact.plans[admissible] != nil else {
                throw ValidationError.admissiblePlanNotFound(admissible)
            }
        }
        // 结果层内部一致（三轮 P1-6 域校验 + 四轮 P1-2 完整性）——
        // ① comparison 的 plan 域 ⊆ plans
        let planKeys = Set(artifact.plans.keys)
        let comparisonKeys = artifact.comparison.paretoFront
            + artifact.comparison.pairwise.keys.flatMap { $0.split(separator: "|").map(String.init) }
        let violations = Set(comparisonKeys).subtracting(planKeys).sorted()
        if !violations.isEmpty {
            throw ValidationError.comparisonPlanDomainViolation(keys: violations)
        }
        // 五轮 P2-5:plan key 含分隔符 "|" 会让 pair 键拆分失效——先拒
        let separatorKeys = artifact.plans.keys.filter { $0.isEmpty || $0.contains("|") }.sorted()
        if !separatorKeys.isEmpty {
            throw ValidationError.comparisonPlanDomainViolation(keys: separatorKeys)
        }
        // ② pairwise 必须是完整无序对域（C(n,2)，键为字典序 a|b 形态）：
        // 缺失 pair / A|A / 反序重复都拒收
        let sortedKeys = artifact.plans.keys.sorted()
        var expectedPairs = Set<String>()
        for i in 0..<sortedKeys.count {
            for j in (i + 1)..<sortedKeys.count {
                expectedPairs.insert("\(sortedKeys[i])|\(sortedKeys[j])")
            }
        }
        let actualPairs = Set(artifact.comparison.pairwise.keys)
        if actualPairs != expectedPairs {
            throw ValidationError.pairwiseDomainIncomplete(
                expected: expectedPairs.sorted(), actual: actualPairs.sorted())
        }
        // ③ paretoFront 必须由 pairwise dominance 推导（不被任何 plan
        // dominate 的集合；循环时 front 为空——与推导一致）
        var dominated = Set<String>()
        for (key, dominance) in artifact.comparison.pairwise {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            switch dominance {
            case .aDominatesB: dominated.insert(parts[1])
            case .bDominatesA: dominated.insert(parts[0])
            case .incomparable: break
            }
        }
        let derivedFront = sortedKeys.filter { !dominated.contains($0) }
        guard derivedFront == artifact.comparison.paretoFront.sorted() else {
            throw ValidationError.paretoFrontInconsistent(
                derived: derivedFront, declared: artifact.comparison.paretoFront.sorted())
        }
        // ② decision 必须由 comparison 经 PartialDecisionPolicy 推导
        // (伪造的前沿 / pairwise 或与之矛盾的 decision 在此拒绝)
        let derived = PartialDecisionPolicy().decide(
            artifact.comparison, allPlanKeys: artifact.plans.keys.sorted()
        )
        guard derived == artifact.decision else {
            throw ValidationError.decisionNotDerivedFromComparison
        }
        // 引用可解析（fail-closed）
        for signalID in artifact.signalIDs where !resolvers.signal(signalID) {
            throw ValidationError.unresolvableReference(kind: "signal", id: signalID.rawValue)
        }
        for factorID in artifact.factorSnapshotIDs where !resolvers.factorSnapshot(factorID) {
            throw ValidationError.unresolvableReference(kind: "factorSnapshot", id: factorID.rawValue)
        }
        for criterion in artifact.criterionVersions where !resolvers.criterion(criterion) {
            throw ValidationError.unresolvableReference(kind: "criterion", id: criterion)
        }
        if !resolvers.indifferenceBand(artifact.indifferenceBandVersion) {
            throw ValidationError.unresolvableReference(kind: "indifferenceBand", id: artifact.indifferenceBandVersion)
        }
    }
}

/// 决策重放器（DEC-9，D004 §3/5）。
///
/// 审查 P1-1 修复：完整重放覆盖 **Planner → Compare → Decide 全链**——
/// plans 的 Δw 由 Planner 从（按 artifact 引用取齐的）确定性输入重新生成，
/// 重放结论含行动计划本身，不只是方案键。不重跑 Research / 不重抓数据 /
/// 不重算 factor（取数是调用方职责，输入按引用 IDs 取齐）。
struct DecisionReplayer: Sendable {
    /// 单个 plan 的规划输入（重放时重新产 Δw）。
    struct PlannerRun: Sendable, Codable, Hashable {
        let portfolio: PortfolioSnapshot
        let target: AllocationTarget?
        let remediationTargets: [RemediationTargetInput]
        let userDirectives: [UserDirectiveInput]
        let actionDomain: ActionDomain
        let plannerParameters: TargetRebalancePlanner.Parameters
    }

    /// 重放的**原材料**（五轮 P1-1：resolver 按引用返回强类型实例 / cardinal
    /// 输入——**不含分数**。CriterionScore 由 Replayer 内部用
    /// CriterionEvaluator 从这些材料重算，resolver 无法提供任意或最新分数
    /// 冒充引用实例的产出）。
    struct ReplayMaterials: Sendable, Codable, Hashable {
        /// 每 plan 的规划输入（Planner 链）
        let plannerRuns: [String: PlannerRun]
        /// criterion 定义（key = fingerprint「id@version」；必须恰好覆盖
        /// artifact.criterionVersions——绑定校验强制，多一个少一个都拒）
        let criterionDefinitions: [String: CriterionDefinition]
        /// 每 plan 的 criterion 输入（key = plan key；值 = 该 plan 对引用
        /// 实例提取的 cardinal——resolver 给**输入值**，分数由 Replayer
        /// 内部 evaluator 计算）
        let criterionInputs: [String: [CriterionInput]]
        /// FactorSnapshot 强类型实例（key = snapshot ID）——factor 引用域
        /// 从定义派生后实例必须齐备（无法「复制 ID 给别的实例」）
        let factorSnapshots: [String: FactorSnapshot]
        let band: IndifferenceBand
        let higherIsBetter: [String: Bool]

        init(
            plannerRuns: [String: PlannerRun],
            criterionDefinitions: [String: CriterionDefinition] = [:],
            criterionInputs: [String: [CriterionInput]] = [:],
            factorSnapshots: [String: FactorSnapshot] = [:],
            band: IndifferenceBand,
            higherIsBetter: [String: Bool] = [:]
        ) {
            self.plannerRuns = plannerRuns
            self.criterionDefinitions = criterionDefinitions
            self.criterionInputs = criterionInputs
            self.factorSnapshots = factorSnapshots
            self.band = band
            self.higherIsBetter = higherIsBetter
        }
    }

    /// 重放结论（审查 P1-1：含行动计划本身）。
    struct ReplayOutcome: Sendable, Codable, Hashable {
        let plans: [String: PortfolioActionPlan]
        let comparison: PlanComparisonResult
        let decision: PartialDecision
    }

    /// 纯计算 helper（私有：不做绑定校验——绑定是 artifact 入口的职责）。
    /// 五轮 P1-1：**scores 在此从材料重算**（criterion definition + cardinal
    /// 原料 → CriterionEvaluator），resolver 提供的不是分数。
    private func compute(materials: ReplayMaterials, now: Date) -> ReplayOutcome {
        var plans: [String: PortfolioActionPlan] = [:]
        for (key, run) in materials.plannerRuns {
            plans[key] = TargetRebalancePlanner(parameters: run.plannerParameters).plan(
                portfolio: run.portfolio,
                target: run.target,
                remediationTargets: run.remediationTargets,
                userDirectives: run.userDirectives,
                actionDomain: run.actionDomain,
                now: now
            )
        }
        // criterion 分数重算（每个 plan 对每个引用 criterion 求值——
        /// 输入值来自 resolver 对引用实例的提取,计算在 evaluator）
        let evaluator = CriterionEvaluator()
        var scores: [String: [CriterionScore]] = [:]
        for key in materials.plannerRuns.keys {
            let planInputs = Dictionary(
                uniqueKeysWithValues: (materials.criterionInputs[key] ?? []).map { ($0.referenceID, $0) }
            )
            scores[key] = materials.criterionDefinitions.values
                .sorted { $0.fingerprint < $1.fingerprint }
                .map { definition in
                    let inputs = definition.inputReferences.map { reference in
                        planInputs[reference.referenceID] ??
                            CriterionInput(referenceID: reference.referenceID, value: nil)
                    }
                    return evaluator.evaluate(definition: definition, inputs: inputs)
                }
        }
        let comparison = CriterionComparator().compare(
            plans: scores,
            band: materials.band,
            higherIsBetter: materials.higherIsBetter
        )
        let decision = PartialDecisionPolicy().decide(
            comparison, allPlanKeys: scores.keys.sorted()
        )
        return ReplayOutcome(plans: plans, comparison: comparison, decision: decision)
    }

    /// Partial 重放（what-if，五轮 P1-1）：替换某 plan 的 criterion 输入
    /// 后重跑——分数仍由 Replayer 重算，what-if 也不接受注入分数。
    /// 产新决策素材，不影响原 artifact（D004 §5）。
    func replayWhatIf(
        base: ReplayMaterials,
        replacingInputs inputs: [String: [CriterionInput]],
        now: Date
    ) -> ReplayOutcome {
        let materials = ReplayMaterials(
            plannerRuns: base.plannerRuns,
            criterionDefinitions: base.criterionDefinitions,
            criterionInputs: base.criterionInputs.merging(inputs) { _, new in new },
            factorSnapshots: base.factorSnapshots,
            band: base.band,
            higherIsBetter: base.higherIsBetter
        )
        return compute(materials: materials, now: now)
    }

    // MARK: - artifact 绑定重放

    enum ReplayError: Error, Equatable, Sendable {
        /// plannerRuns 与 artifact 的 plan 域不一致
        case artifactPlanDomainMismatch(artifact: [String], inputs: [String])
        /// 重放结果与 artifact 不一致（完整重放的「同 IDs → 同决策」被破坏）
        case replayMismatch(detail: String)
        /// 材料与 artifact 引用层不一致（五轮 P1-1）
        case referenceMismatch(declared: String, artifact: String)
    }

    /// 引用解析器（五轮 P1-1）：**材料的唯一合法来源**——按 artifact 引用
    /// 层逐 ID 解析强类型实例（FactorSnapshot）/ cardinal（signal 经
    /// SignalPolicy 的转换值 / observation 提取值）/ criterion 定义 / band
    /// 实例 / 规划输入。**不返回分数**——分数由 Replayer 从材料重算。
    protocol InputResolving: Sendable {
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> ReplayMaterials
    }

    /// 以 artifact 为入口的完整重放（五轮 P1-1）：resolver 解析材料 →
    /// 绑定校验 → 材料重算分数 → 全链重跑。
    func replay(
        artifact: PortfolioDecisionArtifact,
        resolver: any InputResolving,
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        let materials: ReplayMaterials
        do {
            materials = try resolver.resolveMaterials(for: artifact)
        } catch {
            throw .referenceMismatch(declared: "resolver 解析失败: \(error)", artifact: "artifact 引用不可解析")
        }
        try validateBinding(materials: materials, against: artifact)
        return compute(materials: materials, now: now)
    }

    /// 绑定校验（五轮 P1-1/P1-2）：
    /// ① 键域（plannerRuns == artifact.plans）；
    /// ② criterion 定义域**恰好覆盖** artifact.criterionVersions（结构绑定，
    /// resolver 多给少给都拒）；band 实例版本一致；
    /// ③ 逐 plannerRun 的 target 与 artifact.target **无条件严格相等**
    /// （双 nil 或同 ID——多个冲突 Target 不再折叠通过）；
    /// ④ factor 实例域与 artifact.factorSnapshotIDs 一致（强类型实例的
    /// key 域即声明，无法「复制 ID 给别的实例」）。
    private func validateBinding(
        materials: ReplayMaterials, against artifact: PortfolioDecisionArtifact
    ) throws(ReplayError) {
        let plannerKeys = materials.plannerRuns.keys.sorted()
        let artifactKeys = artifact.plans.keys.sorted()
        guard plannerKeys == artifactKeys else {
            throw .artifactPlanDomainMismatch(artifact: artifactKeys, inputs: plannerKeys)
        }
        // criterion 定义域恰好覆盖
        let definitionFingerprints = Set(materials.criterionDefinitions.keys)
        guard definitionFingerprints == Set(artifact.criterionVersions) else {
            throw .referenceMismatch(
                declared: "definitions=\(definitionFingerprints.sorted())",
                artifact: "criterionVersions=\(artifact.criterionVersions.sorted())")
        }
        // band 版本
        let bandVersion = "\(materials.band.policyID)@\(materials.band.version)"
        guard bandVersion == artifact.indifferenceBandVersion else {
            throw .referenceMismatch(
                declared: "band=\(bandVersion)", artifact: "band=\(artifact.indifferenceBandVersion)")
        }
        // 逐 run Target 严格相等(含双 nil;多 Target 冲突在此拒)
        for (key, run) in materials.plannerRuns {
            guard run.target?.id == artifact.target?.id else {
                throw .referenceMismatch(
                    declared: "plan[\(key)].target=\(run.target?.id.rawValue ?? "nil")",
                    artifact: "target=\(artifact.target?.id.rawValue ?? "nil")")
            }
        }
        // factor 引用域从**定义实例**派生(factorMetric refID 约定
        // 「<snapshotID>#<metricKey>」),实例必须齐备——复制 ID 给别的
        // 实例无法通过
        let referencedFactorIDs = Set(
            materials.criterionDefinitions.values.flatMap { definition in
                definition.inputReferences.compactMap { reference -> String? in
                    guard reference.kind == .factorMetric else { return nil }
                    let parts = reference.referenceID.split(separator: "#", maxSplits: 1)
                    return parts.count == 2 ? String(parts[0]) : nil
                }
            }
        )
        guard referencedFactorIDs == Set(artifact.factorSnapshotIDs.map(\.rawValue)),
              Set(materials.factorSnapshots.keys).isSuperset(of: referencedFactorIDs)
        else {
            throw .referenceMismatch(
                declared: "factorRefs=\(referencedFactorIDs.sorted()) instances=\(materials.factorSnapshots.keys.sorted())",
                artifact: "factorSnapshots=\(artifact.factorSnapshotIDs.map(\.rawValue).sorted())")
        }
        // signal 引用域同样从定义派生(signalCardinal refID 即 signalID)
        let referencedSignalIDs = Set(
            materials.criterionDefinitions.values.flatMap { definition in
                definition.inputReferences
                    .filter { $0.kind == .signalCardinal }
                    .map(\.referenceID)
            }
        )
        guard referencedSignalIDs == Set(artifact.signalIDs.map(\.rawValue)) else {
            throw .referenceMismatch(
                declared: "signalRefs=\(referencedSignalIDs.sorted())",
                artifact: "signalIDs=\(artifact.signalIDs.map(\.rawValue).sorted())")
        }
    }

    /// 完整重放一致性验证（D004 §3「同 IDs → 同决策」的运行时形态）：
    /// resolver 解析输入 → 绑定校验（四轮 P1-1）→ 重放 outcome 必须与
    /// artifact 的 decision / comparison / plans 全等，任一不一致抛错。
    func verify(
        artifact: PortfolioDecisionArtifact,
        resolver: any InputResolving,
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        let outcome = try replay(artifact: artifact, resolver: resolver, now: now)
        guard outcome.decision == artifact.decision else {
            throw .replayMismatch(detail: "decision 不一致：\(outcome.decision) vs \(artifact.decision)")
        }
        guard outcome.comparison == artifact.comparison else {
            throw .replayMismatch(detail: "comparison 不一致（Pareto 前沿或 pairwise 漂移）")
        }
        guard outcome.plans == artifact.plans else {
            let differing = outcome.plans.filter { $0.value != artifact.plans[$0.key] }.keys.sorted()
            throw .replayMismatch(detail: "plans 不一致：\(differing.joined(separator: ", "))")
        }
        return outcome
    }
}

// MARK: - 决策组装器（artifact 构造的便捷入口）

extension PortfolioDecisionArtifact {
    /// 从比较结论组装 artifact（id 确定性派生：引用层 + 结果层完整语义——
    /// decision + plans + 上下文，审查 P1-3 修复；只排除 producedAt）。
    static func assemble(
        signalIDs: [SignalID],
        criterionVersions: [String],
        factorSnapshotIDs: [ArtifactID],
        target: AllocationTarget?,
        bandVersion: String,
        knowledgeContextSummary: String,
        decision: PartialDecision,
        comparison: PlanComparisonResult,
        plans: [String: PortfolioActionPlan],
        producedAt: Date
    ) -> PortfolioDecisionArtifact {
        // 确定性类型的编码失败 = 编程错误,fail-fast
        let payload = try! StableDigest.jsonPayload(IdentityPayload(
            signalIDs: signalIDs.map(\.rawValue).sorted(),
            criterionVersions: criterionVersions.sorted(),
            factorSnapshotIDs: factorSnapshotIDs.map(\.rawValue).sorted(),
            targetID: target?.id.rawValue,
            bandVersion: bandVersion,
            knowledgeContextSummary: knowledgeContextSummary,
            decision: decision,
            comparison: comparison,
            plans: plans
        ))
        // 五轮 P1-3:criterion / band 的 policy 依赖一并登记(失效传播:
        // criterion 版本或 band 阈值变更 → 受影响决策可反查)
        let deps: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue, version: nil)] } ?? [])
            + criterionVersions.map { ArtifactDependency(kind: .policy, referenceID: "criterion@\($0)") }
            + [ArtifactDependency(kind: .policy, referenceID: "band@\(bandVersion)")]
        return PortfolioDecisionArtifact(
            id: ArtifactID(rawValue: "dec_\(StableDigest.digest(payload))"),
            producedAt: producedAt,
            validityPolicy: .immutableHistorical,
            dependencies: deps,
            signalIDs: signalIDs,
            criterionVersions: criterionVersions,
            factorSnapshotIDs: factorSnapshotIDs,
            target: target,
            indifferenceBandVersion: bandVersion,
            knowledgeContextSummary: knowledgeContextSummary,
            decision: decision,
            comparison: comparison,
            plans: plans
        )
    }

    /// ID 身份 payload（语义完备；审查 P1-3）。
    private struct IdentityPayload: Encodable {
        let signalIDs: [String]
        let criterionVersions: [String]
        let factorSnapshotIDs: [String]
        let targetID: String?
        let bandVersion: String
        let knowledgeContextSummary: String
        let decision: PartialDecision
        let comparison: PlanComparisonResult
        let plans: [String: PortfolioActionPlan]
    }
}
