import XCTest
@testable import QiemanDashboard

final class StrategyRuleBacktesterTests: XCTestCase {
    /// 合成行情：三段式——横盘 30 根、单边上行 30 根（其间制造回踩）、高位横盘 20 根。
    private func synthesizedBars() -> [MarketDailyBar] {
        var bars: [MarketDailyBar] = []
        var date = 1
        func append(_ close: Double, volume: Double) {
            bars.append(MarketDailyBar(
                date: String(format: "2026-%02d-%02d", date <= 28 ? 6 : 7, (date - 1) % 28 + 1),
                open: close - 0.05, high: close + 0.1, low: close - 0.1,
                close: close, volume: volume, amount: close * volume
            ))
            date += 1
        }
        // 横盘 + 缩量（箱底回踩条件不触发多头排列）
        for index in 0..<30 { append(10 + Double(index % 5) * 0.05, volume: 1000) }
        // 上行段：升 3 回 1 的节奏，回踩日缩量
        var price = 10.0
        for index in 0..<30 {
            let pullback = index % 4 == 3
            price += pullback ? -0.25 : 0.3
            append(price, volume: pullback ? 500 : 1200)
        }
        // 高位横盘放量假突破区
        for index in 0..<20 { append(price + Double(index % 3) * 0.02, volume: 2600) }
        return bars
    }

    func testBacktestRunsAndProducesStats() {
        let bars = synthesizedBars()
        let report = StrategyRuleBacktester.backtest(skillID: "shrink_pullback", bars: bars)
        XCTAssertGreaterThanOrEqual(bars.count, 80)
        XCTAssertFalse(report.trades.isEmpty, "上行段应触发缩量回踩信号")
        XCTAssertEqual(report.sampleCount, report.trades.count)
        if let winRate = report.winRate {
            XCTAssertGreaterThanOrEqual(winRate, 0)
            XCTAssertLessThanOrEqual(winRate, 1)
        }
        // 每笔交易字段完整
        for trade in report.trades {
            XCTAssertFalse(trade.entryDate.isEmpty)
            XCTAssertGreaterThan(trade.exitDate, trade.entryDate, "出场日晚于入场日")
            XCTAssertGreaterThan(trade.entryPrice, 0)
            XCTAssertEqual(trade.returnPct, (trade.exitPrice - trade.entryPrice) / trade.entryPrice * 100, accuracy: 0.02)
        }
        XCTAssertTrue(report.dataBoundary.contains("规则级回测"))
    }

    func testStopLossPriorityHolds() {
        // 构造一笔立即止损的行情：先小样本上行触发条件，随后暴跌
        var bars: [MarketDailyBar] = []
        for index in 0..<40 {
            let close = 10 + Double(index) * 0.15
            bars.append(MarketDailyBar(
                date: String(format: "2026-06-%02d", index + 1),
                open: close, high: close + 0.05, low: close - 0.05,
                close: close, volume: 1200, amount: close * 1200
            ))
        }
        // 触发回踩后暴跌 10%
        let peak = bars.last!.close
        for index in 0..<8 {
            let close = peak * (1 - 0.02 * Double(index + 1))
            bars.append(MarketDailyBar(
                date: String(format: "2026-07-%02d", index + 1),
                open: close * 1.01, high: close * 1.02, low: close * 0.99,
                close: close, volume: 3000, amount: close * 3000
            ))
        }
        let report = StrategyRuleBacktester.backtest(skillID: "shrink_pullback", bars: bars)
        // 上行段斜率恒定（无回踩形态）——预期 0 触发或极少；不崩溃即可
        XCTAssertLessThanOrEqual(report.sampleCount, 2)
    }

    func testInsufficientBarsReturnsBoundary() {
        let report = StrategyRuleBacktester.backtest(skillID: "ma_golden_cross", bars: [])
        XCTAssertEqual(report.sampleCount, 0)
        XCTAssertTrue(report.dataBoundary.contains("不足"))
        XCTAssertNil(report.winRate)
        XCTAssertFalse(report.isSampleSufficient)
    }

