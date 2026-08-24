import Foundation

// MARK: - StateConstraintEvaluator（DEC-2，Epic 10）
//
// 祈使约束（imperative constraint）：「组合状态必须满足 X」——单标的暴露
// 上限、资产类与目标偏差上限、披露覆盖下限。**现状违规 → remediation
// （修复要求），不是 veto**：约束不否决计划（DEC-6 的 Constraint Gate 才
// 管计划），只描述现状与修复方向；修复方案由 DEC-5 planner 产。
//
// D000 联动：即使是风险信号超阈值，也只能触发 remediation（本类型），
// 不能修改 Target。
//
// Operational Obligation（操作义务）刻意与祈使约束分开：义务约束的是
// 「操作流程」（调仓前刷新估值 / 阈值触发通知用户），不是「组合状态」，
// 评估时机与消费方都不同——分开类型，互不复用。

/// 祈使约束定义（versioned；阈值是参数不是魔法数）。
struct StateConstraintDefinition: Sendable, Codable, Hashable {
    let id: String
    let version: String
    let kind: Kind
    let parameters: [Parameter]

    enum Kind: String, Sendable, Codable, Hashable {
        /// 单标的组合暴露上限（参数 threshold，0-1）
        case maxSingleSecurityExposure = "MAX_SINGLE_SECURITY_EXPOSURE"
        /// 资产大类与 Target 偏差上限（参数 threshold；需传入 AllocationTarget）
        case maxAssetClassDeviation = "MAX_ASSET_CLASS_DEVIATION"
        /// 披露覆盖下限（参数 minCoverage，0-1；覆盖 = 1 − unknownWeight）
        case minDisclosureCoverage = "MIN_DISCLOSURE_COVERAGE"
    }

    struct Parameter: Sendable, Codable, Hashable {
        let name: String
        let value: String
        var decimalValue: Decimal? { Decimal(string: value) }
    }

    func parameter(_ name: String) -> Decimal? {
        parameters.first { $0.name == name }?.decimalValue
    }
}

/// 修复要求（违规时的「要做什么」，不是具体方案）。
struct RemediationRequirement: Sendable, Codable, Hashable {
    /// 人读的修复方向（如「将标的 X 的组合暴露降至 10% 以下」）
    let directive: String
    /// 涉及主体（标的 / 资产类 key；通用要求为 nil）
    let relatedKey: String?
    /// 触发本要求的约束
    let constraintID: String
}

/// 单条约束的评估结果。
struct StateConstraintFinding: Sendable, Codable, Hashable {
    let constraint: StateConstraintDefinition
    let status: Status
    /// status == .violated 时非 nil（修复要求）
    let remediation: RemediationRequirement?
    /// status == .unknown 时非 nil（数据缺口说明）
    let insufficiencyNote: String?

    enum Status: String, Sendable, Codable, Hashable {
        case satisfied
        case violated
        /// 数据不足无法判定（lower/upper 跨阈值）——不猜
        case unknown
    }
}

/// 操作义务（与祈使约束分开的「流程 must」）。
struct OperationalObligation: Sendable, Codable, Hashable {
    let id: String
    let version: String
    /// 义务触发时机
    let trigger: Trigger
    /// 义务内容（如「调仓前刷新个人持仓估值」）
    let obligation: String

    enum Trigger: String, Sendable, Codable, Hashable {
        case beforeRebalance = "BEFORE_REBALANCE"
        case onThresholdBreach = "ON_THRESHOLD_BREACH"
        case beforeTargetChange = "BEFORE_TARGET_CHANGE"
    }
}

/// 祈使约束评估器（DEC-2，纯函数；三态判定用 EXP-2 的上下界）。
///
/// 三态规则（以「暴露 ≤ threshold」型约束为例）：
/// - lowerBound > threshold → **violated**（确认违规：已确认部分已超）
/// - upperBound ≤ threshold → **satisfied**（确认满足：最坏情况也没超）
/// - 之间（lower ≤ t < upper）→ **unknown**（可能违规，数据不足不猜）
struct StateConstraintEvaluator: Sendable {
    static let evaluatorVersion = "v1"

    /// 评估全部约束。
    ///
    /// - exposure：EXP-2 报告（含 unknownPortfolioWeight 与三维上下界）
    /// - target：maxAssetClassDeviation 需要；nil 时该类约束 → unknown
    func evaluate(
        constraints: [StateConstraintDefinition],
        exposure: ExposureReport,
        target: AllocationTarget?
    ) -> [StateConstraintFinding] {
        constraints.map { evaluate($0, exposure: exposure, target: target) }
    }

