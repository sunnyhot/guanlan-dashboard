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
        // D001：全部动作 provenance 闭环（类型已保证枚举封闭,复核非空域）
        for (_, plan) in artifact.plans {
            for item in plan.actions {
                switch item.provenance {
                case .targetRebalance, .remediation, .userDirective:
                    break
                }
            }
        }
        // admissible ∈ plans
        for admissible in artifact.decision.admissiblePlans {
            guard artifact.plans[admissible] != nil else {
                throw ValidationError.admissiblePlanNotFound(admissible)
            }
        }
        // 三轮 P1-6:结果层内部一致——
        // ① comparison 的 plan 域(pairwise 键 + 前沿)必须 ⊆ plans
        let planKeys = Set(artifact.plans.keys)
        let comparisonKeys = artifact.comparison.paretoFront
            + artifact.comparison.pairwise.keys.flatMap { $0.split(separator: "|").map(String.init) }
        let violations = Set(comparisonKeys).subtracting(planKeys).sorted()
        if !violations.isEmpty {
            throw ValidationError.comparisonPlanDomainViolation(keys: violations)
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
        /// **已解析引用的身份声明（三轮 P1-3）**：inputs 的取数来源必须与
        /// artifact 引用层逐项一致——verify 核对，防止「任意输入碰巧重放出
        /// 相同结果」冒充「同 IDs → 同决策」。
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

    /// 完整重放：Planner → Compare → Decide 全链确定性重跑。
    func replay(inputs: ReplayInputs, now: Date) -> ReplayOutcome {
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

    /// Partial 重放（what-if）：替换部分引用（如换 scores / 换规划输入）后
    /// 重跑。结果是新决策,不影响原 artifact（D004 §5）。
    func replayWhatIf(
        base: ReplayInputs,
        replacingScores scores: [String: [CriterionScore]],
        now: Date
    ) -> ReplayOutcome {
        replay(inputs: ReplayInputs(
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

    /// 以 artifact 为入口的完整重放：校验 inputs 键域（plannerRuns ==
    /// scores == artifact.plans——决策指向的 plan 必须在重放输入中），
    /// 重跑 Planner→Compare→Decide 全链。
    func replay(
        artifact: PortfolioDecisionArtifact,
        inputs: ReplayInputs,
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        let plannerKeys = inputs.plannerRuns.keys.sorted()
        let scoreKeys = inputs.scores.keys.sorted()
        guard plannerKeys == scoreKeys else {
            throw .planKeyDomainMismatch(plannerRuns: plannerKeys, scores: scoreKeys)
        }
        let artifactKeys = artifact.plans.keys.sorted()
        guard plannerKeys == artifactKeys else {
            throw .artifactPlanDomainMismatch(artifact: artifactKeys, inputs: plannerKeys)
        }
        return replay(inputs: inputs, now: now)
    }

    /// 完整重放一致性验证（D004 §3「同 IDs → 同决策」的运行时形态）：
    /// ① inputs 的已解析引用必须与 artifact 引用层逐项一致（三轮 P1-3）；
    /// ② 重放 outcome 必须与 artifact 的 decision / comparison / plans
    /// 全等。任一不一致抛错（fail-closed，不静默容忍漂移）。
    func verify(
        artifact: PortfolioDecisionArtifact,
        inputs: ReplayInputs,
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        // 三轮 P1-3:引用身份逐项核对(取数来源必须是被重放 artifact 的引用)
        let declared = inputs.resolvedReferences
        let referenced = ResolvedReferences(
            signalIDs: artifact.signalIDs.map(\.rawValue).sorted(),
            factorSnapshotIDs: artifact.factorSnapshotIDs.map(\.rawValue).sorted(),
            criterionVersions: artifact.criterionVersions.sorted(),
            targetID: artifact.target?.id.rawValue,
            bandVersion: artifact.indifferenceBandVersion
        )
        guard declared == referenced else {
            throw .referenceMismatch(
                declared: "signal=\(declared.signalIDs) factor=\(declared.factorSnapshotIDs) criterion=\(declared.criterionVersions) target=\(declared.targetID ?? "-") band=\(declared.bandVersion)",
                artifact: "signal=\(referenced.signalIDs) factor=\(referenced.factorSnapshotIDs) criterion=\(referenced.criterionVersions) target=\(referenced.targetID ?? "-") band=\(referenced.bandVersion)"
            )
        }
        let outcome = try replay(artifact: artifact, inputs: inputs, now: now)
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
