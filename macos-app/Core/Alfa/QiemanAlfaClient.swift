import Foundation

// MARK: - 缓存

/// alfa 投顾组合调仓的内存缓存（TTL + LRU），照搬 `QiemanPlatformCache` 思路。
actor QiemanAlfaCache {
    static let maxEntries = 16
    private var payloads: [String: (Date, PlatformPayload)] = [:]

    func payload(for poCode: String, ttl: TimeInterval) -> PlatformPayload? {
        guard let (loadedAt, payload) = payloads[poCode], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return payload
    }

    func store(payload: PlatformPayload, for poCode: String) {
        payloads[poCode] = (Date(), payload)
        while payloads.count > Self.maxEntries {
            guard let oldestKey = payloads.min(by: { $0.value.0 < $1.value.0 })?.key else { return }
            payloads.removeValue(forKey: oldestKey)
        }
    }
}

// MARK: - 错误

enum AlfaClientError: LocalizedError {
    case missingPoCode
    case graphQL([String])
    case api(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingPoCode:
            return "没有组合代码，无法拉取投顾调仓。"
        case .graphQL(let messages):
            return "投顾接口返回错误：\(messages.joined(separator: "; "))"
        case .api(let message):
            return message
        case .invalidResponse:
            return "投顾接口返回结构异常。"
        }
    }
}

// MARK: - 客户端

/// 且慢 alfa 投顾线客户端。
///
/// 通过 GraphQL（`POST /alfa/v1/graphql`）抓取投顾组合调仓，签名算法见
/// `QiemanRequestSigning`。与 `QiemanPlatformNativeClient`（长赢 REST 接口）并列，
/// 但抓取的调仓数据拍平映射成同一套 `PlatformPayload`，下游 UI 可复用。
final class QiemanAlfaClient {
    private let baseURL = URL(string: "https://qieman.com")!
    private let graphQLPath = "/alfa/v1/graphql"
    private let apiBase = "/pmdj/v2"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private let anonymousID = "anon-\(QiemanRequestSigning.sha256Hex(UUID().uuidString).prefix(16))"
    private let broker = "0008"
    private let payloadTTL: TimeInterval = 120
    private let cache = QiemanAlfaCache()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 公开方法

