import Foundation

// MARK: - CriterionComparator / PartialDecisionPolicy（DEC-8，ADR-D003）
//
// 比较语义（D003）：
// - 只允许 Pareto 语义（Effective Dominance），禁止「加权平均」类聚合
// - IndifferenceBand 是 heuristic policy：version / 阈值 / rationale 必须
//   显式标注（与 FAC-2 SignalPolicy 同一纪律），不允许静默
// - unknown criterion 阻断 dominance（不假装 unknown = 0，DATA006 联动）
// - 非传递性明确处理：不强行打破循环，输出 Partial Decision（部分序）；
//   unresolvedTradeoff 是真实决策状态，交 Presentation / 用户裁决，
//   系统不「假装决定」

/// 无差异带（heuristic policy，必须显式 provenance）。
struct IndifferenceBand: Sendable, Codable, Hashable {
    let policyID: String
    let version: String
    /// 每 criterion 的带（差异绝对值 ≤ band 视为 indifferent）
    let bandsByCriterion: [String: Decimal]
    /// 未单独配置的 criterion 用默认带
    let defaultBand: Decimal
    /// heuristic 理由（必填语义：空串视为未标注，init 拒绝）
    let rationale: String

    init(
        policyID: String, version: String,
        bandsByCriterion: [String: Decimal] = [:],
        defaultBand: Decimal,
        rationale: String
    ) {
        precondition(!rationale.trimmingCharacters(in: .whitespaces).isEmpty,
                     "heuristic band 必须标注 rationale（D003 不允许静默）")
        self.policyID = policyID
        self.version = version
        self.bandsByCriterion = bandsByCriterion
        self.defaultBand = defaultBand
        self.rationale = rationale
    }

    func band(for criterionID: String) -> Decimal {
        bandsByCriterion[criterionID] ?? defaultBand
    }
}

/// 两两比较结论。
enum PairwiseDominance: String, Sendable, Codable, Hashable {
    case aDominatesB
    case bDominatesA
    case incomparable
}

/// 多方案比较结果。
struct PlanComparisonResult: Sendable, Codable, Hashable {
    /// 两两关系（key = "A|B"（A、B 为 plan key，字典序），A 是 key 前段）
    let pairwise: [String: PairwiseDominance]
    /// Pareto 前沿（不被任何其他 plan dominate 的集合；循环时为空）
    let paretoFront: [String]
    /// 因 unknown 阻断比较的 criterion（透明记录）
    let blockingUnknowns: [String]
}

/// Criterion 比较器（DEC-8，deterministic，Pareto 语义）。
struct CriterionComparator: Sendable {
    static let comparatorVersion = "v1"

    enum CompareError: Error, Equatable, Sendable {
        /// plan key 为空或含分隔符 "|"（六轮 P2：非法持久化数据是可恢复的
        /// 校验错误，throw 而非 precondition——比较器位于 artifact 重放路径，
        /// 非法 key 不得崩进程）
        case malformedPlanKey(String)
    }

    /// 比较多方案的 scores。
    ///
    /// - plans：plan key → 该 plan 的全部 CriterionScore（按 criterion id 索引）
    /// - band：无差异带（heuristic，显式 provenance）
    ///
    /// 比较方向读各 CriterionScore.definition.higherIsBetter（六轮 P1-3：
    /// 方向是 versioned 定义的一部分，不再由调用方按 id 注入）。
    func compare(
        plans: [String: [CriterionScore]],
        band: IndifferenceBand
    ) throws(CompareError) -> PlanComparisonResult {
        // 五轮 P2-5:pair 键用 "a|b" 拼接——plan key 含 "|" 会破坏拆分与
        // Pareto 推导;六轮 P2:改为 throw(重放路径上的数据校验错误)
        for key in plans.keys where key.isEmpty || key.contains("|") {
            throw .malformedPlanKey(key)
        }
        let planKeys = plans.keys.sorted()
        // 汇总全部 criterion id（确定性顺序）
        let allCriteria = Set(plans.values.flatMap { $0.map { $0.definition.id } }).sorted()

        var pairwise: [String: PairwiseDominance] = [:]
        var blockingUnknowns = Set<String>()

        for i in 0..<planKeys.count {
            for j in (i + 1)..<planKeys.count {
                let a = planKeys[i], b = planKeys[j]
                let dominance = comparePair(
                    scoresA: indexed(plans[a]), scoresB: indexed(plans[b]),
                    criteria: allCriteria, band: band,
                    blockingUnknowns: &blockingUnknowns
                )
                pairwise["\(a)|\(b)"] = dominance
            }
        }

        // Pareto 前沿：不被任何其他 plan dominate
        var dominated = Set<String>()
        for (key, dominance) in pairwise {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            switch dominance {
            case .aDominatesB: dominated.insert(parts[1])
            case .bDominatesA: dominated.insert(parts[0])
            case .incomparable: break
            }
        }
        let front = planKeys.filter { !dominated.contains($0) }
        return PlanComparisonResult(
            pairwise: pairwise,
            paretoFront: front,
            blockingUnknowns: blockingUnknowns.sorted()
        )
    }

