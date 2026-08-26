import Foundation

// MARK: - PortfolioDecisionArtifact + DecisionValidator + Replay（DEC-9，ADR-D004）
//
// Decision artifact 引用上游 IDs（Signal / Criterion version / Factor
// snapshot / Target / IndifferenceBand）；重放按引用取，不重跑 Research。
// 引用 IDs 一旦写入永不更改（supersede 不改旧引用——DATA008 vintage 精神）。
//
// M7 验收：same mock inputs → same decision——由 DecisionReplayTests
// 之外的单测（PortfolioDecisionTests）用确定性 planner 闭环覆盖。
//
// 六轮审查修复（P1×4）：输入提取/实例身份/重放自包含/依赖多重集合比较。
// 七轮审查修复（P1×3）：逐 plan 求值（PlanMetrics）、what-if 产新 artifact、
// Planner 输入冻结内嵌、删除 ordinal 伪 cardinal 通道。
// 八轮审查修复（P1×4 + P2×2）：
// - P1 投影完整性：projectedWeight 复用 ProjectedPortfolio.project——
//   白名单新标的（eligibleNewSubjects 声明资产类）进入投影，合法但
//   缺席的类别返回已知的 0（不是 unknown）；白名外新标的 fail-closed 拒；
// - P1 冻结规划一致性：frozenPlannerIssue 共享校验（Validator / replay /
//   what-if 同一门禁）——plans 非空、域相等、逐 run Target 相等、逐 plan
//   以冻结 asOf 重跑 Planner 与已存 plan 全等，「Validator 放行而
//   Replayer 拒绝」的分裂不再可能；
// - P1 payload 兼容：plannerInputs 入 payload 后结构不兼容旧
//   PORTFOLIO_DECISION——codec 切换到新 kind PORTFOLIO_DECISION_V2，
//   旧 kind 行不再被 decision typed fetch 接受（不可完整重放的 legacy，
//   fail-closed，不伪造缺失的 PlannerRun）；
// - P1 内容绑定：criterion / band 的引用层纳入 contentDigest（同版本
//   不同权重/引用/方向/阈值在绑定时被拒）；assemble 以定义与 band 实例
//   为唯一来源派生 versions / digests / band 版本（不允许字符串与内容
//   分叉）；
// - P2 Comparator canonical union：定义取全部 plan 的 union，后续 plan
//   首次出现的 criterion 不再漏登记；方向无默认值回退。
// - P2 what-if 洗白：what-if 计算前先过冻结规划一致性校验，损坏的 base
//   不会被「洗成」结构自洽的新 artifact。

