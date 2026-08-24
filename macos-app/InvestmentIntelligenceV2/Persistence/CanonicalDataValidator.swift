import Foundation

// MARK: - CanonicalDataValidator（GRDB-8，四防火墙之三：语义校验）

/// CanonicalObservation 的语义级校验（结构在 ProviderRecordSchemaValidator、
/// identity 在 IdentityResolver、时间在 TemporalNormalizer，各自在前置阶段）。
///
/// 校验的是「值在业务上自洽」：四时间不变量、OHLC 交叉关系、正性约束、
/// 权重界、期间序。全部通过才允许进入 Canonical Commit——错值不进库，
/// 下游（Factor / Risk / Attribution）无需再防脏数据。
struct CanonicalDataValidator: Sendable {

    /// 语义违规（拒收原因，进入 Pipeline 的 Rejection 报告）。
    enum Violation: Error, Equatable, Sendable, CustomStringConvertible {
        /// 四时间不变量（effective ≤ published ≤ available）
        case envelopeInvariant(detail: String)
        /// rawLow > min(open, close) 或 rawHigh < max(open, close)
        case barOHLCTopology(open: String, high: String, low: String, close: String)
        /// 价格 / 复权因子 / NAV 非正
        case nonPositiveValue(field: String, value: String)
        /// 持仓权重出界（< 0 或 > 1）或披露覆盖总权出界
        case holdingWeightOutOfRange(weight: String)
        /// 公司行动比例非正
        case actionRatioNonPositive(ratio: String)
        /// 基本面期间倒置（periodStart > periodEnd）
        case fundamentalPeriodReversed(start: String, end: String)

        var description: String {
            switch self {
            case .envelopeInvariant(let d): return "四时间不变量违反：\(d)"
            case .barOHLCTopology: return "OHLC 拓扑不一致（low ≤ open/close ≤ high 不成立）"
            case .nonPositiveValue(let f, let v): return "\(f) 非正：\(v)"
            case .holdingWeightOutOfRange(let w): return "持仓权重出界 [0,1]：\(w)"
            case .actionRatioNonPositive(let r): return "公司行动比例非正：\(r)"
            case .fundamentalPeriodReversed: return "基本面期间倒置（periodStart > periodEnd）"
            }
        }
    }

    /// 校验单条观测；违规抛 `Violation`。
    func validate(_ observation: CanonicalObservationKind) throws {
        switch observation {
        case .dailyBar(let bar):
            try validateEnvelope(bar.temporalEnvelope)
            // OHLC 拓扑：low ≤ min(open, close)，high ≥ max(open, close)
            let bodyMin = min(bar.rawOpen.value, bar.rawClose.value)
            let bodyMax = max(bar.rawOpen.value, bar.rawClose.value)
            if bar.rawLow.value > bodyMin || bar.rawHigh.value < bodyMax {
                throw Violation.barOHLCTopology(
                    open: describe(bar.rawOpen.value), high: describe(bar.rawHigh.value),
                    low: describe(bar.rawLow.value), close: describe(bar.rawClose.value)
                )
            }
            try requirePositive(bar.rawLow.value, field: "rawLow")
            try requirePositive(bar.adjustmentFactor, field: "adjustmentFactor")

        case .navObservation(let nav):
            try validateEnvelope(nav.temporalEnvelope)
            try requirePositive(nav.unitNAV.value, field: "unitNAV")

        case .fundHoldingSnapshot(let snapshot):
            try validateEnvelope(snapshot.temporalEnvelope)
            for position in snapshot.positions {
                guard position.weight.value >= 0, position.weight.value <= 1 else {
                    throw Violation.holdingWeightOutOfRange(weight: describe(position.weight.value))
                }
            }
            // 披露覆盖总权 ∈ [0, 1]（1 的万分位容差：浮点来源的权重合计）
            let total = snapshot.disclosedWeightTotal.value
            guard total >= 0, total <= Decimal(string: "1.0001")! else {
                throw Violation.holdingWeightOutOfRange(weight: describe(total))
            }

        case .macroObservation(let macro):
            try validateEnvelope(macro.temporalEnvelope)

        case .corporateAction(let action):
            try validateEnvelope(action.temporalEnvelope)
            try requirePositive(action.ratio, field: "action.ratio")

        case .fundamentalObservation(let fundamental):
            try validateEnvelope(fundamental.temporalEnvelope)
            if let start = fundamental.periodStart, start > fundamental.periodEnd {
                throw Violation.fundamentalPeriodReversed(
                    start: CanonicalColumnCodec.encodeTimestamp(start),
                    end: CanonicalColumnCodec.encodeTimestamp(fundamental.periodEnd)
                )
            }
        }
    }

    // MARK: - Helpers

    private func validateEnvelope(_ envelope: TemporalEnvelope) throws {
        if let violation = envelope.validate() {
            throw Violation.envelopeInvariant(detail: String(describing: violation))
        }
    }

    private func requirePositive(_ value: Decimal, field: String) throws {
        guard value > 0 else {
            throw Violation.nonPositiveValue(field: field, value: describe(value))
        }
    }

    private func describe(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description
    }
}
