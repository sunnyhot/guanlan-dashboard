import Foundation

struct UserPortfolioHolding: Codable, Hashable, Identifiable {
    let id: UUID
    let fundCode: String
    let assetType: PersonalAssetType
    let units: Double
    let costPrice: Double?
    let displayName: String?
    let stockMarket: StockMarket?
    let fundMarket: FundMarket?
    let isArchived: Bool
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fundCode
        case assetType
        case units
        case costPrice
        case displayName
        case stockMarket
        case fundMarket
        case isArchived
        case archivedAt
    }

    init(
        id: UUID = UUID(),
        fundCode: String,
        assetType: PersonalAssetType = .fund,
        units: Double,
        costPrice: Double?,
        displayName: String?,
        stockMarket: StockMarket? = nil,
        fundMarket: FundMarket? = nil,
        isArchived: Bool = false,
        archivedAt: String? = nil
    ) {
        self.id = id
        self.fundCode = fundCode
        self.assetType = assetType
        self.units = units
        self.costPrice = costPrice
        self.displayName = displayName
        self.stockMarket = stockMarket
        self.fundMarket = fundMarket
        self.isArchived = isArchived
        self.archivedAt = archivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.fundCode = try container.decode(String.self, forKey: .fundCode)
        self.assetType = try container.decodeIfPresent(PersonalAssetType.self, forKey: .assetType) ?? .fund
        self.units = try container.decode(Double.self, forKey: .units)
        self.costPrice = try container.decodeIfPresent(Double.self, forKey: .costPrice)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.stockMarket = try container.decodeIfPresent(StockMarket.self, forKey: .stockMarket)
        self.fundMarket = try container.decodeIfPresent(FundMarket.self, forKey: .fundMarket)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
    }

    var normalizedFundCode: String {
        fundCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedName: String? {
        let value = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var detectedMarket: StockMarket? {
        if let stockMarket { return stockMarket }
        guard assetType == .stock else { return nil }
        return UserPortfolioHolding.detectStockMarket(from: normalizedFundCode)
    }

    var detectedFundMarket: FundMarket? {
        guard assetType == .fund else { return nil }
        let inferredMarket = UserPortfolioHolding.detectFundMarket(from: normalizedFundCode)
        if fundMarket == .onExchange,
           inferredMarket == .offExchange,
           UserPortfolioHolding.isKnownOffExchangeFundCode(normalizedFundCode) {
            return .offExchange
        }
        return fundMarket ?? inferredMarket
    }

    var marketLabel: String? {
        if assetType == .stock {
            return detectedMarket?.displayName
        }
        return detectedFundMarket?.displayName
    }

    static func detectStockMarket(from code: String) -> StockMarket? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("SH") || trimmed.hasPrefix("SZ") || trimmed.hasPrefix("BJ") {
            return .aShare
        }
        if trimmed.hasPrefix("HK") {
            return .hk
        }
        if trimmed.hasPrefix("US") {
            return .us
        }
        if trimmed.count == 6, trimmed.allSatisfy(\.isNumber) {
            return .aShare
        }
        if trimmed.count == 5, trimmed.allSatisfy(\.isNumber) {
            return .hk
        }
        if trimmed.allSatisfy({ $0.isLetter }) {
            return .us
        }
        return nil
    }

    static func detectFundMarket(from code: String) -> FundMarket {
        let rawCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if rawCode.hasPrefix("ETF:") || rawCode.hasPrefix("LOF:") || rawCode.hasPrefix("EX:") {
            return .onExchange
        }
        if rawCode.hasPrefix("FUND:") || rawCode.hasPrefix("OTC:") {
            return .offExchange
        }
        let normalized = normalizedFundCode(from: code).uppercased()
        guard normalized.count == 6, normalized.allSatisfy(\.isNumber) else {
            return .offExchange
        }
        if isKnownOffExchangeFundCode(normalized) {
            return .offExchange
        }
        if isLikelyExchangeTradedFundCode(normalized) {
            return .onExchange
        }
        return .offExchange
    }

    static func isKnownOffExchangeFundCode(_ code: String) -> Bool {
        let normalized = normalizedFundCode(from: code).uppercased()
        return normalized.hasPrefix("519")
    }

    private static func isLikelyExchangeTradedFundCode(_ code: String) -> Bool {
        let normalized = normalizedFundCode(from: code).uppercased()
        let exchangePrefixes = ["15", "50", "52", "56", "58"]
        if exchangePrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }
        return normalized.hasPrefix("51") && !normalized.hasPrefix("519")
    }

    static func normalizedFundCode(from code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        for prefix in ["ETF:", "LOF:", "EX:", "FUND:", "OTC:"] where upper.hasPrefix(prefix) {
            return String(upper.dropFirst(prefix.count))
        }
        if upper.count == 8,
           (upper.hasPrefix("SH") || upper.hasPrefix("SZ") || upper.hasPrefix("BJ")),
           upper.dropFirst(2).allSatisfy(\.isNumber) {
            return String(upper.dropFirst(2))
        }
        if upper.count == 9,
           (upper.hasSuffix(".SH") || upper.hasSuffix(".SZ") || upper.hasSuffix(".BJ")),
           upper.prefix(6).allSatisfy(\.isNumber) {
            return String(upper.prefix(6))
        }
        return trimmed
    }

    var draftLine: String {
        var parts: [String] = []
        if assetType == .stock, let market = detectedMarket {
            parts.append(market.displayName)
        } else if assetType == .fund, let market = detectedFundMarket {
            parts.append(market.displayName)
        } else if let draftPrefix = assetType.draftPrefix {
            parts.append(draftPrefix)
        }
        parts.append(contentsOf: [normalizedFundCode, Self.decimalText(units)])
        if let costPrice {
            parts.append(Self.decimalText(costPrice))
        }
        if let normalizedName {
            parts.append(normalizedName)
        }
        return parts.joined(separator: " ")
    }

    private static func decimalText(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0000001 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.4f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

struct UserPortfolioValuationRow: Hashable, Identifiable {
    let holding: UserPortfolioHolding
    let fundName: String
    let currentPrice: Double?
    let priceTime: String?
    let priceSource: String?
    let officialNav: Double?
    let officialNavDate: String?
    let estimatePrice: Double?
    let estimatePriceTime: String?
    let marketValue: Double?
    let costValue: Double?
    let profitAmount: Double?
    let profitPct: Double?
    let estimateChangePct: Double?

    var id: UUID { holding.id }

    var resolvedPrice: Double? {
        currentPrice ?? officialNav
    }

    var resolvedPriceTime: String? {
        priceTime ?? officialNavDate
    }

    var resolvedPriceSource: String? {
        priceSource ?? (officialNav != nil ? "最新净值" : nil)
    }

    var dropdownQuote: UserPortfolioDisplayQuote {
        dropdownQuote(marketDate: Self.currentMarketDateString())
    }

    func dropdownQuote(marketDate: String) -> UserPortfolioDisplayQuote {
        if holding.assetType == .stock || holding.detectedFundMarket == .onExchange {
            return UserPortfolioDisplayQuote(
                label: priceTime?.hasPrefix(marketDate) == true ? "实时净值" : "最新净值",
                price: currentPrice,
                time: priceTime
            )
        }

        if let officialNav,
           let officialNavDate,
           officialNavDate.hasPrefix(marketDate) {
            return UserPortfolioDisplayQuote(
                label: "确认净值",
                price: officialNav,
                time: officialNavDate
            )
        }

        if let estimatePrice {
            return UserPortfolioDisplayQuote(
                label: "预估净值",
                price: estimatePrice,
                time: estimatePriceTime
            )
        }

        return UserPortfolioDisplayQuote(
            label: officialNav == nil ? "预估净值" : "最新净值",
            price: officialNav,
            time: officialNavDate ?? priceTime
        )
    }

    static func currentMarketDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    var changeDate: String? {
        guard estimateChangePct != nil else { return nil }
        let rawValue: String?
        if estimatePrice != nil {
            rawValue = estimatePriceTime ?? priceTime ?? officialNavDate
        } else {
            rawValue = priceTime ?? officialNavDate
        }
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(10))
    }

    var changePeriodTitle: String {
        changePeriodTitle(marketDate: Self.currentMarketDateString())
    }

    func changePeriodTitle(marketDate: String) -> String {
        changeDate == marketDate ? "今日涨跌" : "最近涨跌"
    }

    var estimatedMarketValue: Double? {
        guard let estimatePrice, holding.units > 0 else { return nil }
        return estimatePrice * holding.units
    }

    var previousMarketValue: Double? {
        guard
            let marketValue,
            let estimateChangePct
        else {
            return nil
        }
        let factor = 1 + estimateChangePct / 100
        guard factor > 0 else { return nil }
        return marketValue / factor
    }

    var estimatedDailyChangeAmount: Double? {
        if let estimatedMarketValue, let marketValue {
            return estimatedMarketValue - marketValue
        }
        guard
            let marketValue,
            let previousMarketValue
        else {
            return nil
        }
        return marketValue - previousMarketValue
    }
}

