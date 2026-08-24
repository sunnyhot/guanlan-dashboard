import Foundation

// MARK: - FactorMath（FAC-3..7 共享的纯数学 helper）
//
// 全部纯函数、Decimal 运算（同输入同输出，D002 确定性）。
// 窗口语义统一为「尾部 N 根 bar」计数（停牌日无 bar，自然跳过），
// 不用日历日——披露缺口与节假日不影响窗口含义。

enum FactorMath {
    /// 尾部 n 根的算术平均；不足 n 根返回 nil（不猜）。
    static func tailMean(_ values: [Decimal], count n: Int) -> Decimal? {
        guard values.count >= n, n > 0 else { return nil }
        let window = values.suffix(n)
        let sum = window.reduce(Decimal.zero, +)
        return sum / Decimal(n)
    }

    /// 右端索引 idx（含）往前 n 根的算术平均；越界返回 nil。
    /// 调用方保证 idx 在数组范围内。
    static func mean(endingAt idx: Int, window n: Int, in values: [Decimal]) -> Decimal? {
        guard n > 0, idx >= n - 1, idx < values.count else { return nil }
        let window = values[(idx - n + 1)...idx]
        let sum = window.reduce(Decimal.zero, +)
        return sum / Decimal(n)
    }

    /// newer / older − 1（区间比率变化）。
    static func relativeChange(from older: Decimal, to newer: Decimal) -> Decimal {
        newer / older - 1
    }
}

// MARK: - TrendFactorCalculator（FAC-3）

/// 趋势因子：价格与移动平均的关系（4 个 metric）。
///
/// 定义（全部基于复权收盘、尾部 bar 计数窗口）：
/// - `trend.closeVsMA20` = close_t / MA20_t − 1（≥20 根）
/// - `trend.closeVsMA60` = close_t / MA60_t − 1（≥60 根）
/// - `trend.ma20Slope` = MA20_t / MA20_{t−h} − 1（≥20+h 根，h=slopeHorizon）
/// - `trend.ma60Slope` = MA60_t / MA60_{t−h} − 1（≥60+h 根）
///
/// slopeHorizon 是 versioned 参数（definition parameters 声明，默认 5 个
/// 交易日）；MA 与 slope 公式变更走 definition version bump。
struct TrendFactorCalculator: FactorCalculator {
    let slopeHorizon: Int

    init(slopeHorizon: Int = 5) {
        self.slopeHorizon = slopeHorizon
    }

    private let closeVsMA20Window = 20
    private let closeVsMA60Window = 60

    var definitions: [FactorDefinition] {
        [
            FactorDefinition(
                key: "trend.closeVsMA20", version: "v1", unit: .ratio,
                parameters: [.init(name: "windowBars", intValue: closeVsMA20Window)]
            ),
            FactorDefinition(
                key: "trend.closeVsMA60", version: "v1", unit: .ratio,
                parameters: [.init(name: "windowBars", intValue: closeVsMA60Window)]
            ),
            FactorDefinition(
                key: "trend.ma20Slope", version: "v1", unit: .ratio,
                parameters: [
                    .init(name: "windowBars", intValue: closeVsMA20Window),
                    .init(name: "slopeHorizon", intValue: slopeHorizon),
                ]
            ),
            FactorDefinition(
                key: "trend.ma60Slope", version: "v1", unit: .ratio,
                parameters: [
                    .init(name: "windowBars", intValue: closeVsMA60Window),
                    .init(name: "slopeHorizon", intValue: slopeHorizon),
                ]
            ),
        ]
    }

    func compute(inputs: FactorInputs) -> [FactorMetric] {
        let closes = inputs.assetSeries.map(\.adjustedClose)
        let defs = definitions
        var metrics: [FactorMetric] = []

        // closeVsMA(w)：close 对尾部 w 根均值的偏离
        func closeVsMA(_ w: Int) -> Decimal? {
            guard closes.count >= w,
                  let ma = FactorMath.tailMean(closes, count: w),
                  let last = closes.last
            else { return nil }
            return FactorMath.relativeChange(from: ma, to: last)
        }

        // maSlope(w, h)：尾部 MA(w) 相对 h 根前 MA(w) 的变化率
        func maSlope(_ w: Int, horizon h: Int) -> Decimal? {
            let lastIdx = closes.count - 1
            guard let now = FactorMath.mean(endingAt: lastIdx, window: w, in: closes),
                  let past = FactorMath.mean(endingAt: lastIdx - h, window: w, in: closes)
            else { return nil }
            return FactorMath.relativeChange(from: past, to: now)
        }

        let closeVs20 = closeVsMA(closeVsMA20Window)
        let closeVs60 = closeVsMA(closeVsMA60Window)
        let slope20 = maSlope(closeVsMA20Window, horizon: slopeHorizon)
        let slope60 = maSlope(closeVsMA60Window, horizon: slopeHorizon)

        metrics.append(makeMetric(defs[0], value: closeVs20, requiredBars: closeVsMA20Window, actual: closes.count))
        metrics.append(makeMetric(defs[1], value: closeVs60, requiredBars: closeVsMA60Window, actual: closes.count))
        metrics.append(makeMetric(defs[2], value: slope20, requiredBars: closeVsMA20Window + slopeHorizon, actual: closes.count))
        metrics.append(makeMetric(defs[3], value: slope60, requiredBars: closeVsMA60Window + slopeHorizon, actual: closes.count))
        return metrics
    }

    private func makeMetric(
        _ def: FactorDefinition, value: Decimal?, requiredBars: Int, actual: Int
    ) -> FactorMetric {
        if let value {
            return FactorMetric(definition: def, value: value)
        }
        return FactorMetric(definition: def, insufficiency: .init(
            reason: actual == 0 ? .emptySeries : .insufficientBars,
            requiredBars: requiredBars,
            actualBars: actual
        ))
    }
}
