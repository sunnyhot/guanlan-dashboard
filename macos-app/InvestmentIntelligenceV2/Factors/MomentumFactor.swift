import Foundation

// MARK: - MomentumFactorCalculator（FAC-4）

/// 动量因子：区间收益（3 个 metric）。
///
/// 定义（复权收盘、尾部 bar 计数窗口）：
/// - `momentum.return20` = close_t / close_{t−20} − 1（≥21 根）
/// - `momentum.return60` = close_t / close_{t−60} − 1（≥61 根）
/// - `momentum.return120` = close_t / close_{t−120} − 1（≥121 根）
///
/// 复权价直接相除已消除分红 / 拆股的假跳空（adjustedClose 语义），
/// 无需额外分红再投资处理。
struct MomentumFactorCalculator: FactorCalculator {
    private let windows = [20, 60, 120]

    var definitions: [FactorDefinition] {
        windows.map { w in
            FactorDefinition(
                key: "momentum.return\(w)", version: "v1", unit: .ratio,
                parameters: [.init(name: "windowBars", intValue: w)]
            )
        }
    }

    func compute(inputs: FactorInputs) -> [FactorMetric] {
        let closes = inputs.assetSeries.map(\.adjustedClose)
        return definitions.map { def in
            let w = def.parameters.first { $0.name == "windowBars" }?.intValue ?? 0
            let value = windowReturn(closes, window: w)
            if let value {
                return FactorMetric(definition: def, value: value)
            }
            return FactorMetric(definition: def, insufficiency: .init(
                reason: closes.isEmpty ? .emptySeries : .insufficientBars,
                requiredBars: w + 1,
                actualBars: closes.count
            ))
        }
    }

    /// close_t / close_{t−w} − 1；不足 w+1 根返回 nil。
    private func windowReturn(_ closes: [Decimal], window w: Int) -> Decimal? {
        guard w > 0, closes.count >= w + 1 else { return nil }
        let newer = closes[closes.count - 1]
        let older = closes[closes.count - 1 - w]
        return FactorMath.relativeChange(from: older, to: newer)
    }
}
