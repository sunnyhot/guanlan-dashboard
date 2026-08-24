import Foundation

// MARK: - RelativeStrengthFactorCalculator（FAC-7）

/// 相对强度因子：asset 与显式 benchmark 的区间收益差（2 个 metric）。
///
/// 定义：`relativeStrength.vsBenchmark{w}` = assetRet_w − benchmarkRet_w，
/// 其中 Ret_w = close_t / close_{t−w} − 1（各自序列的尾部 bar 计数窗口）。
///
/// **benchmark 必须显式声明**（FAC-7 验收）：calculator 构造参数
/// benchmarkListingID 写进 definition parameters，不存在隐式默认 benchmark；
/// 未指定 benchmark 时引擎传空序列，本 calculator 产 benchmarkMissing
/// 而不是猜一个大盘代理。
///
/// **日期对齐策略（显式语义决策）**：asset 与 benchmark 各自独立取尾部
/// w 根区间收益，不做逐日对齐——跨市场标的（A 股 asset vs 美股 benchmark）
/// 交易日历天然不同，强制逐日对齐会引入对齐启发式（哪天补、怎么补都是
/// 猜测）。PIT 语义下两侧都来自同一 KnowledgeContext，对比口径一致。
struct RelativeStrengthFactorCalculator: FactorCalculator {
    let benchmarkListingID: ListingID?
    let windows: [Int]

    init(benchmarkListingID: ListingID?, windows: [Int] = [20, 60]) {
        self.benchmarkListingID = benchmarkListingID
        self.windows = windows
    }

    var definitions: [FactorDefinition] {
        windows.map { w in
            FactorDefinition(
                key: "relativeStrength.vsBenchmark\(w)", version: "v1", unit: .ratio,
                parameters: [
                    .init(name: "windowBars", intValue: w),
                    .init(name: "benchmarkListingID", value: benchmarkListingID?.rawValue ?? ""),
                    .init(name: "alignment", value: "independent-tail"),
                ]
            )
        }
    }

    func compute(inputs: FactorInputs) -> [FactorMetric] {
        let asset = inputs.assetSeries.map(\.adjustedClose)
        let benchmark = inputs.benchmarkSeries.map(\.adjustedClose)

        return definitions.map { def in
            let w = def.parameters.first { $0.name == "windowBars" }?.intValue ?? 0

            // benchmark 侧缺失（未指定 / 无数据）→ benchmarkMissing，不猜代理
            guard benchmarkListingID != nil, !benchmark.isEmpty else {
                return FactorMetric(definition: def, insufficiency: .init(
                    reason: .benchmarkMissing, requiredBars: w + 1, actualBars: benchmark.count
                ))
            }
            guard let assetReturn = windowReturn(asset, window: w),
                  let benchmarkReturn = windowReturn(benchmark, window: w)
            else {
                // actualBars 报瓶颈侧（谁不足一目了然；两侧同时不足时报较小者）
                return FactorMetric(definition: def, insufficiency: .init(
                    reason: .insufficientBars,
                    requiredBars: w + 1,
                    actualBars: min(asset.count, benchmark.count)
                ))
            }
            return FactorMetric(definition: def, value: assetReturn - benchmarkReturn)
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
