import Foundation

// MARK: - PortfolioDecisionArtifact + DecisionValidator + Replay（DEC-9，ADR-D004）
//
// Decision artifact 引用上游 IDs（Signal / Criterion version / Factor
// snapshot / Target / IndifferenceBand / SignalCardinalPolicy / Planner
// 输入指纹）；重放按引用取，不重跑 Research。
// 引用 IDs 一旦写入永不更改（supersede 不改旧引用——DATA008 vintage 精神）。
//
// M7 验收：same mock inputs → same decision——由 DecisionReplayTests
// 之外的单测（PortfolioDecisionTests）用确定性 planner 闭环覆盖。
//
// 六轮审查修复（P1×4）：
// - P1-1 输入提取：criterion 输入值只能从强类型实例提取（signal 经
//   versioned SignalCardinalPolicy 转换 / factor 按
//   「<snapshotID>#<metricKey>」从 snapshot 提取 / observation 取实例
//   值），resolver 不再提供任何 Decimal；
// - P1-2 实例身份：材料字典 key 必须就是实例自身 ID（fingerprint /
//   rawValue），引用域与实例域精确相等（不再接受 superset）；
// - P1-3 重放自包含：Planner 全部输入按确定性指纹锚定进 artifact，
//   比较方向移入 versioned CriterionDefinition，重放时间从 artifact
//   的 plans 冻结（不再接受外部 now）；
// - P1-4 依赖比较：ArtifactDependency 多重集合结构化比较，不再拼接
//   分隔符字符串（`|` 碰撞不再可能）。

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
    /// Signal→cardinal 转换 policy 版本（六轮 P1-1：ordinal 转 cardinal
    /// 的映射是 policy parameter，必须 versioned 且被 artifact 引用）
    let signalCardinalPolicyVersion: String
    /// 每 plan 的规划输入指纹（六轮 P1-3：portfolio / target /
    /// remediation / directives / actionDomain / plannerParameters 的
    /// 确定性摘要——完整重放凭指纹定位原始 Planner 输入，自包含）
    let plannerInputFingerprints: [String: String]

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
        /// signal cardinal 转换 policy 版本为空（六轮 P1-1）
        case emptySignalPolicyVersion
        /// planner 输入指纹域与 plans 域不一致（六轮 P1-3）
        case plannerFingerprintDomainViolation(keys: [String])
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
        // 六轮 P1-1：signal cardinal 转换 policy 必须被引用
        guard !artifact.signalCardinalPolicyVersion.isEmpty else {
            throw ValidationError.emptySignalPolicyVersion
        }
        // D003：band 版本闭环
        guard artifact.indifferenceBandVersion != "" else {
            throw ValidationError.bandVersionMismatch(
                artifact: "", referenced: "")
        }
        // 六轮 P1-3：planner 输入指纹恰好覆盖 plans 域且非空
        let fingerprintKeys = Set(artifact.plannerInputFingerprints.keys)
        guard fingerprintKeys == Set(artifact.plans.keys),
              !artifact.plannerInputFingerprints.values.contains(where: \.isEmpty)
        else {
            throw ValidationError.plannerFingerprintDomainViolation(
                keys: fingerprintKeys.symmetricDifference(artifact.plans.keys).sorted())
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
        // 拼接分隔符字符串,referenceID/version 含 `|` 的碰撞不再可能;
        // criterion/band/signalPolicy 的 policy 依赖一并登记）
        let expectedDeps: [ArtifactDependency] =
            artifact.signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + artifact.factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (artifact.target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue)] } ?? [])
            + artifact.criterionVersions.map { ArtifactDependency(kind: .policy, referenceID: "criterion@\($0)") }
            + [ArtifactDependency(kind: .policy, referenceID: "band@\(artifact.indifferenceBandVersion)"),
               ArtifactDependency(kind: .policy, referenceID: "signalPolicy@\(artifact.signalCardinalPolicyVersion)")]
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

        /// 规划输入的确定性指纹（六轮 P1-3）：portfolio / target /
        /// remediation / directives / actionDomain / parameters 全量语义
        /// 摘要——artifact 锚定该指纹，重放材料逐 plan 比对，任一漂移即拒。
        func fingerprint() throws -> String {
            "planner-input|\(StableDigest.digest(try StableDigest.jsonPayload(self)))"
        }
    }

    /// 重放的**原材料**（六轮 P1-1/P1-2：resolver 按引用返回强类型实例，
    /// **不含任何 Decimal 与分数**——criterion 输入值由 Replayer 内部经
    /// CriterionInputExtractor 从这些实例提取，分数由 CriterionEvaluator
    /// 重算；resolver 无法注入任意数值或最新分数冒充引用实例的产出）。
    struct ReplayMaterials: Sendable, Codable, Hashable {
        /// 每 plan 的规划输入（Planner 链；绑定校验逐 plan 与 artifact
        /// 的 plannerInputFingerprints 比对）
        let plannerRuns: [String: PlannerRun]
        /// criterion 定义（key = fingerprint「id@version」；绑定校验
        /// key == definition.fingerprint 且恰好覆盖 artifact.criterionVersions）
        let criterionDefinitions: [String: CriterionDefinition]
        /// Signal 强类型实例（key = signalID；绑定校验 key == id 且引用域
        /// 精确相等——同一 signal ID 锁定唯一实例，按 plan 分叉不同数值
        /// 的通道已不存在）
        let signals: [String: InvestmentSignal]
        /// FactorSnapshot 强类型实例（key = snapshot ID；绑定校验
        /// key == snapshot.id.rawValue 且与引用域精确相等）
        let factorSnapshots: [String: FactorSnapshot]
        /// cardinal observation 实例（key = observation ID；绑定校验
        /// key == id 且与 criterion 定义派生的引用域精确相等）
        let observations: [String: CardinalObservation]
        let band: IndifferenceBand
        /// Signal→cardinal 转换 policy（绑定校验 versionedID 与
        /// artifact.signalCardinalPolicyVersion 一致）
        let signalPolicy: SignalCardinalPolicy

        init(
            plannerRuns: [String: PlannerRun],
            criterionDefinitions: [String: CriterionDefinition] = [:],
            signals: [String: InvestmentSignal] = [:],
            factorSnapshots: [String: FactorSnapshot] = [:],
            observations: [String: CardinalObservation] = [:],
            band: IndifferenceBand,
            signalPolicy: SignalCardinalPolicy
        ) {
            self.plannerRuns = plannerRuns
            self.criterionDefinitions = criterionDefinitions
            self.signals = signals
            self.factorSnapshots = factorSnapshots
            self.observations = observations
            self.band = band
            self.signalPolicy = signalPolicy
        }
    }

    /// 重放结论（审查 P1-1：含行动计划本身）。
    struct ReplayOutcome: Sendable, Codable, Hashable {
        let plans: [String: PortfolioActionPlan]
        let comparison: PlanComparisonResult
        let decision: PartialDecision
    }

    /// 纯计算 helper（私有：不做绑定校验——绑定是 artifact 入口的职责）。
    /// 六轮 P1-1：输入值从强类型实例提取 + 分数重算（definition + 实例
    /// → extractor → evaluator）；提取源是决策级共享实例，同一引用 ID
    /// 在所有 plan 下锁定同一数值。frozenNowByPlan 完整性由调用方保证
    /// （replay 取自 artifact plans / what-if 由 now 展开；缺键时兜底
    /// portfolio.asOf——plan 锚定组合状态时间，防御性不改变语义）。
    private func compute(
        materials: ReplayMaterials,
        frozenNowByPlan: [String: Date]
    ) throws -> ReplayOutcome {
        var plans: [String: PortfolioActionPlan] = [:]
        for (key, run) in materials.plannerRuns {
            plans[key] = TargetRebalancePlanner(parameters: run.plannerParameters).plan(
                portfolio: run.portfolio,
                target: run.target,
                remediationTargets: run.remediationTargets,
                userDirectives: run.userDirectives,
                actionDomain: run.actionDomain,
                now: frozenNowByPlan[key] ?? run.portfolio.asOf
            )
        }
        // criterion 分数重算：每个引用 criterion 求值一次（提取源共享，
        // 全部 plan 取同一组分数——plan 间差异由 Planner 输入体现，
        // 不再有 per-plan 注入数值的通道）
        let evaluator = CriterionEvaluator()
        let sharedScores: [CriterionScore] = try materials.criterionDefinitions.values
            .sorted { $0.fingerprint < $1.fingerprint }
            .map { definition in
                let inputs = try CriterionInputExtractor.inputs(
                    definition: definition,
                    signals: materials.signals,
                    factorSnapshots: materials.factorSnapshots,
                    observations: materials.observations,
                    signalPolicy: materials.signalPolicy
                )
                return evaluator.evaluate(definition: definition, inputs: inputs)
            }
        let scores = Dictionary(
            uniqueKeysWithValues: materials.plannerRuns.keys.map { ($0, sharedScores) }
        )
        let comparison = try CriterionComparator().compare(
            plans: scores,
            band: materials.band
        )
        let decision = PartialDecisionPolicy().decide(
            comparison, allPlanKeys: scores.keys.sorted()
        )
        return ReplayOutcome(plans: plans, comparison: comparison, decision: decision)
    }

    /// Partial 重放（what-if，五轮 P1-1 + 六轮 P1-1）：替换解析出的
    /// **强类型实例**（signal / factor snapshot / observation——假想情景
    /// 改的是实例内容，ID 身份不变）后重跑。分数仍由 Replayer 从实例
    /// 提取重算，what-if 也不接受注入数值。产新决策素材，不影响原
    /// artifact（D004 §5）；now 是情景时间（显式选择，不属于 artifact
    /// 绑定重放——那条路径的时间从 artifact plans 冻结）。
    func replayWhatIf(
        base: ReplayMaterials,
        replacingSignals signals: [String: InvestmentSignal] = [:],
        replacingFactorSnapshots factorSnapshots: [String: FactorSnapshot] = [:],
        replacingObservations observations: [String: CardinalObservation] = [:],
        now: Date
    ) throws(ReplayError) -> ReplayOutcome {
        let mergedSignals = base.signals.merging(signals) { _, new in new }
        let mergedFactorSnapshots = base.factorSnapshots.merging(factorSnapshots) { _, new in new }
        let mergedObservations = base.observations.merging(observations) { _, new in new }
        try Self.validateInstanceIdentity(
            signals: mergedSignals,
            factorSnapshots: mergedFactorSnapshots,
            observations: mergedObservations
        )
        let materials = ReplayMaterials(
            plannerRuns: base.plannerRuns,
            criterionDefinitions: base.criterionDefinitions,
            signals: mergedSignals,
            factorSnapshots: mergedFactorSnapshots,
            observations: mergedObservations,
            band: base.band,
            signalPolicy: base.signalPolicy
        )
        let frozenNowByPlan = Dictionary(
            uniqueKeysWithValues: base.plannerRuns.keys.sorted().map { ($0, now) }
        )
        do {
            return try compute(materials: materials, frozenNowByPlan: frozenNowByPlan)
        } catch let error as CriterionComparator.CompareError {
            throw .malformedPlanKey(String(describing: error))
        } catch {
            throw .referenceMismatch(
                declared: "what-if 输入提取失败: \(error)",
                artifact: "引用实例不可提取")
        }
    }

    // MARK: - artifact 绑定重放

    enum ReplayError: Error, Equatable, Sendable {
        /// plannerRuns 与 artifact 的 plan 域不一致
        case artifactPlanDomainMismatch(artifact: [String], inputs: [String])
        /// 重放结果与 artifact 不一致（完整重放的「同 IDs → 同决策」被破坏）
        case replayMismatch(detail: String)
        /// 材料与 artifact 引用层不一致（五轮 P1-1）
        case referenceMismatch(declared: String, artifact: String)
        /// 材料实例身份不符（六轮 P1-2：字典 key ≠ 实例自身 ID——
        /// 「复制 ID 给别的实例」无法通过）
        case materialIdentityMismatch(detail: String)
        /// 规划输入与 artifact 锚定指纹不一致（六轮 P1-3）
        case plannerInputMismatch(planKey: String)
        /// artifact 无 plans，无法取冻结时间（六轮 P1-3）
        case frozenTimeUnavailable(artifactPlans: [String])
        /// plan key 非法（空或含分隔符 |——六轮 P2：throw 而非崩溃）
        case malformedPlanKey(String)
    }

    /// 引用解析器（五轮 P1-1）：**材料的唯一合法来源**——按 artifact 引用
    /// 层逐 ID 解析强类型实例（FactorSnapshot / InvestmentSignal /
    /// CardinalObservation）/ criterion 定义 / band 实例 / 规划输入 /
    /// signal cardinal 转换 policy。**不返回数值**——输入值由 Replayer
    /// 从实例提取、分数由 evaluator 重算。
    protocol InputResolving: Sendable {
        func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> ReplayMaterials
    }

    /// 以 artifact 为入口的完整重放（五轮 P1-1 + 六轮 P1-3）：resolver 解析
    /// 材料 → 绑定校验 → 材料提取输入重算分数 → 全链重跑。**不接受外部
    /// now**——各 plan 的重放时间从 artifact.plans[key].asOf 冻结（同 IDs
    /// 唯一确定重放结果，含 plan id / asOf）。
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
        guard !artifact.plans.isEmpty else {
            throw .frozenTimeUnavailable(artifactPlans: artifact.plans.keys.sorted())
        }
        let frozenNowByPlan = artifact.plans.mapValues(\.asOf)
        do {
            return try compute(materials: materials, frozenNowByPlan: frozenNowByPlan)
        } catch let error as CriterionComparator.CompareError {
            throw .malformedPlanKey(String(describing: error))
        } catch {
            throw .referenceMismatch(
                declared: "输入提取失败: \(error)",
                artifact: "引用实例不可提取")
        }
    }

    /// 绑定校验（五轮 P1-1/P1-2 + 六轮 P1-1/2/3）：
    /// ① 键域（plannerRuns == artifact.plans）；
    /// ② 实例身份（六轮 P1-2）——criterionDefinitions / signals /
    ///    factorSnapshots / observations 的字典 key 必须就是实例自身
    ///    ID（fingerprint / rawValue），换版本或换实例挂旧键无法通过；
    /// ③ 引用域与实例域**精确相等**——criterion 定义域恰好覆盖
    ///    artifact.criterionVersions；factor / signal 引用域从定义实例
    ///    派生后与 artifact 声明、材料实例域三方相等（superset 也拒）；
    ///    observation 引用域与实例域相等；
    /// ④ band / signalPolicy 版本与 artifact 引用一致；
    /// ⑤ 逐 plannerRun 的 target 与 artifact.target 无条件严格相等；
    /// ⑥ 逐 plan 规划输入指纹与 artifact 锚定值相等（六轮 P1-3）；
    /// ⑦ factorMetric 引用必须符合「<snapshotID>#<metricKey>」约定。
    private func validateBinding(
        materials: ReplayMaterials, against artifact: PortfolioDecisionArtifact
    ) throws(ReplayError) {
        let plannerKeys = materials.plannerRuns.keys.sorted()
        let artifactKeys = artifact.plans.keys.sorted()
        guard plannerKeys == artifactKeys else {
            throw .artifactPlanDomainMismatch(artifact: artifactKeys, inputs: plannerKeys)
        }
        // ② 实例身份（六轮 P1-2）
        try Self.validateInstanceIdentity(
            signals: materials.signals,
            factorSnapshots: materials.factorSnapshots,
            observations: materials.observations
        )
        for (key, definition) in materials.criterionDefinitions
        where key != definition.fingerprint {
            throw .materialIdentityMismatch(
                detail: "criterionDefinitions[\(key)] 挂的是 fingerprint=\(definition.fingerprint) 的定义")
        }
        // ③ criterion 定义域恰好覆盖
        let definitionFingerprints = Set(materials.criterionDefinitions.keys)
        guard definitionFingerprints == Set(artifact.criterionVersions) else {
            throw .referenceMismatch(
                declared: "definitions=\(definitionFingerprints.sorted())",
                artifact: "criterionVersions=\(artifact.criterionVersions.sorted())")
        }
        // ④ band / signalPolicy 版本
        let bandVersion = "\(materials.band.policyID)@\(materials.band.version)"
        guard bandVersion == artifact.indifferenceBandVersion else {
            throw .referenceMismatch(
                declared: "band=\(bandVersion)", artifact: "band=\(artifact.indifferenceBandVersion)")
        }
        guard materials.signalPolicy.versionedID == artifact.signalCardinalPolicyVersion else {
            throw .referenceMismatch(
                declared: "signalPolicy=\(materials.signalPolicy.versionedID)",
                artifact: "signalPolicy=\(artifact.signalCardinalPolicyVersion)")
        }
        // ⑤ 逐 run Target 严格相等(含双 nil;多 Target 冲突在此拒)
        for (key, run) in materials.plannerRuns {
            guard run.target?.id == artifact.target?.id else {
                throw .referenceMismatch(
                    declared: "plan[\(key)].target=\(run.target?.id.rawValue ?? "nil")",
                    artifact: "target=\(artifact.target?.id.rawValue ?? "nil")")
            }
        }
        // ⑥ 规划输入指纹（六轮 P1-3）
        for (key, run) in materials.plannerRuns {
            let fingerprint: String
            do {
                fingerprint = try run.fingerprint()
            } catch {
                throw .referenceMismatch(
                    declared: "规划输入指纹计算失败: \(error)",
                    artifact: "plannerInputFingerprints[\(key)]")
            }
            guard fingerprint == artifact.plannerInputFingerprints[key] else {
                throw .plannerInputMismatch(planKey: key)
            }
        }
        // ⑦ + ③ factor 引用域：约定校验后从定义实例派生，三方精确相等
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
        let factorInstanceIDs = Set(materials.factorSnapshots.keys)
        guard referencedFactorIDs == Set(artifact.factorSnapshotIDs.map(\.rawValue)),
              factorInstanceIDs == referencedFactorIDs
        else {
            throw .referenceMismatch(
                declared: "factorRefs=\(referencedFactorIDs.sorted()) instances=\(factorInstanceIDs.sorted())",
                artifact: "factorSnapshots=\(artifact.factorSnapshotIDs.map(\.rawValue).sorted())")
        }
        // ③ signal 引用域（signalCardinal refID 即 signalID）
        let referencedSignalIDs = Set(
            materials.criterionDefinitions.values.flatMap { definition in
                definition.inputReferences
                    .filter { $0.kind == .signalCardinal }
                    .map(\.referenceID)
            }
        )
        let signalInstanceIDs = Set(materials.signals.keys)
        guard referencedSignalIDs == Set(artifact.signalIDs.map(\.rawValue)),
              signalInstanceIDs == referencedSignalIDs
        else {
            throw .referenceMismatch(
                declared: "signalRefs=\(referencedSignalIDs.sorted()) instances=\(signalInstanceIDs.sorted())",
                artifact: "signalIDs=\(artifact.signalIDs.map(\.rawValue).sorted())")
        }
        // ③ observation 引用域（引用活在 criterion 定义内，artifact 经
        // criterionVersions 传递闭合）
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
                artifact: "observations 由 criterion 定义传递引用")
        }
    }

    /// 实例身份校验（六轮 P1-2）：材料字典 key 必须就是实例自身 ID。
    static func validateInstanceIdentity(
        signals: [String: InvestmentSignal],
        factorSnapshots: [String: FactorSnapshot],
        observations: [String: CardinalObservation]
    ) throws(ReplayError) {
        for (key, signal) in signals where key != signal.id.rawValue {
            throw .materialIdentityMismatch(
                detail: "signals[\(key)] 挂的是 id=\(signal.id.rawValue) 的实例")
        }
        for (key, snapshot) in factorSnapshots where key != snapshot.id.rawValue {
            throw .materialIdentityMismatch(
                detail: "factorSnapshots[\(key)] 挂的是 id=\(snapshot.id.rawValue) 的实例")
        }
        for (key, observation) in observations where key != observation.id.rawValue {
            throw .materialIdentityMismatch(
                detail: "observations[\(key)] 挂的是 id=\(observation.id.rawValue) 的实例")
        }
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
    /// 从比较结论组装 artifact（id 确定性派生：引用层 + 结果层完整语义——
    /// decision + plans + 上下文 + 规划输入指纹，审查 P1-3 修复；只排除
    /// producedAt）。plannerRuns 必须恰好覆盖 plans 域（规划输入指纹的
    /// 锚定前提，违反即编程错误 fail-fast）。
    static func assemble(
        signalIDs: [SignalID],
        criterionVersions: [String],
        factorSnapshotIDs: [ArtifactID],
        target: AllocationTarget?,
        bandVersion: String,
        signalPolicyVersion: String,
        knowledgeContextSummary: String,
        decision: PartialDecision,
        comparison: PlanComparisonResult,
        plans: [String: PortfolioActionPlan],
        plannerRuns: [String: DecisionReplayer.PlannerRun],
        producedAt: Date
    ) -> PortfolioDecisionArtifact {
        precondition(
            Set(plannerRuns.keys) == Set(plans.keys),
            "assemble 的 plannerRuns 必须恰好覆盖 plans 域（规划输入指纹锚定前提）")
        // 规划输入指纹（确定性类型,编码失败 = 编程错误,fail-fast）
        var plannerInputFingerprints: [String: String] = [:]
        for (key, run) in plannerRuns {
            plannerInputFingerprints[key] = try! run.fingerprint()
        }
        // 确定性类型的编码失败 = 编程错误,fail-fast
        let payload = try! StableDigest.jsonPayload(IdentityPayload(
            signalIDs: signalIDs.map(\.rawValue).sorted(),
            criterionVersions: criterionVersions.sorted(),
            factorSnapshotIDs: factorSnapshotIDs.map(\.rawValue).sorted(),
            targetID: target?.id.rawValue,
            bandVersion: bandVersion,
            signalPolicyVersion: signalPolicyVersion,
            plannerInputFingerprints: plannerInputFingerprints,
            knowledgeContextSummary: knowledgeContextSummary,
            decision: decision,
            comparison: comparison,
            plans: plans
        ))
        // 五轮 P1-3 + 六轮 P1-1:criterion / band / signalPolicy 的 policy
        // 依赖一并登记(失效传播:任一 policy 版本变更 → 受影响决策可反查)
        let deps: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue, version: nil)] } ?? [])
            + criterionVersions.map { ArtifactDependency(kind: .policy, referenceID: "criterion@\($0)") }
            + [ArtifactDependency(kind: .policy, referenceID: "band@\(bandVersion)"),
               ArtifactDependency(kind: .policy, referenceID: "signalPolicy@\(signalPolicyVersion)")]
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
            signalCardinalPolicyVersion: signalPolicyVersion,
            plannerInputFingerprints: plannerInputFingerprints,
            knowledgeContextSummary: knowledgeContextSummary,
            decision: decision,
            comparison: comparison,
            plans: plans
        )
    }

    /// ID 身份 payload（语义完备；审查 P1-3 + 六轮 P1-3 规划输入指纹）。
    private struct IdentityPayload: Encodable {
        let signalIDs: [String]
        let criterionVersions: [String]
        let factorSnapshotIDs: [String]
        let targetID: String?
        let bandVersion: String
        let signalPolicyVersion: String
        let plannerInputFingerprints: [String: String]
        let knowledgeContextSummary: String
        let decision: PartialDecision
        let comparison: PlanComparisonResult
        let plans: [String: PortfolioActionPlan]
    }
}
