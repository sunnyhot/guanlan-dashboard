import Foundation

// MARK: - AppModel Extension: Menu Bar Ticker Entry Building

extension AppModel {
    var menuBarTickerConfiguredItemCount: Int {
        menuBarTickerSettings.selections.count
    }

    var menuBarTickerVisibleEntries: [MenuBarTickerEntry] {
        guard menuBarTickerSettings.isEnabled else { return [] }
        let settings = menuBarTickerSettings.normalized()
        return menuBarTickerCandidateEntries(settings: settings, maxEntries: settings.maxVisibleItems)
    }

    func isMenuBarTickerKindEnabled(_ kind: MenuBarTickerKind) -> Bool {
        menuBarTickerSettings.selections.contains { $0.kindValue == kind }
    }

    func setMenuBarTickerKind(_ kind: MenuBarTickerKind, isEnabled: Bool) {
        var settings = menuBarTickerSettings
        if isEnabled {
            if !settings.selections.contains(where: { $0.kindValue == kind }) {
                settings.selections.append(.kind(kind))
            }
        } else {
            settings.selections.removeAll { $0.kindValue == kind }
        }
        persistMenuBarTickerSettings(settings)
        if isEnabled, kind.marketIndexRequest != nil {
            Task { await refreshMarketIndices(kinds: MarketIndexKind.allCases, updateNotice: false) }
        }
    }

    func isMenuBarHoldingMetricEnabled(holdingID: UUID, metric: MenuBarHoldingMetric) -> Bool {
        let target = MenuBarHoldingMetricSelection(holdingID: holdingID, metric: metric)
        return menuBarTickerSettings.selections.contains {
            $0.holdingValue == target
        }
    }

    func setMenuBarHoldingMetric(holdingID: UUID, metric: MenuBarHoldingMetric, isEnabled: Bool) {
        var settings = menuBarTickerSettings
        let selection = MenuBarHoldingMetricSelection(holdingID: holdingID, metric: metric)
        if isEnabled {
            if !settings.selections.contains(where: { $0.holdingValue == selection }) {
                settings.selections.append(.holding(selection))
            }
        } else {
            settings.selections.removeAll { $0.holdingValue == selection }
        }
        persistMenuBarTickerSettings(settings)
    }

    func setMenuBarTickerEnabled(_ isEnabled: Bool) {
        var settings = menuBarTickerSettings
        settings.isEnabled = isEnabled
        persistMenuBarTickerSettings(settings)
        if isEnabled {
            Task { await refreshMarketIndicesIfNeeded() }
        }
    }

    func setMenuBarTickerMaxVisibleItems(_ maxVisibleItems: Int) {
        var settings = menuBarTickerSettings
        settings.maxVisibleItems = maxVisibleItems
        persistMenuBarTickerSettings(settings)
    }

    func updateMenuBarTickerAppearance(_ update: (inout MenuBarTickerAppearance) -> Void) {
        var settings = menuBarTickerSettings
        update(&settings.appearance)
        persistMenuBarTickerSettings(settings)
    }

    func setMenuBarTickerCarouselInterval(_ seconds: Double) {
        var settings = menuBarTickerSettings
        settings.carouselIntervalSeconds = seconds
        persistMenuBarTickerSettings(settings)
    }

    func moveMenuBarTickerSelection(from source: IndexSet, to destination: Int) {
        var settings = menuBarTickerSettings
        settings.selections.move(fromOffsets: source, toOffset: destination)
        persistMenuBarTickerSettings(settings)
    }

    var menuBarTickerAllCandidates: [MenuBarTickerEntry] {
        guard menuBarTickerSettings.isEnabled else { return [] }
        return menuBarTickerCandidateEntries(settings: menuBarTickerSettings.normalized())
    }

    func resetMenuBarTickerSettings() {
        persistMenuBarTickerSettings(.default)
    }

    func clearMenuBarHoldingSelections() {
        var settings = menuBarTickerSettings
        settings.selections.removeAll { $0.holdingValue != nil }
        persistMenuBarTickerSettings(settings)
    }

    func persistMenuBarTickerSettings(_ settings: MenuBarTickerSettings) {
        let normalized = settings.normalized()
        menuBarTickerSettings = normalized
        normalized.save()
    }

