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
            if let artifactTarget = artifact.target {
                guard plan.targetID == artifactTarget.id else {
                    throw ValidationError.targetProvenanceMismatch(
                        planID: plan.id,
                        detail: "plan.targetID \(plan.targetID?.rawValue ?? "nil") ≠ artifact.target \(artifactTarget.id.rawValue)")
                }
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
        // dependencies 引用集合与引用层一致（四轮 P1-3）
        var expectedRefs = Set(artifact.signalIDs.map(\.rawValue))
        expectedRefs.formUnion(artifact.factorSnapshotIDs.map(\.rawValue))
        if let target = artifact.target {
            expectedRefs.insert(target.id.rawValue)
        }
        guard Set(artifact.dependencies.map(\.referenceID)) == expectedRefs else {
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

    /// 重放的确定性输入快照。
    struct ReplayInputs: Sendable, Codable, Hashable {
        /// 每 plan 的规划输入（Planner 链）
        let plannerRuns: [String: PlannerRun]
        /// 每 plan 的 criterion 分数（Compare 链；由 criterion evaluator 按
        /// 引用取齐的 cardinal 输入重算——同样是确定性重放的一部分）
        let scores: [String: [CriterionScore]]
        let band: IndifferenceBand
        let higherIsBetter: [String: Bool]
        /// resolver 声明的取数来源（signal / factor 两类无法从 inputs 内容
        /// 派生——criterion/target/band 在 derivedReferences 里**从实际内容
        /// 结构性派生**，调用方无法自报；四轮 P1-1）
        let resolvedReferences: ResolvedReferences

        init(
            plannerRuns: [String: PlannerRun],
            scores: [String: [CriterionScore]],
            band: IndifferenceBand,
            higherIsBetter: [String: Bool],
            resolvedReferences: ResolvedReferences = ResolvedReferences()
        ) {
            self.plannerRuns = plannerRuns
            self.scores = scores
            self.band = band
            self.higherIsBetter = higherIsBetter
            self.resolvedReferences = resolvedReferences
        }

        /// **从实际内容结构性派生**的引用身份（四轮 P1-1：无法自报）——
        /// criterion 来自 scores 的 definition fingerprint、band 来自
        /// inputs.band 的 policyID@version、target 来自 plannerRuns。
        var derivedReferences: ResolvedReferences {
            let criteria = Set(scores.values.flatMap { $0.map { $0.definition.fingerprint } })
            let targetIDs = Set(plannerRuns.values.compactMap { $0.target?.id.rawValue })
            return ResolvedReferences(
                signalIDs: resolvedReferences.signalIDs,
                factorSnapshotIDs: resolvedReferences.factorSnapshotIDs,
                criterionVersions: criteria.sorted(),
                targetID: targetIDs.count == 1 ? targetIDs.first : nil,
                bandVersion: "\(band.policyID)@\(band.version)"
            )
        }
    }

    /// 重放取数时实际解析到的引用身份（按 artifact 引用层结构）。
    struct ResolvedReferences: Sendable, Codable, Hashable {
        let signalIDs: [String]
        let factorSnapshotIDs: [String]
        let criterionVersions: [String]
        let targetID: String?
        let bandVersion: String

        init(
            signalIDs: [String] = [], factorSnapshotIDs: [String] = [],
            criterionVersions: [String] = [], targetID: String? = nil,
            bandVersion: String = ""
        ) {
            self.signalIDs = signalIDs
            self.factorSnapshotIDs = factorSnapshotIDs
            self.criterionVersions = criterionVersions
            self.targetID = targetID
            self.bandVersion = bandVersion
        }
    }

    /// 重放结论（审查 P1-1：含行动计划本身）。
    struct ReplayOutcome: Sendable, Codable, Hashable {
        let plans: [String: PortfolioActionPlan]
        let comparison: PlanComparisonResult
        let decision: PartialDecision
    }

    /// 纯计算 helper（四轮 P1-1 私有化：不做任何绑定校验——绑定是
    /// artifact 入口的职责，裸输入不得绕过引用解析）。
    private func compute(inputs: ReplayInputs, now: Date) -> ReplayOutcome {
        var plans: [String: PortfolioActionPlan] = [:]
        for (key, run) in inputs.plannerRuns {
            plans[key] = TargetRebalancePlanner(parameters: run.plannerParameters).plan(
                portfolio: run.portfolio,
                target: run.target,
                remediationTargets: run.remediationTargets,
                userDirectives: run.userDirectives,
                actionDomain: run.actionDomain,
                now: now
            )
        }
        let comparison = CriterionComparator().compare(
            plans: inputs.scores,
            band: inputs.band,
            higherIsBetter: inputs.higherIsBetter
        )
        let decision = PartialDecisionPolicy().decide(
            comparison, allPlanKeys: inputs.scores.keys.sorted()
        )
        return ReplayOutcome(plans: plans, comparison: comparison, decision: decision)
    }

    /// Partial 重放（what-if）：替换部分引用后重跑（D004 §5：产新决策的
    /// 素材，不是完整重放——绑定校验不适用）。resolver 构造的 base 输入
    /// 才是合法起点。
    func replayWhatIf(
        base: ReplayInputs,
        replacingScores scores: [String: [CriterionScore]],
        now: Date
    ) -> ReplayOutcome {
        compute(inputs: ReplayInputs(
            plannerRuns: base.plannerRuns,
            scores: base.scores.merging(scores) { _, new in new },
            band: base.band,
            higherIsBetter: base.higherIsBetter
        ), now: now)
    }

    // MARK: - artifact 绑定重放（二轮审查 P1-2）

    enum ReplayError: Error, Equatable, Sendable {
        /// plannerRuns 与 scores 的 plan key 域不一致
        case planKeyDomainMismatch(plannerRuns: [String], scores: [String])
        /// inputs 与 artifact 的 plan 域不一致（决策指向的 plan 不在重放输入中）
        case artifactPlanDomainMismatch(artifact: [String], inputs: [String])
        /// 重放结果与 artifact 不一致（完整重放的「同 IDs → 同决策」被破坏）
        case replayMismatch(detail: String)
        /// inputs 的已解析引用与 artifact 引用层不一致（三轮 P1-3）
        case referenceMismatch(declared: String, artifact: String)
    }

    /// 引用解析器（四轮 P1-1）：**inputs 的唯一合法来源**——按 artifact
    /// 引用层真实取数（planner 输入 / criterion scores 从 factor 与 signal
    /// cardinal 重算 / band 实例）。实现方对 signal/factor 声明负责
    /// （这两类无法从 inputs 内容派生）；criterion/target/band 由
    /// derivedReferences 从实际内容结构性派生，实现方无法自报。
    protocol InputResolving: Sendable {
        func resolveInputs(for artifact: PortfolioDecisionArtifact) throws -> ReplayInputs
    }

    enum ResolverError: Error, Equatable, Sendable {
        case resolutionFailed(reason: String)
    }

    /// 以 artifact 为入口的完整重放（四轮 P1-1）：resolver 解析输入 →
    /// 绑定校验（键域 + 结构性派生引用 + resolver 声明引用）→ 全链重跑。
    func replay(
        artifact: PortfolioDecisionArtifact,
        resolver: any InputResolving,
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        let inputs: ReplayInputs
        do {
            inputs = try resolver.resolveInputs(for: artifact)
        } catch {
            throw .referenceMismatch(declared: "resolver 解析失败: \(error)", artifact: "artifact 引用不可解析")
        }
        try validateBinding(inputs: inputs, against: artifact)
        return compute(inputs: inputs, now: now)
    }

    /// 绑定校验：①键域（plannerRuns == scores == artifact.plans）；
    /// ②结构性派生引用（criterion 来自 scores 实际 definition、band 来自
    /// 实际实例、target 来自 plannerRuns 实际引用）必须与 artifact 引用层
    /// 一致；③resolver 声明的 signal/factor 引用一致。
    private func validateBinding(
        inputs: ReplayInputs, against artifact: PortfolioDecisionArtifact
    ) throws(ReplayError) {
        let plannerKeys = inputs.plannerRuns.keys.sorted()
        let scoreKeys = inputs.scores.keys.sorted()
        guard plannerKeys == scoreKeys else {
            throw .planKeyDomainMismatch(plannerRuns: plannerKeys, scores: scoreKeys)
        }
        let artifactKeys = artifact.plans.keys.sorted()
        guard plannerKeys == artifactKeys else {
            throw .artifactPlanDomainMismatch(artifact: artifactKeys, inputs: plannerKeys)
        }
        // 结构性派生(criterion/band/target)+ resolver 声明(signal/factor)
        let derived = inputs.derivedReferences
        let referenced = ResolvedReferences(
            signalIDs: artifact.signalIDs.map(\.rawValue).sorted(),
            factorSnapshotIDs: artifact.factorSnapshotIDs.map(\.rawValue).sorted(),
            criterionVersions: artifact.criterionVersions.sorted(),
            targetID: artifact.target?.id.rawValue,
            bandVersion: artifact.indifferenceBandVersion
        )
        // 派生项必须一致(criterion/target/band——从实际内容算出,不可自报)
        guard derived.criterionVersions == referenced.criterionVersions,
              derived.targetID == referenced.targetID,
              derived.bandVersion == referenced.bandVersion
        else {
            throw .referenceMismatch(
                declared: "derived criterion=\(derived.criterionVersions) target=\(derived.targetID ?? "-") band=\(derived.bandVersion)",
                artifact: "criterion=\(referenced.criterionVersions) target=\(referenced.targetID ?? "-") band=\(referenced.bandVersion)"
            )
        }
        // resolver 声明项必须一致(signal/factor)
        guard derived.signalIDs == referenced.signalIDs,
              derived.factorSnapshotIDs == referenced.factorSnapshotIDs
        else {
            throw .referenceMismatch(
                declared: "resolver signal=\(derived.signalIDs) factor=\(derived.factorSnapshotIDs)",
                artifact: "signal=\(referenced.signalIDs) factor=\(referenced.factorSnapshotIDs)"
            )
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
        let deps: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue, version: nil)] } ?? [])
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
