import Foundation

// MARK: - Provider 协议（供引擎 fallback 链与测试注入）

protocol MarketQuoteProviding: Sendable {
    var name: String { get }
    func quotes(codes: [String]) async throws -> [MarketQuote]
}

protocol MarketKlineProviding: Sendable {
    var name: String { get }
    func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar]
}

protocol MarketSnapshotProviding: Sendable {
    var name: String { get }
    func fullMarketSnapshot() async throws -> [MarketQuote]
}

// MARK: - 腾讯行情 Provider 协议适配

extension TencentQuoteProvider: MarketQuoteProviding {}

// MARK: - 东财单股行情 Provider（fallback 用，轻字段）

/// 东财单股行情（`push2.eastmoney.com/api/qt/stock/get`）。免 token。
///
/// 作为腾讯行情的 fallback：只取价格三件套 + 名称 + 时间（口径与
/// QiemanPlatformNativeClient.fetchEastmoneyStockQuote 一致：f43 价格按 f59 精度缩放）。
struct EastmoneyQuoteProvider: MarketQuoteProviding {
    let name = "eastmoney"

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    func quotes(codes: [String]) async throws -> [MarketQuote] {
        var result: [MarketQuote] = []
        for code in codes {
            let bare = MarketCodeNormalizer.bareACode(from: code)
            guard let secid = EastmoneyKlineProvider.secid(forBareCode: bare) else { continue }
            let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&fields=f43,f57,f58,f59,f60,f86,f169,f170")!
            let payload = try await session.json(url, headers: [
                "Accept": "application/json",
                "Referer": "https://quote.eastmoney.com/",
            ])
            if let quote = Self.parseQuote(payload as? [String: Any] ?? [:], fallbackCode: bare) {
                result.append(quote)
            }
        }
        return result
    }

    static func parseQuote(_ object: [String: Any], fallbackCode: String) -> MarketQuote? {
        guard let data = object["data"] as? [String: Any] else { return nil }

        func double(_ key: String) -> Double? {
            if let number = data[key] as? NSNumber { return number.doubleValue }
            if let text = data[key] as? String { return Double(text) }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let number = data[key] as? NSNumber { return number.intValue }
            if let text = data[key] as? String { return Int(text) }
            return nil
        }

        let code = (data["f57"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackCode
        let scale = pow(10.0, Double(int("f59") ?? 2))
        func scaled(_ key: String) -> Double? {
            double(key).map { $0 / scale }
        }

        let price = scaled("f43")
        let previousClose = scaled("f60")
        let changePct = double("f170").map { $0 / 100 }
        guard price != nil || previousClose != nil else { return nil }

        let quotedAt = int("f86").flatMap { seconds -> String? in
            guard seconds > 0 else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }

        return MarketQuote(
            code: code,
            name: (data["f58"] as? String) ?? "",
            price: price,
            previousClose: previousClose,
            changePct: changePct,
            board: MarketBoardRule.board(forCode: code),
            quotedAt: quotedAt ?? "",
            source: "eastmoney"
        )
    }
}

// MARK: - 腾讯日 K Provider（东财 K 线的 fallback）

/// 腾讯日 K Provider（`web.ifzq.gtimg.cn/appstock/app/fqkline/get`）。免 token，JSON 响应。
///
/// 参数对拍 daily_stock_analysis `tencent_fetcher.py`：单次上限 800 根，
/// `count = max(30, min(800, 自然日×1.8+20))`；响应在 `data.{symbol}.qfqday`（或 `day`）；
/// 量纲坑：成交量单位「手」→ ×100。
struct TencentKlineProvider: MarketKlineProviding {
    let name = "tencent"
    static let maxCount = 800

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
        guard let symbol = TencentQuoteProvider.tencentSymbol(for: code) else {
            throw MarketDataError.invalidResponse
        }
        let clamped = min(max(days, 20), 500)
        let count = max(30, min(Self.maxCount, clamped * 2 + 20))
        let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(symbol),day,,,\(count),qfq")!
        let payload = try await session.json(url, headers: [
            "Accept": "application/json,text/plain,*/*",
            "Referer": "https://gu.qq.com/",
        ])
        return Self.parsePayload(payload, symbol: symbol)
    }

    // MARK: - 解析（纯函数，供测试）

    static func parsePayload(_ payload: Any, symbol: String) -> [MarketDailyBar] {
        guard let object = payload as? [String: Any],
              let data = object["data"] as? [String: Any],
              let symbolData = data[symbol] as? [String: Any]
        else { return [] }
        let rows = (symbolData["qfqday"] as? [[Any]]) ?? (symbolData["day"] as? [[Any]]) ?? []
        return rows.compactMap(parseRow)
    }

    /// 行格式：`[日期, 开, 收, 高, 低, 量(手), 额?]`（部分行带第 7 位成交额）。
    static func parseRow(_ row: [Any]) -> MarketDailyBar? {
        func double(_ index: Int) -> Double? {
            guard row.indices.contains(index) else { return nil }
            if let number = row[index] as? NSNumber { return number.doubleValue }
            if let text = row[index] as? String { return Double(text) }
            return nil
        }
        func dateText(_ index: Int) -> String? {
            guard row.indices.contains(index), let text = row[index] as? String else { return nil }
            return String(text.prefix(10))
        }
        guard let date = dateText(0),
              let open = double(1),
              let close = double(2),
              let high = double(3),
              let low = double(4),
              let volumeHands = double(5)
        else { return nil }
        return MarketDailyBar(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volumeHands * 100,
            amount: double(6) ?? 0,
            pctChg: nil
        )
    }
}

// MARK: - 东财全市场快照 Provider（新浪快照的 fallback，含北交所）

/// 东财选股快照 Provider（`data.eastmoney.com/dataapi/xuangu/list`）。免 token，周末可用。
///
/// 对拍 daily_stock_analysis `screening/snapshot.py:477-523`：分页 ps=500，
/// 终止条件 `page × ps >= data.result.count`；须带 `Referer: data.eastmoney.com/xuangu/`；
/// host 限速（≥1s + 0.3s 抖动）由 MarketDataSession 按 host 策略统一保证。
/// 无昨收字段 → 按 CHANGE_RATE 反推（effectivePreviousClose）。
struct EastmoneySnapshotProvider: MarketSnapshotProviding {
    let name = "eastmoney"