    func menuBarTickerCandidateEntries(
        settings: MenuBarTickerSettings,
        maxEntries: Int? = nil
    ) -> [MenuBarTickerEntry] {
        let telemetryStart = PerformanceTelemetry.start()
        var entries: [MenuBarTickerEntry] = []
        var didBuildAggregates = false
        defer {
            PerformanceTelemetry.record(
                "menuBar.entries.build",
                startedAt: telemetryStart,
                metadata: [
                    "selectionCount": "\(settings.selections.count)",
                    "rowCount": "\(userPortfolioSnapshot?.rows.count ?? 0)",
                    "entryCount": "\(entries.count)",
                    "aggregateBuilt": "\(didBuildAggregates)"
                ]
            )
        }
        let rows = userPortfolioSnapshot?.rows ?? []
        var aggregates: MenuBarTickerAggregateSet?
        func aggregateSet() -> MenuBarTickerAggregateSet {
            if let aggregates { return aggregates }
            let built = MenuBarTickerAggregateSet(rows: rows)
            aggregates = built
            didBuildAggregates = true
            return built
        }
        var rowsByHoldingID: [UUID: UserPortfolioValuationRow]?

        selectionLoop: for selection in settings.selections {
            switch selection {
            case .kind(let kind):
                if let entry = menuBarTickerEntry(for: kind, rows: rows, aggregates: aggregateSet) {
                    entries.append(entry)
                    if let maxEntries, entries.count >= maxEntries { break selectionLoop }
                }
            case .holding(let sel):
                let holdingRows: [UUID: UserPortfolioValuationRow]
                if let cached = rowsByHoldingID {
                    holdingRows = cached
                } else {
                    let built = Dictionary(rows.map { ($0.holding.id, $0) }, uniquingKeysWith: { first, _ in first })
                    rowsByHoldingID = built
                    holdingRows = built
                }

                guard let row = holdingRows[sel.holdingID],
                      let entry = menuBarTickerEntry(row: row, metric: sel.metric) else {
                    continue
                }
                entries.append(entry)
                if let maxEntries, entries.count >= maxEntries { break selectionLoop }
            }
        }

        return entries
    }