struct UserPortfolioDisplayQuote: Hashable {
    let label: String
    let price: Double?
    let time: String?

    var trimmedTime: String? {
        let value = time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var compactLabel: String {
        label.replacingOccurrences(of: "净值", with: "")
    }

    var compactText: String {
        "\(compactLabel) \(price.map(decimalText) ?? "—")"
    }
}

struct UserPortfolioDailyChangeSummary: Hashable {
    let amount: Double?
    let pct: Double?

    init(rows: [UserPortfolioValuationRow]) {
        var amountTotal = 0.0
        var amountCount = 0
        var pctChangeTotal = 0.0
        var pctPreviousTotal = 0.0

        for row in rows {
            guard let change = row.estimatedDailyChangeAmount else { continue }
            amountTotal += change
            amountCount += 1

            if let previous = row.previousMarketValue, previous > 0 {
                pctChangeTotal += change
                pctPreviousTotal += previous
            }
        }

        amount = amountCount > 0 ? amountTotal : nil
        pct = pctPreviousTotal > 0 ? pctChangeTotal / pctPreviousTotal * 100 : nil
    }
}

struct UserPortfolioSnapshot: Hashable {
    let rows: [UserPortfolioValuationRow]
    let refreshedAt: String
    let totalMarketValue: Double
    let totalCostValue: Double?
    let totalProfitAmount: Double?
    let totalProfitPct: Double?
    let dailyChangeSummary: UserPortfolioDailyChangeSummary

