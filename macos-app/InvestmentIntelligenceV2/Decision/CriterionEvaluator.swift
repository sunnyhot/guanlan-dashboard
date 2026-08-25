import Foundation

// MARK: - CriterionEvaluator（DEC-7，Epic 10，ADR-D002）
//
// Criterion 是 cardinal 量（Decimal + 单位），由 versioned deterministic
// evaluator 算出。**黑箱 criterion 禁止（D002）**：
// - 输入只能是 cardinal（factor metric / observation value / plan 的
//   投影组合与交易强度指标）——CriterionInput 不接受 ordinal signal
//   （七轮 P1：ordinal→±1/±0.6/±0.2 一类编码是伪 cardinal，重新打开
//   黑箱评分通道；LLM signal 保持 narrative，不进数学运算）
// - LLM 不产分：LLM 影响只能经 Research → 事实证据 → 可测量 cardinal
//   observation/metric → 本 evaluator
// - 同输入同输出 + inputReferences 可追溯 + computation 审计串

/// Criterion 定义（versioned deterministic）。
struct CriterionDefinition: Sendable, Codable, Hashable {
    let id: String
    let version: String
    let evaluatorKind: EvaluatorKind
    /// 输入引用（含 weightedSum 权重，全部可审计）
    let inputReferences: [InputReference]
    /// 输出单位（cardinal 量纲声明）
    let unit: FactorUnit
    /// 比较方向（六轮 P1-3：方向是 versioned 定义的一部分，不再由重放
    /// 调用方按 criterion id 临时注入——cost 类 criterion 显式 false）
    let higherIsBetter: Bool

    enum EvaluatorKind: String, Sendable, Codable, Hashable {
        /// Σ weight_i × value_i（线性加权）
        case weightedSum = "WEIGHTED_SUM"
        /// |value_a − value_b|（恰两个引用）
        case absoluteDeviation = "ABSOLUTE_DEVIATION"
    }

    struct InputReference: Sendable, Codable, Hashable {
        let kind: Kind
        let referenceID: String
        /// weightedSum 的权重（absoluteDeviation 忽略）
        let weight: Decimal

        enum Kind: String, Sendable, Codable, Hashable {
            case observation = "OBSERVATION"
            /// FactorSnapshot 的 metric（refID 约定「<snapshotID>#<metricKey>」）
            case factorMetric = "FACTOR_METRIC"
            /// plan-scoped 指标（投影组合 / 交易强度——七轮 P1：方案各自
            /// 的 criterion 差异来源，refID 见 PlanMetrics）
            case planMetric = "PLAN_METRIC"
        }
    }

    init(
        id: String,
        version: String,
        evaluatorKind: EvaluatorKind,
        inputReferences: [InputReference],
        unit: FactorUnit,
        higherIsBetter: Bool = true
    ) {
        self.id = id
        self.version = version
        self.evaluatorKind = evaluatorKind
        self.inputReferences = inputReferences
        self.unit = unit
        self.higherIsBetter = higherIsBetter
    }

    var fingerprint: String { "\(id)@\(version)" }

    // 旧 payload（方向入定义前）无 higherIsBetter 键 → 按 true 解码，
    // 与 comparator 历史缺省一致；方向变更必须 bump version（D002 纪律）
    private enum CodingKeys: String, CodingKey {
        case id, version, evaluatorKind, inputReferences, unit, higherIsBetter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        evaluatorKind = try c.decode(EvaluatorKind.self, forKey: .evaluatorKind)
        inputReferences = try c.decode([InputReference].self, forKey: .inputReferences)
        unit = try c.decode(FactorUnit.self, forKey: .unit)
        higherIsBetter = try c.decodeIfPresent(Bool.self, forKey: .higherIsBetter) ?? true
    }
}

/// 单个求值输入（运行时 cardinal 值；value nil = 缺失 → unknown 不猜）。
struct CriterionInput: Sendable, Codable, Hashable {
    let referenceID: String
    let value: Decimal?

    init(referenceID: String, value: Decimal?) {
        self.referenceID = referenceID
        self.value = value
    }
}