    func menuBarTickerEntry(
        for kind: MenuBarTickerKind,
        rows: [UserPortfolioValuationRow],
        aggregates: () -> MenuBarTickerAggregateSet
    ) -> MenuBarTickerEntry? {
        switch kind {
        case .totalValue:
            guard let summary = personalAssetSummary else { return nil }
            let value = summary.totalEffectiveHoldingAmount
            guard value > 0 else { return nil }
            return MenuBarTickerEntry(
                id: kind.rawValue,
                title: "总资产",
                value: compactCurrency(value),
                detail: currencyText(value),
                compactText: "总 \(compactCurrency(value))",
                tone: .neutral
            )
        case .overallDailyAmount:
            let aggregate = aggregates().all
            return aggregate.amountEntry(id: kind.rawValue, title: "整体涨跌", compactTitle: "今", value: aggregate.dailyAmount)
        case .overallDailyPct:
            let aggregate = aggregates().all
            return aggregate.percentEntry(id: kind.rawValue, title: "整体涨跌率", compactTitle: "今", value: aggregate.dailyPct)
        case .overallProfitAmount:
            let aggregate = aggregates().all
            return aggregate.amountEntry(id: kind.rawValue, title: "整体收益", compactTitle: "益", value: aggregate.profitAmount)
        case .overallProfitPct:
            let aggregate = aggregates().all
            return aggregate.percentEntry(id: kind.rawValue, title: "整体收益率", compactTitle: "益", value: aggregate.profitPct)
        case .offExchangeDailyAmount:
            let aggregate = aggregates().fund(.offExchange)
            return aggregate.amountEntry(id: kind.rawValue, title: "场外涨跌", compactTitle: "场外", value: aggregate.dailyAmount)
        case .offExchangeDailyPct:
            let aggregate = aggregates().fund(.offExchange)
            return aggregate.percentEntry(id: kind.rawValue, title: "场外涨跌率", compactTitle: "场外", value: aggregate.dailyPct)
        case .offExchangeProfitAmount:
            let aggregate = aggregates().fund(.offExchange)
            return aggregate.amountEntry(id: kind.rawValue, title: "场外收益", compactTitle: "场外益", value: aggregate.profitAmount)
        case .offExchangeProfitPct:
            let aggregate = aggregates().fund(.offExchange)
            return aggregate.percentEntry(id: kind.rawValue, title: "场外收益率", compactTitle: "场外益", value: aggregate.profitPct)
        case .onExchangeDailyAmount:
            let aggregate = aggregates().fund(.onExchange)
            return aggregate.amountEntry(id: kind.rawValue, title: "场内涨跌", compactTitle: "场内", value: aggregate.dailyAmount)
        case .onExchangeDailyPct:
            let aggregate = aggregates().fund(.onExchange)
            return aggregate.percentEntry(id: kind.rawValue, title: "场内涨跌率", compactTitle: "场内", value: aggregate.dailyPct)
        case .onExchangeProfitAmount:
            let aggregate = aggregates().fund(.onExchange)
            return aggregate.amountEntry(id: kind.rawValue, title: "场内收益", compactTitle: "场内益", value: aggregate.profitAmount)
        case .onExchangeProfitPct:
            let aggregate = aggregates().fund(.onExchange)
            return aggregate.percentEntry(id: kind.rawValue, title: "场内收益率", compactTitle: "场内益", value: aggregate.profitPct)
        case .sseIndexLevel, .sseIndexChangeAmount, .sseIndexChangePct,
             .csi300IndexLevel, .csi300IndexChangeAmount, .csi300IndexChangePct,
             .chinextIndexLevel, .chinextIndexChangeAmount, .chinextIndexChangePct,
             .hsiIndexLevel, .hsiIndexChangeAmount, .hsiIndexChangePct,
             .nasdaqIndexLevel, .nasdaqIndexChangeAmount, .nasdaqIndexChangePct,
             .sp500IndexLevel, .sp500IndexChangeAmount, .sp500IndexChangePct,
             .dowJonesIndexLevel, .dowJonesIndexChangeAmount, .dowJonesIndexChangePct:
            guard let request = kind.marketIndexRequest else { return nil }
            return menuBarTickerEntry(indexKind: request.kind, metric: request.metric, id: kind.rawValue)
        case .topDailyPct:
            var topRow: UserPortfolioValuationRow?
            for row in rows {
                guard let pct = row.estimateChangePct else { continue }
                if let current = topRow {
                    if abs(pct) > abs(current.estimateChangePct ?? 0) {
                        topRow = row
                    }
                } else {
                    topRow = row
                }
            }
            guard let row = topRow else { return nil }
            return menuBarTickerEntry(row: row, metric: .dailyPct, customTitle: "最大涨跌")
        case .topProfitPct:
            var topRow: UserPortfolioValuationRow?
            for row in rows {
                guard let pct = row.profitPct else { continue }
                if let current = topRow {
                    if pct > (current.profitPct ?? -.greatestFiniteMagnitude) {
                        topRow = row
                    }
                } else {
                    topRow = row
                }
            }
            guard let row = topRow else { return nil }
            return menuBarTickerEntry(row: row, metric: .profitPct, customTitle: "最大收益")
        }
    }

    func menuBarTickerEntry(indexKind: MarketIndexKind, metric: MarketIndexMetric, id: String) -> MenuBarTickerEntry? {
        guard let quote = marketIndexQuotes[indexKind] else { return nil }
        switch metric {
        case .level:
            let text = compactIndexLevel(quote.price)
            return MenuBarTickerEntry(
                id: id,
                title: "\(indexKind.compactLabel)点位",
                value: text,
                detail: "\(quote.name) · \(quote.sourceLabel)\(quote.quotedAt.isEmpty ? "" : " · \(quote.quotedAt)")",
                compactText: "\(indexKind.compactLabel) \(text)",
                tone: .neutral
            )
        case .changeAmount:
            guard let value = quote.changeAmount else { return nil }
            let text = compactIndexPoints(value)
            return MenuBarTickerEntry(
                id: id,
                title: "\(indexKind.compactLabel)涨跌点",
                value: text,
                detail: "\(quote.name) · \(quote.changePct.map(compactPercent) ?? "暂无涨跌率")",
                compactText: "\(indexKind.compactLabel) \(text)",
                tone: tickerTone(for: value)
            )
        case .changePct:
            guard let value = quote.changePct else { return nil }
            let text = compactPercent(value)
            return MenuBarTickerEntry(
                id: id,
                title: "\(indexKind.compactLabel)涨跌率",
                value: text,
                detail: "\(quote.name) · \(quote.changeAmount.map(compactIndexPoints) ?? "暂无涨跌点")",
                compactText: "\(indexKind.compactLabel) \(text)",
                tone: tickerTone(for: value)
            )
        }
    }

