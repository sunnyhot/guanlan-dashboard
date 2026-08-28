import Foundation

/// 市场广度统计（涨跌家数/涨停跌停/成交额合计）。本地计算，不是接口值。
///
/// 规则（对拍 daily_stock_analysis `efinance_fetcher.py` `_calc_market_stats`）：
/// - 前收盘价优先用源字段，缺失时按涨跌幅反推（`effectivePreviousClose`）；
/// - 涨跌停价按板块+ST 规则计算，源直接给出涨跌停价时优先；
/// - 触板判定容差半分；
/// - 涨停/跌停家数是涨/跌家数的子集（不重复计入涨跌数）。
enum MarketBreadthCalculator {
    static func compute(
        quotes: [MarketQuote],
        computedAt: String,
        boundaryNote: String = ""
    ) -> MarketBreadthStats {
        var stats = MarketBreadthStats()
        stats.computedAt = computedAt
        var amountTotalYuan: Double = 0
        var hasAmount = false
        var boundaryNotes: [String] = []
        if !boundaryNote.isEmpty { boundaryNotes.append(boundaryNote) }

        for quote in quotes {
            guard quote.hasUsablePrice, let price = quote.price else {
                stats.excludedCount += 1
                continue
            }
            guard let previousClose = quote.effectivePreviousClose else {
                stats.excludedCount += 1
                continue
            }
            stats.sampleCount += 1

            if abs(price - previousClose) < 0.005 {
                stats.flatCount += 1
            } else if price > previousClose {
                stats.upCount += 1
            } else {
                stats.downCount += 1
            }

            if let board = quote.board ?? MarketBoardRule.board(forCode: quote.code) {
                let isST = quote.isST
                if MarketBoardRule.isLimitUp(
                    price: price,
                    previousClose: previousClose,
                    board: board,
                    isST: isST,
                    sourceLimitUpPrice: quote.limitUpPrice
                ) {
                    stats.limitUpCount += 1
                }
                if MarketBoardRule.isLimitDown(
                    price: price,
                    previousClose: previousClose,
                    board: board,
                    isST: isST,
                    sourceLimitDownPrice: quote.limitDownPrice
                ) {
                    stats.limitDownCount += 1
                }
            }

            if let amount = quote.amount, amount > 0, amount.isFinite {
                amountTotalYuan += amount
                hasAmount = true
            }
        }

        let derivedCount = quotes.filter { quote in
            quote.hasUsablePrice && quote.previousClose == nil && quote.effectivePreviousClose != nil
        }.count
        if derivedCount > 0 {
            boundaryNotes.append("\(derivedCount) 只前收盘价按涨跌幅反推")
        }
        if hasAmount {
            stats.totalAmountYi = (amountTotalYuan / 1e8 * 10).rounded() / 10
        }
        if stats.excludedCount > 0 {
            boundaryNotes.append("\(stats.excludedCount) 只因缺价格/前收盘价未计入")
        }
        stats.dataBoundary = boundaryNotes.joined(separator: "；")
        return stats
    }
}
