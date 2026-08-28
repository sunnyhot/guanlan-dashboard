import Foundation

// MARK: - 结果模型

/// 技术分析理由条目（✅/❌ 逐条，供 prompt 注入与 Evidence 对接）。
struct TechnicalReason: Codable, Hashable, Sendable {
    enum Polarity: String, Codable, Hashable, Sendable {
        case bullish
        case bearish
        case neutral
    }

    /// 展示文本，自带 ✅/❌/⚠️ 前缀
    let text: String
    let module: String
    let polarity: Polarity
}

/// 均线排列（7 态）。
enum MAAlignment: String, Codable, Hashable, Sendable {
    case strongBull   // MA5>MA10>MA20 且 MA20 上行
    case bull         // MA5>MA10>MA20
    case weakBull     // MA5>MA10 但 MA10<MA20
    case range        // 无明确排列
    case weakBear     // MA5<MA10 但 MA10>MA20
    case bear         // MA5<MA10<MA20
    case strongBear   // MA5<MA10<MA20 且 MA20 下行

    var displayName: String {
        switch self {
        case .strongBull: return "强多头排列"
        case .bull: return "多头排列"
        case .weakBull: return "弱多头"
        case .range: return "均线纠缠"
        case .weakBear: return "弱空头"
        case .bear: return "空头排列"
        case .strongBear: return "强空头排列"
        }
    }

    var isBullish: Bool {
        switch self {
        case .strongBull, .bull, .weakBull: return true
        default: return false
        }
    }
}

/// 量价状态（5 态，对拍 DSA 量价组合口径）。
enum VolumePriceState: String, Codable, Hashable, Sendable {
    case shrinkPullback   // 缩量回调（最佳洗盘形态）
    case expandRally      // 放量上涨
    case flatVolume       // 平量
    case dryRally         // 无量上涨
    case expandSelloff    // 放量下跌

    var displayName: String {
        switch self {
        case .shrinkPullback: return "缩量回调"
        case .expandRally: return "放量上涨"
        case .flatVolume: return "平量"
        case .dryRally: return "无量上涨"
        case .expandSelloff: return "放量下跌"
        }
    }
}

/// MACD 状态（对拍 DSA 7 态扩展为 8 态含死叉方向）。
enum MACDState: String, Codable, Hashable, Sendable {
    case goldenCrossAboveZero
    case goldenCross
    case zeroCrossUp
    case aboveZero
    case goldenCrossBelowZero
    case belowZero
    case deathCross
    case deathCrossBelowZero

    var displayName: String {
        switch self {
        case .goldenCrossAboveZero: return "零上金叉"
        case .goldenCross: return "金叉"
        case .zeroCrossUp: return "DIF 上穿零轴"
        case .aboveZero: return "零上运行"
        case .goldenCrossBelowZero: return "零下金叉"
        case .belowZero: return "零下运行"
        case .deathCross: return "死叉"
        case .deathCrossBelowZero: return "零下死叉"
        }
    }
}

/// RSI 状态（以 RSI6 为主判断周期）。
enum RSIState: String, Codable, Hashable, Sendable {
    case oversold    // <30
    case weak        // 30-50
    case neutral     // 50 附近
    case strong      // 50-70
    case overbought  // >70

    var displayName: String {
        switch self {
        case .oversold: return "超卖"
        case .weak: return "弱势"
        case .neutral: return "中性"
        case .strong: return "强势"
        case .overbought: return "超买"
        }
    }
}

/// 规则技术分析结果。评分与理由由确定性规则产生，可作为零 token 本地证据。
struct TechnicalAnalysisResult: Codable, Hashable, Sendable {
    let code: String
    let asOf: String
    /// 0-100 加权评分：趋势30 + 乖离20 + 量能15 + 支撑10 + MACD15 + RSI10
    let score: Int
    let scoreBreakdown: [String: Int]
    let signalBand: CanonicalScoreBand
    let maAlignment: MAAlignment?
    let volumePriceState: VolumePriceState?
    let macdState: MACDState?
    let rsiState: RSIState?
    let ma5: Double?
    let ma10: Double?
    let ma20: Double?
    let ma60: Double?
    let biasMA5: Double?
    let support: Double?
    let resistance: Double?
    let volumeRatio: Double?
    let close: Double?
    let reasons: [TechnicalReason]
    let riskFactors: [TechnicalReason]
    let dataBoundary: String

