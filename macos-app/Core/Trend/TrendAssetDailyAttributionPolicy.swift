import Foundation

/// 约束基金当日涨跌说明必须是可验证归因，而不是市值、累计盈亏或持仓名单的复述。
enum TrendAssetDailyAttributionPolicy {
    static let attributionPrefix = "涨跌归因："
    static let unavailablePrefix = "原因待确认："
    static let maxUnderlyingQuoteCount = 40

    private static let causalEvidencePrefixes = [
        "market:stock:",
        "web:tavily:",
        "vendor:alphavantage:",
    ]
    private static let unavailableBoundaryTerms = [
        "缺少", "未取得", "未提供", "无法", "不足", "没有",
    ]

    static func displayText(
        from rawValue: String?,
        hasDailyChange: Bool
    ) -> String? {
        guard hasDailyChange else { return nil }
        guard let value = normalized(rawValue),
              value.hasPrefix(attributionPrefix) || value.hasPrefix(unavailablePrefix) else {
            return unavailablePrefix
                + "旧报告只记录了持仓结构与净值结果，没有提供可验证的当日涨跌归因；请重新运行 AI 分析。"
        }
        return value
    }

    static func validationMessage(for asset: TrendAssetView) -> String? {
        guard let value = normalized(asset.impactText) else {
            return "基金 \(asset.code ?? asset.name) 的 impactText 不能为空。"
        }
        if value.hasPrefix(unavailablePrefix) {
            guard unavailableBoundaryTerms.contains(where: value.contains) else {
                return "基金 \(asset.code ?? asset.name) 使用「原因待确认：」时，必须说明缺少哪类行情或证据，不能继续复述静态持仓数据。"
            }
            return nil
        }
        guard value.hasPrefix(attributionPrefix) else {
            return "基金 \(asset.code ?? asset.name) 的 impactText 必须以「涨跌归因：」或「原因待确认：」开头；不得用市值、累计盈亏、持仓名单或净值涨跌本身代替原因。"
        }

        let supportingIDs = asset.claimEvidence.supportingEvidenceIDs
        guard supportingIDs.contains(where: isCausalEvidenceID) else {
            return "基金 \(asset.code ?? asset.name) 声称完成涨跌归因，但没有引用底层证券行情或外部研究证据；证据不足时请改为「原因待确认：」。"
        }
        return nil
    }

    static func underlyingQuoteCodes(
        in snapshot: PortfolioLookThroughSnapshot
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for fundCode in snapshot.disclosures.keys.sorted() {
            guard let disclosure = snapshot.disclosures[fundCode] else { continue }
            let topStocks = disclosure.holdings
                .filter { $0.kind == .stock }
                .sorted { $0.weightPct > $1.weightPct }
                .prefix(3)
            for holding in topStocks {
                let code = holding.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty, seen.insert(code).inserted else { continue }
                result.append(code)
                if result.count == maxUnderlyingQuoteCount {
                    return result
                }
            }
        }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isCausalEvidenceID(_ evidenceID: String) -> Bool {
        causalEvidencePrefixes.contains { evidenceID.hasPrefix($0) }
    }
}
