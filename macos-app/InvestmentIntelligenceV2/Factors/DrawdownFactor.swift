import Foundation

// MARK: - DrawdownFactorCalculator（FAC-6）

/// 回撤因子：252 个交易日窗口的当前 / 最大回撤（2 个 metric）。
///
/// 定义（复权收盘、尾部 bar 计数窗口）：
/// - `drawdown.current252` = close_t / max(尾部 ≤252 根) − 1（≤ 0；
///   收盘恰为窗口最高时为 0）
/// - `drawdown.max252` = 窗口内逐点回撤的最小值
///   min_i(close_i / max(窗口前缀) − 1)（≤ 0；单调上涨窗口为 0）
///
/// 窗口语义是**上限（cap）**而非精确值：不足 252 根时用全部可得 bar——
/// 「过去一年最大回撤」在上市不满一年时仍良定义（与 MA20 不足 20 根时
/// 均值失去意义不同）。实际 bar 数记录在 FactorSnapshot.assetCoverage，
/// 由下游判断可信度。窗口政策差异在 definition parameters 显式声明。
struct DrawdownFactorCalculator: FactorCalculator {
    let windowBars: Int

    init(windowBars: Int = 252) {
        self.windowBars = windowBars
    }

    var definitions: [FactorDefinition] {
        [
            FactorDefinition(
                key: "drawdown.current252", version: "v1", unit: .ratio,
                parameters: [
                    .init(name: "windowBars", intValue: windowBars),
                    .init(name: "windowPolicy", value: "cap"),
                ]
            ),
            FactorDefinition(
                key: "drawdown.max252", version: "v1", unit: .ratio,
                parameters: [
                    .init(name: "windowBars", intValue: windowBars),
                    .init(name: "windowPolicy", value: "cap"),
                ]
            ),
        ]
    }

    func compute(inputs: FactorInputs) -> [FactorMetric] {
        let closes = inputs.assetSeries.map(\.adjustedClose)
        let defs = definitions

        guard !closes.isEmpty else {
            return defs.map {
                FactorMetric(definition: $0, insufficiency: .init(
                    reason: .emptySeries, requiredBars: 1, actualBars: 0
                ))
            }
        }

        let window = Array(closes.suffix(windowBars))
        // 窗口内逐点回撤（含 running max 单调化）
        var runningMax = window[0]
        var maxDrawdown = Decimal.zero
        for close in window {
            runningMax = max(runningMax, close)
            let drawdown = FactorMath.relativeChange(from: runningMax, to: close)
            maxDrawdown = min(maxDrawdown, drawdown)
        }
        let currentDrawdown = FactorMath.relativeChange(from: runningMax, to: window[window.count - 1])

        var metrics: [FactorMetric] = [
            FactorMetric(definition: defs[0], value: currentDrawdown)
        ]
        // maxDrawdown 至少需要一个「高点之后的点」才有定义；单根窗口恒 0 无信息量
        if window.count >= 2 {
            metrics.append(FactorMetric(definition: defs[1], value: maxDrawdown))
        } else {
            metrics.append(FactorMetric(definition: defs[1], insufficiency: .init(
                reason: .insufficientBars, requiredBars: 2, actualBars: window.count
            )))
        }
        return metrics
    }
}