    var holdingCount: Int { rows.count }
    var dailyChangeCoverageCount: Int {
        rows.filter { $0.estimatedDailyChangeAmount != nil || $0.estimateChangePct != nil }.count
    }
    var dailyChangePendingCount: Int {
        max(0, holdingCount - dailyChangeCoverageCount)
    }
    var latestOfficialNavDate: String? {
        rows.compactMap(\.officialNavDate).map { String($0.prefix(10)) }.max()
    }
    var latestChangeDate: String? {
        rows.compactMap(\.changeDate).max()
    }
    var dailyChangeTitle: String {
        dailyChangeTitle(marketDate: UserPortfolioValuationRow.currentMarketDateString())
    }
    func dailyChangeTitle(marketDate: String) -> String {
        let coveredRows = rows.filter {
            $0.estimatedDailyChangeAmount != nil || $0.estimateChangePct != nil
        }
        guard !coveredRows.isEmpty else { return "今日涨跌" }
        return coveredRows.allSatisfy { $0.changeDate == marketDate } ? "今日涨跌" : "最近涨跌"
    }
    var refreshNoticeMessage: String {
        guard holdingCount > 0 else { return "个人持仓已刷新。" }
        if dailyChangeCoverageCount == holdingCount {
            return "个人持仓估值和涨跌已刷新。"
        }
        if dailyChangeCoverageCount == 0 {
            if let latestOfficialNavDate {
                return "持仓净值已刷新至 \(latestOfficialNavDate)；涨跌数据待公布。"
            }
            return "个人持仓已刷新；涨跌暂时没有可用数据。"
        }
        return "个人持仓已刷新；涨跌已更新 \(dailyChangeCoverageCount)/\(holdingCount)，其余待公布。"
    }
    var hasIncompleteValuationCoverage: Bool {
        rows.contains { $0.marketValue == nil }
    }

    init(
        rows: [UserPortfolioValuationRow],
        refreshedAt: String,
        totalMarketValue: Double,
        totalCostValue: Double?,
        totalProfitAmount: Double?,
        totalProfitPct: Double?,
        dailyChangeSummary: UserPortfolioDailyChangeSummary? = nil
    ) {
        self.rows = rows
        self.refreshedAt = refreshedAt
        self.totalMarketValue = totalMarketValue
        self.totalCostValue = totalCostValue
        self.totalProfitAmount = totalProfitAmount
        self.totalProfitPct = totalProfitPct
        self.dailyChangeSummary = dailyChangeSummary ?? UserPortfolioDailyChangeSummary(rows: rows)
    }
}
