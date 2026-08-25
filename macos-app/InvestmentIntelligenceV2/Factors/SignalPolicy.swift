import Foundation

// MARK: - SignalPolicy（FAC-2，Epic 7）
//
// Cardinal / Ordinal 防火墙（V3.1 §46 / D002）：
// - Factor 引擎只产 metric（Decimal + unit，cardinal）
// - metric → ordinal signal（bullish / bearish / neutral）的转换是**策略**，
//   不是事实——分类阈值是人为选择的 policy parameter，必须 versioned 且
//   带 provenance 标注（与 IndifferenceBand 的 heuristicPolicy 同一纪律）
// - ordinal 一旦产生不可再进 cardinal 运算：OrdinalFactorSignal 刻意不携带
//   任何数值字段，类型上无法把方向变回数字
//
// 数据不足联动（ADR-DATA006）：metric value == nil → direction = .uncertain，
// 不猜方向。

/// 阈值来源分类（FAC-2：阈值 provenance 可审计）。
enum SignalThresholdBasis: String, Sendable, Codable, Hashable {
    /// 人为选定的经验阈值（默认档；必须附 rationale 说明依据）
    case heuristic = "HEURISTIC"
    /// 从数据分布推导（如历史分位数；需记录样本窗口）
    case empiricalQuantile = "EMPIRICAL_QUANTILE"
    /// 文献 / 公开研究引用
    case literature = "LITERATURE"
}

/// SignalPolicy 的 provenance（policy 身份 + 阈值依据）。
struct SignalPolicyProvenance: Sendable, Codable, Hashable {
    /// policy 稳定标识（如 "trend-ordinal"）
    let policyID: String
    /// policy 版本（阈值调整必须 bump，历史 ordinal 可重放）
    let policyVersion: String
    let basis: SignalThresholdBasis
    /// 阈值依据说明（heuristic 时必填，why this band）
    let rationale: String?
    /// empiricalQuantile 时的样本窗口描述（其他 basis 为 nil）
    let quantileSampleWindow: String?

    init(
        policyID: String,
        policyVersion: String,
        basis: SignalThresholdBasis,
        rationale: String? = nil,
        quantileSampleWindow: String? = nil
    ) {
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.basis = basis
        self.rationale = rationale
        self.quantileSampleWindow = quantileSampleWindow
    }
}

/// 单条阈值带规则：metricKey + 半开区间 [lower, upper) → direction。
struct SignalBandRule: Sendable, Codable, Hashable {
    /// 匹配的 FactorDefinition.key
    let metricKey: String
    /// 下界（含）；nil = 负无穷
    let lowerBound: Decimal?
    /// 上界（不含）；nil = 正无穷
    let upperBound: Decimal?
    let direction: SignalDirection
    let strength: SignalStrength

    init(
        metricKey: String,
        lowerBound: Decimal?,
        upperBound: Decimal?,
        direction: SignalDirection,
        strength: SignalStrength
    ) {
        self.metricKey = metricKey
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.direction = direction
        self.strength = strength
    }

    /// 值是否落入本带（lower ≤ x < upper）。
    func contains(_ value: Decimal) -> Bool {
        if let lower = lowerBound, value < lower { return false }
        if let upper = upperBound, value >= upper { return false }
        return true
    }
}

/// ordinal 因子信号（FAC-2 产出）。
///
/// **不携带任何 cardinal 字段**（刻意）：direction / strength 是序数语义，
/// 类型上没有数值可取，ordinal 无法回流 cardinal 运算（V3.1 §46）。
/// 需要数值时回到 FactorSnapshot 的 metric，不走本类型。
struct OrdinalFactorSignal: Sendable, Codable, Hashable {
    /// 对应的 FactorDefinition.key（溯源到 metric，不含 metric 值）
    let metricKey: String
    /// metric 的定义版本（重放时定位是哪版公式的产出）
    let factorDefinitionVersion: String
    let direction: SignalDirection
    let strength: SignalStrength
    /// 产生本 signal 的 SignalPolicy provenance（阈值可审计）
    let policyProvenance: SignalPolicyProvenance

    init(
        metricKey: String,
        factorDefinitionVersion: String,
        direction: SignalDirection,
        strength: SignalStrength,
        policyProvenance: SignalPolicyProvenance
    ) {
        self.metricKey = metricKey
        self.factorDefinitionVersion = factorDefinitionVersion
        self.direction = direction
        self.strength = strength
        self.policyProvenance = policyProvenance
    }
}

/// versioned SignalPolicy：metric → ordinal（FAC-2）。
///
/// 转换语义：
/// - metric value == nil（输入不足）→ .uncertain（不猜，ADR-DATA006）
/// - 规则按 metricKey 匹配、按声明顺序取**第一条**命中带（policy 内顺序
///   是定义的一部分，重放稳定）
/// - 无任何规则命中（缝隙 / 无该 key 的规则）→ .uncertain
///   （fail-open 到不确定，不默认 neutral——「没规则」≠「中性」）
struct SignalPolicy: Sendable, Codable, Hashable {
    let provenance: SignalPolicyProvenance
    let rules: [SignalBandRule]

    init(provenance: SignalPolicyProvenance, rules: [SignalBandRule]) {
        self.provenance = provenance
        self.rules = rules
    }