    /// 稳定证据 ID（供 Evidence Ledger 登记，零 token 确定性证据）。
    var evidenceID: String { "ta:\(code):\(String(asOf.prefix(10)))" }

    var evidenceSummary: String {
        let parts = [
            "评分 \(score)（\(signalBand.displayName)）",
            maAlignment.map { "均线\($0.displayName)" },
            volumePriceState.map { "量价\($0.displayName)" },
            macdState.map { "MACD \($0.displayName)" },
            rsiState.map { "RSI \($0.displayName)" },
            biasMA5.map { String(format: "MA5 乖离 %.2f%%", $0) },
        ].compactMap { $0 }
        return parts.joined(separator: "；")
    }
}

// MARK: - 引擎

/// 规则技术分析引擎（纯函数）。LLM 负责合成与解读，不负责算数——
/// 本引擎先算好指标并给出加权评分与逐条理由，指标参数对拍 daily_stock_analysis
/// `stock_analyzer.py`（MA/乖离/量价/支撑压力/MACD 12-26-9/RSI 6-12-24）。
enum TechnicalAnalysisEngine {
    static let minBars = 15

    static func analyze(code: String, bars: [MarketDailyBar], asOf: String = "") -> TechnicalAnalysisResult {
        let sorted = bars.sorted { $0.date < $1.date }
        let boundary = boundaryNotes(sorted)
        guard sorted.count >= minBars else {
            return TechnicalAnalysisResult(
                code: code, asOf: asOf.isEmpty ? (sorted.last?.date ?? "") : asOf,
                score: 40, scoreBreakdown: [:], signalBand: .watch,
                maAlignment: nil, volumePriceState: nil, macdState: nil, rsiState: nil,
                ma5: nil, ma10: nil, ma20: nil, ma60: nil, biasMA5: nil,
                support: nil, resistance: nil, volumeRatio: nil,
                close: sorted.last?.close,
                reasons: [], riskFactors: [],
                dataBoundary: "样本不足（\(sorted.count) 根 < \(minBars)），仅返回收盘价，不产出判断"
            )
        }

        let closes = sorted.map(\.close)
        let current = closes.last ?? 0

        // MARK: 均线与排列

        let ma5 = movingAverage(closes, window: 5)
        let ma10 = movingAverage(closes, window: 10)
        let ma20 = movingAverage(closes, window: 20)
        let ma60 = movingAverage(closes, window: 60)
        let ma20Previous = movingAverage(Array(closes.dropLast()), window: 20)
        let alignment = alignment(ma5: ma5, ma10: ma10, ma20: ma20, ma20Previous: ma20Previous)

        var reasons: [TechnicalReason] = []
        var risks: [TechnicalReason] = []
        var breakdown: [String: Int] = [:]

        // 趋势 30 分
        let trendScore: Int
        switch alignment {
        case .strongBull: trendScore = 30
        case .bull: trendScore = 24
        case .weakBull: trendScore = 18
        case .range: trendScore = 12
        case .weakBear: trendScore = 6
        case .bear: trendScore = 3
        case .strongBear: trendScore = 0
        case nil: trendScore = 12
        }
        breakdown["trend"] = trendScore
        if let alignment {
            let polarity: TechnicalReason.Polarity = alignment.isBullish ? .bullish : .bearish
            reasons.append(TechnicalReason(
                text: (alignment.isBullish ? "✅ 均线" : "❌ 均线") + alignment.displayName,
                module: "trend", polarity: polarity
            ))
            if alignment == .strongBear {
                risks.append(TechnicalReason(text: "❌ 强空头排列，趋势向下，禁止抄底", module: "trend", polarity: .bearish))
            }
        }

        // MARK: 乖离率 20 分

        let bias5 = ma5.map { (current - $0) / $0 * 100 }
        var biasScore = 10
        let bearishTrend: Bool
        switch alignment {
        case .weakBear, .bear, .strongBear: bearishTrend = true
        default: bearishTrend = false
        }
        if let bias5 {
            let limit = biasLimit(for: alignment)
            if bearishTrend {
                // 空头语境：回踩均线不构成买点，反抽均线是压力
                if bias5 < 0 {
                    biasScore = 6
                    risks.append(TechnicalReason(text: String(format: "❌ 下跌趋势中贴靠均线（乖离 %.1f%%），不构成买点", bias5), module: "bias", polarity: .bearish))
                } else if bias5 < 2 {
                    biasScore = 8
                    risks.append(TechnicalReason(text: String(format: "⚠️ 空头反抽均线（乖离 %.1f%%），均线是压力不是支撑", bias5), module: "bias", polarity: .bearish))
                } else {
                    biasScore = 12
                }
            } else {
                switch bias5 {
                case ..<(-5):
                    biasScore = 8
                    risks.append(TechnicalReason(text: String(format: "⚠️ MA5 乖离 %.1f%%，深跌待企稳", bias5), module: "bias", polarity: .bearish))
                case -5..<0:
                    biasScore = 18
                    reasons.append(TechnicalReason(text: String(format: "✅ 回踩均线（乖离 %.1f%%），洗盘概率大", bias5), module: "bias", polarity: .bullish))
                case 0..<2:
                    biasScore = 20
                    reasons.append(TechnicalReason(text: "✅ 乖离 <2%，贴近均线，最佳买点区间", module: "bias", polarity: .bullish))
                case 2..<limit:
                    biasScore = 12
                    reasons.append(TechnicalReason(text: String(format: "⚠️ 乖离 %.1f%%，偏离均线，只宜小仓", bias5), module: "bias", polarity: .neutral))
                default:
                    biasScore = 4
                    risks.append(TechnicalReason(text: String(format: "❌ 乖离 %.1f%% 超限（强趋势阈值 %.0f%%），严禁追高", bias5, limit), module: "bias", polarity: .bearish))
                }
            }
        }
        breakdown["bias"] = biasScore

        // MARK: 量能 15 分

        let volumes = sorted.map(\.volume)
        let avgVolume5 = volumes.count >= 6
            ? volumes.suffix(from: volumes.count - 6).dropLast().reduce(0, +) / 5
            : nil
        let ratio = (avgVolume5 ?? 0) > 0 ? (volumes.last ?? 0) / (avgVolume5 ?? 1) : nil
        let previousClose = closes.count >= 2 ? closes[closes.count - 2] : nil
        let upDay = previousClose.map { current >= $0 } ?? true
        let volumeState: VolumePriceState?
        let volumeScore: Int
        if let ratio {
            let shrink = ratio < 0.7
            let expand = ratio > 1.5
            if shrink && !upDay {
                volumeState = .shrinkPullback; volumeScore = 15
                reasons.append(TechnicalReason(text: String(format: "✅ 缩量回调（量比 %.2f），主力洗盘迹象", ratio), module: "volume", polarity: .bullish))
            } else if expand && upDay {
                volumeState = .expandRally; volumeScore = 12
                reasons.append(TechnicalReason(text: String(format: "✅ 放量上涨（量比 %.2f），资金介入", ratio), module: "volume", polarity: .bullish))
            } else if shrink && upDay {
                volumeState = .dryRally; volumeScore = 6
                risks.append(TechnicalReason(text: String(format: "⚠️ 无量上涨（量比 %.2f），上涨质量存疑", ratio), module: "volume", polarity: .neutral))
            } else if expand && !upDay {
                volumeState = .expandSelloff; volumeScore = 0
                risks.append(TechnicalReason(text: String(format: "❌ 放量下跌（量比 %.2f），抛压沉重", ratio), module: "volume", polarity: .bearish))
            } else {
                volumeState = .flatVolume; volumeScore = 10
            }
            if ratio > 10 {
                risks.append(TechnicalReason(text: String(format: "⚠️ 成交量较 5 日均量放大 %.1f 倍，必须降权解读，不能机械视为强确认", ratio), module: "volume", polarity: .neutral))
            }
        } else {
            volumeState = nil
            volumeScore = 8
        }
        breakdown["volume"] = volumeScore

        // MARK: 支撑 10 分

        var supportScore = 0
        let low20 = sorted.suffix(20).map(\.low).min()
        var supportCandidates: [Double] = []
        // 支撑必须是价格**上方/下方贴近**的均线：价格已跌破的均线是压力不是支撑
        if let ma5, current >= ma5 * 0.98 { supportCandidates.append(ma5) }
        if let ma10, current >= ma10 * 0.98 { supportCandidates.append(ma10) }
        if let low20, current >= low20 { supportCandidates.append(low20) }
        let support = supportCandidates.min()
        if let ma5, current >= ma5, (current - ma5) / ma5 <= 0.02 {
            supportScore += 5
            reasons.append(TechnicalReason(text: "✅ 站稳 MA5 支撑", module: "support", polarity: .bullish))
        }
        if let ma10, current >= ma10, (current - ma10) / ma10 <= 0.05 {
            supportScore += 5
            reasons.append(TechnicalReason(text: "✅ MA10 支撑有效", module: "support", polarity: .bullish))
        }
        breakdown["support"] = supportScore

        var resistanceCandidates: [Double] = []
        let high60 = sorted.suffix(60).map(\.high).max()
        if let high60, high60 > current { resistanceCandidates.append(high60) }
        if let ma20, ma20 > current { resistanceCandidates.append(ma20) }
        let resistance = resistanceCandidates.min()

        // MARK: MACD 15 分

        let macdResult = macd(closes)
        let macdState: MACDState?
        let macdScore: Int
        if let state = macdResult?.state {
            macdState = state
            switch state {
            case .goldenCrossAboveZero: macdScore = 15
            case .goldenCross: macdScore = 12
            case .zeroCrossUp: macdScore = 10
            case .aboveZero: macdScore = 8
            case .goldenCrossBelowZero: macdScore = 6
            case .belowZero: macdScore = 4
            case .deathCross: macdScore = 2
            case .deathCrossBelowZero: macdScore = 0
            }
            let bullishMACD: Bool
            switch state {
            case .goldenCrossAboveZero, .goldenCross, .zeroCrossUp, .aboveZero, .goldenCrossBelowZero:
                bullishMACD = true
            case .belowZero, .deathCross, .deathCrossBelowZero:
                bullishMACD = false
            }
            reasons.append(TechnicalReason(
                text: (bullishMACD ? "✅ MACD " : "❌ MACD ") + state.displayName,
                module: "macd",
                polarity: bullishMACD ? .bullish : .bearish
            ))
        } else {
            macdState = nil
            macdScore = 7
        }
        breakdown["macd"] = macdScore

        // MARK: RSI 10 分

        let rsi6 = rsi(closes, period: 6)
        let rsiState: RSIState?
        let rsiScore: Int
        if let value = rsi6 {
            switch value {
            case ..<30: rsiState = .oversold; rsiScore = 10
            case 30..<50: rsiState = .weak; rsiScore = 3
            case 50..<70: rsiState = .strong; rsiScore = 8
            default: rsiState = .overbought; rsiScore = 0
            }
            switch rsiState {
            case .oversold:
                reasons.append(TechnicalReason(text: String(format: "✅ RSI6 %.0f 超卖，反弹动能积聚", value), module: "rsi", polarity: .bullish))
            case .overbought:
                risks.append(TechnicalReason(text: String(format: "❌ RSI6 %.0f 超买，短线过热", value), module: "rsi", polarity: .bearish))
            default:
                break
            }
        } else {
            rsiState = nil
            rsiScore = 5
        }
        breakdown["rsi"] = rsiScore

        let total = breakdown.values.reduce(0, +)
        let normalized = min(max(total, 0), 100)

        return TechnicalAnalysisResult(
            code: code,
            asOf: asOf.isEmpty ? (sorted.last?.date ?? "") : asOf,
            score: normalized,
            scoreBreakdown: breakdown,
            signalBand: CanonicalScoreBand.band(forScore: normalized),
            maAlignment: alignment,
            volumePriceState: volumeState,
            macdState: macdState,
            rsiState: rsiState,
            ma5: ma5, ma10: ma10, ma20: ma20, ma60: ma60,
            biasMA5: bias5,
            support: support,
            resistance: resistance,
            volumeRatio: ratio,
            close: current,
            reasons: reasons,
            riskFactors: risks,
            dataBoundary: boundary
        )
    }

