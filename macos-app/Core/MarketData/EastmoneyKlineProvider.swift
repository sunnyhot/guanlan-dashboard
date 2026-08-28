import Foundation

/// 东财日 K Provider（`push2his.eastmoney.com/api/qt/stock/kline/get`）。免 token。
///
/// 参数：`secid={1|0}.{code}`（沪 1 深 0 北 0）、`klt=101` 日线、`fqt=1` 前复权。
/// 坑（对拍 daily_stock_analysis `efinance_fetcher.py`）：成交量单位「手」→ ×100；
/// klines 是逗号分隔字符串：日期,开,收,高,低,量(手),额,振幅%,涨跌幅%,涨跌额,换手率%。
struct EastmoneyKlineProvider: MarketKlineProviding {
    let name = "eastmoney"

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
        let bare = MarketCodeNormalizer.bareACode(from: code)
        guard let secid = Self.secid(forBareCode: bare) else {
            throw MarketDataError.invalidResponse
        }
        let span = Self.dateSpan(forDays: days)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "push2his.eastmoney.com"
        components.path = "/api/qt/stock/kline/get"
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "klt", value: "101"),
            URLQueryItem(name: "fqt", value: "1"),
            URLQueryItem(name: "beg", value: span.begin),
            URLQueryItem(name: "end", value: span.end),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
        ]
        let url = components.url!
        let payload = try await session.json(url, headers: [
            "Accept": "application/json",
            "Referer": "https://quote.eastmoney.com/",
        ])
        guard let object = payload as? [String: Any],
              let data = object["data"] as? [String: Any],
              let klines = data["klines"] as? [String] else {
            throw MarketDataError.invalidResponse
        }
        return Self.parseKlines(klines)
    }

    // MARK: - 解析（纯函数，供测试）

    /// `2026-08-28,10.00,10.50,10.60,9.90,123456,1290000.00,7.00,5.00,0.50,1.20` → MarketDailyBar
    static func parseKlines(_ klines: [String]) -> [MarketDailyBar] {
        klines.compactMap { line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6,
                  let open = Double(parts[1]),
                  let close = Double(parts[2]),
                  let high = Double(parts[3]),
                  let low = Double(parts[4]),
                  let volumeHands = Double(parts[5])
            else { return nil }
            let amount = parts.count > 6 ? Double(parts[6]) : nil
            let pct = parts.count > 8 ? Double(parts[8]) : nil
            // 东财成交量单位：手 → 股
            let volume = volumeHands * 100
            return MarketDailyBar(
                date: String(parts[0].prefix(10)),
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume,
                amount: amount ?? 0,
                pctChg: pct
            )
        }
    }

    // MARK: - 工具

    /// secid：6/5/9 开头沪市 `1.`，其余（0/3/688 除外规则一致，深市与北交所）`0.`。
    static func secid(forBareCode bare: String) -> String? {
        guard bare.count == 6, bare.allSatisfy(\.isNumber) else { return nil }
        if bare.hasPrefix("6") || bare.hasPrefix("5") || bare.hasPrefix("9") {
            return bare.hasPrefix("92") ? "0.\(bare)" : "1.\(bare)"
        }
        return "0.\(bare)"
    }

    /// 日期窗口：自然日 × 1.9 + 20 天余量覆盖节假日，再截到 2006-01-01 起（东财历史起点够用）。
    static func dateSpan(forDays days: Int, from date: Date = Date()) -> (begin: String, end: String) {
        let clamped = min(max(days, 20), 1000)
        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        let begin = calendar.date(byAdding: .day, value: -(clamped * 2 + 20), to: date) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return (formatter.string(from: begin), formatter.string(from: end))
    }
}