    /// 抓取投顾组合调仓，映射成 `PlatformPayload`（复用现有模型）。
    func fetchAlfaPayload(poCode: String) async throws -> PlatformPayload {
        let target = poCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw AlfaClientError.missingPoCode
        }
        if let cached = await cache.payload(for: target, ttl: payloadTTL) {
            return cached
        }
        let data = try await requestAdjustments(poCode: target)
        let payload = buildPayload(poCode: target, data: data)
        await cache.store(payload: payload, for: target)
        return payload
    }

    /// 拉取投顾组合的当前持仓成分（PoFundComposition query）。
    func fetchAlfaComposition(poCode: String) async throws -> [AlfaHoldingPart] {
        let target = poCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw AlfaClientError.missingPoCode
        }
        let data = try await requestGraphQL(
            operationName: "PoFundComposition",
            variables: ["poCode": target],
            query: Self.compositionQuery
        )
        return Self.flattenComposition(poCode: target, data: data)
    }

    /// 拉取可选组合目录（数据源：`/m4/hand-picked`，REST，无需签名）。
    func fetchPortfolioCatalog() async throws -> [AlfaPortfolioCatalogItem] {
        let raw = try await requestREST(path: "/m4/hand-picked", params: [:])
        guard let object = raw as? [String: Any],
              let categories = object["handPickedItems"] as? [[String: Any]] else {
            throw AlfaClientError.invalidResponse
        }
        var items: [AlfaPortfolioCatalogItem] = []
        for category in categories {
            let categoryName = Self.normalizedString(category["shortName"]).isEmpty
                ? Self.normalizedString(category["name"])
                : Self.normalizedString(category["shortName"])
            guard let recommends = category["recommends"] as? [[String: Any]] else { continue }
            for rec in recommends {
                let poCode = Self.normalizedString(rec["recCode"])
                let name = Self.normalizedString(rec["recName"])
                guard !poCode.isEmpty, !name.isEmpty else { continue }
                items.append(
                    AlfaPortfolioCatalogItem(
                        poCode: poCode,
                        name: name,
                        author: Self.normalizedString(rec["author"]),
                        category: categoryName
                    )
                )
            }
        }
        return items
    }

    /// 查询单个组合基本信息（用于校验组合码是否有效、获取名称）。
    func fetchPortfolioName(poCode: String) async throws -> String? {
        let target = poCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw AlfaClientError.missingPoCode }
        let data = try await requestGraphQL(
            operationName: "PoBasicDetail",
            variables: ["poCode": target, "isLongWin": false],
            query: Self.basicDetailQuery
        )
        let portfolio = (data["portfolio"] as? [String: Any]) ?? [:]
        let name = Self.normalizedString(portfolio["poName"])
        return name.isEmpty ? nil : name
    }

    // MARK: - GraphQL 请求

    /// 发起 GraphQL 请求，返回 `data` 节点内容。
    private func requestGraphQL(operationName: String, variables: [String: Any], query: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "operationName": operationName,
            "variables": variables,
            "query": query,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: baseURL.appendingPathComponent(graphQLPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://qieman.com", forHTTPHeaderField: "Origin")
        request.setValue("https://qieman.com", forHTTPHeaderField: "Referer")
        request.setValue(broker, forHTTPHeaderField: "x-broker")
        request.setValue(QiemanRequestSigning.makeXRequestID(prefix: "zeus.", anonymousID: anonymousID), forHTTPHeaderField: "x-request-id")
        request.setValue(QiemanRequestSigning.makeXSign(), forHTTPHeaderField: "x-sign")
        request.setValue(anonymousID, forHTTPHeaderField: "sensors-anonymous-id")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AlfaClientError.invalidResponse }
        guard http.statusCode == 200 else {
            throw AlfaClientError.api("HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AlfaClientError.invalidResponse
        }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { ($0["message"] as? String) }
            throw AlfaClientError.graphQL(messages.isEmpty ? ["未知错误"] : messages)
        }
        guard let dataNode = object["data"] as? [String: Any] else {
            throw AlfaClientError.invalidResponse
        }
        return dataNode
    }

    /// 拉取调仓数据（GraphQL `Adjustment` query）。
    private func requestAdjustments(poCode: String) async throws -> [String: Any] {
        try await requestGraphQL(
            operationName: "Adjustment",
            variables: [
                "page": ["size": 50] as [String: Any],
                "needPreference": false,
                "needCategoryDict": false,
                "isModelPo": false,
                "poCode": poCode,
            ],
            query: Self.adjustmentQuery
        )
    }

    /// REST GET 请求（用于 hand-picked 目录）。
    private func requestREST(path: String, params: [String: String]) async throws -> Any {
        var components = URLComponents(url: baseURL.appendingPathComponent(apiBase).appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !params.isEmpty {
            components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw AlfaClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - 拍平映射

    /// 将 GraphQL `Adjustment` 响应拍平成 `PlatformPayload`。
    /// groups[].parts[] 三层展开为扁平的 actions 列表。
    private func buildPayload(poCode: String, data: [String: Any]) -> PlatformPayload {
        Self.flattenAdjustments(poCode: poCode, data: data)
    }

    /// 纯函数拍平逻辑（internal 便于测试）。
    static func flattenAdjustments(poCode: String, data: [String: Any]) -> PlatformPayload {
        let portfolio = (data["portfolio"] as? [String: Any]) ?? [:]
        let adjustmentsNode = (portfolio["adjustments"] as? [String: Any]) ?? [:]
        let rawAdjustments = (adjustmentsNode["adjustments"] as? [[String: Any]]) ?? []

        var actions: [PlatformActionPayload] = []
        var adjustmentCount = 0

        for adjustment in rawAdjustments {
            let adjustmentID = Self.intValue(adjustment["adjustmentId"]) ?? 0
            let dateText = Self.normalizedString(adjustment["date"])
            let comment = Self.normalizedString(adjustment["comment"])
            let articleNode = adjustment["article"] as? [String: Any]
            let articleLink = Self.normalizedString(articleNode?["link"])
            let groups = (adjustment["groups"] as? [[String: Any]]) ?? []
            let txnDate = Self.formatDate(dateText)
            let hasParts = groups.contains { !(($0["parts"] as? [[String: Any]]) ?? []).isEmpty }
            guard hasParts else { continue }
            adjustmentCount += 1

            for (groupIndex, group) in groups.enumerated() {
                let groupName = Self.normalizedString(group["movementName"])
                let parts = (group["parts"] as? [[String: Any]]) ?? []
                for (partIndex, part) in parts.enumerated() {
                    guard let action = makeAction(
                        from: part,
                        poCode: poCode,
                        adjustmentID: adjustmentID,
                        adjustmentComment: comment,
                        groupName: groupName,
                        txnDate: txnDate,
                        articleLink: articleLink,
                        groupIndex: groupIndex,
                        partIndex: partIndex,
                        partsCount: parts.count
                    ) else { continue }
                    actions.append(action)
                }
            }
        }

        actions.sort { ($0.txnDate ?? "") > ($1.txnDate ?? "") }

        let buyCount = actions.filter { $0.side == "buy" }.count
        let sellCount = actions.filter { $0.side == "sell" }.count

        return PlatformPayload(
            supported: true,
            prodCode: poCode,
            count: actions.count,
            buyCount: buyCount,
            sellCount: sellCount,
            adjustmentCount: adjustmentCount,
            latest: actions.first,
            actions: actions,
            holdings: nil,
            timeline: nil,
            error: nil
        )
    }

    /// 将 GraphQL `PoFundComposition` 响应拍平成持仓成分列表。
    /// groups[].parts[] 两层展开为扁平的 AlfaHoldingPart 列表。
    static func flattenComposition(poCode: String, data: [String: Any]) -> [AlfaHoldingPart] {
        let portfolio = (data["portfolio"] as? [String: Any]) ?? [:]
        let composition = (portfolio["composition"] as? [String: Any]) ?? [:]
        let groups = (composition["groups"] as? [[String: Any]]) ?? []

        var parts: [AlfaHoldingPart] = []
        for group in groups {
            let groupParts = (group["parts"] as? [[String: Any]]) ?? []
            let categoryCode = normalizedString(group["categoryCode"])
            for rawPart in groupParts {
                let fundNode = (rawPart["fund"] as? [String: Any]) ?? [:]
                let fundCode = normalizedString(fundNode["fundCode"])
                let fundName = normalizedString(fundNode["fundName"])
                guard !fundCode.isEmpty || !fundName.isEmpty else { continue }
                let percent = doubleValue(rawPart["percent"]) ?? 0
                parts.append(
                    AlfaHoldingPart(
                        sourcePoCode: poCode,
                        fundCode: fundCode,
                        fundName: fundName,
                        percent: percent,
                        nav: doubleValue(fundNode["nav"]),
                        navDate: formatDate(normalizedString(fundNode["navDate"])),
                        dailyReturn: doubleValue(fundNode["dailyReturn"]),
                        categoryCode: categoryCode.isEmpty ? nil : categoryCode,
                        varietyName: normalizedString(rawPart["varietyName"]).isEmpty ? nil : normalizedString(rawPart["varietyName"])
                    )
                )
            }
        }
        // 按占比降序
        return parts.sorted { $0.percent > $1.percent }
    }
    private static func makeAction(
        from part: [String: Any],
        poCode: String,
        adjustmentID: Int,
        adjustmentComment: String,
        groupName: String,
        txnDate: String,
        articleLink: String,
        groupIndex: Int,
        partIndex: Int,
        partsCount: Int
    ) -> PlatformActionPayload? {
        let fundNode = (part["fund"] as? [String: Any]) ?? [:]
        let fundCode = normalizedString(fundNode["fundCode"])
        let fundName = normalizedString(fundNode["fundName"])
        guard !fundCode.isEmpty || !fundName.isEmpty else { return nil }

        let before = doubleValue(part["beforePercent"])
        let after = doubleValue(part["afterPercent"])
        let side = deriveSide(before: before, after: after)
        let actionLabel = side == "buy" ? "加仓" : (side == "sell" ? "减仓" : "调整")
        let pctText = percentText(before: before, after: after)
        let actionTitle = "\(actionLabel) \(fundName)（\(pctText)）"

        return PlatformActionPayload(
            actionKey: "\(adjustmentID):\(fundCode):\(side):\(groupIndex)-\(partIndex)",
            adjustmentId: adjustmentID,
            adjustmentTitle: adjustmentComment.isEmpty ? "调仓 \(adjustmentID)" : adjustmentComment,
            title: fundName,
            actionTitle: actionTitle,
            fundName: fundName,
            fundCode: fundCode,
            side: side,
            action: actionLabel,
            tradeUnit: nil,
            postPlanUnit: nil,
            createdAt: txnDate,
            txnDate: txnDate,
            createdTs: nil,
            txnTs: nil,
            articleUrl: articleLink.isEmpty ? nil : articleLink,
            comment: adjustmentComment,
            strategyType: nil,
            largeClass: nil,
            buyDate: nil,
            nav: nil,
            navDate: nil,
            orderCountInAdjustment: partsCount,
            tradeValuation: nil,
            tradeValuationDate: nil,
            tradeValuationSource: nil,
            currentValuation: nil,
            currentValuationTime: nil,
            currentValuationSource: nil,
            valuationChangeAmount: nil,
            valuationChangePct: nil,
            beforePercent: before,
            afterPercent: after,
            groupName: groupName.isEmpty ? nil : groupName,
            sourcePoCode: poCode.isEmpty ? nil : poCode
        )
    }

    /// 由 before/after 百分比推导买卖方向。
    static func deriveSide(before: Double?, after: Double?) -> String {
        guard let before, let after else { return "hold" }
        if after > before + 0.0001 { return "buy" }
        if after < before - 0.0001 { return "sell" }
        return "hold"
    }

    // MARK: - 工具

    static func normalizedString(_ value: Any?) -> String {
        QiemanText.normalizedString(value)
    }

    static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    /// ISO8601 日期（如 "2026-03-05T00:00:00+08:00"）转 "yyyy-MM-dd"。
    static func formatDate(_ iso: String) -> String {
        guard iso.count >= 10 else { return iso }
        return String(iso.prefix(10))
    }

    /// 百分比格式化（0~1 → "0%→5%"）。
    static func percentText(before: Double?, after: Double?) -> String {
        let b = before.map { Self.formatPercent($0) } ?? "—"
        let a = after.map { Self.formatPercent($0) } ?? "—"
        return "\(b)→\(a)"
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = value * 100
        return String(format: "%.2f%%", pct)
    }

    // MARK: - GraphQL query 文本

    /// 调仓查询（来自 HAR 抓包的字节级原版，schema 对默认值/片段敏感，勿改）。
    static let adjustmentQuery = """
    query Adjustment($poCode: String!, $page: Pagination = null, $needPreference: Boolean! = false, $needCategoryDict: Boolean! = false, $isModelPo: Boolean = false, $categoryType: FundCategoryType) {
      portfolio(poCode: $poCode, isModelPo: $isModelPo) {
        isSupportSmartAip
        adjustments(page: $page, categoryType: $categoryType) {
          adjustments {
            date
            comment
            adjustmentId
            article {
              text
              link
              __typename
            }
            groups {
              categoryCode
              categoryCodeLevel1
              movementName
              parts {
                fund {
                  fundCode
                  fundName
                  __typename
                }
                movementName
                beforePercent
                afterPercent
                categoryCode
                categoryCodeLevel1
                __typename
              }
              beforePercent
              afterPercent
              __typename
            }
            __typename
          }
          totalCount
          pageInfo {
            hasMore
            cursor
            __typename
          }
          __typename
        }
        __typename
      }
      preferences @include(if: $needPreference) {
        portfolio(poCode: $poCode, isModelPo: $isModelPo) {
          adjustmentDetailListSeries
          adjustmentDetailDimensions
          __typename
        }
        __typename
      }
      dicts @include(if: $needCategoryDict) {
        portfolioCompositionCategoryNames
        portfolioRiskLevelNames
        fundCategoryLevel1Names
        __typename
      }
    }
    """

    /// 组合基本信息查询（用于校验组合码、获取名称）。
    static let basicDetailQuery = """
    query PoBasicDetail($poCode: String!, $isLongWin: Boolean) {
      portfolio(poCode: $poCode, isModelPo: $isLongWin) {
        poName
        __typename
      }
    }
    """

    /// 当前持仓成分查询（来自 HAR 抓包，schema 对完整性敏感，勿删片段）。
    static let compositionQuery = """
    query PoFundComposition($poCode: String!) {
      portfolio(poCode: $poCode) {
        composition {
          updatedAt
          groups {
            parts {
              percent
              categoryCode
              fund {
                fundCode
                fundName
                nav
                navDate
                dailyReturn
                __typename
              }
              candidateFunds {
                fundCode
                fundName
                __typename
              }
              latestMovementName
              latestMovement
              varietyName
              __typename
            }
            percent
            categoryCode
            __typename
          }
          __typename
        }
        __typename
      }
      preferences {
        portfolio(poCode: $poCode) {
          hasFundInvestPoolPage
          hasAdjustmentHistoryPage
          displayCompositionPieChart
          displayCompositionDetailList
          compositionDetailListSeries
          __typename
        }
        __typename
      }
      dicts {
        portfolioCompositionCategoryNames
        __typename
      }
    }
    """
}