    // MARK: - 一致性消毒

    /// 注入 prompt 前剔除与主信号方向冲突的理由（对拍 DSA `_sanitize_trend_analysis_for_prompt`）。
    /// 返回消毒后的结果与被剔除项的说明。
    static func sanitizeForPrompt(_ result: TechnicalAnalysisResult) -> (result: TechnicalAnalysisResult, consistencyNotes: [String]) {
        let bullishSignal = result.signalBand == .strongBuy || result.signalBand == .buy
        let bearishSignal = result.signalBand == .reduce || result.signalBand == .sell
        guard bullishSignal || bearishSignal else { return (result, []) }

        let keepPolarity: TechnicalReason.Polarity? = bullishSignal ? .bearish : .bullish
        // 看多信号：保留 bullish 理由，剔除 bearish 理由；看空信号反之。⚠️ 风险项（bearish risks）在看多信号里保留供对冲提示？DSA 的做法是剔除冲突理由并写注释——风险项保留（风险提示不等于反向判断），仅剔除主理由中反向的。
        let filteredReasons = result.reasons.filter { reason in
            guard let keepPolarity else { return true }
            return reason.polarity != keepPolarity
        }
        let removed = result.reasons.count - filteredReasons.count
        guard removed > 0 else { return (result, []) }

        var sanitized = result
        sanitized = TechnicalAnalysisResult(
            code: result.code, asOf: result.asOf, score: result.score,
            scoreBreakdown: result.scoreBreakdown, signalBand: result.signalBand,
            maAlignment: result.maAlignment, volumePriceState: result.volumePriceState,
            macdState: result.macdState, rsiState: result.rsiState,
            ma5: result.ma5, ma10: result.ma10, ma20: result.ma20, ma60: result.ma60,
            biasMA5: result.biasMA5, support: result.support, resistance: result.resistance,
            volumeRatio: result.volumeRatio, close: result.close,
            reasons: filteredReasons, riskFactors: result.riskFactors,
            dataBoundary: result.dataBoundary
        )
        let direction = bullishSignal ? "看多" : "看空"
        let notes = ["一致性约束：主信号\(direction)，已剔除 \(removed) 条方向冲突的技术理由（评分口径不变）"]
        return (sanitized, notes)
    }

