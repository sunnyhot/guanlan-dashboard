import Foundation

/// A股板块识别与涨跌停价规则。
///
/// 口径对拍 daily_stock_analysis（MIT）`efinance_fetcher.py` 的 `_calc_market_stats`：
/// - 北交所 ±30%
/// - 科创板（688）/创业板（30x）±20%（注册制板块 ST 不缩幅）
/// - 主板 ST ±5%
/// - 其余主板 ±10%
/// - 涨跌停价 = 前收盘 × (1±幅度)，四舍五入到分；触板判定容差半分。
enum MarketBoardRule {
    // MARK: - 板块识别

    /// 从 6 位 A股代码识别板块；非法代码返回 nil。
    static func board(forCode code: String) -> MarketBoard? {
        let bare = MarketCodeNormalizer.bareACode(from: code)
        guard bare.count == 6, bare.allSatisfy(\.isNumber) else { return nil }
        if bare.hasPrefix("68") { return .star }
        if bare.hasPrefix("30") { return .chiNext }
        if bare.hasPrefix("4") || bare.hasPrefix("8") || bare.hasPrefix("92") { return .bse }
        if bare.hasPrefix("6") || bare.hasPrefix("5") || bare.hasPrefix("9") { return .shMain }
        return .szMain
    }

    /// 名称是否含 ST 标记（ST/*ST 均按风险警示板处理）。
    static func isSTName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("ST")
    }

    // MARK: - 涨跌停幅度

    static func limitRatio(board: MarketBoard, isST: Bool) -> Double {
        switch board {
        case .bse:
            return 0.30
        case .star, .chiNext:
            return 0.20
        case .shMain, .szMain:
            return isST ? 0.05 : 0.10
        }
    }

    // MARK: - 涨跌停价

    /// 四舍五入到分（交易所涨跌停价规则）。
    static func roundedToCent(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value * 100).rounded() / 100
    }

    static func limitUpPrice(previousClose: Double, board: MarketBoard, isST: Bool) -> Double? {
        guard previousClose > 0, previousClose.isFinite else { return nil }
        return roundedToCent(previousClose * (1 + limitRatio(board: board, isST: isST)))
    }

    static func limitDownPrice(previousClose: Double, board: MarketBoard, isST: Bool) -> Double? {
        guard previousClose > 0, previousClose.isFinite else { return nil }
        return roundedToCent(previousClose * (1 - limitRatio(board: board, isST: isST)))
    }

    // MARK: - 触板判定

    /// 判定是否触涨停。优先用行情源直接给出的涨停价，缺失时按规则计算。
    /// 容差 0.0051 元（半分），覆盖浮点误差与源端截断。
    static func isLimitUp(
        price: Double,
        previousClose: Double?,
        board: MarketBoard,
        isST: Bool,
        sourceLimitUpPrice: Double? = nil
    ) -> Bool {
        guard price > 0 else { return false }
        let limit = sourceLimitUpPrice
            ?? previousClose.flatMap { limitUpPrice(previousClose: $0, board: board, isST: isST) }
        guard let limit else { return false }
        return abs(price - limit) < 0.0051
    }

    static func isLimitDown(
        price: Double,
        previousClose: Double?,
        board: MarketBoard,
        isST: Bool,
        sourceLimitDownPrice: Double? = nil
    ) -> Bool {
        guard price > 0 else { return false }
        let limit = sourceLimitDownPrice
            ?? previousClose.flatMap { limitDownPrice(previousClose: $0, board: board, isST: isST) }
        guard let limit else { return false }
        return abs(price - limit) < 0.0051
    }
}
