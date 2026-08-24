import Foundation

// MARK: - TargetRebalancePlanner（DEC-5，Epic 10，ADR-D001）
//
// Δw 的唯一生产者。**SizingProvenance 铁律（D001）**：每条 Δw 必须带
// target / remediation / user 三类来源之一；LLM / Agent / Signal 不能
// 直接产 Δw——类型层保证：planner 的输入类型里不存在 Signal /
// RiskProfile，它们只能经 DEC-2 remediation（结构化）间接进入。
//
// 确定性算法（DEC-9 replay 基础）：同输入同输出。
// 分配规则（资产类层 → 持仓层）：
// - 偏差超 toleranceBand 才动（带内不交易，减少摩擦）
// - 类内 pro-rata：按既有持仓相对权重等比缩放到目标类权重
// - 组合中不存在、target > 0 的类 → 不猜新标的，显式 note（用户/白名单职责）
// - target 中不存在的类（目标 0）→ 整类清仓

/// Δw 来源证明（D001 §Decision 1，仅三类）。
enum SizingProvenance: Sendable, Codable, Hashable {
    /// Target 跟随（D000 的 AllocationTarget 触发的再平衡）
    case targetRebalance(TargetRebalance)
    /// 状态约束修复（DEC-2 RemediationRequirement）
    case remediation(Remediation)
    /// 用户显式操作（手动加 / 减仓）
    case userDirective(UserDirective)

    struct TargetRebalance: Sendable, Codable, Hashable {
        let targetID: InvestmentTargetID
        let targetCreatedAt: Date
    }

    struct Remediation: Sendable, Codable, Hashable {
        let requirement: RemediationRequirement
    }

    struct UserDirective: Sendable, Codable, Hashable {
        /// 用户操作事件引用（显式事件，D000 §5 精神）
        let directiveID: String
        let note: String?
    }
}

/// 带来源证明的单条计划动作。
struct PlannedAction: Sendable, Codable, Hashable {
    let action: PortfolioAction
    let provenance: SizingProvenance
}

/// 组合行动计划。
struct PortfolioActionPlan: Sendable, Codable, Hashable {
    let id: String
    let asOf: Date
    /// 参照的 Target（纯 remediation/user 计划可为 nil）
    let targetID: InvestmentTargetID?
    /// 全部动作（同 subjectKey 可多条——不同来源各自留证；投影层合并）
    let actions: [PlannedAction]
    /// 显式说明（无法执行的 target 片段 / 被动作域剔除的动作——不静默）
    let notes: [String]
    let plannerVersion: String
}

/// 用户显式指令输入（planner 的 user 来源通道）。
struct UserDirectiveInput: Sendable, Codable, Hashable {
    let subjectKey: String
    let deltaWeight: Ratio
    let directiveID: String
    let note: String?
}

/// remediation 数值化输入（由调用方从 StateConstraintFinding + 暴露数据
/// 推导：如「标的 X 暴露上限 0.1」；planner 只管执行降到 cap）。
struct RemediationTargetInput: Sendable, Codable, Hashable {
    let subjectKey: String
    /// 该标的的组合权重上限（卖出至 cap）
    let maxWeight: Ratio
    let requirement: RemediationRequirement
}

/// Target 再平衡规划器（DEC-5，确定性）。
struct TargetRebalancePlanner: Sendable {
    static let plannerVersion = "v1"

    /// 规划参数（versioned）。
    struct Parameters: Sendable, Codable, Hashable {
        /// 偏差容忍带（资产类 |current − target| ≤ band 不交易）
        let rebalanceToleranceBand: Decimal