    // MARK: - 指标计算

    static func movingAverage(_ values: [Double], window: Int) -> Double? {
        guard values.count >= window, window > 0 else { return nil }
        let slice = values.suffix(window)
        return slice.reduce(0, +) / Double(window)
    }

    static func alignment(ma5: Double?, ma10: Double?, ma20: Double?, ma20Previous: Double?) -> MAAlignment? {
        guard let ma5, let ma10, let ma20 else { return nil }
        let ma20Rising = ma20Previous.map { $0 > 0 && ma20 >= $0 } ?? false
        let ma20Falling = ma20Previous.map { $0 > 0 && ma20 <= $0 } ?? false
        if ma5 > ma10, ma10 > ma20 {
            return ma20Rising ? .strongBull : .bull
        }
        if ma5 < ma10, ma10 < ma20 {
            return ma20Falling ? .strongBear : .bear
        }
        if ma5 > ma10 { return .weakBull }
        if ma5 < ma10 { return .weakBear }
        return .range
    }

    /// 乖离率上限：强趋势（强多/多）放宽至 7.5%，其余 5%（对拍 DSA「强势趋势股放宽阈值×1.5」）。
    static func biasLimit(for alignment: MAAlignment?) -> Double {
        switch alignment {
        case .strongBull, .bull: return 7.5
        default: return 5.0
        }
    }

