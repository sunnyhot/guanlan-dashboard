import Foundation

/// 信号市价结算器（纯函数）。输入信号 + 覆盖窗口的日 K，输出结算结果。
///
/// 结算规则（保守口径）：
/// 1. 同一根 K 线同时触及止损与目标 → **先止损**（不利优先）；
/// 2. 开盘跳空穿越价位 → 按开盘价结算（不以盘中极值结算不可能成交的价位）；
/// 3. 无入场带的信号从创建日收盘价直接跟踪目标/止损；
/// 4. 看多：low ≤ 止损 / high ≥ 目标；看空反向；
/// 5. 到期（reviewDueAt + 2 个交易日缓冲）未触发 → expiredUnresolved（计入样本不计入胜率分子）；
/// 6. 无覆盖行情 → insufficientData。
enum MarketSignalSettler {
    struct Result {
        let status: SignalStatus
        let settlement: SignalSettlement
        let event: SignalEvent?
    }

    static func settle(
        signal: MarketDecisionSignal,
        bars: [MarketDailyBar],
        asOf: String,
        now: Date = Date()
    ) -> Result {
        let sorted = bars.sorted { $0.date < $1.date }
        let window = sorted.filter { bar in
            bar.date >= String(signal.createdAt.prefix(10)) && bar.date <= String(asOf.prefix(10))
        }
        guard !window.isEmpty, let reference = window.first?.close, reference > 0 else {
            let settlement = SignalSettlement(
                settledAt: asOf, outcome: .insufficientData,
                settlePrice: nil, settleDate: nil,
                maxFavorablePct: nil, maxAdversePct: nil,
                note: "结算窗口内无覆盖日 K（窗口 \(String(signal.createdAt.prefix(10))) ~ \(String(asOf.prefix(10)))）"
            )
            return Result(
                status: .insufficientData,
                settlement: settlement,
                event: SignalEvent(at: asOf, type: .insufficientData, reason: settlement.note)
            )
        }

        let isDue = isPastDue(signal: signal, asOf: asOf, now: now)
        let conditions = signal.priceConditions
        guard conditions.isSettleable || isDue else {
            // 未到期且无价格条件：继续跟踪（调用方不应在此调用，防御性返回 active 语义由服务层处理）
            let settlement = SignalSettlement(
                settledAt: asOf, outcome: .expiredUnresolved,
                settlePrice: nil, settleDate: nil,
                maxFavorablePct: maxFavorablePct(window, reference: reference, direction: signal.direction),
                maxAdversePct: maxAdversePct(window, reference: reference, direction: signal.direction),
                note: "无价格条件且未到期，保持跟踪"
            )
            return Result(status: .active, settlement: settlement, event: nil)
        }

        var maxFavorable = maxFavorablePct(window, reference: reference, direction: signal.direction)
        var maxAdverse = maxAdversePct(window, reference: reference, direction: signal.direction)
        _ = (maxFavorable, maxAdverse) // 供下方结算时覆盖

        // 逐根扫描：先找止损（保守），再找目标
        for bar in window {
            if let stop = conditions.stopLoss, touched(bar: bar, level: stop, direction: signal.direction, isStop: true) {
                let price = gapAdjustedPrice(bar: bar, level: stop, direction: signal.direction, isStop: true)
                let settlement = SignalSettlement(
                    settledAt: asOf,
                    outcome: .hitStop,
                    settlePrice: price,
                    settleDate: bar.date,
                    maxFavorablePct: maxFavorablePct(window.filter { $0.date <= bar.date }, reference: reference, direction: signal.direction),
                    maxAdversePct: maxAdversePct(window.filter { $0.date <= bar.date }, reference: reference, direction: signal.direction),
                    note: "触发止损\(gapNote(bar: bar, level: stop))（同根 K 线双触时按先止损的保守口径）"
                )
                return Result(
                    status: .settledLoss,
                    settlement: settlement,
                    event: SignalEvent(at: asOf, type: .settled, reason: "止损触发于 \(bar.date) @\(String(format: "%.2f", price))")
                )
            }
            if let target = conditions.targetPrice, touched(bar: bar, level: target, direction: signal.direction, isStop: false) {
                // 同根 K 线同时触及止损已在上一分支处理（先止损）；这里到达说明该根未触止损
                let price = gapAdjustedPrice(bar: bar, level: target, direction: signal.direction, isStop: false)
                let settlement = SignalSettlement(
                    settledAt: asOf,
                    outcome: .hitTarget,
                    settlePrice: price,
                    settleDate: bar.date,
                    maxFavorablePct: maxFavorablePct(window.filter { $0.date <= bar.date }, reference: reference, direction: signal.direction),
                    maxAdversePct: maxAdversePct(window.filter { $0.date <= bar.date }, reference: reference, direction: signal.direction),
                    note: "到达目标价\(gapNote(bar: bar, level: target))"
                )
                return Result(
                    status: .settledWin,
                    settlement: settlement,
                    event: SignalEvent(at: asOf, type: .settled, reason: "目标达成于 \(bar.date) @\(String(format: "%.2f", price))")
                )
            }
        }

        // 未触任何价位
        guard isDue else {
            return Result(
                status: .active,
                settlement: SignalSettlement(
                    settledAt: asOf, outcome: .expiredUnresolved,
                    settlePrice: nil, settleDate: nil,
                    maxFavorablePct: maxFavorable, maxAdversePct: maxAdverse,
                    note: "未到期未触发，继续跟踪"
                ),
                event: nil
            )
        }

        let settlement = SignalSettlement(
            settledAt: asOf,
            outcome: .expiredUnresolved,
            settlePrice: nil,
            settleDate: nil,
            maxFavorablePct: maxFavorable,
            maxAdversePct: maxAdverse,
            note: "到期未触发：计入样本但不计入胜率分子（防「只统计敢报价的」幸存者偏差）"
        )
        return Result(
            status: .expiredUnresolved,
            settlement: settlement,
            event: SignalEvent(at: asOf, type: .expired, reason: "复查期到，条件未触发")
        )
    }