    static let pageSize = 500
    static let maxPages = 16

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    func fullMarketSnapshot() async throws -> [MarketQuote] {
        var quotes: [MarketQuote] = []
        var totalCount = Int.max
        for page in 1...Self.maxPages {
            let payload = try await session.json(pageURL(page: page), headers: [
                "Accept": "application/json",
                "Referer": "https://data.eastmoney.com/xuangu/",
            ])
            guard let object = payload as? [String: Any],
                  (object["success"] as? Bool) ?? true,
                  let data = object["data"] as? [String: Any],
                  let result = data["result"] as? [String: Any],
                  let rows = result["data"] as? [[String: Any]]
            else {
                throw MarketDataError.invalidResponse
            }
            if totalCount == Int.max {
                if let count = result["count"] as? Int {
                    totalCount = count
                } else if let countText = result["count"] as? String, let count = Int(countText) {
                    totalCount = count
                }
            }
            quotes += rows.compactMap(Self.parseItem)
            if page * Self.pageSize >= totalCount || rows.isEmpty { break }
        }
        return quotes
    }

    func pageURL(page: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "data.eastmoney.com"
        components.path = "/dataapi/xuangu/list"
        components.queryItems = [
            URLQueryItem(name: "st", value: "SECURITY_CODE"),
            URLQueryItem(name: "sr", value: "1"),
            URLQueryItem(name: "ps", value: String(Self.pageSize)),
            URLQueryItem(name: "p", value: String(page)),
            URLQueryItem(name: "sty", value: "SECUCODE,SECURITY_CODE,SECURITY_NAME_ABBR,NEW_PRICE,CHANGE_RATE,VOLUME_RATIO,DEAL_AMOUNT,TURNOVERRATE,PE9,PBNEWMRQ,TOTAL_MARKET_CAP,CIRCULATION_MARKET_CAP"),
            URLQueryItem(name: "filter", value: "(MARKET+in+(\"上交所主板\",\"深交所主板\",\"深交所创业板\",\"上交所科创板\",\"北交所\"))"),
            URLQueryItem(name: "source", value: "SELECT_SECURITIES"),
            URLQueryItem(name: "client", value: "WEB"),
        ]
        return components.url!
    }

    static func parseItem(_ item: [String: Any]) -> MarketQuote? {
        func double(_ key: String) -> Double? {
            if let number = item[key] as? NSNumber { return number.doubleValue }
            if let text = item[key] as? String { return Double(text).flatMap { $0.isFinite ? $0 : nil } }
            return nil
        }
        func string(_ key: String) -> String {
            (item[key] as? String) ?? ""
        }

        let code = string("SECURITY_CODE").trimmingCharacters(in: .whitespaces)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let name = string("SECURITY_NAME_ABBR")
        let isST = MarketBoardRule.isSTName(name)

        return MarketQuote(
            code: code,
            name: name,
            price: double("NEW_PRICE"),
            previousClose: nil,
            changePct: double("CHANGE_RATE"),
            amount: double("DEAL_AMOUNT"),
            turnoverRate: double("TURNOVERRATE"),
            peRatio: double("PE9"),
            pbRatio: double("PBNEWMRQ"),
            volumeRatio: double("VOLUME_RATIO"),
            totalMarketCap: double("TOTAL_MARKET_CAP"),
            circMarketCap: double("CIRCULATION_MARKET_CAP"),
            isST: isST,
            board: MarketBoardRule.board(forCode: code),
            source: "eastmoney"
        )
    }
}

// MARK: - 新浪快照 Provider 协议适配

extension SinaSnapshotProvider: MarketSnapshotProviding {}