    // MARK: - 单对判定

    private func indexed(_ scores: [CriterionScore]?) -> [String: CriterionScore] {
        Dictionary((scores ?? []).map { ($0.definition.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func comparePair(
        scoresA: [String: CriterionScore],
        scoresB: [String: CriterionScore],
        criteria: [String],
        band: IndifferenceBand,
        blockingUnknowns: inout Set<String>
    ) -> PairwiseDominance {
        var aBetterCount = 0
        var bBetterCount = 0

        for criterion in criteria {
            let aScore = scoresA[criterion]
            let bScore = scoresB[criterion]
            // 任一侧缺失 / unknown → 该 criterion 阻断（不假装 = 0）
            guard let av = aScore?.value, let bv = bScore?.value else {
                blockingUnknowns.insert(criterion)
                return .incomparable
            }
            // 方向取自 versioned 定义（六轮 P1-3）——同一 criterion 版本下
            // 两侧定义相同（artifact 引用层锁定），取 A 侧即代表比较方向
            let diff = (aScore?.definition.higherIsBetter ?? true) ? av - bv : bv - av
            if abs(diff) <= band.band(for: criterion) {
                continue  // indifferent：忽略
            }
            if diff > 0 { aBetterCount += 1 } else { bBetterCount += 1 }
        }

        if aBetterCount > 0 && bBetterCount == 0 { return .aDominatesB }
        if bBetterCount > 0 && aBetterCount == 0 { return .bDominatesA }
        return .incomparable  // 各有优势或全 indifferent
    }
}

/// 部分决策（D003 §4：不强制 total order）。
///
/// 语义相等只看 (status, admissiblePlans)——explanation 是 Presentation
/// 文案,重放推导的措辞与历史措辞可能不同但不构成语义漂移（三轮 P1-6
/// 校验依赖此语义相等）。
struct PartialDecision: Sendable, Codable, Hashable {
    static func == (lhs: PartialDecision, rhs: PartialDecision) -> Bool {
        lhs.status == rhs.status && lhs.admissiblePlans == rhs.admissiblePlans
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(status)
        hasher.combine(admissiblePlans)
    }

    enum Status: String, Sendable, Codable, Hashable {
        /// 前沿恰一个：有明确偏好
        case singlePreferred
        /// 多方案并列 / 循环 / unknown 阻断：真实决策状态，交用户裁决
        case unresolvedTradeoff
    }

    let status: Status
    /// 可采纳方案（前沿；循环时为全部循环成员）
    let admissiblePlans: [String]
    /// 人读解释（Presentation 层消费）
    let explanation: String
}

/// 部分决策策略（DEC-8：非传递性明确处理）。
struct PartialDecisionPolicy: Sendable {
    static let policyVersion = "v1"

    /// 从比较结果产部分决策。
    ///
    /// - 前沿恰一个 → singlePreferred
    /// - 前沿多个 → unresolvedTradeoff（多个 admissible，不强行取唯一胜者）
    /// - 前沿空（非传递循环：A>B>C>A）→ 全部循环成员 admissible +
    ///   unresolvedTradeoff——**不强行打破循环**（D003）
    func decide(
        _ comparison: PlanComparisonResult,
        allPlanKeys: [String]
    ) -> PartialDecision {
        if comparison.paretoFront.count == 1 {
            return PartialDecision(
                status: .singlePreferred,
                admissiblePlans: comparison.paretoFront,
                explanation: "方案 \(comparison.paretoFront[0]) 在全部非无差异 criterion 上不劣于且至少一项严格优于其他方案"
            )
        }
        if comparison.paretoFront.isEmpty {
            // 全被 dominate = 非传递循环：循环成员都可采纳
            return PartialDecision(
                status: .unresolvedTradeoff,
                admissiblePlans: allPlanKeys.sorted(),
                explanation: "方案间存在偏好循环（非传递性），系统不强行打破——全部循环成员可采纳，交由用户裁决"
            )
        }
        let reason: String
        if !comparison.blockingUnknowns.isEmpty {
            reason = "存在 unknown criterion（\(comparison.blockingUnknowns.joined(separator: ", "))）阻断比较，且多方案互不支配"
        } else {
            reason = "多个方案互不支配（各有优势 criterion），无加权聚合语义（D003 禁止）"
        }
        return PartialDecision(
            status: .unresolvedTradeoff,
            admissiblePlans: comparison.paretoFront,
            explanation: reason
        )
    }
}