        init(rebalanceToleranceBand: Decimal = Decimal(string: "0.05")!) {
            self.rebalanceToleranceBand = rebalanceToleranceBand
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 生成行动计划。
    ///
    /// 输入三类来源（D001）：target（AllocationTarget）+ remediation
    /// （数值化降仓目标）+ user（显式指令）。动作域外的动作被剔除并
    /// 记入 notes（不静默）。
    func plan(
        portfolio: PortfolioSnapshot,
        target: AllocationTarget?,
        remediationTargets: [RemediationTargetInput],
        userDirectives: [UserDirectiveInput],
        actionDomain: ActionDomain,
        now: Date
    ) -> PortfolioActionPlan {
        var planned: [PlannedAction] = []
        var notes: [String] = []

        // 1) Target 跟随（资产类层 → pro-rata 到持仓层）
        if let target {
            let classWeights = portfolio.assetClassWeights()
            let targetProvenance = SizingProvenance.targetRebalance(.init(
                targetID: target.id, targetCreatedAt: target.createdAt
            ))

            // 组合中出现的全部资产类 = target ∪ 现有
            let allClasses = Set(classWeights.keys).union(target.entries.map(\.assetClass))
            for assetClass in allClasses.sorted(by: { $0.rawValue < $1.rawValue }) {
                let current = classWeights[assetClass]?.value ?? 0
                let desired = target.targetWeight(for: assetClass)?.value ?? 0
                let deviation = desired - current
                if abs(deviation) <= parameters.rebalanceToleranceBand {
                    continue  // 带内不交易
                }
                let classPositions = portfolio.positions.filter { $0.assetClass == assetClass }
                if classPositions.isEmpty {
                    // target > 0 但组合无此类持仓：不猜新标的
                    notes.append("资产类 \(assetClass.rawValue) 目标 \(desired) 但组合内无持仓——需用户显式新增（planner 不引入新标的）")
                    continue
                }
                // pro-rata：类内每持仓按相对权重分摊偏差
                let classTotal = classPositions.reduce(Decimal.zero) { $0 + $1.weight.value }
                for position in classPositions {
                    let share = classTotal > 0 ? position.weight.value / classTotal : Decimal.zero
                    let delta = deviation * share
                    guard delta != 0 else { continue }
                    planned.append(PlannedAction(
                        action: PortfolioAction(subjectKey: position.subjectKey, deltaWeight: Ratio(value: delta)),
                        provenance: targetProvenance
                    ))
                }
            }
        }

        // 2) remediation：卖出至 cap（只降不加）
        for input in remediationTargets {
            let current = portfolio.positions
                .first { $0.subjectKey == input.subjectKey }?.weight.value ?? 0
            let delta = min(input.maxWeight.value, current) - current
            guard delta < 0 else { continue }  // 已在 cap 内或无法定位持仓 → 无动作
            planned.append(PlannedAction(
                action: PortfolioAction(subjectKey: input.subjectKey, deltaWeight: Ratio(value: delta)),
                provenance: .remediation(.init(requirement: input.requirement))
            ))
        }

        // 3) user 显式指令直通（provenance = 操作事件引用）
        for input in userDirectives {
            planned.append(PlannedAction(
                action: PortfolioAction(subjectKey: input.subjectKey, deltaWeight: input.deltaWeight),
                provenance: .userDirective(.init(directiveID: input.directiveID, note: input.note))
            ))
        }

        // 4) 动作域门禁：域外动作剔除 + 显式 note（不静默；联合约束是 DEC-6）
        var kept: [PlannedAction] = []
        for item in planned {
            if actionDomain.contains(action: item.action) {
                kept.append(item)
            } else {
                notes.append("动作 \(item.action.subjectKey) Δ\(item.action.deltaWeight.value) 超出动作域被剔除（来源：\(item.provenance.kindLabel)）")
            }
        }

        // 确定性排序：subjectKey → delta → provenance kind
        let sorted = kept.sorted {
            if $0.action.subjectKey != $1.action.subjectKey {
                return $0.action.subjectKey < $1.action.subjectKey
            }
            if $0.action.deltaWeight.value != $1.action.deltaWeight.value {
                return $0.action.deltaWeight.value < $1.action.deltaWeight.value
            }
            return $0.provenance.kindLabel < $1.provenance.kindLabel
        }

        let canonical = "plan|\(Int(now.timeIntervalSince1970))|\(target?.id.rawValue ?? "-")|\(sorted.map { "\($0.action.subjectKey):\($0.action.deltaWeight.value):\($0.provenance.kindLabel)" }.joined(separator: ","))"
        return PortfolioActionPlan(
            id: "plan_\(Self.digest(canonical))",
            asOf: now,
            targetID: target?.id,
            actions: sorted,
            notes: notes,
            plannerVersion: Self.plannerVersion
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

extension SizingProvenance {
    /// 来源分类标签（排序与 note 用；不携带数值语义）。
    var kindLabel: String {
        switch self {
        case .targetRebalance: return "target"
        case .remediation: return "remediation"
        case .userDirective: return "user"
        }
    }
}
