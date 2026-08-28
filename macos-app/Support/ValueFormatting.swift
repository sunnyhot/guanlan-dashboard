import Foundation

private let currencyFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

private let integerUnitsFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = 0
    return f
}()

private let fractionalUnitsFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

private func formattedNumber(_ value: Double) -> String {
    currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

func currencyText(_ value: Double) -> String {
    currencyText(value, market: nil)
}

func currencyText(_ value: Double, market: StockMarket?) -> String {
    (market?.currencySymbol ?? "¥") + formattedNumber(value)
}

func currencyOptional(_ value: Double?, market: StockMarket?) -> String {
    guard let value else { return "—" }
    return currencyText(value, market: market)
}

func signedCurrencyText(_ value: Double?) -> String {
    signedCurrencyText(value, market: nil)
}

func signedCurrencyText(_ value: Double?, market: StockMarket?) -> String {
    guard let value else { return "—" }
    let sign = value >= 0 ? "+" : "-"
    let symbol = market?.currencySymbol ?? "¥"
    return "\(symbol)\(sign)\(formattedNumber(abs(value)))"
}

func dailyChangeCurrencyText(_ value: Double?, market: StockMarket? = nil) -> String {
    value.map { signedCurrencyText($0, market: market) } ?? "待公布"
}

func percentOptional(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%+.2f%%", value)
}

func dailyChangePercentText(_ value: Double?) -> String {
    value.map { percentOptional($0) } ?? "待公布"
}

func decimalOptional(_ value: Double?) -> String {
    guard let value else { return "—" }
    return decimalText(value)
}

func decimalText(_ value: Double) -> String {
    String(format: "%.4f", value)
}

func unitsText(_ value: Double) -> String {
    let rounded = value.rounded()
    if abs(value - rounded) < 0.0000001 {
        return integerUnitsFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
    return fractionalUnitsFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

/// 指数点位/贵金属价格：千分位 + 2 位小数。
func levelText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

/// 带符号的涨跌数值（指数点位差/汇率差），不附加货币符号。
func signedAmountText(_ value: Double?, fractionDigits: Int = 2) -> String {
    guard let value else { return "—" }
    let sign = value >= 0 ? "+" : "-"
    let magnitude = fractionDigits >= 4
        ? decimalText(abs(value))
        : formattedNumber(abs(value))
    return "\(sign)\(magnitude)"
}
