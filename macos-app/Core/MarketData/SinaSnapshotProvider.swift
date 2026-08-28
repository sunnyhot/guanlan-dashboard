import Foundation

/// 新浪全市场快照 Provider（`Market_Center.getHQNodeData`，node=hs_a 分页）。免 token。
///
/// 用途：市场广度计算的主数据源（一次拿全市场行情 + 估值字段）。
/// 坑（对拍 daily_stock_analysis `screening/snapshot.py:425-474`）：
/// - `mktcap`/`nmc`（总市值/流通市值）单位是**万元**，需 ×1e4 归一到元；
/// - node=hs_a 覆盖沪深 A股，**不含北交所**（dataBoundary 注明，东财快照源补齐）；
/// - 数值字段是字符串，需容错转换。
struct SinaSnapshotProvider: Sendable {
    static let pageSize = 100
    let name = "sina"
    /// 沪深 A股约 5400+ 只，60 页封顶防异常场景失控循环。
    static let maxPages = 60

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    // MARK: - 抓取

    /// 分页拉取全市场快照，直到单页数量 < pageSize（数据末尾）或达到页数上限。
    func fullMarketSnapshot() async throws -> [MarketQuote] {
        var quotes: [MarketQuote] = []
        for page in 1...Self.maxPages {
            let text = try await session.text(pageURL(page: page), headers: [
                "Accept": "text/javascript,*/*",
                "Referer": "https://vip.stock.finance.sina.com.cn/mkt/",
            ])
            let pageQuotes = Self.parsePage(text)
            quotes += pageQuotes
            if pageQuotes.count < Self.pageSize { break }
        }
        return quotes
    }

    func pageURL(page: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "vip.stock.finance.sina.com.cn"
        components.path = "/quotes_service/api/json_v2.php/Market_Center.getHQNodeData"
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "num", value: String(Self.pageSize)),
            URLQueryItem(name: "sort", value: "symbol"),
            URLQueryItem(name: "asc", value: "1"),
            URLQueryItem(name: "node", value: "hs_a"),
            URLQueryItem(name: "symbol", value: ""),
            URLQueryItem(name: "_s_r_a", value: "page"),
        ]
        return components.url!
    }

    // MARK: - 解析（纯函数，供测试）

    /// 解析单页 JSON 数组文本为行情列表。空页/坏页返回空数组（由调用方按页大小判断是否到末尾）。
    static func parsePage(_ jsonText: String) -> [MarketQuote] {
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data),
              let items = payload as? [[String: Any]]
        else { return [] }
        return items.compactMap(parseItem)
    }

    static func parseItem(_ item: [String: Any]) -> MarketQuote? {
        func string(_ key: String) -> String {
            (item[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func double(_ key: String) -> Double? {
            let raw = string(key)
            guard !raw.isEmpty else { return nil }
            return Double(raw).flatMap { $0.isFinite ? $0 : nil }
        }

        let symbol = string("symbol")
        let name = string("name")
        guard symbol.count > 2 else { return nil }
        let code = MarketCodeNormalizer.bareACode(from: symbol)
        let price = double("trade")

        // 新浪市值单位：万元 → 元
        let totalMarketCap = double("mktcap").map { $0 * 1e4 }
        let circMarketCap = double("nmc").map { $0 * 1e4 }
        let isST = MarketBoardRule.isSTName(name)

        return MarketQuote(
            code: code,
            name: name,
            price: price,
            previousClose: double("settlement"),
            changePct: double("changepercent"),
            open: double("open"),
            high: double("high"),
            low: double("low"),
            volume: double("volume"),
            amount: double("amount"),
            turnoverRate: double("turnoverratio"),
            peRatio: double("per"),
            pbRatio: double("pb"),
            volumeRatio: nil,
            totalMarketCap: totalMarketCap,
            circMarketCap: circMarketCap,
            limitUpPrice: nil,
            limitDownPrice: nil,
            isST: isST,
            board: MarketBoardRule.board(forCode: code),
            quotedAt: string("ticktime"),
            source: "sina"
        )
    }
}