    /// MACD（12/26/9）。返回最新状态与 DIF/DEA。
    static func macd(_ closes: [Double]) -> (state: MACDState, dif: Double, dea: Double)? {
        guard closes.count >= 35 else { return nil }
        let ema12 = emaSeries(closes, period: 12)
        let ema26 = emaSeries(closes, period: 26)
        guard ema12.count == closes.count, ema26.count == closes.count else { return nil }
        var difSeries: [Double] = []
        for index in closes.indices {
            difSeries.append(ema12[index] - ema26[index])
        }
        let deaSeries = emaSeries(difSeries, period: 9)
        guard let dif = difSeries.last, let difPrev = difSeries.dropLast().last,
              let dea = deaSeries.last, let deaPrev = deaSeries.dropLast().last
        else { return nil }

        let crossedUp = difPrev <= deaPrev && dif > dea
        let crossedDown = difPrev >= deaPrev && dif < dea
        let difAboveZero = dif > 0

        let state: MACDState
        if crossedUp {
            state = difAboveZero ? .goldenCrossAboveZero : .goldenCrossBelowZero
        } else if crossedDown {
            state = difAboveZero ? .deathCross : .deathCrossBelowZero
        } else if difPrev <= 0 && dif > 0 {
            state = .zeroCrossUp
        } else if dif > dea {
            state = difAboveZero ? .aboveZero : .goldenCross
        } else {
            state = difAboveZero ? .deathCross : .belowZero
        }
        return (state, dif, dea)
    }

