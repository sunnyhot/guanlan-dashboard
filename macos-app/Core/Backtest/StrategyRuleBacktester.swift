import Foundation

// MARK: - 回测报告

/// 策略技能规则级回测报告。定位：验证技能 prompt 中的量化条件是否有统计优势，
/// 不做参数寻优（防过拟合；寻优待 L8 验证有价值后评估）。
struct BacktestReport: Codable, Hashable, Sendable {
    struct Trade: Codable, Hashable, Sendable {
        let entryDate: String
        let exitDate: String
        let entryPrice: Double
        let exitPrice: Double
        let returnPct: Double
        let exitReason: String
    }

    let skillID: String
    let subjectCode: String
    let sampleCount: Int
    let winRate: Double?          // wins / (wins + losses)；未了结不计入
    let profitFactor: Double?     // 总盈利 / 总亏损
    let avgReturnPct: Double?
    let maxDrawdownPct: Double?
    let trades: [Trade]
    let dataBoundary: String

    var isSampleSufficient: Bool { sampleCount >= 30 }
}

// MARK: - 回测器

/// 规则级回测器：在历史 K 线上逐日求值可计算的技能条件（MA 金叉/缩量回踩/放量突破/箱体/一阳夹三阴），
/// 信号次日开盘入场，固定止损止盈或 MA20 破位平仓，输出统计。
///
/// 与 L2 引擎的关系：指标计算全部复用 TechnicalAnalysisEngine，保证回测口径与实盘研判一致。
enum StrategyRuleBacktester {
    struct Config {
        var stopLossPct: Double = 0.05      // 5% 止损
        var takeProfitPct: Double = 0.08    // 8% 止盈
        var useMA20Exit: Bool = true        // 收盘跌破 MA20 平仓
        var cooldownBars: Int = 5           // 出场后冷却 K 线数

        init(stopLossPct: Double = 0.05, takeProfitPct: Double = 0.08, useMA20Exit: Bool = true, cooldownBars: Int = 5) {
            self.stopLossPct = stopLossPct
            self.takeProfitPct = takeProfitPct
            self.useMA20Exit = useMA20Exit
            self.cooldownBars = cooldownBars
        }
    }

    static func backtest(
        skillID: String,
        bars: [MarketDailyBar],
        config: Config = Config()
    ) -> BacktestReport {
        let sorted = bars.sorted { $0.date < $1.date }
        guard sorted.count >= 35 else {
            return BacktestReport(
                skillID: skillID, subjectCode: "", sampleCount: 0,
                winRate: nil, profitFactor: nil, avgReturnPct: nil, maxDrawdownPct: nil,
                trades: [], dataBoundary: "K 线不足（\(sorted.count) 根 < 35），无法回测"
            )
        }

        var trades: [BacktestReport.Trade] = []
        var cooldown = 0
        var index = 35 // 预热：保证 MA20/MACD 样本可用

        while index < sorted.count - 1 {
            if cooldown > 0 {
                cooldown -= 1
                index += 1
                continue
            }
            let history = Array(sorted[0...index])
            guard let current = history.last else { break }
            let analysis = TechnicalAnalysisEngine.analyze(code: "backtest", bars: history)

            guard signalTriggered(skillID: skillID, analysis: analysis, currentBar: current) else {
                index += 1
                continue
            }

            // 次日开盘入场
            let entryIndex = index + 1
            let entry = sorted[entryIndex]
            let entryPrice = entry.open
            guard entryPrice > 0 else {
                index += 1
                continue
            }
            let stop = entryPrice * (1 - config.stopLossPct)
            let target = entryPrice * (1 + config.takeProfitPct)

            // 持仓扫描：同根先止损（与信号结算同口径）
            var exitIndex = entryIndex
            var exitPrice = entry.close
            var exitReason = "期末平仓"
            var settled = false
            for scan in entryIndex..<sorted.count {
                let bar = sorted[scan]
                if bar.low <= stop {
                    exitPrice = bar.open <= stop ? bar.open : stop
                    exitIndex = scan
                    exitReason = "止损"
                    settled = true
                    break
                }
                if bar.high >= target {
                    exitPrice = bar.open >= target ? bar.open : target
                    exitIndex = scan
                    exitReason = "止盈"
                    settled = true
                    break
                }
                if config.useMA20Exit,
                   scan > entryIndex,
                   let ma20 = TechnicalAnalysisEngine.movingAverage(
                       Array(sorted[0...scan].map(\.close)), window: 20),
                   bar.close < ma20 {
                    exitPrice = bar.close
                    exitIndex = scan
                    exitReason = "跌破MA20"
                    settled = true
                    break
                }
                exitPrice = bar.close
                exitIndex = scan
            }
            _ = settled

            let returnPct = (exitPrice - entryPrice) / entryPrice * 100
            trades.append(BacktestReport.Trade(
                entryDate: entry.date,
                exitDate: sorted[exitIndex].date,
                entryPrice: entryPrice,
                exitPrice: exitPrice,
                returnPct: (returnPct * 100).rounded() / 100,
                exitReason: exitReason
            ))
            index = exitIndex + 1
            cooldown = config.cooldownBars
        }

        return buildReport(skillID: skillID, bars: sorted, trades: trades)
    }

