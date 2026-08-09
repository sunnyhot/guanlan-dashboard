import Foundation

enum MenuBarTickerKind: String, Codable, CaseIterable, Identifiable {
    case totalValue
    case overallDailyAmount
    case overallDailyPct
    case overallProfitAmount
    case overallProfitPct
    case offExchangeDailyAmount
    case offExchangeDailyPct
    case offExchangeProfitAmount
    case offExchangeProfitPct
    case onExchangeDailyAmount
    case onExchangeDailyPct
    case onExchangeProfitAmount
    case onExchangeProfitPct
    case topDailyPct
    case topProfitPct
    case sseIndexLevel
    case sseIndexChangeAmount
    case sseIndexChangePct
    case csi300IndexLevel
    case csi300IndexChangeAmount
    case csi300IndexChangePct
    case chinextIndexLevel
    case chinextIndexChangeAmount
    case chinextIndexChangePct
    case hsiIndexLevel
    case hsiIndexChangeAmount
    case hsiIndexChangePct
    case nasdaqIndexLevel
    case nasdaqIndexChangeAmount
    case nasdaqIndexChangePct
    case sp500IndexLevel
    case sp500IndexChangeAmount
    case sp500IndexChangePct
    case dowJonesIndexLevel
    case dowJonesIndexChangeAmount
    case dowJonesIndexChangePct

    var id: String { rawValue }

    var label: String {
        if let marketIndexRequest {
            return "\(marketIndexRequest.kind.compactLabel)\(marketIndexRequest.metric.labelSuffix)"
        }

        switch self {
        case .totalValue: return "总资产"
        case .overallDailyAmount: return "整体涨跌额"
        case .overallDailyPct: return "整体涨跌率"
        case .overallProfitAmount: return "整体收益额"
        case .overallProfitPct: return "整体收益率"
        case .offExchangeDailyAmount: return "场外涨跌额"
        case .offExchangeDailyPct: return "场外涨跌率"
        case .offExchangeProfitAmount: return "场外收益额"
        case .offExchangeProfitPct: return "场外收益率"
        case .onExchangeDailyAmount: return "场内涨跌额"
        case .onExchangeDailyPct: return "场内涨跌率"
        case .onExchangeProfitAmount: return "场内收益额"
        case .onExchangeProfitPct: return "场内收益率"
        case .topDailyPct: return "最大涨跌标的"
        case .topProfitPct: return "最大收益标的"
        default: return rawValue
        }
    }

    var detail: String {
        if let marketIndexRequest {
            switch marketIndexRequest.metric {
            case .level:
                return "\(marketIndexRequest.kind.label)实时点位"
            case .changeAmount, .changePct:
                return "\(marketIndexRequest.kind.label)当日涨跌"
            }
        }

        switch self {
        case .totalValue:
            return "总持仓 + 待确认 + 下次计划"
        case .overallDailyAmount, .overallDailyPct:
            return "全部已持有资产今日涨跌"
        case .overallProfitAmount, .overallProfitPct:
            return "全部已持有资产相对成本收益"
        case .offExchangeDailyAmount, .offExchangeDailyPct, .offExchangeProfitAmount, .offExchangeProfitPct:
            return "按场外基金聚合"
        case .onExchangeDailyAmount, .onExchangeDailyPct, .onExchangeProfitAmount, .onExchangeProfitPct:
            return "按场内基金、ETF、LOF 聚合"
        case .topDailyPct:
            return "自动选择今日涨跌绝对值最大的持仓"
        case .topProfitPct:
            return "自动选择收益率最高的持仓"
        default:
            return "大盘指数行情"
        }
    }