/// Criterion 求值结果（cardinal 或 unknown）。
struct CriterionScore: Sendable, Codable, Hashable {
    let definition: CriterionDefinition
    /// nil = unknown（有输入缺失，不猜）
    let value: Decimal?
    /// 缺失的引用 ID（value nil 时非空）
    let missingInputs: [String]
    /// 人读计算轨迹（审计：「为什么是这个分」）
    let computation: String
}

/// Criterion 求值器（DEC-7，纯函数 deterministic）。
struct CriterionEvaluator: Sendable {
    static let evaluatorVersion = "v1"

    func evaluate(definition: CriterionDefinition, inputs: [CriterionInput]) -> CriterionScore {
        let byID = Dictionary(inputs.map { ($0.referenceID, $0) }, uniquingKeysWith: { first, _ in first })

        func value(for reference: CriterionDefinition.InputReference) -> Decimal? {
            byID[reference.referenceID]?.value
        }

        switch definition.evaluatorKind {
        case .weightedSum:
            var total: Decimal = .zero
            var terms: [String] = []
            var missing: [String] = []
            for reference in definition.inputReferences {
                guard let v = value(for: reference) else {
                    missing.append(reference.referenceID)
                    continue
                }
                total += reference.weight * v
                terms.append("\(reference.weight)×\(v)")
            }
            if !missing.isEmpty {
                return CriterionScore(
                    definition: definition, value: nil, missingInputs: missing,
                    computation: "输入缺失: \(missing.joined(separator: ", "))"
                )
            }
            return CriterionScore(
                definition: definition, value: total, missingInputs: [],
                computation: terms.joined(separator: " + ") + " = \(total)"
            )

        case .absoluteDeviation:
            guard definition.inputReferences.count == 2 else {
                return CriterionScore(
                    definition: definition, value: nil,
                    missingInputs: definition.inputReferences.map(\.referenceID),
                    computation: "absoluteDeviation 恰需两个引用"
                )
            }
            let refs = definition.inputReferences
            guard let a = value(for: refs[0]), let b = value(for: refs[1]) else {
                let missing = refs.filter { value(for: $0) == nil }.map(\.referenceID)
                return CriterionScore(
                    definition: definition, value: nil, missingInputs: missing,
                    computation: "输入缺失: \(missing.joined(separator: ", "))"
                )
            }
            let result = abs(a - b)
            return CriterionScore(
                definition: definition, value: result, missingInputs: [],
                computation: "|\(a) − \(b)| = \(result)"
            )
        }
    }
}

// MARK: - 输入提取（六轮 P1-1 + 七轮 P1：Decimal 只能从强类型实例/plan 推导，resolver 不提供数值）

/// 带 cardinal 值的 observation 强类型实例（criterion 的 OBSERVATION 输入通道）。
///
/// 仅收单一数值语义明确的观测类型（Macro / Fundamental）；DailyBar、NAV、
/// 持仓快照等观测无单一「数值」语义（OHLCV / 净值三元组 / 持仓结构），
/// 不直接进入 criterion 运算——需要时经 Factor 引擎折叠成 metric 再引用。
enum CardinalObservation: Sendable, Codable, Hashable {
    case macro(MacroObservation)
    case fundamental(FundamentalObservation)

    var id: ObservationID {
        switch self {
        case .macro(let observation): return observation.id
        case .fundamental(let observation): return observation.id
        }
    }

    /// 从实例本身提取的 cardinal 值（两类观测的 value 恒非 nil）
    var value: Decimal {
        switch self {
        case .macro(let observation): return observation.value
        case .fundamental(let observation): return observation.value
        }
    }
}

/// plan-scoped cardinal 指标（七轮 P1）：从 (plan, portfolio) 确定性推导的
/// 方案各自量纲——每个 PortfolioActionPlan 有自己的分数，比较才有 D003
/// 的 dominance 语义。命名空间封闭（本 enum 是唯一合法 refID 来源）。
enum PlanMetrics: Sendable {
    /// Σ|Δw|（全部动作的绝对权重变化之和——交易强度/成本代理，量纲 ratio）
    static let turnover = "plan.turnover"
    /// 投影组合资产类权重 refID 前缀：`plan.projectedWeight#<AssetClass.rawValue>`
    static let projectedWeightPrefix = "plan.projectedWeight"

