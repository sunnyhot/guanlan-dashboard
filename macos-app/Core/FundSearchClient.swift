import Foundation

/// 基金/股票模糊搜索客户端，通过天天基金 + 东方财富搜索 API 实现。
/// 支持用名称、拼音、代码模糊搜索场外基金、场内基金（ETF/LOF）和股票。
struct FundSearchClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 搜索基金和股票，返回合并去重的结果列表。
    /// - Parameter keyword: 搜索关键词（名称、拼音、代码均可）
    /// - Returns: 搜索结果，最多 10 条
    func search(_ keyword: String) async -> [FundSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }

        async let funds = searchFunds(trimmed)
        async let stocks = searchStocks(trimmed)

        var merged = await funds
        let stockResults = await stocks
        let existingCodes = Set(merged.map(\.code))
        for stock in stockResults where !existingCodes.contains(stock.code) {
            merged.append(stock)
        }
        return Array(merged.prefix(10))
    }

    // MARK: - 场外基金搜索

    private func searchFunds(_ keyword: String) async -> [FundSearchResult] {
        guard let url = URL(string: "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchPageJson.ashx?m=1&key=\(Self.urlEncode(keyword))&pageindex=0&pagesize=8") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let datas = json["Datas"] as? [[String: Any]] else {
            return []
        }

        return datas.compactMap { (item: [String: Any]) -> FundSearchResult? in
            let code = item["CODE"] as? String ?? item["SYMBOL"] as? String
            let name = item["NAME"] as? String ?? (item["FundBaseInfo"] as? [String: Any])?["SHORTNAME"] as? String
            let fundType = (item["FundBaseInfo"] as? [String: Any])?["FTYPE"] as? String
            guard let code, let name else { return nil }
            return FundSearchResult(
                code: code,
                name: name,
                displayName: "\(name)（\(code)）",
                category: Self.fundCategoryLabel(fundType),
                assetType: .fund
            )
        }
    }

    // MARK: - 股票/ETF 搜索

    private func searchStocks(_ keyword: String) async -> [FundSearchResult] {
        guard let url = URL(string: "https://searchapi.eastmoney.com/api/suggest/get?input=\(Self.urlEncode(keyword))&type=14") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = json["QuotationCodeTable"] as? [[String: Any]] else {
            return []
        }

        return table.compactMap { (item: [String: Any]) -> FundSearchResult? in
            guard let code = item["Code"] as? String,
                  let name = item["Name"] as? String else {
                return nil
            }
            let mktNum = item["MktNum"] as? String ?? ""
            let assetType: PersonalAssetType
            let category: String

            // MktNum: "1"=沪A, "0"=深A, "116"=港股, "105"=美股, ETF 带在 type 里
            let type = item["Type"] as? String ?? ""
            if type.contains("ETF") || type.contains("LOF") || code.hasPrefix("5") && mktNum == "1" || code.hasPrefix("1") && mktNum == "0" {
                assetType = .fund
                category = "场内基金"
            } else if mktNum == "116" || mktNum == "0116" {
                assetType = .stock
                category = "港股"
            } else if mktNum == "105" || mktNum == "0105" || mktNum == "71" {
                assetType = .stock
                category = "美股"
            } else {
                assetType = .stock
                category = mktNum == "1" ? "沪A" : "深A"
            }

            // 只保留 6 位代码的股票/基金结果
            guard code.count == 5 || code.count == 6 else { return nil }

            return FundSearchResult(
                code: code,
                name: name,
                displayName: "\(name)（\(code)）",
                category: category,
                assetType: assetType
            )
        }
    }

    // MARK: - Helpers

    private static func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    private static func fundCategoryLabel(_ ftype: String?) -> String {
        guard let ftype else { return "基金" }
        if ftype.contains("股票") { return "股票型" }
        if ftype.contains("混合") { return "混合型" }
        if ftype.contains("债券") { return "债券型" }
        if ftype.contains("指数") || ftype.contains("ETF") { return "指数型" }
        if ftype.contains("QDII") { return "QDII" }
        if ftype.contains("货币") { return "货币型" }
        return "基金"
    }
}

// MARK: - 搜索结果模型

struct FundSearchResult: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let displayName: String
    let category: String
    let assetType: PersonalAssetType
    var id: String { code }
}
