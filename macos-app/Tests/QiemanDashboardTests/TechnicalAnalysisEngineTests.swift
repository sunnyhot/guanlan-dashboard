import XCTest
@testable import QiemanDashboard

// MARK: - Canonical 分数带

final class CanonicalDecisionScaleTests: XCTestCase {
    func testBandBoundaries() {
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 100), .strongBuy)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 80), .strongBuy)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 79), .buy)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 60), .buy)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 59), .watch)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 40), .watch)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 39), .reduce)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 20), .reduce)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 19), .sell)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 0), .sell)
        // 越界钳制
        XCTAssertEqual(CanonicalScoreBand.band(forScore: -5), .sell)
        XCTAssertEqual(CanonicalScoreBand.band(forScore: 150), .strongBuy)
    }

    func testCoherentActionsPerBand() {
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 85, action: .buy))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 65, action: .add))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 50, action: .watch))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 50, action: .hold))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 30, action: .reduce))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 10, action: .avoid))
        XCTAssertTrue(CanonicalDecisionScale.isCoherent(score: 55, action: .alert), "alert 中性，任何带都合法")

        XCTAssertFalse(CanonicalDecisionScale.isCoherent(score: 65, action: .hold), "≥60 分给 hold 不自洽")
        XCTAssertFalse(CanonicalDecisionScale.isCoherent(score: 35, action: .watch), "<40 分给 watch 不自洽")
        XCTAssertFalse(CanonicalDecisionScale.isCoherent(score: 85, action: .reduce))
    }

    func testAlignActionAdjustsAndAudits() {
        // 自洽：原样返回
        let coherent = CanonicalDecisionScale.alignAction(score: 50, declared: .watch)
        XCTAssertEqual(coherent.action, .watch)
        XCTAssertFalse(coherent.adjusted)
        XCTAssertNil(coherent.reason)

        // 不自洽：按分数带对齐并给出审计原因
        let adjusted = CanonicalDecisionScale.alignAction(score: 70, declared: .hold)
        XCTAssertEqual(adjusted.action, .buy)
        XCTAssertTrue(adjusted.adjusted)
        XCTAssertTrue(adjusted.reason?.contains("70") ?? false)
        XCTAssertTrue(adjusted.reason?.contains("不自洽") ?? false)

        let adjustedDown = CanonicalDecisionScale.alignAction(score: 25, declared: .watch)
        XCTAssertEqual(adjustedDown.action, .reduce)
    }

    func testDecisionTypeAndConfidenceMapping() {
        XCTAssertEqual(CanonicalAction.buy.decisionType, .buy)
        XCTAssertEqual(CanonicalAction.add.decisionType, .buy)
        XCTAssertEqual(CanonicalAction.watch.decisionType, .hold)
        XCTAssertEqual(CanonicalAction.alert.decisionType, .hold)
        XCTAssertEqual(CanonicalAction.reduce.decisionType, .sell)
        XCTAssertEqual(CanonicalAction.avoid.decisionType, .sell)

        XCTAssertEqual(CanonicalDecisionScale.confidenceValue(for: "高"), 0.8)
        XCTAssertEqual(CanonicalDecisionScale.confidenceValue(for: "中"), 0.6)
        XCTAssertEqual(CanonicalDecisionScale.confidenceValue(for: "低"), 0.4)
    }
}

// MARK: - 规则技术分析

final class TechnicalAnalysisEngineTests: XCTestCase {
    /// 生成线性走势 K 线（可指定末根覆盖，构造量价形态）。
    private func linearBars(
        count: Int,
        start: Double,
        step: Double,
        volume: Double = 1000,
        lastClose: Double? = nil,
        lastVolume: Double? = nil
    ) -> [MarketDailyBar] {
        var bars: [MarketDailyBar] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let anchor = formatter.date(from: "2026-04-01")!
        for index in 0..<count {
            let close = start + step * Double(index)
            bars.append(MarketDailyBar(
                date: formatter.string(from: anchor.addingTimeInterval(Double(index) * 86_400)),
                open: close - 0.05,
                high: close + 0.1,
                low: close - 0.1,
                close: close,
                volume: index == count - 1 ? (lastVolume ?? volume) : volume,
                amount: (lastVolume ?? volume) * close,
                pctChg: nil
            ))
        }
        if let lastClose {
            var last = bars.removeLast()
            last = MarketDailyBar(date: last.date, open: last.open, high: max(last.high, lastClose), low: min(last.low, lastClose), close: lastClose, volume: last.volume, amount: last.volume * lastClose, pctChg: nil)
            bars.append(last)
        }
        return bars
    }