    /// 技能量化条件的可计算触发判定（严格子集：只有可从 TA 结果确定性判定的技能参与回测）。
    static func signalTriggered(skillID: String, analysis: TechnicalAnalysisResult, currentBar: MarketDailyBar) -> Bool {
        switch skillID {
        case "ma_golden_cross":
            // 金叉状态 + 量能确认（量比 > 1.2）
            guard let macd = analysis.macdState else { return false }
            let goldenStates: [MACDState] = [.goldenCross, .goldenCrossAboveZero, .goldenCrossBelowZero]
            let volumeOK = (analysis.volumeRatio ?? 0) > 1.2
            return goldenStates.contains(macd) && volumeOK && analysis.maAlignment?.isBullish == true
        case "shrink_pullback":
            // 多头排列 + 缩量回踩（量价状态 = 缩量回调 + 乖离 <2%）
            let bullAlignment = analysis.maAlignment == .bull || analysis.maAlignment == .strongBull
            return bullAlignment
                && analysis.volumePriceState == .shrinkPullback
                && (analysis.biasMA5 ?? 99) < 2.0
        case "volume_breakout":
            // 量比 > 2 且价格已在全部压力位之上（TA 中 resistance 为 nil 即处于 60 日高点）
            return analysis.resistance == nil && (analysis.volumeRatio ?? 0) > 2.0
        case "box_oscillation":
            // 贴近支撑（距支撑 ≤2%）且缩量（量比 <1）
            guard let support = analysis.support, let close = analysis.close else { return false }
            let nearSupport = (close - support) / support <= 0.02
            return nearSupport && (analysis.volumeRatio ?? 1) < 1.0
        case "one_yang_three_yin":
            // 形态无法从 TA 摘要判定，回测跳过（条件不可计算）
            return false
        default:
            // 框架类/LLM 判定类技能不可确定性回测
            return false
        }
    }

    // MARK: - 统计

    static func buildReport(skillID: String, bars: [MarketDailyBar], trades: [BacktestReport.Trade]) -> BacktestReport {
        guard !trades.isEmpty else {
            return BacktestReport(
                skillID: skillID, subjectCode: "", sampleCount: 0,
                winRate: nil, profitFactor: nil, avgReturnPct: nil, maxDrawdownPct: nil,
                trades: [], dataBoundary: "区间内无触发信号"
            )
        }
        let wins = trades.filter { $0.returnPct > 0 }
        let losses = trades.filter { $0.returnPct <= 0 }
        let winRate = trades.count > 0 ? Double(wins.count) / Double(trades.count) : nil
        let grossProfit = wins.map(\.returnPct).reduce(0, +)
        let grossLoss = abs(losses.map(\.returnPct).reduce(0, +))
        let profitFactor = grossLoss > 0 ? grossProfit / grossLoss : nil
        let avgReturn = trades.map(\.returnPct).reduce(0, +) / Double(trades.count)

        // 简化最大回撤：按逐笔累计收益曲线
        var cumulative = 0.0
        var peak = 0.0
        var maxDrawdown = 0.0
        for trade in trades {
            cumulative += trade.returnPct
            peak = max(peak, cumulative)
            maxDrawdown = max(maxDrawdown, peak - cumulative)
        }

        let boundary = [
            "样本 \(trades.count) 笔（\(trades.count < 30 ? "不足 30，结论仅供参考" : "充分")）",
            "规则级回测：仅验证技能量化条件，未含 LLM 综合与情报维度",
            "K 线区间 \(bars.first?.date ?? "") ~ \(bars.last?.date ?? "")",
        ].joined(separator: "；")

        return BacktestReport(
            skillID: skillID,
            subjectCode: "",
            sampleCount: trades.count,
            winRate: winRate.map { ($0 * 10000).rounded() / 10000 },
            profitFactor: profitFactor.map { ($0 * 100).rounded() / 100 },
            avgReturnPct: (avgReturn * 100).rounded() / 100,
            maxDrawdownPct: (maxDrawdown * 100).rounded() / 100,
            trades: trades,
            dataBoundary: boundary
        )
    }
}
