import Foundation

func watchlistPriceText(_ value: Double?, item: PersonalWatchlistItem) -> String {
    guard let value else { return "—" }
    let number = decimalText(value)
    guard item.assetType == .stock, let market = item.detectedStockMarket else { return number }
    return "\(market.currencySymbol)\(number)"
}

func watchlistAxisPrice(_ value: Double) -> String {
    if abs(value) >= 1_000 {
        return String(format: "%.0f", value)
    }
    if abs(value) >= 10 {
        return String(format: "%.2f", value)
    }
    return String(format: "%.4f", value)
}