    var marketIndexRequest: (kind: MarketIndexKind, metric: MarketIndexMetric)? {
        switch self {
        case .sseIndexLevel: return (.sseComposite, .level)
        case .sseIndexChangeAmount: return (.sseComposite, .changeAmount)
        case .sseIndexChangePct: return (.sseComposite, .changePct)
        case .csi300IndexLevel: return (.csi300, .level)
        case .csi300IndexChangeAmount: return (.csi300, .changeAmount)
        case .csi300IndexChangePct: return (.csi300, .changePct)
        case .chinextIndexLevel: return (.chinext, .level)
        case .chinextIndexChangeAmount: return (.chinext, .changeAmount)
        case .chinextIndexChangePct: return (.chinext, .changePct)
        case .hsiIndexLevel: return (.hsi, .level)
        case .hsiIndexChangeAmount: return (.hsi, .changeAmount)
        case .hsiIndexChangePct: return (.hsi, .changePct)
        case .nasdaqIndexLevel: return (.nasdaq, .level)
        case .nasdaqIndexChangeAmount: return (.nasdaq, .changeAmount)
        case .nasdaqIndexChangePct: return (.nasdaq, .changePct)
        case .sp500IndexLevel: return (.sp500, .level)
        case .sp500IndexChangeAmount: return (.sp500, .changeAmount)
        case .sp500IndexChangePct: return (.sp500, .changePct)
        case .dowJonesIndexLevel: return (.dowJones, .level)
        case .dowJonesIndexChangeAmount: return (.dowJones, .changeAmount)
        case .dowJonesIndexChangePct: return (.dowJones, .changePct)
        default: return nil
        }
    }

    static let overallKinds: [MenuBarTickerKind] = [
        .totalValue,
        .overallDailyAmount,
        .overallDailyPct,
        .overallProfitAmount,
        .overallProfitPct,
    ]

    static func tickerKind(indexKind: MarketIndexKind, metric: MarketIndexMetric) -> MenuBarTickerKind? {
        switch (indexKind, metric) {
        case (.sseComposite, .level): return .sseIndexLevel
        case (.sseComposite, .changeAmount): return .sseIndexChangeAmount
        case (.sseComposite, .changePct): return .sseIndexChangePct
        case (.csi300, .level): return .csi300IndexLevel
        case (.csi300, .changeAmount): return .csi300IndexChangeAmount
        case (.csi300, .changePct): return .csi300IndexChangePct
        case (.chinext, .level): return .chinextIndexLevel
        case (.chinext, .changeAmount): return .chinextIndexChangeAmount
        case (.chinext, .changePct): return .chinextIndexChangePct
        case (.hsi, .level): return .hsiIndexLevel
        case (.hsi, .changeAmount): return .hsiIndexChangeAmount
        case (.hsi, .changePct): return .hsiIndexChangePct
        case (.nasdaq, .level): return .nasdaqIndexLevel
        case (.nasdaq, .changeAmount): return .nasdaqIndexChangeAmount
        case (.nasdaq, .changePct): return .nasdaqIndexChangePct
        case (.sp500, .level): return .sp500IndexLevel
        case (.sp500, .changeAmount): return .sp500IndexChangeAmount
        case (.sp500, .changePct): return .sp500IndexChangePct
        case (.dowJones, .level): return .dowJonesIndexLevel
        case (.dowJones, .changeAmount): return .dowJonesIndexChangeAmount
        case (.dowJones, .changePct): return .dowJonesIndexChangePct
        }
    }

    static let automaticKinds: [MenuBarTickerKind] = [
        .topDailyPct,
        .topProfitPct,
    ]
}

enum MenuBarHoldingMetric: String, Codable, CaseIterable, Identifiable {
    case dailyAmount
    case dailyPct
    case profitAmount
    case profitPct
    case price
    case marketValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dailyAmount: return "涨跌额"
        case .dailyPct: return "涨跌率"
        case .profitAmount: return "收益额"
        case .profitPct: return "收益率"
        case .price: return "现价"
        case .marketValue: return "市值"
        }
    }
}

struct MenuBarHoldingMetricSelection: Codable, Hashable, Identifiable {
    var holdingID: UUID
    var metric: MenuBarHoldingMetric

    var id: String { "\(holdingID.uuidString):\(metric.rawValue)" }
}

enum MenuBarTickerSelection: Codable, Hashable, Identifiable {
    case kind(MenuBarTickerKind)
    case holding(MenuBarHoldingMetricSelection)

    var id: String {
        switch self {
        case .kind(let kind): return kind.rawValue
        case .holding(let sel): return sel.id
        }
    }

    var kindValue: MenuBarTickerKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }

    var holdingValue: MenuBarHoldingMetricSelection? {
        if case .holding(let sel) = self { return sel }
        return nil
    }
}
