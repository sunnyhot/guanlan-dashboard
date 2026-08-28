import Foundation

// MARK: - 热榜源定义

/// NewsNow 财经热榜源。免 token，JSON 响应；属增强型数据，失败静默降级不阻塞主流程。
enum NewsFeedSource: String, CaseIterable, Codable, Hashable, Sendable {
    case cailiansheHot = "cls-hot"            // 财联社热门
    case xueqiuHotStock = "xueqiu-hotstock"   // 雪球热门股票
    case wallstreetcnQuick = "wallstreetcn-quick" // 华尔街见闻快讯
    case jin10 = "jin10"                      // 金十数据

    var displayName: String {
        switch self {
        case .cailiansheHot: return "财联社热榜"
        case .xueqiuHotStock: return "雪球热门股票"
        case .wallstreetcnQuick: return "华尔街见闻快讯"
        case .jin10: return "金十数据"
        }
    }
}

// MARK: - 热榜条目

struct NewsFeedItem: Codable, Hashable, Sendable, Identifiable {
    var id: String { itemID }
    let itemID: String
    let title: String
    var url: String?
    var sourceID: String
    var sourceName: String
}

// MARK: - Provider

/// NewsNow 热榜 Provider（`newsnow.busiyi.world/api/s?id={source}`）。
///
/// 对拍 daily_stock_analysis `intelligence_service.py`：UA 伪装浏览器、不跟随重定向；
/// 响应 `{code, data: [{id, title, url, ...}]}`，字段宽松解析（id 可为数字/字符串）。
struct NewsNowFeedProvider: Sendable {
    static let baseURL = URL(string: "https://newsnow.busiyi.world")!

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    func fetch(source: NewsFeedSource) async throws -> [NewsFeedItem] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/s"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: source.rawValue)]
        let url = components.url!
        let payload = try await session.json(url, headers: [
            "Accept": "application/json",
            "Referer": "https://newsnow.busiyi.world/",
        ])
        return Self.parseItems(payload, source: source)
    }

    // MARK: - 解析（纯函数，供测试）

    static func parseItems(_ payload: Any, source: NewsFeedSource) -> [NewsFeedItem] {
        guard let object = payload as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            let title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let itemID: String
            if let text = row["id"] as? String {
                itemID = text
            } else if let number = row["id"] as? NSNumber {
                itemID = number.stringValue
            } else if let rank = row["rank"] as? NSNumber {
                itemID = "rank-\(rank.stringValue)"
            } else {
                itemID = title
            }
            let url = (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return NewsFeedItem(
                itemID: "\(source.rawValue):\(itemID)",
                title: title,
                url: url,
                sourceID: source.rawValue,
                sourceName: source.displayName
            )
        }
    }
}