    private func evaluate(
        _ constraint: StateConstraintDefinition,
        exposure: ExposureReport,
        target: AllocationTarget?
    ) -> StateConstraintFinding {
        switch constraint.kind {
        case .maxSingleSecurityExposure:
            guard let threshold = constraint.parameter("threshold") else {
                return unknown(constraint, note: "约束缺 threshold 参数")
            }
            let securities = exposure.estimates.filter { $0.dimension == .singleSecurity }
            guard !securities.isEmpty else {
                return unknown(constraint, note: "无穿透标的暴露数据")
            }
            // 判定优先级（审查 P1 修复：不看单项，看全集合）：
            // ① 任一标的已确认超限（lower > threshold）→ violated（取确认暴露最深者）
            // ② 全部标的最坏情况都不超（upper ≤ threshold）→ satisfied
            // ③ 其间（存在跨阈值的上下界）→ unknown
            if let confirmed = securities
                .filter({ $0.lowerBound.value > threshold })
                .max(by: { $0.lowerBound.value < $1.lowerBound.value })
            {
                return violated(
                    constraint,
                    directive: "将标的 \(confirmed.key) 的组合暴露降至 \(percent(threshold)) 以下（已确认 \(percent(confirmed.lowerBound.value))）",
                    relatedKey: confirmed.key
                )
            }
            if securities.allSatisfy({ $0.upperBound.value <= threshold }) {
                return satisfied(constraint)
            }
            let straddling = securities
                .filter { $0.upperBound.value > threshold }
                .max(by: { $0.upperBound.value < $1.upperBound.value })
            return StateConstraintFinding(
                constraint: constraint,
                status: .unknown,
                remediation: nil,
                insufficiencyNote: "标的 \(straddling?.key ?? "?") 确认值未超阈值，最坏情况 \(percent(straddling?.upperBound.value ?? 0)) 超过 \(percent(threshold))——披露缺口内可能违规"
            )

        case .maxAssetClassDeviation:
            guard let threshold = constraint.parameter("threshold") else {
                return unknown(constraint, note: "约束缺 threshold 参数")
            }
            guard let target else {
                return unknown(constraint, note: "无 AllocationTarget，偏差无法定义（Target 不可从数据推断——D000）")
            }
            let classes = exposure.estimates.filter { $0.dimension == .assetClass }
            guard !classes.isEmpty else {
                return unknown(constraint, note: "无资产大类暴露数据")
            }
            // 偏差区间数学（审查 P1 修复：Target 落在暴露区间 [lo, hi] 内时
            // 偏差下界为 0，不是 |lo − t|）：
            //   deviationLower = max(0, lo − t, t − hi)   （到区间的最短距离）
            //   deviationUpper = max(|lo − t|, |hi − t|)  （到端点的最长距离）
            func deviationInterval(_ estimate: ExposureEstimate, target t: Decimal) -> (lower: Decimal, upper: Decimal) {
                let lo = estimate.lowerBound.value
                let hi = estimate.upperBound.value
                let shortest = max(0, max(lo - t, t - hi))
                let longest = max(abs(lo - t), abs(hi - t))
                return (shortest, longest)
            }
            // 逐类区间 → 全局判定（同单标的三级优先）：
            // ① 任一类确认偏差超阈 → violated；② 全部类最坏不超 → satisfied
            var anyConfirmedOver = false
            var allWorstUnder = true
            var worstConfirmed: (key: String, lower: Decimal)?
            var worstUnknown: (key: String, lower: Decimal, upper: Decimal)?
            for estimate in classes {
                let targetWeight = target.targetWeight(for: AssetClass(rawValue: estimate.key)!)?.value
                    ?? Decimal.zero  // Target 无该类 = 目标 0（显式：Target 定义域缺即 0 目标）
                let interval = deviationInterval(estimate, target: targetWeight)
                if interval.lower > threshold {
                    anyConfirmedOver = true
                    if worstConfirmed == nil || interval.lower > worstConfirmed!.lower {
                        worstConfirmed = (estimate.key, interval.lower)
                    }
                }
                if interval.upper > threshold {
                    allWorstUnder = false
                    if worstUnknown == nil || interval.upper > worstUnknown!.upper {
                        worstUnknown = (estimate.key, interval.lower, interval.upper)
                    }
                }
            }
            if anyConfirmedOver, let confirmed = worstConfirmed {
                return violated(
                    constraint,
                    directive: "将资产大类 \(confirmed.key) 与目标的偏差收敛到 \(percent(threshold)) 以内（已确认偏差 \(percent(confirmed.lower))）",
                    relatedKey: confirmed.key
                )
            }
            if allWorstUnder {
                return satisfied(constraint)
            }
            let s = worstUnknown!
            return StateConstraintFinding(
                constraint: constraint,
                status: .unknown,
                remediation: nil,
                insufficiencyNote: "资产大类 \(s.key) 的偏差区间 [\(percent(s.lower)), \(percent(s.upper))] 跨阈值 \(percent(threshold))——披露缺口内可能违规"
            )

        case .minDisclosureCoverage:
            guard let minCoverage = constraint.parameter("minCoverage") else {
                return unknown(constraint, note: "约束缺 minCoverage 参数")
            }
            // coverage = 1 − unknown；unknown 是确定值（缺口不带上界）
            let coverage = Decimal.one - exposure.unknownPortfolioWeight.value
            if coverage < minCoverage {
                return violated(constraint,
                    directive: "补齐持仓披露数据（当前覆盖 \(percent(coverage))，要求 ≥ \(percent(minCoverage))）",
                    relatedKey: nil)
            }
            return satisfied(constraint)
        }
    }

    // MARK: - 判定 helper

    private func satisfied(_ constraint: StateConstraintDefinition) -> StateConstraintFinding {
        StateConstraintFinding(constraint: constraint, status: .satisfied, remediation: nil, insufficiencyNote: nil)
    }

    private func violated(
        _ constraint: StateConstraintDefinition, directive: String, relatedKey: String?
    ) -> StateConstraintFinding {
        StateConstraintFinding(
            constraint: constraint,
            status: .violated,
            remediation: RemediationRequirement(
                directive: directive, relatedKey: relatedKey, constraintID: constraint.id
            ),
            insufficiencyNote: nil
        )
    }

    private func unknown(_ constraint: StateConstraintDefinition, note: String) -> StateConstraintFinding {
        StateConstraintFinding(constraint: constraint, status: .unknown, remediation: nil, insufficiencyNote: note)
    }

    private func percent(_ value: Decimal) -> String {
        "\((value * 100).rounded(toScale: 2))%"
    }
}

private extension Decimal {
    static let one = Decimal(1)
}
