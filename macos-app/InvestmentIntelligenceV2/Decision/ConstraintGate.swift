import Foundation

// MARK: - ConstraintGate（DEC-6，Epic 10，ADR-D001 §Decision 4）
//
// 双层约束门保护 Δw：
// - action-level pruning：单条动作违反硬约束（最小交易量 / 单动作上限）
//   → 裁剪（剔除并留证）
// - portfolio-level on ProjectedPortfolio：投影后的组合违反联合约束
//   （总预算 / 再平衡零和 / 无负权重 / 无杠杆 / 平均相关性）→ 整体
//   verdict 拒绝；总预算超限可显式 rescale（按比例缩放，provenance 保留）
//
// 铁律（D001）：两层 gate 都**不引入新的 Δw 来源**，只裁剪 / 缩放已
// provenanced 的 Δw。

/// 双层约束门（DEC-6，纯函数）。
struct ConstraintGate: Sendable {
    static let gateVersion = "v1"

    // MARK: - Layer 1：action-level pruning

    /// 单条动作的硬约束。
    enum ActionRule: Sendable, Codable, Hashable {
        /// 最小交易量（|Δw| 低于此值剔除——碎单无意义）
        case minTradeSize(Decimal)
        /// 单动作最大 |Δw|
        case maxSingleDelta(Decimal)

        func violated(by delta: Decimal) -> Bool {
            switch self {
            case .minTradeSize(let min): return abs(delta) < min
            case .maxSingleDelta(let max): return abs(delta) > max
            }
        }

        var label: String {
            switch self {
            case .minTradeSize(let v): return "minTradeSize(\(v))"
            case .maxSingleDelta(let v): return "maxSingleDelta(\(v))"
            }
        }
    }

    struct PruneResult: Sendable, Codable, Hashable {
        let kept: [PlannedAction]
        /// 被剔除的动作 + 违反的规则 label（留证不静默）
        let pruned: [PrunedAction]

        struct PrunedAction: Sendable, Codable, Hashable {
            let action: PlannedAction
            let ruleLabel: String
        }
    }

    /// 第一层：逐动作硬约束裁剪。
    func prune(actions: [PlannedAction], rules: [ActionRule]) -> PruneResult {
        var kept: [PlannedAction] = []
        var pruned: [PruneResult.PrunedAction] = []
        for item in actions {
            let violated = rules.first { $0.violated(by: item.action.deltaWeight.value) }
            if let violated {
                pruned.append(.init(action: item, ruleLabel: violated.label))
            } else {
                kept.append(item)
            }
        }
        return PruneResult(kept: kept, pruned: pruned)
    }

    // MARK: - Layer 2：portfolio-level（联合约束，在投影上评估）

    /// 组合级联合约束。
    enum PortfolioRule: Sendable, Codable, Hashable {
        /// 投影后任何持仓权重不得为负（忠实投影保留的负值在此拒绝）
        case noNegativeWeights
        /// 投影后 Σw ≤ 1 + 容差（无杠杆）
        case weightsSumAtMostOne(tolerance: Decimal)
        /// 再平衡零和：ΣΔ ≈ 0（容差内）；user 单边计划不应启用此规则
        case rebalanceZeroSum(tolerance: Decimal)
        /// 总换手预算：Σ|Δ| ≤ cap
        case totalBudget(cap: Decimal)
        /// 平均相关性上限：投影组合的权重加权平均 |ρ| ≤ cap（ρ 缺失对
        /// 跳过——unknown 不猜不阻断，但记录 note）
        case maxAverageCorrelation(cap: Decimal)

        var label: String {
            switch self {
            case .noNegativeWeights: return "noNegativeWeights"
            case .weightsSumAtMostOne(let t): return "weightsSumAtMostOne(±\(t))"
            case .rebalanceZeroSum(let t): return "rebalanceZeroSum(±\(t))"
            case .totalBudget(let cap): return "totalBudget(\(cap))"
            case .maxAverageCorrelation(let cap): return "maxAverageCorrelation(\(cap))"
            }
        }
    }

    /// 组合级评估结论。
    struct GateVerdict: Sendable, Codable, Hashable {
        let passed: Bool
        /// 违反明细（规则 label + 说明；passed == false 时非空）
        let violations: [String]
        /// 相关性评估中因数据缺失被跳过的标的对（透明记录）
        let correlationSkippedPairs: Int
    }

    /// 第二层：在 ProjectedPortfolio 上评估联合约束。
    func evaluate(
        projected: ProjectedPortfolio,
        actions: [PortfolioAction],
        rules: [PortfolioRule],
        correlations: [CorrelationPair] = []
    ) -> GateVerdict {
        var violations: [String] = []
        var skipped = 0

        for rule in rules {
            switch rule {
            case .noNegativeWeights:
                let negative = projected.positions.filter { $0.weight.value < 0 }
                if !negative.isEmpty {
                    violations.append("\(rule.label)：\(negative.map(\.subjectKey).sorted().joined(separator: ", ")) 权重为负")
                }

            case .weightsSumAtMostOne(let tolerance):
                let sum = projected.positions.reduce(Decimal.zero) { $0 + $1.weight.value }
                if sum > Decimal.one + tolerance {
                    violations.append("\(rule.label)：投影后 Σw = \(sum)")
                }

            case .rebalanceZeroSum(let tolerance):
                let deltaSum = actions.reduce(Decimal.zero) { $0 + $1.deltaWeight.value }
                if abs(deltaSum) > tolerance {
                    violations.append("\(rule.label)：ΣΔ = \(deltaSum)")
                }

            case .totalBudget(let cap):
                let turnover = actions.reduce(Decimal.zero) { $0 + abs($1.deltaWeight.value) }
                if turnover > cap {
                    violations.append("\(rule.label)：Σ|Δ| = \(turnover) > \(cap)")
                }

            case .maxAverageCorrelation(let cap):
                let (average, skippedPairs) = Self.weightedAverageCorrelation(
                    projected: projected, correlations: correlations
                )
                skipped = skippedPairs
                if let average, average > cap {
                    violations.append("\(rule.label)：加权平均相关 = \(average)")
                }
            }
        }

        return GateVerdict(
            passed: violations.isEmpty,
            violations: violations,
            correlationSkippedPairs: skipped
        )
    }