    func testInsufficientBarsReturnsNeutralWatch() {
        let result = TechnicalAnalysisEngine.analyze(code: "600519", bars: linearBars(count: 10, start: 10, step: 0.1))
        XCTAssertEqual(result.score, 40)
        XCTAssertEqual(result.signalBand, .watch)
        XCTAssertTrue(result.dataBoundary.contains("样本不足"))
        XCTAssertNil(result.maAlignment)
        XCTAssertNil(result.macdState)
    }

    func testSteadyUptrendScoresBuyBandWithStrongBull() {
        // 40 根稳步上行：close 10.0 → 13.9，量恒定
        let bars = linearBars(count: 40, start: 10, step: 0.1)
        let result = TechnicalAnalysisEngine.analyze(code: "600519", bars: bars)

        XCTAssertEqual(result.maAlignment, .strongBull, "MA5>MA10>MA20 且 MA20 上行")
        XCTAssertEqual(result.scoreBreakdown["trend"], 30)

        // MA5 = (13.5+13.6+13.7+13.8+13.9)/5 = 13.7；乖离 = 0.2/13.7 ≈ 1.46% < 2% → 满分 20
        XCTAssertEqual(result.scoreBreakdown["bias"], 20)
        XCTAssertEqual(result.biasMA5 ?? 0, 1.46, accuracy: 0.05)

        // 量恒定 → 平量 10
        XCTAssertEqual(result.volumePriceState, .flatVolume)
        XCTAssertEqual(result.scoreBreakdown["volume"], 10)

        // 持续上行 RSI=100 → 超买 0 分 + 风险项
        XCTAssertEqual(result.rsiState, .overbought)
        XCTAssertEqual(result.scoreBreakdown["rsi"], 0)
        XCTAssertTrue(result.riskFactors.contains { $0.text.contains("超买") })

        // MACD：持续上行 dif>dea 且 dif>0 → aboveZero（8）或 goldenCrossAboveZero（15）
        XCTAssertNotNil(result.macdState)

        // 总分 = 30+20+10+10+macd+0；macd 8 → 78（buy 带）；macd 15 → 85（strongBuy）
        let total = result.scoreBreakdown.values.reduce(0, +)
        XCTAssertEqual(result.score, total, "分数 = 各模块之和")
        XCTAssertTrue([78, 85].contains(result.score), "稳步上行应落入看多带，实际 \(result.score)")

        XCTAssertNotNil(result.support)
        XCTAssertTrue(result.reasons.contains { $0.text.contains("多头排列") })
        XCTAssertEqual(result.evidenceID, "ta:600519:\(String(result.asOf.prefix(10)))")
        XCTAssertTrue(result.evidenceSummary.contains("评分"))
    }

    func testSteadyDowntrendScoresSellSide() {
        // 40 根持续下行：close 20.0 → 16.1
        let bars = linearBars(count: 40, start: 20, step: -0.1)
        let result = TechnicalAnalysisEngine.analyze(code: "600519", bars: bars)

        XCTAssertEqual(result.maAlignment, .strongBear)
        XCTAssertEqual(result.scoreBreakdown["trend"], 0)
        XCTAssertTrue(result.riskFactors.contains { $0.text.contains("禁止抄底") })
        XCTAssertLessThan(result.score, 40, "持续下行应落入减仓/看空带，实际 \(result.score)")
    }