    /// 单个 metric → ordinal signal。
    func ordinalSignal(for metric: FactorMetric) -> OrdinalFactorSignal {
        guard let value = metric.value else {
            return OrdinalFactorSignal(
                metricKey: metric.definition.key,
                factorDefinitionVersion: metric.definition.version,
                direction: .uncertain,
                strength: .weak,
                policyProvenance: provenance
            )
        }
        let matched = rules
            .filter { $0.metricKey == metric.definition.key }
            .first { $0.contains(value) }
        return OrdinalFactorSignal(
            metricKey: metric.definition.key,
            factorDefinitionVersion: metric.definition.version,
            direction: matched?.direction ?? .uncertain,
            strength: matched?.strength ?? .weak,
            policyProvenance: provenance
        )
    }

    /// 整个 snapshot 的 metrics → ordinal signals（顺序随 metrics）。
    func signals(from snapshot: FactorSnapshot) -> [OrdinalFactorSignal] {
        snapshot.metrics.map { ordinalSignal(for: $0) }
    }
}

// MARK: - 预置 policy（v1，全部 heuristic 显式标注）

extension SignalPolicy {
    /// 趋势 / 动量类 ratio metric 的三带划分工厂（对给定 metricKeys 各生成三条带）。
    /// heuristic 依据：±2% 为常见「突破 / 跌破」经验带；阈值调整走 v2。
    static func trendRatioV1(metricKeys: [String]) -> SignalPolicy {
        let bands: [(Decimal?, Decimal?, SignalDirection, SignalStrength)] = [
            (nil, Decimal(string: "-0.02")!, .bearish, .strong),
            (Decimal(string: "-0.02")!, Decimal(string: "-0.005")!, .bearish, .weak),
            (Decimal(string: "-0.005")!, Decimal(string: "0.005")!, .neutral, .weak),
            (Decimal(string: "0.005")!, Decimal(string: "0.02")!, .bullish, .weak),
            (Decimal(string: "0.02")!, nil, .bullish, .strong),
        ]
        let rules = metricKeys.flatMap { key in
            bands.map { lower, upper, direction, strength in
                SignalBandRule(
                    metricKey: key, lowerBound: lower, upperBound: upper,
                    direction: direction, strength: strength
                )
            }
        }
        return SignalPolicy(
            provenance: SignalPolicyProvenance(
                policyID: "trend-ratio",
                policyVersion: "v1",
                basis: .heuristic,
                rationale: "±2% 为趋势显著带经验值（突破/跌破惯用阈值），±0.5% 内视为中性"
            ),
            rules: rules
        )
    }
}

// MARK: - SignalCardinalPolicy（ordinal → cardinal 的 versioned 回流口，六轮 P1-1）
//
// D002：criterion 只吃 cardinal；ordinal signal 需经 versioned policy 转换。
// 映射值是人为选定的 policy parameter（不是事实），必须 versioned 且带
// rationale（与 SignalPolicy / IndifferenceBand 同一纪律）；决策 artifact
// 引用其版本，重放时按版本取转换，不受后续调参影响。

/// versioned ordinal→cardinal 转换 policy。
struct SignalCardinalPolicy: Sendable, Codable, Hashable {
    let policyID: String
    let version: String
    /// direction × strength → Decimal 映射（uncertain 不入映射——恒 unknown）
    let mapping: [SignalDirection: [SignalStrength: Decimal]]
    /// heuristic 理由（必填语义：空串视为未标注，init 拒绝）
    let rationale: String

    init(
        policyID: String,
        version: String,
        mapping: [SignalDirection: [SignalStrength: Decimal]],
        rationale: String
    ) {
        precondition(!rationale.trimmingCharacters(in: .whitespaces).isEmpty,
                     "signal cardinal 转换必须标注 rationale（D002 不允许静默）")
        self.policyID = policyID
        self.version = version
        self.mapping = mapping
        self.rationale = rationale
    }

    var versionedID: String { "\(policyID)@\(version)" }

    /// ordinal signal → cardinal。uncertain / 映射缺失 → nil（unknown，不猜）。
    func cardinal(for signal: InvestmentSignal) -> Decimal? {
        guard signal.direction.isDeterministic else { return nil }
        return mapping[signal.direction]?[signal.strength]
    }

    /// 预置 v1：对称三档（bullish 正 / bearish 负 / neutral 0）。
    /// heuristic 依据：strength 三档按 1 / 0.6 / 0.2 线性衰减，中性恒 0；
    /// 映射值调整必须 bump version（历史决策按旧版重放）。
    static func symmetricV1() -> SignalCardinalPolicy {
        SignalCardinalPolicy(
            policyID: "signal-cardinal-symmetric",
            version: "v1",
            mapping: [
                .bullish: [.strong: Decimal(string: "1")!, .moderate: Decimal(string: "0.6")!, .weak: Decimal(string: "0.2")!],
                .bearish: [.strong: Decimal(string: "-1")!, .moderate: Decimal(string: "-0.6")!, .weak: Decimal(string: "-0.2")!],
                .neutral: [.strong: .zero, .moderate: .zero, .weak: .zero],
            ],
            rationale: "对称三档经验映射（±1/±0.6/±0.2，neutral=0）；仅作 criterion 加权通道的量纲约定"
        )
    }
}