    static func turnover(of plan: PortfolioActionPlan) -> Decimal {
        plan.actions.reduce(Decimal.zero) { $0 + abs($1.action.deltaWeight.value) }
    }

    /// plan 的 Δw 应用到 portfolio 后按资产类聚合的权重（不引入新标的的
    /// 类别信息——组合外 subjectKey 的 Δw 不计入投影，保持可推导）。
    static func projectedAssetClassWeights(
        of plan: PortfolioActionPlan, portfolio: PortfolioSnapshot
    ) -> [AssetClass: Decimal] {
        var weightsBySubject = Dictionary(
            uniqueKeysWithValues: portfolio.positions.map { ($0.subjectKey, $0.weight.value) }
        )
        for item in plan.actions {
            weightsBySubject[item.action.subjectKey, default: .zero] += item.action.deltaWeight.value
        }
        var byClass: [AssetClass: Decimal] = [:]
        for position in portfolio.positions {
            byClass[position.assetClass, default: .zero] += weightsBySubject[position.subjectKey] ?? .zero
        }
        return byClass
    }
}

/// Criterion 输入提取器（六轮 P1-1 + 七轮 P1）。
///
/// 输入值的**唯一合法来源**：
/// - `planMetric`：从 (plan, portfolio) 强类型推导的方案各自指标
///   （turnover / 投影资产类权重）——方案间 criterion 差异的唯一通道；
/// - `factorMetric`：按「`<snapshotID>#<metricKey>`」约定从 FactorSnapshot
///   实例的 metrics 提取（决策级共享 cardinal）；
/// - `observation`：从 CardinalObservation 实例取 value（决策级共享）。
///
/// resolver / 调用方不提供任何 Decimal，ordinal signal 不存在转换通道
/// （七轮 P1：没有可测量来源的 signal 保持 narrative，不进数学运算）。
enum CriterionInputExtractor: Sendable {
    enum ExtractionError: Error, Equatable, Sendable {
        /// factorMetric 引用 ID 不符合「<snapshotID>#<metricKey>」约定
        case malformedFactorReference(String)
        /// planMetric 引用 ID 不在 PlanMetrics 封闭命名空间内
        case malformedPlanMetricReference(String)
    }

    static func inputs(
        definition: CriterionDefinition,
        plan: PortfolioActionPlan,
        portfolio: PortfolioSnapshot,
        factorSnapshots: [String: FactorSnapshot],
        observations: [String: CardinalObservation]
    ) throws -> [CriterionInput] {
        try definition.inputReferences.map { reference in
            switch reference.kind {
            case .planMetric:
                return CriterionInput(
                    referenceID: reference.referenceID,
                    value: try planMetricValue(reference.referenceID, plan: plan, portfolio: portfolio)
                )
            case .factorMetric:
                let parts = reference.referenceID.split(separator: "#", maxSplits: 1)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw ExtractionError.malformedFactorReference(reference.referenceID)
                }
                let value = factorSnapshots[String(parts[0])]?
                    .metrics.first { $0.definition.key == String(parts[1]) }?.value
                return CriterionInput(referenceID: reference.referenceID, value: value)
            case .observation:
                let value = observations[reference.referenceID].map(\.value)
                return CriterionInput(referenceID: reference.referenceID, value: value)
            }
        }
    }

    /// plan-scoped 指标取值（命名空间封闭，fail-closed）。
    private static func planMetricValue(
        _ referenceID: String,
        plan: PortfolioActionPlan,
        portfolio: PortfolioSnapshot
    ) throws -> Decimal? {
        if referenceID == PlanMetrics.turnover {
            return PlanMetrics.turnover(of: plan)
        }
        if referenceID.hasPrefix(PlanMetrics.projectedWeightPrefix + "#") {
            let raw = String(referenceID.dropFirst(PlanMetrics.projectedWeightPrefix.count + 1))
            guard let assetClass = AssetClass(rawValue: raw) else {
                throw ExtractionError.malformedPlanMetricReference(referenceID)
            }
            return PlanMetrics.projectedAssetClassWeights(of: plan, portfolio: portfolio)[assetClass]
        }
        throw ExtractionError.malformedPlanMetricReference(referenceID)
    }
}
