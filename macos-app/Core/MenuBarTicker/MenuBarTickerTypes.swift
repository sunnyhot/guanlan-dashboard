import Foundation
import SwiftUI

enum MenuBarTickerTone: String, Hashable {
    case positive
    case negative
    case neutral
}

struct MenuBarTickerEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let compactText: String
    let tone: MenuBarTickerTone
}

enum MarketIndexKind: String, Codable, CaseIterable, Identifiable {
    case sseComposite
    case csi300
    case chinext
    case hsi
    case nasdaq
    case sp500
    case dowJones

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sseComposite: return "上证指数"
        case .csi300: return "沪深300"
        case .chinext: return "创业板指"
        case .hsi: return "恒生指数"
        case .nasdaq: return "纳斯达克"
        case .sp500: return "标普500"
        case .dowJones: return "道琼斯"
        }
    }

    var compactLabel: String {
        switch self {
        case .sseComposite: return "上证"
        case .csi300: return "沪深"
        case .chinext: return "创业"
        case .hsi: return "恒指"
        case .nasdaq: return "纳指"
        case .sp500: return "标普"
        case .dowJones: return "道指"
        }
    }

    var tencentSymbol: String {
        switch self {
        case .sseComposite: return "sh000001"
        case .csi300: return "sh000300"
        case .chinext: return "sz399006"
        case .hsi: return "hkHSI"
        case .nasdaq: return "usIXIC"
        case .sp500: return "usINX"
        case .dowJones: return "usDJI"
        }
    }
}

enum MarketIndexMetric: Hashable {
    case level
    case changeAmount
    case changePct

    var labelSuffix: String {
        switch self {
        case .level: return "点位"
        case .changeAmount: return "涨跌点"
        case .changePct: return "涨跌率"
        }
    }
}

struct MarketIndexQuote: Hashable, Identifiable {
    let kind: MarketIndexKind
    let name: String
    let price: Double
    let previousClose: Double?
    let changeAmount: Double?
    let changePct: Double?
    let quotedAt: String
    let sourceLabel: String

    var id: String { kind.rawValue }
}

/// 黄金/汇率行情标的，统一走新浪行情（腾讯无外汇数据）。
/// 海外现货（hf_ 前缀）与外汇（fx_ 前缀）返回字段布局不同，解析差异见
/// `QiemanPlatformNativeClient.fetchGoldForexQuotes`。
enum GoldForexKind: String, Codable, CaseIterable, Identifiable {
    case xauUSD
    case xagUSD
    case usdCNY
    case usdCNH

    var id: String { rawValue }

    var sinaSymbol: String {
        switch self {
        case .xauUSD: return "hf_XAU"
        case .xagUSD: return "hf_XAG"
        case .usdCNY: return "fx_susdcny"
        case .usdCNH: return "fx_susdcnh"
        }
    }

    var label: String {
        switch self {
        case .xauUSD: return "伦敦金"
        case .xagUSD: return "伦敦银"
        case .usdCNY: return "美元/在岸人民币"
        case .usdCNH: return "美元/离岸人民币"
        }
    }

    var compactLabel: String {
        switch self {
        case .xauUSD: return "伦敦金"
        case .xagUSD: return "伦敦银"
        case .usdCNY: return "在岸人民币"
        case .usdCNH: return "离岸人民币"
        }
    }

    var isForex: Bool {
        self == .usdCNY || self == .usdCNH
    }
}

struct GoldForexQuote: Hashable, Identifiable {
    let kind: GoldForexKind
    let name: String
    let price: Double
    let previousClose: Double?
    let changeAmount: Double?
    let changePct: Double?
    let quotedAt: String
    let sourceLabel: String

    var id: String { kind.rawValue }
}
