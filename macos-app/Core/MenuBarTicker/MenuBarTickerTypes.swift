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