    // MARK: - Rescale（总预算显式缩放，不引入新 Δw）

    /// 把全部动作按比例缩放到总预算内（provenance 原样保留）。
    /// 预算内时原样返回；零动作返回空。
    func rescaled(actions: [PlannedAction], toBudget cap: Decimal) -> [PlannedAction] {
        let turnover = actions.reduce(Decimal.zero) { $0 + abs($1.action.deltaWeight.value) }
        guard turnover > cap, turnover > 0 else { return actions }
        let factor = cap / turnover
        return actions.map { item in
            PlannedAction(
                action: PortfolioAction(
                    subjectKey: item.action.subjectKey,
                    deltaWeight: Ratio(value: item.action.deltaWeight.value * factor)
                ),
                provenance: item.provenance
            )
        }
    }

    // MARK: - 加权平均相关

    /// 权重加权平均 |ρ|：Σ_ij w_i w_j |ρ_ij| / Σ_ij w_i w_j（i≠j）。
    /// ρ 缺失（unknown）的对从分子分母同时剔除——不猜；跳过数返回。
    private static func weightedAverageCorrelation(
        projected: ProjectedPortfolio, correlations: [CorrelationPair]
    ) -> (average: Decimal?, skipped: Int) {
        // 对键：无序对（两侧排序后拼接），与投影主体的 listing| 前缀剥除匹配。
        // 反序重复对（(A,B) 与 (B,A)）确定性合并（二轮审查 P2-8：不再 trap）：
        // 值完全一致 → 幂等保留；不一致 → 保留序列化字典序较小者（上游
        // 数据矛盾的确定性行为，不静默不崩溃）。
        var correlationByPairKey: [String: CorrelationPair] = [:]
        for pair in correlations {
            let key = [pair.listingA.rawValue, pair.listingB.rawValue].sorted().joined(separator: "|")
            if let existing = correlationByPairKey[key] {
                correlationByPairKey[key] = Self.deterministicPick(existing, pair)
            } else {
                correlationByPairKey[key] = pair
            }
        }
        var numerator: Decimal = .zero
        var denominator: Decimal = .zero
        var skipped = 0
        let positions = projected.positions.filter { $0.weight.value > 0 }
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                let a = positions[i], b = positions[j]
                guard let keyA = Self.listingKey(a.subjectKey),
                      let keyB = Self.listingKey(b.subjectKey)
                else {
                    skipped += 1  // 基金等非 listing 主体无行情序列——跳过不猜
                    continue
                }
                let pairKey = [keyA, keyB].sorted().joined(separator: "|")
                guard let pair = correlationByPairKey[pairKey],
                      let rho = pair.pearson?.value
                else {
                    skipped += 1
                    continue
                }
                let pairWeight = a.weight.value * b.weight.value
                numerator += pairWeight * abs(rho)
                denominator += pairWeight
            }
        }
        guard denominator > 0 else { return (nil, skipped) }
        return (numerator / denominator, skipped)
    }

    /// 冲突对的确定性选择（三轮 P1-5：保守）。安全约束禁止字典序取小者
    /// 降风险（0.9 vs 0.5 冲突取 0.5 会让上限 0.8 错误通过）——
    /// 取 **|ρ| 绝对值较大者**（最坏情况评估）；同 |ρ| 时取序列化较小者
    /// 保稳定（方向无关）。
    private static func deterministicPick(_ a: CorrelationPair, _ b: CorrelationPair) -> CorrelationPair {
        if a.pearson == b.pearson && a.sampleCount == b.sampleCount {
            return a
        }
        let magnitudeA = a.pearson.map { abs($0.value) } ?? -1
        let magnitudeB = b.pearson.map { abs($0.value) } ?? -1
        if magnitudeA != magnitudeB {
            return magnitudeA > magnitudeB ? a : b
        }
        return serialize(a) <= serialize(b) ? a : b
    }

    private static func serialize(_ pair: CorrelationPair) -> String {
        let rho = pair.pearson.map { "\($0.value)" } ?? "nil"
        // 规范对键（排序）:选择只取决于数值,与输入方向无关
        let pairKey = [pair.listingA.rawValue, pair.listingB.rawValue].sorted().joined(separator: "|")
        return "\(pairKey)|\(rho)|\(pair.sampleCount)"
    }

    /// subjectKey（fund|xxx / listing|xxx）→ CorrelationPair 的 ListingID 域。
    /// 审查 P1 修复：CorrelationPair 存裸 ListingID（rawValue 无前缀），
    /// 投影主体键是 listing|code 形态——必须剥前缀后按无序对匹配；
    /// 基金主体返回 nil（无法映射行情序列，跳过不猜）。
    private static func listingKey(_ subjectKey: String) -> String? {
        guard subjectKey.hasPrefix("listing|") else { return nil }
        return String(subjectKey.dropFirst("listing|".count))
    }
}

private extension Decimal {
    static let one = Decimal(1)
}