    func menuBarTickerEntry(
        row: UserPortfolioValuationRow,
        metric: MenuBarHoldingMetric,
        customTitle: String? = nil
    ) -> MenuBarTickerEntry? {
        let name = compactAssetName(row.fundName)
        let title = customTitle ?? name
        let id = "holding:\(row.holding.id.uuidString):\(metric.rawValue)"

        switch metric {
        case .dailyAmount:
            guard let value = row.estimatedDailyChangeAmount else { return nil }
            let text = compactSignedCurrency(value, market: row.holding.detectedMarket)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)涨跌",
                value: text,
                detail: "\(row.fundName) · \(signedCurrencyText(value, market: row.holding.detectedMarket))",
                compactText: "\(name) \(text)",
                tone: tickerTone(for: value)
            )
        case .dailyPct:
            guard let value = row.estimateChangePct ?? tickerPctFromAmount(row.estimatedDailyChangeAmount, previous: row.previousMarketValue) else { return nil }
            let text = compactPercent(value)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)涨跌率",
                value: text,
                detail: "\(row.fundName) · \(signedCurrencyText(row.estimatedDailyChangeAmount, market: row.holding.detectedMarket))",
                compactText: "\(name) \(text)",
                tone: tickerTone(for: value)
            )
        case .profitAmount:
            guard let value = row.profitAmount else { return nil }
            let text = compactSignedCurrency(value, market: row.holding.detectedMarket)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)收益",
                value: text,
                detail: "\(row.fundName) · \(percentOptional(row.profitPct))",
                compactText: "\(name)益 \(text)",
                tone: tickerTone(for: value)
            )
        case .profitPct:
            guard let value = row.profitPct else { return nil }
            let text = compactPercent(value)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)收益率",
                value: text,
                detail: "\(row.fundName) · \(signedCurrencyText(row.profitAmount, market: row.holding.detectedMarket))",
                compactText: "\(name)益 \(text)",
                tone: tickerTone(for: value)
            )
        case .price:
            guard let value = row.resolvedPrice else { return nil }
            let text = decimalText(value)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)现价",
                value: text,
                detail: "\(row.fundName) · \(row.resolvedPriceSource ?? "当前价格")",
                compactText: "\(name) \(text)",
                tone: .neutral
            )
        case .marketValue:
            guard let value = row.marketValue else { return nil }
            let text = compactCurrency(value, market: row.holding.detectedMarket)
            return MenuBarTickerEntry(
                id: id,
                title: "\(title)市值",
                value: text,
                detail: "\(row.fundName) · \(currencyText(value, market: row.holding.detectedMarket))",
                compactText: "\(name) \(text)",
                tone: .neutral
            )
        }
    }
}

// MARK: - Aggregate Helpers

private struct MenuBarTickerAggregateAccumulator {
    private var dailyAmountTotal = 0.0
    private var dailyAmountCount = 0
    private var previousValueTotal = 0.0
    private var previousValueCount = 0
    private var profitAmountTotal = 0.0
    private var profitAmountCount = 0
    private var costValueTotal = 0.0
    private var costValueCount = 0

    mutating func add(_ row: UserPortfolioValuationRow) {
        if let value = row.estimatedDailyChangeAmount {
            dailyAmountTotal += value
            dailyAmountCount += 1
        }
        if let value = row.previousMarketValue {
            previousValueTotal += value
            previousValueCount += 1
        }
        if let value = row.profitAmount {
            profitAmountTotal += value
            profitAmountCount += 1
        }
        if let value = row.costValue {
            costValueTotal += value
            costValueCount += 1
        }
    }

    func makeAggregate() -> MenuBarTickerAggregate {
        MenuBarTickerAggregate(
            dailyAmount: tickerCompactNilIfEmpty(dailyAmountTotal, sourceCount: dailyAmountCount),
            previousValue: tickerCompactNilIfEmpty(previousValueTotal, sourceCount: previousValueCount),
            profitAmount: tickerCompactNilIfEmpty(profitAmountTotal, sourceCount: profitAmountCount),
            costValue: tickerCompactNilIfEmpty(costValueTotal, sourceCount: costValueCount)
        )
    }
}

struct MenuBarTickerAggregateSet {
    let all: MenuBarTickerAggregate
    private let funds: [FundMarket: MenuBarTickerAggregate]