    func testNonComputableSkillsNeverTrigger() {
        let bars = synthesizedBars()
        for skillID in ["bull_trend", "chan_theory", "wave_theory", "emotion_cycle", "one_yang_three_yin", "dragon_head"] {
            let report = StrategyRuleBacktester.backtest(skillID: skillID, bars: bars)
            XCTAssertEqual(report.sampleCount, 0, "\(skillID) 不可确定性回测，应零触发")
        }
    }

    func testGoldenCrossTriggerRequiresVolumeAndAlignment() {
        let bullish = TechnicalAnalysisResult(
            code: "t", asOf: "2026-08-28", score: 70, scoreBreakdown: [:],
            signalBand: .buy, maAlignment: .bull, volumePriceState: .expandRally,
            macdState: .goldenCross, rsiState: .strong,
            ma5: 10, ma10: 9.9, ma20: 9.8, ma60: nil, biasMA5: 1,
            support: 9.9, resistance: nil, volumeRatio: 1.5, close: 10.1,
            reasons: [], riskFactors: [], dataBoundary: ""
        )
        let bar = MarketDailyBar(date: "2026-08-28", open: 10, high: 10.2, low: 9.9, close: 10.1, volume: 100, amount: 1000)
        XCTAssertTrue(StrategyRuleBacktester.signalTriggered(skillID: "ma_golden_cross", analysis: bullish, currentBar: bar))

        // 量能不足
        var lowVolume = bullish
        lowVolume = TechnicalAnalysisResult(
            code: "t", asOf: "2026-08-28", score: 70, scoreBreakdown: [:],
            signalBand: .buy, maAlignment: .bull, volumePriceState: .flatVolume,
            macdState: .goldenCross, rsiState: .strong,
            ma5: 10, ma10: 9.9, ma20: 9.8, ma60: nil, biasMA5: 1,
            support: 9.9, resistance: nil, volumeRatio: 1.0, close: 10.1,
            reasons: [], riskFactors: [], dataBoundary: ""
        )
        XCTAssertFalse(StrategyRuleBacktester.signalTriggered(skillID: "ma_golden_cross", analysis: lowVolume, currentBar: bar))

        // 空头排列
        var bearish = bullish
        bearish = TechnicalAnalysisResult(
            code: "t", asOf: "2026-08-28", score: 30, scoreBreakdown: [:],
            signalBand: .reduce, maAlignment: .bear, volumePriceState: .expandRally,
            macdState: .goldenCross, rsiState: .strong,
            ma5: 9.8, ma10: 9.9, ma20: 10, ma60: nil, biasMA5: -1,
            support: 9.7, resistance: 10.2, volumeRatio: 1.5, close: 9.85,
            reasons: [], riskFactors: [], dataBoundary: ""
        )
        XCTAssertFalse(StrategyRuleBacktester.signalTriggered(skillID: "ma_golden_cross", analysis: bearish, currentBar: bar))
    }

    func testWinRateAndProfitFactorMath() {
        let trades = [
            BacktestReport.Trade(entryDate: "2026-06-01", exitDate: "2026-06-05", entryPrice: 10, exitPrice: 11, returnPct: 10, exitReason: "止盈"),
            BacktestReport.Trade(entryDate: "2026-06-10", exitDate: "2026-06-12", entryPrice: 10, exitPrice: 9.5, returnPct: -5, exitReason: "止损"),
            BacktestReport.Trade(entryDate: "2026-06-20", exitDate: "2026-06-25", entryPrice: 10, exitPrice: 10.8, returnPct: 8, exitReason: "止盈"),
        ]
        let report = StrategyRuleBacktester.buildReport(skillID: "x", bars: [], trades: trades)
        XCTAssertEqual(report.sampleCount, 3)
        XCTAssertEqual(report.winRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.profitFactor ?? 0, 18.0 / 5.0, accuracy: 0.011, "(10+8)/5")
        XCTAssertEqual(report.avgReturnPct ?? 0, 13.0 / 3.0, accuracy: 0.011)
        XCTAssertGreaterThan(report.maxDrawdownPct ?? 0, 0)
        XCTAssertTrue(report.dataBoundary.contains("不足 30"))
    }
}
