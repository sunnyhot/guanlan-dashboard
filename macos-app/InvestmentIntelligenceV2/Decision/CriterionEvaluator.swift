import Foundation

// MARK: - CriterionEvaluator（DEC-7，Epic 10，ADR-D002）
//
// Criterion 是 cardinal 量（Decimal + 单位），由 versioned deterministic
// evaluator 算出。**黑箱 criterion 禁止（D002）**：
// - 输入只能是 cardinal（factor metric / observation value / 经 SignalPolicy
//   转换后的 cardinal）——CriterionInput 不接受 ordinal signal
// - LLM 不产分：LLM 影响只能经 Signal → SignalPolicy → cardinal → 本 evaluator
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
            case factorMetric = "FACTOR_METRIC"
            /// 经 SignalPolicy（FAC-2）转换后的 cardinal（ordinal 不直接进）
            case signalCardinal = "SIGNAL_CARDINAL"
        }
    }

    var fingerprint: String { "\(id)@\(version)" }
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