    init(rows: [UserPortfolioValuationRow]) {
        var allAccumulator = MenuBarTickerAggregateAccumulator()
        var fundAccumulators: [FundMarket: MenuBarTickerAggregateAccumulator] = [:]

        for row in rows {
            allAccumulator.add(row)
            if row.holding.assetType == .fund, let market = row.holding.detectedFundMarket {
                fundAccumulators[market, default: MenuBarTickerAggregateAccumulator()].add(row)
            }
        }

        all = allAccumulator.makeAggregate()
        funds = Dictionary(uniqueKeysWithValues: FundMarket.allCases.map { market in
            (market, fundAccumulators[market]?.makeAggregate() ?? .empty)
        })
    }

    func fund(_ market: FundMarket) -> MenuBarTickerAggregate {
        funds[market] ?? .empty
    }
}

struct MenuBarTickerAggregate {
    static let empty = MenuBarTickerAggregate(dailyAmount: nil, previousValue: nil, profitAmount: nil, costValue: nil)

    let dailyAmount: Double?
    let dailyPct: Double?
    let profitAmount: Double?
    let profitPct: Double?

    init(dailyAmount: Double?, previousValue: Double?, profitAmount: Double?, costValue: Double?) {
        self.dailyAmount = dailyAmount
        dailyPct = tickerPctFromAmount(dailyAmount, previous: previousValue)
        self.profitAmount = profitAmount
        profitPct = tickerPctFromAmount(profitAmount, previous: costValue)
    }

    func amountEntry(id: String, title: String, compactTitle: String, value: Double?, market: StockMarket? = nil) -> MenuBarTickerEntry? {
        guard let value else { return nil }
        let text = compactSignedCurrency(value, market: market)
        return MenuBarTickerEntry(
            id: id,
            title: title,
            value: text,
            detail: signedCurrencyText(value, market: market),
            compactText: "\(compactTitle) \(text)",
            tone: tickerTone(for: value)
        )
    }

    func percentEntry(id: String, title: String, compactTitle: String, value: Double?) -> MenuBarTickerEntry? {
        guard let value else { return nil }
        let text = compactPercent(value)
        return MenuBarTickerEntry(
            id: id,
            title: title,
            value: text,
            detail: text,
            compactText: "\(compactTitle) \(text)",
            tone: tickerTone(for: value)
        )
    }
}

// MARK: - Formatting Helpers

func tickerCompactNilIfEmpty(_ value: Double, sourceCount: Int) -> Double? {
    sourceCount > 0 ? value : nil
}

func tickerPctFromAmount(_ amount: Double?, previous: Double?) -> Double? {
    guard let amount, let previous, previous > 0 else { return nil }
    return amount / previous * 100
}

func tickerTone(for value: Double?) -> MenuBarTickerTone {
    let value = value ?? 0
    if value > 0 { return .positive }
    if value < 0 { return .negative }
    return .neutral
}

func compactCurrency(_ value: Double, market: StockMarket? = nil) -> String {
    compactCurrencyText(value, market: market, signed: false)
}

func compactSignedCurrency(_ value: Double, market: StockMarket? = nil) -> String {
    compactCurrencyText(value, market: market, signed: true)
}

func compactCurrencyText(_ value: Double, market: StockMarket?, signed: Bool) -> String {
    let symbol = market?.currencySymbol ?? "¥"
    let sign = signed ? (value >= 0 ? "+" : "-") : ""
    let absolute = abs(value)
    if absolute >= 100_000_000 {
        return "\(symbol)\(sign)\(String(format: "%.1f", absolute / 100_000_000))亿"
    }
    if absolute >= 10_000 {
        return "\(symbol)\(sign)\(String(format: "%.1f", absolute / 10_000))万"
    }
    if absolute >= 1_000 {
        return "\(symbol)\(sign)\(String(format: "%.0f", absolute))"
    }
    return "\(symbol)\(sign)\(String(format: "%.2f", absolute))"
}

func compactPercent(_ value: Double) -> String {
    String(format: "%+.2f%%", value)
}

func compactIndexLevel(_ value: Double) -> String {
    String(format: "%.2f", value)
}

func compactIndexPoints(_ value: Double) -> String {
    String(format: "%+.2f点", value)
}

func compactAssetName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "标的" }
    let cleaned = trimmed
        .replacingOccurrences(of: "指数证券投资基金", with: "")
        .replacingOccurrences(of: "证券投资基金", with: "")
        .replacingOccurrences(of: "交易型开放式指数", with: "ETF")
        .replacingOccurrences(of: "(QDII)", with: "")
        .replacingOccurrences(of: "\u{ff08}QDII\u{ff09}", with: "")
    if cleaned.count <= 6 { return cleaned }
    return String(cleaned.prefix(6))
}