    func testShrinkPullbackPatternDetected() {
        // 20 根上行后，末根缩量回调：close 11.9→11.7，量 1000→500
        let bars = linearBars(count: 20, start: 10, step: 0.1, lastClose: 11.7, lastVolume: 500)
        let result = TechnicalAnalysisEngine.analyze(code: "300750", bars: bars)

        XCTAssertEqual(result.volumePriceState, .shrinkPullback)
        XCTAssertEqual(result.scoreBreakdown["volume"], 15)
        XCTAssertEqual(result.volumeRatio ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(result.reasons.contains { $0.text.contains("缩量回调") })
    }

    func testExpandSelloffPatternDetected() {
        let bars = linearBars(count: 20, start: 20, step: -0.1, lastClose: 18.1, lastVolume: 3000)
        let result = TechnicalAnalysisEngine.analyze(code: "000001", bars: bars)
        XCTAssertEqual(result.volumePriceState, .expandSelloff)
        XCTAssertEqual(result.scoreBreakdown["volume"], 0)
        XCTAssertTrue(result.riskFactors.contains { $0.text.contains("放量下跌") })
    }

    func testOverextendedUpriskFlagsNoChasing() {
        // 末根暴涨制造高乖离：close 平稳 20 根后跳到 +12%
        let bars = linearBars(count: 20, start: 10, step: 0.02, lastClose: 11.5)
        let result = TechnicalAnalysisEngine.analyze(code: "600519", bars: bars)
        // MA5 ≈ (10.38+10.4+10.42+10.44+11.5)/5 ≈ 10.63 → 乖离 ≈ 8.2% > 5%
        XCTAssertGreaterThan(result.biasMA5 ?? 0, 5)
        XCTAssertTrue(result.riskFactors.contains { $0.text.contains("严禁追高") })
        XCTAssertLessThanOrEqual(result.scoreBreakdown["bias"] ?? 20, 4)
    }

    func testSanitizeRemovesConflictingReasonsButKeepsRisks() {
        let mixed = TechnicalAnalysisResult(
            code: "600519", asOf: "2026-08-28", score: 70, scoreBreakdown: [:],
            signalBand: .buy,
            maAlignment: .bull, volumePriceState: .expandRally, macdState: .aboveZero, rsiState: .strong,
            ma5: 10, ma10: 9.9, ma20: 9.8, ma60: nil, biasMA5: 1.0,
            support: 9.9, resistance: 10.5, volumeRatio: 1.6, close: 10.1,
            reasons: [
                TechnicalReason(text: "✅ 多头排列", module: "trend", polarity: .bullish),
                TechnicalReason(text: "❌ MACD 死叉", module: "macd", polarity: .bearish),
            ],
            riskFactors: [TechnicalReason(text: "⚠️ 超买", module: "rsi", polarity: .bearish)],
            dataBoundary: ""
        )
        let (sanitized, notes) = TechnicalAnalysisEngine.sanitizeForPrompt(mixed)
        XCTAssertEqual(sanitized.reasons.count, 1, "看多信号剔除 bearish 主理由")
        XCTAssertEqual(sanitized.reasons[0].text, "✅ 多头排列")
        XCTAssertEqual(sanitized.riskFactors.count, 1, "风险项保留（风险提示≠反向判断）")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("一致性约束"))
        XCTAssertEqual(sanitized.score, mixed.score, "消毒不改评分口径")
    }

    func testRSIKnownValues() {
        let up = TechnicalAnalysisEngine.rsi(Array(stride(from: 10.0, through: 20.0, by: 1.0)), period: 6)
        XCTAssertEqual(up ?? 0, 100, accuracy: 0.001, "纯上涨 RSI=100")
        let down = TechnicalAnalysisEngine.rsi(Array(stride(from: 20.0, through: 10.0, by: -1.0)), period: 6)
        XCTAssertEqual(down ?? 0, 0, accuracy: 0.001, "纯下跌 RSI=0")
        let flat = TechnicalAnalysisEngine.rsi([Double](repeating: 10.0, count: 20), period: 6)
        XCTAssertEqual(flat ?? 0, 50, accuracy: 0.001, "无波动 RSI=50")
        XCTAssertNil(TechnicalEngineRSIHelper.shortSeries)
    }

    func testEMASeriesMatchesManualComputation() {
        let ema = TechnicalAnalysisEngine.emaSeries([1, 2, 3, 4], period: 2)
        XCTAssertEqual(ema[0], 1, accuracy: 0.0001)
        XCTAssertEqual(ema[1], 1 + (2 - 1) * 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ema[2], 1.666_666 + (3 - 1.666_666) * 2.0 / 3.0, accuracy: 0.001)
    }
}

private enum TechnicalEngineRSIHelper {
    static let shortSeries: Double? = TechnicalAnalysisEngine.rsi([1, 2, 3], period: 6)
}

// MARK: - 工具注册

final class MarketDataToolRegistrationTests: XCTestCase {
    func testRegistryExposesNewMarketDataTools() {
        let registry = TrendResearchToolRegistry()
        let names = Set(registry.tools.keys)
        XCTAssertTrue(names.contains("get_market_breadth"), "广度工具已注册")
        XCTAssertTrue(names.contains("get_daily_kline"), "日K技术分析工具已注册")
        XCTAssertTrue(names.contains("get_market_snapshot"), "既有快照工具不受影响")
        let breadth = registry.definitions.first { $0.function.name == "get_market_breadth" }
        XCTAssertNotNil(breadth)
        XCTAssertFalse(breadth?.function.description.isEmpty ?? true)
        let kline = registry.definitions.first { $0.function.name == "get_daily_kline" }
        XCTAssertNotNil(kline)
        XCTAssertFalse(kline?.function.description.isEmpty ?? true)
    }
}
