import Foundation

/// 基金/股票模糊搜索客户端，通过天天基金 + 东方财富搜索 API 实现。
/// 支持用名称、拼音、代码模糊搜索场外基金、场内基金（ETF/LOF）和股票。
struct FundSearchClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 搜索基金和股票，返回合并去重的结果列表。
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

    // MARK: - 场外基金搜索（天天基金 FundSearchAPI.ashx）

    private func searchFunds(_ keyword: String) async -> [FundSearchResult] {
        let encoded = Self.urlEncode(keyword)
        guard let url = URL(string: "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx?callback=&m=1&key=\(encoded)") else {
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
            guard let code = item["CODE"] as? String,
                  let name = item["NAME"] as? String else { return nil }
            let fundBaseInfo = item["FundBaseInfo"] as? [String: Any]
            let fundType = fundBaseInfo?["FTYPE"] as? String
            let shortName = fundBaseInfo?["SHORTNAME"] as? String
            return FundSearchResult(
                code: code,
                name: shortName ?? name,
                displayName: "\(shortName ?? name)（\(code)）",
                category: Self.fundCategoryLabel(fundType),
                assetType: .fund
            )
        }
    }

    // MARK: - 股票/ETF 搜索（东方财富 searchapi）

    private func searchStocks(_ keyword: String) async -> [FundSearchResult] {
        let encoded = Self.urlEncode(keyword)
        guard let url = URL(string: "https://searchapi.eastmoney.com/api/suggest/get?input=\(encoded)&type=14") else {
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
              let qct = json["QuotationCodeTable"] as? [String: Any],
              let table = qct["Data"] as? [[String: Any]] else {
            return []
        }

        return table.compactMap { (item: [String: Any]) -> FundSearchResult? in
            guard let code = item["Code"] as? String,
                  let name = item["Name"] as? String,
                  code.count == 5 || code.count == 6 else { return nil }

            let mktNum = item["MktNum"] as? String ?? ""
            let securityType = item["SecurityTypeName"] as? String ?? ""
            let category: String

            // MktNum: "1"=沪A, "0"=深A, "116"=港股, "105"=美股
            if mktNum == "116" || mktNum == "0116" {
                category = "港股"
            } else if mktNum == "105" || mktNum == "0105" || mktNum == "71" {
                category = "美股"
            } else {
                category = securityType.isEmpty ? "A股" : securityType
            }

            return FundSearchResult(
                code: code,
                name: name,
                displayName: "\(name)（\(code)）",
                category: category,
                assetType: .stock
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
