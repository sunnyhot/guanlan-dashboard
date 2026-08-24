import Foundation

// MARK: - VolatilityFactorCalculator（FAC-5）

/// 波动率因子：已实现波动（2 个 metric）。
///
/// 定义（复权收盘、尾部 bar 计数窗口）：
/// - `volatility.realized20`：尾部 20 个日收益率 r_i = c_i/c_{i−1} − 1 的
///   **样本**标准差（Bessel n−1 分母）：sqrt(Σ(r−r̄)²/(n−1))，≥21 根
/// - `volatility.realized60`：同理 60 个收益率，≥61 根
///
/// unit = ratioPerDay（日频波动，不年化——年化系数 252 是展示层策略，
/// 不是因子定义的一部分；跨标的比较在相同日频单位下已公平）。
struct VolatilityFactorCalculator: FactorCalculator {
    let windows: [Int]

    init(windows: [Int] = [20, 60]) {
        self.windows = windows
    }

    var definitions: [FactorDefinition] {
        windows.map { w in
            FactorDefinition(
                key: "volatility.realized\(w)", version: "v1", unit: .ratioPerDay,
                parameters: [
                    .init(name: "windowReturns", intValue: w),
                    .init(name: "denominator", value: "n-1"),
                ]
            )
        }
    }

    func compute(inputs: FactorInputs) -> [FactorMetric] {
        let closes = inputs.assetSeries.map(\.adjustedClose)
        return definitions.map { def in
            let w = def.parameters.first { $0.name == "windowReturns" }?.intValue ?? 0
            if let value = realizedVol(closes, returns: w) {
                return FactorMetric(definition: def, value: value)
            }
            return FactorMetric(definition: def, insufficiency: .init(
                reason: closes.isEmpty ? .emptySeries : .insufficientBars,
                requiredBars: w + 1,
                actualBars: closes.count
            ))
        }
    }

    /// 尾部 w 个日收益率的样本标准差；不足 w+1 根返回 nil。
    private func realizedVol(_ closes: [Decimal], returns w: Int) -> Decimal? {
        guard w > 1, closes.count >= w + 1 else { return nil }
        let last = closes.count - 1
        var returns: [Decimal] = []
        returns.reserveCapacity(w)
        for i in (last - w + 1)...last {
            returns.append(FactorMath.relativeChange(from: closes[i - 1], to: closes[i]))
        }
        let n = Decimal(returns.count)
        let mean = returns.reduce(Decimal.zero, +) / n
        let sumSquaredDeviation = returns.reduce(Decimal.zero) { $0 + ($1 - mean) * ($1 - mean) }
        let variance = sumSquaredDeviation / (n - 1)
        return variance.decimalSquareRoot()
    }
}