    // MARK: - 内部

    /// 是否越过了复查期 + 2 个交易日缓冲。
    static func isPastDue(signal: MarketDecisionSignal, asOf: String, now: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let due = formatter.date(from: signal.reviewDueAt) else { return false }
        let buffered = MarketPhase.nextTradingDay(after: MarketPhase.nextTradingDay(after: due))
        return now >= buffered
    }

    /// 触价判定（含当根）。
    private static func touched(bar: MarketDailyBar, level: Double, direction: CanonicalDecisionType, isStop: Bool) -> Bool {
        // 看多：止损在下（low ≤ level），目标在上（high ≥ level）
        // 看空：目标在下（low ≤ level），止损在上（high ≥ level）
        if direction == .sell {
            return isStop ? bar.high >= level : bar.low <= level
        }
        return isStop ? bar.low <= level : bar.high >= level
    }

    /// 跳空穿越按开盘价结算：开盘已越过价位时用开盘价（无法在价位成交）。
    private static func gapAdjustedPrice(bar: MarketDailyBar, level: Double, direction: CanonicalDecisionType, isStop: Bool) -> Double {
        let gappedThrough: Bool
        if direction == .sell {
            gappedThrough = isStop ? bar.open >= level : bar.open <= level
        } else {
            gappedThrough = isStop ? bar.open <= level : bar.open >= level
        }
        return gappedThrough ? bar.open : level
    }

    private static func gapNote(bar: MarketDailyBar, level: Double) -> String {
        bar.open == level ? "" : "（开盘 \(String(format: "%.2f", bar.open)) 已跳空穿越，按开盘价结算）"
    }

    private static func maxFavorablePct(_ bars: [MarketDailyBar], reference: Double, direction: CanonicalDecisionType) -> Double? {
        guard !bars.isEmpty else { return nil }
        let extremes = bars.map { bar -> Double in
            direction == .sell ? (reference - bar.low) / reference * 100 : (bar.high - reference) / reference * 100
        }
        return (extremes.max() ?? 0 * 100).rounded(digits: 2)
    }

    private static func maxAdversePct(_ bars: [MarketDailyBar], reference: Double, direction: CanonicalDecisionType) -> Double? {
        guard !bars.isEmpty else { return nil }
        let extremes = bars.map { bar -> Double in
            direction == .sell ? (bar.high - reference) / reference * 100 : (bar.low - reference) / reference * 100
        }
        return (extremes.max() ?? 0 * 100).rounded(digits: 2)
    }
}

extension Double {
    fileprivate func rounded(digits: Int) -> Double {
        let base = pow(10.0, Double(digits))
        return (self * base).rounded() / base
    }
}
