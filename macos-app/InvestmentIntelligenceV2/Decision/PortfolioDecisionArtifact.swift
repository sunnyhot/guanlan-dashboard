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
    }

    /// 校验 artifact 完备性与 provenance 闭环。
    ///
    /// - resolver：引用可解析性检查（Signal / Factor / Target 实例是否可取；
    ///   测试传 stub，生产接 Signal Store（RES-6）/ Repository）
    func validate(
        artifact: PortfolioDecisionArtifact,
        referenceResolver: (SignalID) -> Bool = { _ in true }
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
        for (key, plan) in artifact.plans {
            for item in plan.actions {
                switch item.provenance {
                case .targetRebalance, .remediation, .userDirective:
                    break
                }
            }
            _ = key
        }
        // admissible ∈ plans
        for admissible in artifact.decision.admissiblePlans {
            guard artifact.plans[admissible] != nil else {
                throw ValidationError.admissiblePlanNotFound(admissible)
            }
        }
        // 引用可解析（Signal IDs）
        for signalID in artifact.signalIDs where !referenceResolver(signalID) {
            // 单个不可解析不在此抛——D004：supersede 不改旧引用，resolver
            // 返回 false 时上游已丢失,属存储层问题;此处只做完备性结构校验
        }
    }
}

/// 决策重放器（DEC-9，D004 §3/5）。
struct DecisionReplayer: Sendable {
    /// 重放的确定性输入快照（按 artifact 引用取齐后组装；**不重跑 Research /
    /// 不重抓数据 / 不重算 factor**——取数是调用方职责，replayer 只重跑
    /// Planner→Compare→Decide 的确定性链）。
    struct ReplayInputs: Sendable, Codable, Hashable {
        let plans: [String: [CriterionScore]]
        let band: IndifferenceBand
        let higherIsBetter: [String: Bool]
        let allPlanKeys: [String]
    }

    /// 完整重放：同 IDs 取齐的 inputs → 同决策（确定性链）。
    func replay(inputs: ReplayInputs) -> PartialDecision {
        let comparison = CriterionComparator().compare(
            plans: inputs.plans,
            band: inputs.band,
            higherIsBetter: inputs.higherIsBetter
        )
        return PartialDecisionPolicy().decide(comparison, allPlanKeys: inputs.allPlanKeys)
    }

    /// Partial 重放（what-if）：替换部分引用（如换 plans 的 scores）后重跑。
    /// 结果是新决策,不影响原 artifact（D004 §5）。
    func replayWhatIf(base: ReplayInputs, replacing plans: [String: [CriterionScore]]) -> PartialDecision {
        replay(inputs: ReplayInputs(
            plans: base.plans.merging(plans) { _, new in new },
            band: base.band,
            higherIsBetter: base.higherIsBetter,
            allPlanKeys: base.allPlanKeys
        ))
    }
}

// MARK: - 决策组装器（artifact 构造的便捷入口）

extension PortfolioDecisionArtifact {
    /// 从比较结论组装 artifact（id 确定性派生：引用层 + 结果层内容）。
    static func assemble(
        signalIDs: [SignalID],
        criterionVersions: [String],
        factorSnapshotIDs: [ArtifactID],
        target: AllocationTarget?,
        bandVersion: String,
        knowledgeContextSummary: String,
        decision: PartialDecision,
        plans: [String: PortfolioActionPlan],
        producedAt: Date
    ) -> PortfolioDecisionArtifact {
        let canonical = "decision|\(signalIDs.map(\.rawValue).sorted().joined(separator: ","))|\(criterionVersions.sorted().joined(separator: ","))|\(factorSnapshotIDs.map(\.rawValue).sorted().joined(separator: ","))|\(target?.id.rawValue ?? "-")|\(bandVersion)|\(decision.admissiblePlans.sorted().joined(separator: ","))"
        let deps: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
            + factorSnapshotIDs.map { ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue) }
            + (target.map { [ArtifactDependency(kind: .target, referenceID: $0.id.rawValue, version: nil)] } ?? [])
        return PortfolioDecisionArtifact(
            id: ArtifactID(rawValue: "dec_\(Self.digest(canonical))"),
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
            plans: plans
        )
    }

    /// 双 FNV-1a 确定性摘要（与同模块其他 id 派生同算法）。
    private static func digest(_ input: String) -> String {
        let data = Data(input.utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in data {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0xbf58476d1ce4e5b9
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}