/// 决策 artifact（DEC-9）。
struct PortfolioDecisionArtifact: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 决策一经产出即历史事实（重放产新 artifact，不改旧）
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    // 引用层（D004 §1：重放按这些 IDs 取，不重跑 Research）
    /// 引用的 Signal IDs（research provenance——ordinal signal 保持
    /// narrative，不进 criterion 数学运算，D002/七轮 P1）
    let signalIDs: [SignalID]
    /// 参与决策的 criterion 版本指纹
    let criterionVersions: [String]
    /// criterion 内容摘要（fingerprint → contentDigest；八轮 P1-4：
    /// 版本字符串不绑定材料语义——同版本不同内容在绑定时被拒）
    let criterionContentDigests: [String: String]
    /// 底层 FactorSnapshot 引用
    let factorSnapshotIDs: [ArtifactID]
    /// 参照 Target（D000 provenance 闭环）
    let target: AllocationTarget?
    /// 比较用的 IndifferenceBand 版本
    let indifferenceBandVersion: String
    /// band 内容摘要（八轮 P1-4）
    let bandContentDigest: String
    /// 冻结内嵌的规划输入（七轮 P1-3：每 plan 的 portfolio / target /
    /// remediation / directives / actionDomain / parameters——完整重放
    /// 从 artifact 本体取 Planner 输入，自包含，不依赖外部 Store）
    let plannerInputs: [String: DecisionReplayer.PlannerRun]

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
        /// plans 为空（八轮 P1-2：无方案决策是退化形态，不产出 artifact）
        case emptyPlans
        /// 内嵌规划输入域与 plans 域不一致（七轮 P1-3）
        case plannerInputDomainViolation(keys: [String])
        /// 内嵌规划输入的 Target 与 artifact.target 冲突（八轮 P1-2）
        case plannerTargetConflict(planKey: String)
        /// 已存 plan 无法由内嵌规划输入以冻结 asOf 重放（八轮 P1-2）
        case frozenPlanMismatch(planKey: String)
        /// 内容摘要域不完整（摘要未覆盖全部 criterion 版本 / band 摘要缺失，
        /// 八轮 P1-4）
        case contentDigestIncomplete(keys: [String])
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
    /// （criterion / band 的版本可解析性由 resolver 查证；Planner 输入
    /// 冻结内嵌于 artifact 本体，无需 resolver——七轮 P1-3。）
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
        // 八轮 P1-4：内容摘要恰好覆盖全部 criterion 版本且非空；band 摘要非空
        let digestKeys = Set(artifact.criterionContentDigests.keys)
        guard digestKeys == Set(artifact.criterionVersions),
              !artifact.criterionContentDigests.values.contains(where: \.isEmpty),
              !artifact.bandContentDigest.isEmpty
        else {
            throw ValidationError.contentDigestIncomplete(
                keys: digestKeys.symmetricDifference(artifact.criterionVersions).sorted())
        }
        // 八轮 P1-2：冻结规划一致性（空 plans / 域 / 逐 run Target /
        // 逐 plan 可重放）——与 Replayer/what-if 共用同一门禁
        if let issue = DecisionReplayer.frozenPlannerIssue(of: artifact) {
            switch issue {
            case .emptyPlans:
                throw ValidationError.emptyPlans
            case .domainMismatch(let artifactKeys, let inputKeys):
                throw ValidationError.plannerInputDomainViolation(
                    keys: Set(artifactKeys).symmetricDifference(inputKeys).sorted())
            case .targetConflict(let planKey):
                throw ValidationError.plannerTargetConflict(planKey: planKey)
            case .planNotReproducible(let planKey):
                throw ValidationError.frozenPlanMismatch(planKey: planKey)
            }
        }
        // D001：provenance 实校验（四轮 P1-3：原实现是空操作枚举）——
        // plan 与 targetRebalance 动作引用的 Target 必须 == artifact.target；
        // remediation / userDirective 的标识非空
        for plan in artifact.plans.values {
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
        // dependencies 与引用层完整比较（五轮 P1-3:kind/version/重复都参与;
        // 六轮 P1-4:多重集合按 ArtifactDependency 结构化相等计数——不再
        // 拼接分隔符字符串;八轮 P1-4:criterion/band 依赖携带内容摘要为
        // version——失效传播按内容粒度）
        let expectedDeps: [ArtifactDependency] =
            artifact.signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + artifact.factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (artifact.target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue)] } ?? [])
            + artifact.criterionVersions.map {
                ArtifactDependency(
                    kind: .policy, referenceID: "criterion@\($0)",
                    version: artifact.criterionContentDigests[$0])
            }
            + [ArtifactDependency(
                kind: .policy, referenceID: "band@\(artifact.indifferenceBandVersion)",
                version: artifact.bandContentDigest)]
        let dependencyCounts = { (deps: [ArtifactDependency]) -> [ArtifactDependency: Int] in
            var counts: [ArtifactDependency: Int] = [:]
            for dep in deps { counts[dep, default: 0] += 1 }
            return counts
        }
        guard dependencyCounts(artifact.dependencies) == dependencyCounts(expectedDeps) else {
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
/// 完整重放覆盖 **Planner → Compare → Decide 全链**——plans 的 Δw 由
/// Planner 从 artifact **冻结内嵌**的规划输入重新生成，重放结论含行动
/// 计划本身。不重跑 Research / 不重抓数据 / 不重算 factor（取数是调用方
/// 职责，输入按引用 IDs 取齐）。
struct DecisionReplayer: Sendable {
    /// 单个 plan 的规划输入（冻结内嵌进 artifact，重放时重新产 Δw）。
    struct PlannerRun: Sendable, Codable, Hashable {
        let portfolio: PortfolioSnapshot
        let target: AllocationTarget?
        let remediationTargets: [RemediationTargetInput]
        let userDirectives: [UserDirectiveInput]
        let actionDomain: ActionDomain
        let plannerParameters: TargetRebalancePlanner.Parameters
    }

    /// 重放的**原材料**（七轮 P1 收敛后只剩决策级共享 cardinal 与定义：
    /// resolver 按引用返回强类型实例，**不含任何 Decimal 与分数**——
    /// criterion 输入值由 Replayer 内部经 CriterionInputExtractor 从实例
    /// 与 plan-scoped 指标推导，分数由 CriterionEvaluator 逐 plan 重算）。
    struct ReplayMaterials: Sendable, Codable, Hashable {
        /// criterion 定义（key = fingerprint「id@version」；一致性校验
        /// key == definition.fingerprint；绑定重放另要求恰好覆盖
        /// artifact.criterionVersions 且内容摘要一致，what-if 允许记录
        /// 新版本引用）
        let criterionDefinitions: [String: CriterionDefinition]
        /// FactorSnapshot 强类型实例（key = snapshot ID；一致性校验
        /// key == snapshot.id.rawValue 且与定义派生的引用域精确相等）
        let factorSnapshots: [String: FactorSnapshot]
        /// cardinal observation 实例（key = observation ID；一致性校验
        /// key == id 且与 criterion 定义派生的引用域精确相等）
        let observations: [String: CardinalObservation]
        let band: IndifferenceBand

        init(
            criterionDefinitions: [String: CriterionDefinition] = [:],
            factorSnapshots: [String: FactorSnapshot] = [:],
            observations: [String: CardinalObservation] = [:],
            band: IndifferenceBand
        ) {
            self.criterionDefinitions = criterionDefinitions
            self.factorSnapshots = factorSnapshots
            self.observations = observations
            self.band = band
        }
    }

    /// 重放结论（审查 P1-1：含行动计划本身）。
    struct ReplayOutcome: Sendable, Codable, Hashable {
        let plans: [String: PortfolioActionPlan]
        let comparison: PlanComparisonResult
        let decision: PartialDecision
    }

    /// 纯计算 helper（**不做绑定校验——绑定是入口的职责**；WF-1 起对
    /// Workflow 层开放：plannerInputs → plans → scores → compare → decide
    /// 的首产与重放共用同一实现，首产即重放一致）。
    /// 七轮 P1-1：**逐 plan 求值**——criterion 输入含 plan-scoped 指标
    /// （turnover / 投影资产类权重，从各自的 plan + portfolio +
    /// actionDomain 推导）与决策级共享 cardinal（factor metric /
    /// observation），方案分数不再共享。frozenNowByPlan 完整性由调用方
    /// 保证（replay/what-if 取自 artifact plans；首产传空字典，plan
    /// asOf 兜底 portfolio.asOf——防御性，不改变语义）。
    func compute(
        materials: ReplayMaterials,
        plannerInputs: [String: PlannerRun],
        frozenNowByPlan: [String: Date]
    ) throws -> ReplayOutcome {
        let evaluator = CriterionEvaluator()
        let orderedDefinitions = materials.criterionDefinitions.values
            .sorted { $0.fingerprint < $1.fingerprint }
        var plans: [String: PortfolioActionPlan] = [:]
        var scores: [String: [CriterionScore]] = [:]
        for (key, run) in plannerInputs {
            let plan = TargetRebalancePlanner(parameters: run.plannerParameters).plan(
                portfolio: run.portfolio,
                target: run.target,
                remediationTargets: run.remediationTargets,
                userDirectives: run.userDirectives,
                actionDomain: run.actionDomain,
                now: frozenNowByPlan[key] ?? run.portfolio.asOf
            )
            plans[key] = plan
            scores[key] = try orderedDefinitions.map { definition in
                let inputs = try CriterionInputExtractor.inputs(
                    definition: definition,
                    plan: plan,
                    portfolio: run.portfolio,
                    actionDomain: run.actionDomain,
                    factorSnapshots: materials.factorSnapshots,
                    observations: materials.observations
                )
                return evaluator.evaluate(definition: definition, inputs: inputs)
            }
        }
        let comparison = try CriterionComparator().compare(
            plans: scores,
            band: materials.band
        )
        let decision = PartialDecisionPolicy().decide(
            comparison, allPlanKeys: scores.keys.sorted()
        )
        return ReplayOutcome(plans: plans, comparison: comparison, decision: decision)
    }

    // MARK: - 冻结规划一致性（八轮 P1-2/P2-6，三入口共享门禁）

    /// 冻结规划输入一致性检查（Validator / replay / what-if 共用）：
    /// ① plans 非空（空方案决策是退化形态）；
    /// ② plannerInputs 域 == plans 域；
    /// ③ 逐 run Target 与 artifact.target 无条件严格相等（含双 nil）；
    /// ④ 逐 plan 以 plan.asOf 冻结时间重跑 TargetRebalancePlanner，必须
    ///    与已存 plan 全等——artifact 的结果层必须可由内嵌输入重放
    ///    （「Validator 放行而 Replayer 拒绝」的分裂不再可能）。
    enum FrozenPlannerIssue: Equatable, Sendable {
        case emptyPlans
        case domainMismatch(artifact: [String], inputs: [String])
        case targetConflict(planKey: String)
        case planNotReproducible(planKey: String)
    }

    static func frozenPlannerIssue(
        of artifact: PortfolioDecisionArtifact
    ) -> FrozenPlannerIssue? {
        guard !artifact.plans.isEmpty else { return .emptyPlans }
        let artifactKeys = Set(artifact.plans.keys)
        let inputKeys = Set(artifact.plannerInputs.keys)
        guard artifactKeys == inputKeys else {
            return .domainMismatch(artifact: artifactKeys.sorted(), inputs: inputKeys.sorted())
        }
        for (key, run) in artifact.plannerInputs {
            guard run.target?.id == artifact.target?.id else {
                return .targetConflict(planKey: key)
            }
            let regenerated = TargetRebalancePlanner(
                parameters: run.plannerParameters
            ).plan(
                portfolio: run.portfolio,
                target: run.target,
                remediationTargets: run.remediationTargets,
                userDirectives: run.userDirectives,
                actionDomain: run.actionDomain,
                now: artifact.plans[key]?.asOf ?? run.portfolio.asOf
            )
            guard regenerated == artifact.plans[key] else {
                return .planNotReproducible(planKey: key)
            }
        }
        return nil
    }

    static func replayError(for issue: FrozenPlannerIssue) -> ReplayError {
        switch issue {
        case .emptyPlans:
            return .frozenTimeUnavailable(artifactPlans: [])
        case .domainMismatch(let artifactKeys, let inputKeys):
            return .artifactPlanDomainMismatch(artifact: artifactKeys, inputs: inputKeys)
        case .targetConflict(let planKey):
            return .referenceMismatch(
                declared: "plannerInputs[\(planKey)].target 与 artifact.target 冲突",
                artifact: "冻结规划输入不一致")
        case .planNotReproducible(let planKey):
            return .frozenPlannerInconsistent(planKey: planKey)
        }
    }

    /// 组装错误 → ReplayError 映射（十七轮 P1-4：assemble 的 throws 化
    /// 让 what-if/重放路径同样 fail-closed，不崩进程）。
    static func replayError(forAssembly error: PortfolioDecisionArtifact.AssemblyError) -> ReplayError {
        switch error {
        case .plannerRunDomainMismatch(let artifact, let inputs):
            return .artifactPlanDomainMismatch(artifact: artifact, inputs: inputs)
        case .emptyCriterionDefinitions:
            return .referenceMismatch(
                declared: "criterion 定义集为空",
                artifact: "D002 要求至少一条可追溯 criterion")
        case .duplicateCriterionFingerprints(let fingerprints):
            return .referenceMismatch(
                declared: "criterion 指纹重复：\(fingerprints.sorted())",
                artifact: "同 id@version 不同内容")
        case .criterionDigestFailed(let fingerprint, let underlying):
            return .referenceMismatch(
                declared: "criterion[\(fingerprint)] 内容摘要编码失败：\(underlying)",
                artifact: "材料含不可编码值")
        case .bandDigestFailed(let version, let underlying):
            return .referenceMismatch(
                declared: "band[\(version)] 内容摘要编码失败：\(underlying)",
                artifact: "材料含不可编码值")
        case .identityPayloadEncodingFailed(let underlying):
            return .referenceMismatch(
                declared: "身份 payload 编码失败：\(underlying)",
                artifact: "引用层/结果层含不可编码值")
        }
    }

    /// Comparator 错误 → ReplayError 逐 case 映射（九轮 P3：不做
    /// String(describing:) 笼统归类——比较器将来新增 case 不会被静默
    /// 误标为 malformedPlanKey）。
    static func replayError(for compareError: CriterionComparator.CompareError) -> ReplayError {
        switch compareError {
        case .malformedPlanKey(let key):
            return .malformedPlanKey(key)
        case .duplicateCriterion(let planKey, let criterionID):
            return .referenceMismatch(
                declared: "plan[\(planKey)] 的 criterion[\(criterionID)] 重复",
                artifact: "比较 schema 非法")
        case .criterionDefinitionMismatch(let criterionID):
            return .referenceMismatch(
                declared: "criterion[\(criterionID)] 跨 plan 定义不一致",
                artifact: "比较 schema 非法")
        }
    }

    // MARK: - artifact 绑定重放 / what-if

    enum ReplayError: Error, Equatable, Sendable {
        /// plannerInputs（内嵌）与 artifact 的 plan 域不一致
        case artifactPlanDomainMismatch(artifact: [String], inputs: [String])
        /// 重放结果与 artifact 不一致（完整重放的「同 IDs → 同决策」被破坏）
        case replayMismatch(detail: String)
        /// 材料与引用约定不一致（引用域/实例域/版本或内容摘要绑定失败）
        case referenceMismatch(declared: String, artifact: String)
        /// 材料实例身份不符（字典 key ≠ 实例自身 ID——「复制 ID 给别的
        /// 实例」无法通过）
        case materialIdentityMismatch(detail: String)
        /// artifact 无 plans，无法取冻结时间
        case frozenTimeUnavailable(artifactPlans: [String])
        /// 已存 plan 无法由内嵌规划输入重放（八轮 P1-2）
        case frozenPlannerInconsistent(planKey: String)
        /// plan key 非法（空或含分隔符 |——throw 而非崩溃）
        case malformedPlanKey(String)
    }

    /// 引用解析器：**材料的唯一合法来源**——按 artifact 引用层逐 ID 解析
    /// 强类型实例（FactorSnapshot / CardinalObservation）/ criterion 定义 /
    /// band 实例。**不返回数值**——输入值由 Replayer 从实例与 plan-scoped
    /// 指标推导、分数由 evaluator 逐 plan 重算。
    protocol InputResolving: Sendable {
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> ReplayMaterials
    }

    /// 以 artifact 为入口的完整重放：resolver 解析材料 → 绑定校验 →
    /// 冻结规划一致性校验 → 逐 plan 提取输入重算分数 → 全链重跑
    /// （Planner 输入取自 artifact 冻结内嵌的 plannerInputs，时间从
    /// artifact.plans[key].asOf 冻结——同 IDs 唯一确定重放结果）。
    func replay(
        artifact: PortfolioDecisionArtifact,
        resolver: any InputResolving
    ) throws(ReplayError) -> ReplayOutcome {
        let materials: ReplayMaterials
        do {
            materials = try resolver.resolveMaterials(for: artifact)
        } catch {
            throw .referenceMismatch(declared: "resolver 解析失败: \(error)", artifact: "artifact 引用不可解析")
        }
        try validateBinding(materials: materials, against: artifact)
        if let issue = Self.frozenPlannerIssue(of: artifact) {
            throw Self.replayError(for: issue)
        }
        do {
            return try compute(
                materials: materials,
                plannerInputs: artifact.plannerInputs,
                frozenNowByPlan: artifact.plans.mapValues(\.asOf)
            )
        } catch let error as CriterionComparator.CompareError {
            throw Self.replayError(for: error)
        } catch {
            throw .referenceMismatch(
                declared: "输入提取失败: \(error)",
                artifact: "引用实例不可提取")
        }
    }

    /// Partial 重放（what-if，七轮 P1-2 重设计 + 八轮 P2-6）：以 base 的
    /// **冻结规划输入**为准（先过冻结规划一致性校验——损坏的 base 不会
    /// 被「洗成」结构自洽的新 artifact），用 resolver 提供的替换材料
    /// （新实例 / 新 criterion 版本——版本纪律：引用变更是新定义，必须
    /// bump version）重算比较，**产出新 artifact 记录新引用**（D004 §5）。
    /// 同 ID 换内容的通道不存在——替换实例携带自己的新 ID。
    func replayWhatIf(
        base: PortfolioDecisionArtifact,
        resolver: any InputResolving,
        producedAt: Date
    ) throws(ReplayError) -> PortfolioDecisionArtifact {
        let materials: ReplayMaterials
        do {
            materials = try resolver.resolveMaterials(for: base)
        } catch {
            throw .referenceMismatch(declared: "resolver 解析失败: \(error)", artifact: "what-if 引用不可解析")
        }
        let referencedFactorIDs = try Self.validateMaterialsConsistency(materials)
        if let issue = Self.frozenPlannerIssue(of: base) {
            throw Self.replayError(for: issue)
        }
        let outcome: ReplayOutcome
        do {
            outcome = try compute(
                materials: materials,
                plannerInputs: base.plannerInputs,
                frozenNowByPlan: base.plans.mapValues(\.asOf)
            )
        } catch let error as CriterionComparator.CompareError {
            throw Self.replayError(for: error)
        } catch {
            throw .referenceMismatch(
                declared: "what-if 输入提取失败: \(error)",
                artifact: "引用实例不可提取")
        }
        do {
            return try PortfolioDecisionArtifact.assemble(
            signalIDs: base.signalIDs,
            criterionDefinitions: materials.criterionDefinitions.values.sorted {
                $0.fingerprint < $1.fingerprint
            },
            factorSnapshotIDs: referencedFactorIDs.sorted().map { ArtifactID(rawValue: $0) },
            target: base.target,
            band: materials.band,
            knowledgeContextSummary: base.knowledgeContextSummary,
            decision: outcome.decision,
            comparison: outcome.comparison,
            plans: outcome.plans,
            plannerRuns: base.plannerInputs,
            producedAt: producedAt
            )
        } catch let error as PortfolioDecisionArtifact.AssemblyError {
            throw Self.replayError(forAssembly: error)
        } catch {
            throw .referenceMismatch(
                declared: "what-if 组装失败: \(error)",
                artifact: "引用材料非法")
        }
    }

    /// 绑定校验（完整重放）：材料内部自洽（validateMaterialsConsistency）
    /// + 与 artifact 引用层精确对齐——criterion 定义域恰好覆盖
    /// criterionVersions 且**内容摘要一致**（八轮 P1-4：同版本不同
    /// 权重/引用/方向的定义被拒）；band 版本与内容摘要一致；factor
    /// 引用域 == 声明域。（逐 run Target 与 plans 可重放性在
    /// frozenPlannerIssue 共享校验中。）
    private func validateBinding(
        materials: ReplayMaterials, against artifact: PortfolioDecisionArtifact
    ) throws(ReplayError) {
        let referencedFactorIDs = try Self.validateMaterialsConsistency(materials)
        // criterion 定义域恰好覆盖 + 内容摘要一致
        let definitionFingerprints = Set(materials.criterionDefinitions.keys)
        guard definitionFingerprints == Set(artifact.criterionVersions) else {
            throw .referenceMismatch(
                declared: "definitions=\(definitionFingerprints.sorted())",
                artifact: "criterionVersions=\(artifact.criterionVersions.sorted())")
        }
        for (key, definition) in materials.criterionDefinitions {
            let digest: String
            do {
                digest = try definition.contentDigest()
            } catch {
                throw .referenceMismatch(
                    declared: "定义摘要计算失败: \(error)",
                    artifact: "criterion[\(key)]")
            }
            guard digest == artifact.criterionContentDigests[key] else {
                throw .referenceMismatch(
                    declared: "criterion[\(key)] 内容摘要不符（同版本不同内容）",
                    artifact: "criterionContentDigests[\(key)]")
            }
        }
        // band 版本 + 内容摘要
        let bandVersion = "\(materials.band.policyID)@\(materials.band.version)"
        guard bandVersion == artifact.indifferenceBandVersion else {
            throw .referenceMismatch(
                declared: "band=\(bandVersion)", artifact: "band=\(artifact.indifferenceBandVersion)")
        }
        let bandDigest: String
        do {
            bandDigest = try materials.band.contentDigest()
        } catch {
            throw .referenceMismatch(
                declared: "band 摘要计算失败: \(error)",
                artifact: "bandContentDigest")
        }
        guard bandDigest == artifact.bandContentDigest else {
            throw .referenceMismatch(
                declared: "band 内容摘要不符（同版本不同阈值）",
                artifact: "bandContentDigest")
        }
        // factor 引用域（从定义实例派生）== artifact 声明域
        guard referencedFactorIDs == Set(artifact.factorSnapshotIDs.map(\.rawValue)) else {
            throw .referenceMismatch(
                declared: "factorRefs=\(referencedFactorIDs.sorted())",
                artifact: "factorSnapshots=\(artifact.factorSnapshotIDs.map(\.rawValue).sorted())")
        }
    }

    /// 材料内部自洽（绑定重放与 what-if 共用）：
    /// ⓪ criterion 定义集非空（九轮 P1：resolver 是外部数据来源——
    /// criterion store 故障/维护返回空集时不得让 what-if 一路走到
    /// assemble 的 precondition 崩进程；与六轮 P2「重放路径不崩」同一
    /// 纪律）；
    /// ① 实例身份——字典 key 必须就是实例自身 ID（definition.fingerprint /
    ///    snapshot.id / observation.id），换版本或换实例挂旧键无法通过；
    /// ② factorMetric 引用约定合法（「<snapshotID>#<metricKey>」）；
    /// ③ factor / observation 引用域（从定义实例派生）与实例域精确相等
    ///    （superset 也拒——多余实例同样是 artifact 外的材料）。
    /// 返回 factor 引用域（调用方与 artifact 声明域比对 / what-if 记录新引用）。
    static func validateMaterialsConsistency(
        _ materials: ReplayMaterials
    ) throws(ReplayError) -> Set<String> {
        guard !materials.criterionDefinitions.isEmpty else {
            throw .referenceMismatch(
                declared: "criterion 定义集为空",
                artifact: "决策材料必须含至少一个 criterion 定义（D002）")
        }
        for (key, definition) in materials.criterionDefinitions
        where key != definition.fingerprint {
            throw .materialIdentityMismatch(
                detail: "criterionDefinitions[\(key)] 挂的是 fingerprint=\(definition.fingerprint) 的定义")
        }
        for (key, snapshot) in materials.factorSnapshots
        where key != snapshot.id.rawValue {
            throw .materialIdentityMismatch(
                detail: "factorSnapshots[\(key)] 挂的是 id=\(snapshot.id.rawValue) 的实例")
        }
        for (key, observation) in materials.observations
        where key != observation.id.rawValue {
            throw .materialIdentityMismatch(
                detail: "observations[\(key)] 挂的是 id=\(observation.id.rawValue) 的实例")
        }
        var referencedFactorIDs = Set<String>()
        for definition in materials.criterionDefinitions.values {
            for reference in definition.inputReferences {
                guard reference.kind == .factorMetric else { continue }
                let parts = reference.referenceID.split(separator: "#", maxSplits: 1)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw .referenceMismatch(
                        declared: "malformed factorMetric 引用 \(reference.referenceID)",
                        artifact: "约定 <snapshotID>#<metricKey>")
                }
                referencedFactorIDs.insert(String(parts[0]))
            }
        }
        guard Set(materials.factorSnapshots.keys) == referencedFactorIDs else {
            throw .referenceMismatch(
                declared: "factorRefs=\(referencedFactorIDs.sorted()) instances=\(materials.factorSnapshots.keys.sorted())",
                artifact: "factor 引用域与实例域必须精确相等")
        }
        let referencedObservationIDs = Set(
            materials.criterionDefinitions.values.flatMap { definition in
                definition.inputReferences
                    .filter { $0.kind == .observation }
                    .map(\.referenceID)
            }
        )
        guard Set(materials.observations.keys) == referencedObservationIDs else {
            throw .referenceMismatch(
                declared: "observationRefs=\(referencedObservationIDs.sorted()) instances=\(materials.observations.keys.sorted())",
                artifact: "observation 引用域与实例域必须精确相等")
        }
        return referencedFactorIDs
    }

    /// 完整重放一致性验证（D004 §3「同 IDs → 同决策」的运行时形态）：
    /// resolver 解析输入 → 绑定校验 → 冻结时间重放 → outcome 必须与
    /// artifact 的 decision / comparison / plans 全等，任一不一致抛错。
    func verify(
        artifact: PortfolioDecisionArtifact,
        resolver: any InputResolving
    ) throws(ReplayError) -> ReplayOutcome {
        let outcome = try replay(artifact: artifact, resolver: resolver)
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
    /// 组装错误（十七轮 P1-4：外部材料供给的非法形态是**可恢复的输入
    /// 错误**——precondition 会崩进程，违反 fail-closed 不崩契约；九轮
    /// P3 只护住了 replay 路径，首产路径在此补齐）。
    enum AssemblyError: Error, Equatable, Sendable {
        case plannerRunDomainMismatch(artifact: [String], inputs: [String])
        case emptyCriterionDefinitions
        case duplicateCriterionFingerprints([String])
        /// criterion 内容摘要编码失败（外部材料含不可编码值——可恢复输入
        /// 错误，十八轮审查 P2-6：不再 try! 崩进程）
        case criterionDigestFailed(fingerprint: String, underlying: String)
        /// band 内容摘要编码失败（同上）
        case bandDigestFailed(version: String, underlying: String)
        /// 身份 payload 编码失败（引用层/结果层含不可编码值——NaN Decimal
        /// 等外部材料）
        case identityPayloadEncodingFailed(underlying: String)
    }

    /// 从比较结论组装 artifact（id 确定性派生：引用层 + 内容摘要 + 冻结
    /// 规划输入 + 结果层完整语义，只排除 producedAt）。
    /// **criterion / band 的版本与摘要一律从定义/实例派生**（八轮 P1-4：
    /// 调用方不再传版本字符串——版本与内容不允许分叉）。
    /// plannerRuns 必须恰好覆盖 plans 域（冻结内嵌的完整性前提）。
    static func assemble(
        signalIDs: [SignalID],
        criterionDefinitions: [CriterionDefinition],
        factorSnapshotIDs: [ArtifactID],
        target: AllocationTarget?,
        band: IndifferenceBand,
        knowledgeContextSummary: String,
        decision: PartialDecision,
        comparison: PlanComparisonResult,
        plans: [String: PortfolioActionPlan],
        plannerRuns: [String: DecisionReplayer.PlannerRun],
        producedAt: Date
    ) throws -> PortfolioDecisionArtifact {
        guard Set(plannerRuns.keys) == Set(plans.keys) else {
            throw AssemblyError.plannerRunDomainMismatch(
                artifact: plans.keys.sorted(), inputs: plannerRuns.keys.sorted())
        }
        guard !criterionDefinitions.isEmpty else {
            throw AssemblyError.emptyCriterionDefinitions
        }
        // 九轮 P3:同 id@version 两份不同内容传入会静默塌缩摘要字典
        // (后者胜出)——重复指纹在此拒绝
        let fingerprints = criterionDefinitions.map(\.fingerprint)
        guard Set(fingerprints).count == fingerprints.count else {
            throw AssemblyError.duplicateCriterionFingerprints(fingerprints)
        }
        let sortedDefinitions = criterionDefinitions.sorted { $0.fingerprint < $1.fingerprint }
        let criterionVersions = sortedDefinitions.map(\.fingerprint)
        // 内容摘要（编码失败 = 外部材料不可编码，可恢复输入错误——
        // 十八轮审查 P2-6：try! 崩进程改为 AssemblyError fail-closed）
        var criterionContentDigests: [String: String] = [:]
        for definition in sortedDefinitions {
            do {
                criterionContentDigests[definition.fingerprint] = try definition.contentDigest()
            } catch {
                throw AssemblyError.criterionDigestFailed(
                    fingerprint: definition.fingerprint, underlying: "\(error)")
            }
        }
        let bandVersion = "\(band.policyID)@\(band.version)"
        let bandContentDigest: String
        do {
            bandContentDigest = try band.contentDigest()
        } catch {
            throw AssemblyError.bandDigestFailed(version: bandVersion, underlying: "\(error)")
        }
        let payload: String
        do {
            payload = try StableDigest.jsonPayload(IdentityPayload(
                signalIDs: signalIDs.map(\.rawValue).sorted(),
                criterionVersions: criterionVersions,
                criterionContentDigests: criterionContentDigests,
                factorSnapshotIDs: factorSnapshotIDs.map(\.rawValue).sorted(),
                targetID: target?.id.rawValue,
                bandVersion: bandVersion,
                bandContentDigest: bandContentDigest,
                plannerInputs: plannerRuns,
                knowledgeContextSummary: knowledgeContextSummary,
                decision: decision,
                comparison: comparison,
                plans: plans
            ))
        } catch {
            throw AssemblyError.identityPayloadEncodingFailed(underlying: "\(error)")
        }
        // 五轮 P1-3 + 八轮 P1-4:criterion / band 的 policy 依赖携带内容
        // 摘要为 version(失效传播按内容粒度)
        let deps: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue, version: nil)] } ?? [])
            + criterionVersions.map {
                ArtifactDependency(
                    kind: .policy, referenceID: "criterion@\($0)",
                    version: criterionContentDigests[$0])
            }
            + [ArtifactDependency(
                kind: .policy, referenceID: "band@\(bandVersion)",
                version: bandContentDigest)]
        return PortfolioDecisionArtifact(
            id: ArtifactID(rawValue: "dec_\(StableDigest.digest(payload))"),
            producedAt: producedAt,
            validityPolicy: .immutableHistorical,
            dependencies: deps,
            signalIDs: signalIDs,
            criterionVersions: criterionVersions,
            criterionContentDigests: criterionContentDigests,
            factorSnapshotIDs: factorSnapshotIDs,
            target: target,
            indifferenceBandVersion: bandVersion,
            bandContentDigest: bandContentDigest,
            plannerInputs: plannerRuns,
            knowledgeContextSummary: knowledgeContextSummary,
            decision: decision,
            comparison: comparison,
            plans: plans
        )
    }

    /// ID 身份 payload（语义完备；七轮 P1-3 冻结规划输入 + 八轮 P1-4
    /// 内容摘要参与身份派生）。
    private struct IdentityPayload: Encodable {
        let signalIDs: [String]
        let criterionVersions: [String]
        let criterionContentDigests: [String: String]
        let factorSnapshotIDs: [String]
        let targetID: String?
        let bandVersion: String
        let bandContentDigest: String
        let plannerInputs: [String: DecisionReplayer.PlannerRun]
        let knowledgeContextSummary: String
        let decision: PartialDecision
        let comparison: PlanComparisonResult
        let plans: [String: PortfolioActionPlan]
    }
}