    /// EMA 序列（与输入等长，前 period-1 个用当前均值占位）。
    static func emaSeries(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty, period > 0 else { return [] }
        let multiplier = 2.0 / Double(period + 1)
        var result: [Double] = []
        var ema = values[0]
        for (index, value) in values.enumerated() {
            if index == 0 {
                result.append(ema)
                continue
            }
            ema = (value - ema) * multiplier + ema
            result.append(ema)
        }
        return result
    }

    /// RSI（Wilder 平滑）。
    static func rsi(_ closes: [Double], period: Int) -> Double? {
        guard closes.count > period, period > 0 else { return nil }
        var gains: [Double] = []
        var losses: [Double] = []
        for index in 1..<closes.count {
            let delta = closes[index] - closes[index - 1]
            gains.append(max(delta, 0))
            losses.append(max(-delta, 0))
        }
        let gainWindow = gains.prefix(period).reduce(0, +) / Double(period)
        let lossWindow = losses.prefix(period).reduce(0, +) / Double(period)
        var avgGain = gainWindow
        var avgLoss = lossWindow
        for index in period..<gains.count {
            avgGain = (avgGain * Double(period - 1) + gains[index]) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + losses[index]) / Double(period)
        }
        if avgLoss == 0 {
            return avgGain == 0 ? 50 : 100
        }
        let rs = avgGain / avgLoss
        return 100 - 100 / (1 + rs)
    }

    static func boundaryNotes(_ bars: [MarketDailyBar]) -> String {
        guard !bars.isEmpty else { return "无 K 线数据" }
        var notes: [String] = []
        if bars.count < 35 { notes.append("K 线 \(bars.count) 根不足 MACD(12/26/9) 最低样本，MACD 按中性 7 分计") }
        if bars.count < 61 { notes.append("MA60 样本不足") }
        return notes.joined(separator: "；")
    }
}
