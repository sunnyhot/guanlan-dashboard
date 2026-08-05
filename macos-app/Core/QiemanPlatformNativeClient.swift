import CryptoKit
import Foundation

actor QiemanPlatformCache {
    static let maxPayloadEntries = 16
    static let maxFundCacheEntries = 256
    static let maxStockQuoteEntries = 256

    private var payloads: [String: (Date, PlatformPayload)] = [:]
    private var histories: [String: (Date, NativeFundHistory)] = [:]
    private var quotes: [String: (Date, NativeFundQuote)] = [:]
    private var stockQuotes: [String: (Date, NativeStockQuote)] = [:]
    private var stockDailySeries: [String: (Date, [PersonalWatchlistDailyPoint])] = [:]
    private var marketIndexQuotes: [MarketIndexKind: (Date, MarketIndexQuote)] = [:]

    func payload(for prodCode: String, ttl: TimeInterval) -> PlatformPayload? {
        guard let (loadedAt, payload) = payloads[prodCode], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return payload
    }

    func store(payload: PlatformPayload, for prodCode: String) {
        store(payload, for: prodCode, in: &payloads, maxEntries: Self.maxPayloadEntries)
    }

    fileprivate func history(for fundCode: String, ttl: TimeInterval) -> NativeFundHistory? {
        guard let (loadedAt, history) = histories[fundCode], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return history
    }

    fileprivate func store(history: NativeFundHistory, for fundCode: String) {
        guard !history.series.isEmpty else {
            histories.removeValue(forKey: fundCode)
            return
        }
        store(history, for: fundCode, in: &histories, maxEntries: Self.maxFundCacheEntries)
    }

    fileprivate func quote(for fundCode: String, ttl: TimeInterval) -> NativeFundQuote? {
        guard let (loadedAt, quote) = quotes[fundCode], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return quote
    }

    fileprivate func store(quote: NativeFundQuote, for fundCode: String) {
        guard quote.price > 0 || (quote.officialNav ?? 0) > 0 || (quote.estimatePrice ?? 0) > 0 else {
            quotes.removeValue(forKey: fundCode)
            return
        }
        store(quote, for: fundCode, in: &quotes, maxEntries: Self.maxFundCacheEntries)
    }

    fileprivate func stockQuote(for stockCode: String, ttl: TimeInterval) -> NativeStockQuote? {
        guard let (loadedAt, quote) = stockQuotes[stockCode], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return quote
    }

    fileprivate func store(stockQuote: NativeStockQuote, for stockCode: String) {
        store(stockQuote, for: stockCode, in: &stockQuotes, maxEntries: Self.maxStockQuoteEntries)
    }

    fileprivate func stockDailySeries(
        for identityKey: String,
        ttl: TimeInterval
    ) -> [PersonalWatchlistDailyPoint]? {
        guard let (loadedAt, series) = stockDailySeries[identityKey],
              Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return series
    }

    fileprivate func store(
        stockDailySeries series: [PersonalWatchlistDailyPoint],
        for identityKey: String
    ) {
        guard !series.isEmpty else {
            stockDailySeries.removeValue(forKey: identityKey)
            return
        }
        store(series, for: identityKey, in: &stockDailySeries, maxEntries: Self.maxStockQuoteEntries)
    }

    func marketIndexQuote(for kind: MarketIndexKind, ttl: TimeInterval) -> MarketIndexQuote? {
        guard let (loadedAt, quote) = marketIndexQuotes[kind], Date().timeIntervalSince(loadedAt) < ttl else {
            return nil
        }
        return quote
    }

    func store(marketIndexQuote: MarketIndexQuote, for kind: MarketIndexKind) {
        marketIndexQuotes[kind] = (Date(), marketIndexQuote)
    }

    private func store<Value>(
        _ value: Value,
        for key: String,
        in cache: inout [String: (Date, Value)],
        maxEntries: Int
    ) {
        cache[key] = (Date(), value)
        pruneOldest(&cache, maxEntries: maxEntries)
    }

    private func pruneOldest<Value>(
        _ cache: inout [String: (Date, Value)],
        maxEntries: Int
    ) {
        guard maxEntries > 0 else { return }
        while cache.count > maxEntries {
            guard let oldestKey = cache.min(by: { $0.value.0 < $1.value.0 })?.key else {
                return
            }
            cache.removeValue(forKey: oldestKey)
        }
    }
}

final class QiemanPlatformNativeClient {
    let baseURL = URL(string: "https://qieman.com")!
    let apiBase = "/pmdj/v2"
    let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    let anonymousID = "anon-\(QiemanPlatformNativeClient.sha256Hex(UUID().uuidString).prefix(16))"
    private let payloadTTL: TimeInterval = 120
    private let historyTTL: TimeInterval = 12 * 60 * 60
    private let stockDailySeriesTTL: TimeInterval = 6 * 60 * 60
    private let quoteTTL: TimeInterval = 45
    private let cache = QiemanPlatformCache()
    let session: URLSession
    let now: () -> Date
    private static let preloadConcurrencyLimit = 6

    init(session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    func fetchPlatformPayload(prodCode: String) async throws -> PlatformPayload {
        let target = normalizedString(prodCode)
        guard !target.isEmpty else {
            throw NativePlatformError.missingProdCode
        }
        if let cached = await cache.payload(for: target, ttl: payloadTTL) {
            return cached
        }

        let raw = try await requestAdjustments(prodCode: target)
        let payload = try await buildPlatformPayload(prodCode: target, rawItems: raw)
        await cache.store(payload: payload, for: target)
        return payload
    }

    func fetchUserPortfolioSnapshot(
        holdings: [UserPortfolioHolding],
        forceQuoteRefresh: Bool = false
    ) async throws -> UserPortfolioSnapshot {
        let normalizedHoldings = holdings.filter { !$0.normalizedFundCode.isEmpty && $0.units > 0 }
        guard !normalizedHoldings.isEmpty else {
            return UserPortfolioSnapshot(
                rows: [],
                refreshedAt: isoTimestampNow(),
                totalMarketValue: 0,
                totalCostValue: nil,
                totalProfitAmount: nil,
                totalProfitPct: nil
            )
        }

        let fundCodes = Array(Set(normalizedHoldings.filter {
            $0.assetType == .fund && $0.detectedFundMarket != .onExchange
        }.map(\.normalizedFundCode)))
        let stockCodes = Array(Set(normalizedHoldings.filter {
            $0.assetType == .stock || ($0.assetType == .fund && $0.detectedFundMarket == .onExchange)
        }.map(\.normalizedFundCode)))
        async let stockQuotesTask = preloadStockQuotes(stockCodes)
        let (histories, quotes) = await preloadHistoriesAndQuotes(
            fundCodes,
            forceQuoteRefresh: forceQuoteRefresh
        )
        let stockQuotes = await stockQuotesTask

        let rows = normalizedHoldings.map { holding -> UserPortfolioValuationRow in
            let pricePayload = userPortfolioPricePayload(
                for: holding,
                histories: histories,
                quotes: quotes,
                stockQuotes: stockQuotes
            )
            let resolvedPrice = pricePayload.currentPrice ?? pricePayload.officialNav
            let marketValue = resolvedPrice.map { round($0 * holding.units, digits: 2) }
            let costValue = holding.costPrice.map { round($0 * holding.units, digits: 2) }
            let profitAmount = zipOptional(marketValue, costValue).map { round($0.0 - $0.1, digits: 2) }
            let profitPct = zipOptional(profitAmount, costValue).flatMap { pair -> Double? in
                let profit = pair.0
                let cost = pair.1
                guard cost > 0 else { return nil }
                return round(profit / cost * 100, digits: 2)
            }

            return UserPortfolioValuationRow(
                holding: holding,
                fundName: firstNonEmpty([
                    holding.normalizedName ?? "",
                    pricePayload.assetName,
                    holding.normalizedFundCode,
                ]),
                currentPrice: pricePayload.currentPrice.map { round($0, digits: 4) },
                priceTime: pricePayload.priceTime.nilIfEmpty,
                priceSource: pricePayload.priceSource.nilIfEmpty,
                officialNav: pricePayload.officialNav.map { round($0, digits: 4) },
                officialNavDate: pricePayload.officialNavDate.nilIfEmpty,
                estimatePrice: pricePayload.estimatePrice.map { round($0, digits: 4) },
                estimatePriceTime: pricePayload.estimatePriceTime.nilIfEmpty,
                marketValue: marketValue,
                costValue: costValue,
                profitAmount: profitAmount,
                profitPct: profitPct,
                estimateChangePct: pricePayload.estimateChangePct
            )
        }

        let totalMarketValue = round(rows.compactMap(\.marketValue).reduce(0, +), digits: 2)
        let costRows = rows.compactMap(\.costValue)
        let profitRows = rows.compactMap(\.profitAmount)
        let totalCostValue = costRows.isEmpty ? nil : round(costRows.reduce(0, +), digits: 2)
        let totalProfitAmount = profitRows.isEmpty ? nil : round(profitRows.reduce(0, +), digits: 2)
        let totalProfitPct: Double?
        if let totalCostValue, totalCostValue > 0, let totalProfitAmount {
            totalProfitPct = round(totalProfitAmount / totalCostValue * 100, digits: 2)
        } else {
            totalProfitPct = nil
        }

        return UserPortfolioSnapshot(
            rows: rows.sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) },
            refreshedAt: isoTimestampNow(),
            totalMarketValue: totalMarketValue,
            totalCostValue: totalCostValue,
            totalProfitAmount: totalProfitAmount,
            totalProfitPct: totalProfitPct
        )
    }

    func fetchPersonalWatchlistSnapshot(
        records: [PersonalWatchlistRecord],
        forceQuoteRefresh: Bool = false
    ) async throws -> PersonalWatchlistSnapshot {
        let normalizedRecords = records.filter { !$0.item.normalizedCode.isEmpty }
        guard !normalizedRecords.isEmpty else {
            return PersonalWatchlistSnapshot(rows: [], refreshedAt: isoTimestampNow())
        }

        let syntheticHoldings = normalizedRecords.map { record in
            UserPortfolioHolding(
                id: record.id,
                fundCode: record.item.normalizedCode,
                assetType: record.item.assetType,
                units: 1,
                costPrice: record.baseline?.price,
                displayName: record.item.normalizedName,
                stockMarket: record.item.detectedStockMarket,
                fundMarket: record.item.detectedFundMarket
            )
        }

        async let marketDailySeriesTask = preloadWatchlistMarketDailySeries(
            normalizedRecords.map(\.item)
        )
        let portfolioSnapshot = try await fetchUserPortfolioSnapshot(
            holdings: syntheticHoldings,
            forceQuoteRefresh: forceQuoteRefresh
        )

        let offExchangeCodes = normalizedRecords.compactMap { record -> String? in
            record.item.category == .offExchangeFund ? record.item.normalizedCode : nil
        }
        let fundHistories = await preloadHistories(offExchangeCodes)
        let marketDailySeries = await marketDailySeriesTask
        let valuationByID = Dictionary(uniqueKeysWithValues: portfolioSnapshot.rows.map { ($0.id, $0) })
        let marketDate = currentMarketDateText()

        let rows = normalizedRecords.map { record -> PersonalWatchlistQuoteRow in
            let valuation = valuationByID[record.id]
            let displayQuote = valuation?.dropdownQuote(marketDate: marketDate)
            let currentPrice = displayQuote?.price.flatMap { $0 > 0 ? $0 : nil }
            let quotedAt = displayQuote?.trimmedTime
            let sourceLabel = displayQuote?.label

            let fetchedDailyPoints: [PersonalWatchlistDailyPoint]
            if record.item.category == .offExchangeFund {
                fetchedDailyPoints = (fundHistories[record.item.normalizedCode]?.series ?? [])
                    .suffix(PersonalWatchlistRecord.maximumDailyPointCount)
                    .map {
                        PersonalWatchlistDailyPoint(
                            date: $0.date,
                            price: $0.nav,
                            quotedAt: $0.date,
                            sourceLabel: "基金净值"
                        )
                    }
            } else {
                fetchedDailyPoints = marketDailySeries[record.id] ?? []
            }

            var allDailyPoints = fetchedDailyPoints
            if let currentPrice {
                allDailyPoints.append(
                    PersonalWatchlistDailyPoint(
                        date: PersonalWatchlistItem.normalizedDate(quotedAt ?? marketDate),
                        price: currentPrice,
                        quotedAt: quotedAt,
                        sourceLabel: sourceLabel
                    )
                )
            }

            let resolvedName = valuation?.fundName.nilIfEmpty ?? record.item.normalizedName ?? record.item.normalizedCode
            let enrichedRecord = record.updating(
                displayName: resolvedName,
                appending: allDailyPoints
            )
            return PersonalWatchlistQuoteRow(
                record: enrichedRecord,
                assetName: resolvedName,
                currentPrice: currentPrice,
                quotedAt: quotedAt,
                sourceLabel: sourceLabel,
                dailyChangePct: valuation?.estimateChangePct,
                dailyPoints: enrichedRecord.dailyPoints
            )
        }

        return PersonalWatchlistSnapshot(
            rows: rows.sorted {
                if $0.category != $1.category {
                    return Self.watchlistCategoryOrder($0.category) < Self.watchlistCategoryOrder($1.category)
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            refreshedAt: isoTimestampNow()
        )
    }

    func fetchPersonalAssetPriceHistory(
        for holding: UserPortfolioHolding
    ) async throws -> [PersonalWatchlistDailyPoint] {
        let code = holding.normalizedFundCode
        guard !code.isEmpty else { return [] }

        if holding.assetType == .fund, holding.detectedFundMarket == .offExchange {
            let history: NativeFundHistory
            if let cached = await cache.history(for: code, ttl: historyTTL) {
                history = cached
            } else {
                history = try await fetchFundHistorySeries(code)
                await cache.store(history: history, for: code)
            }
            return history.series
                .suffix(PersonalWatchlistRecord.maximumDailyPointCount)
                .map {
                    PersonalWatchlistDailyPoint(
                        date: $0.date,
                        price: $0.nav,
                        quotedAt: $0.date,
                        sourceLabel: "基金净值"
                    )
                }
        }

        let item = PersonalWatchlistItem(
            id: holding.id,
            code: code,
            displayName: holding.normalizedName,
            assetType: holding.assetType,
            stockMarket: holding.detectedMarket,
            fundMarket: holding.detectedFundMarket,
            followedAt: ""
        )
        if let cached = await cache.stockDailySeries(for: item.identityKey, ttl: stockDailySeriesTTL) {
            return cached
        }
        let series = try await fetchWatchlistMarketDailySeries(item)
        await cache.store(stockDailySeries: series, for: item.identityKey)
        return series
    }

    func fetchMarketIndexQuotes(kinds: [MarketIndexKind]) async -> [MarketIndexKind: MarketIndexQuote] {
        let uniqueKinds = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
        guard !uniqueKinds.isEmpty else { return [:] }

        var results: [MarketIndexKind: MarketIndexQuote] = [:]
        await withTaskGroup(of: (MarketIndexKind, MarketIndexQuote?).self) { group in
            var nextIndex = 0

            func enqueue(_ kind: MarketIndexKind) {
                group.addTask {
                    if let cached = await self.cache.marketIndexQuote(for: kind, ttl: self.quoteTTL) {
                        return (kind, cached)
                    }
                    guard let quote = try? await self.fetchMarketIndexQuote(kind) else {
                        return (kind, nil)
                    }
                    await self.cache.store(marketIndexQuote: quote, for: kind)
                    return (kind, quote)
                }
            }

            while nextIndex < Swift.min(uniqueKinds.count, Self.preloadConcurrencyLimit) {
                enqueue(uniqueKinds[nextIndex])
                nextIndex += 1
            }

            while let (kind, quote) = await group.next() {
                if let quote {
                    results[kind] = quote
                }
                if nextIndex < uniqueKinds.count {
                    enqueue(uniqueKinds[nextIndex])
                    nextIndex += 1
                }
            }
        }
        return results
    }

    func resolveAssetNames(holdings: [UserPortfolioHolding]) async -> [UUID: String] {
        let fundCodes = Array(Set(holdings.filter {
            $0.assetType == .fund && $0.detectedFundMarket != .onExchange
        }.map(\.normalizedFundCode).filter { !$0.isEmpty }))
        let stockCodes = Array(Set(holdings.filter {
            $0.assetType == .stock || ($0.assetType == .fund && $0.detectedFundMarket == .onExchange)
        }.map(\.normalizedFundCode).filter { !$0.isEmpty }))

        async let fundNamesByCodeTask = resolveFundNames(fundCodes: fundCodes)
        async let stockQuotesTask = preloadStockQuotes(stockCodes)
        let fundNamesByCode = await fundNamesByCodeTask
        let stockQuotes = await stockQuotesTask

        var names: [UUID: String] = [:]
        for holding in holdings {
            switch holding.assetType {
            case .fund:
                if holding.detectedFundMarket == .onExchange,
                   let name = stockQuotes[holding.normalizedFundCode]?.stockName,
                   !name.isEmpty {
                    names[holding.id] = name
                } else if let name = fundNamesByCode[holding.normalizedFundCode], !name.isEmpty {
                    names[holding.id] = name
                }
            case .stock:
                if let name = stockQuotes[holding.normalizedFundCode]?.stockName, !name.isEmpty {
                    names[holding.id] = name
                }
            }
        }
        return names
    }

    func resolveAssetName(assetType: PersonalAssetType, code: String) async -> String? {
        let holding = UserPortfolioHolding(
            fundCode: code,
            assetType: assetType,
            units: 1,
            costPrice: nil,
            displayName: nil
        )
        return await resolveAssetNames(holdings: [holding])[holding.id]
    }

    func resolveFundNames(fundCodes: [String]) async -> [String: String] {
        let normalizedCodes = Array(Set(fundCodes.map(normalizedString).filter { !$0.isEmpty }))
        guard !normalizedCodes.isEmpty else { return [:] }

        let (histories, quotes) = await preloadHistoriesAndQuotes(normalizedCodes)

        var names: [String: String] = [:]
        for code in normalizedCodes {
            let name = firstNonEmpty([
                quotes[code]?.fundName ?? "",
                histories[code]?.fundName ?? "",
            ])
            if !name.isEmpty {
                names[code] = name
            }
        }
        return names
    }

    private func userPortfolioPricePayload(
        for holding: UserPortfolioHolding,
        histories: [String: NativeFundHistory],
        quotes: [String: NativeFundQuote],
        stockQuotes: [String: NativeStockQuote]
    ) -> NativeUserPortfolioPricePayload {
        switch holding.assetType {
        case .fund:
            if holding.detectedFundMarket == .onExchange {
                let quote = stockQuotes[holding.normalizedFundCode]
                return NativeUserPortfolioPricePayload(
                    assetName: quote?.stockName ?? "",
                    currentPrice: (quote?.price ?? 0) > 0 ? quote?.price : nil,
                    priceTime: quote?.priceTime ?? "",
                    priceSource: quote?.priceSourceLabel ?? "",
                    officialNav: (quote?.previousClose ?? 0) > 0 ? quote?.previousClose : nil,
                    officialNavDate: quote?.priceTime ?? "",
                    estimatePrice: nil,
                    estimatePriceTime: "",
                    estimateChangePct: quote?.changePct
                )
            }
            let history = histories[holding.normalizedFundCode]
            let quote = quotes[holding.normalizedFundCode]
            let latestNav = history?.series.last
            return NativeUserPortfolioPricePayload(
                assetName: firstNonEmpty([quote?.fundName ?? "", history?.fundName ?? ""]),
                currentPrice: (quote?.price ?? 0) > 0 ? quote?.price : nil,
                priceTime: firstNonEmpty([quote?.priceTime ?? "", latestNav?.date ?? ""]),
                priceSource: firstNonEmpty([quote?.priceSourceLabel ?? "", quote?.priceSource ?? "", "最新净值"]),
                officialNav: quote?.officialNav ?? latestNav?.nav,
                officialNavDate: firstNonEmpty([quote?.officialNavDate ?? "", latestNav?.date ?? ""]),
                estimatePrice: quote?.estimatePrice,
                estimatePriceTime: quote?.estimateTime ?? "",
                estimateChangePct: quote?.estimateChangePct
            )
        case .stock:
            let quote = stockQuotes[holding.normalizedFundCode]
            return NativeUserPortfolioPricePayload(
                assetName: quote?.stockName ?? "",
                currentPrice: (quote?.price ?? 0) > 0 ? quote?.price : nil,
                priceTime: quote?.priceTime ?? "",
                priceSource: quote?.priceSourceLabel ?? "",
                officialNav: (quote?.previousClose ?? 0) > 0 ? quote?.previousClose : nil,
                officialNavDate: quote?.priceTime ?? "",
                estimatePrice: nil,
                estimatePriceTime: "",
                estimateChangePct: quote?.changePct
            )
        }
    }

    private func requestAdjustments(prodCode: String) async throws -> [[String: Any]] {
        let payload = try await requestJSON(
            hostURL: baseURL,
            path: "/long-win/plan/adjustments",
            params: [
                "desc": "true",
                "prodCode": prodCode,
            ],
            headers: [:]
        )
        // 顶层直接是数组
        if let list = payload as? [[String: Any]] {
            return list
        }
        // 接口可能包了一层字典：尝试常见 key 解包
        if let object = payload as? [String: Any] {
            for key in ["data", "list", "rows", "result", "items", "records"] {
                if let list = object[key] as? [[String: Any]] {
                    return list
                }
            }
            // 诊断：打印顶层 key 帮助定位结构变化
            #if DEBUG
            print("[Platform] adjustments 顶层为字典，keys=\(object.keys.sorted())")
            #endif
        } else {
            #if DEBUG
            print("[Platform] adjustments 顶层类型异常: \(Swift.type(of: payload))")
            #endif
        }
        throw NativePlatformError.invalidResponse
    }

    private func buildPlatformPayload(prodCode: String, rawItems: [[String: Any]]) async throws -> PlatformPayload {
        var adjustments: [NativePlatformAdjustment] = []
        var actionSeeds: [NativePlatformActionSeed] = []

        for rawItem in rawItems {
            let adjustmentID = intValue(rawItem["adjustmentId"]) ?? 0
            let createdTs = intValue(rawItem["adjustCreateTime"]) ?? 0
            let txnTs = intValue(rawItem["adjustTxnDate"]) ?? 0
            let normalizedOrders = ((rawItem["orders"] as? [[String: Any]]) ?? []).map { normalizePlatformOrder($0, adjustmentID: adjustmentID) }
            let adjustmentTitle = firstNonEmpty([normalizedString(rawItem["comment"]), "调仓 \(adjustmentID)"])
            let articleURL = normalizedString(rawItem["url"])
            let createdAt = formatTime(formatTimestampMs(createdTs))
            let txnDate = formatTime(formatTimestampMs(txnTs))
            var orderCount = 0

            for (index, order) in normalizedOrders.enumerated() {
                let side = order.side
                guard side == "buy" || side == "sell" else { continue }
                orderCount += 1
                let actionTitle = "\(order.label)\(order.tradeUnit)份\(order.title)"
                actionSeeds.append(
                    NativePlatformActionSeed(
                        actionKey: "\(adjustmentID):\(order.fundCode):\(side):\(index + 1)",
                        adjustmentID: adjustmentID,
                        adjustmentTitle: adjustmentTitle,
                        title: order.title,
                        actionTitle: actionTitle,
                        fundName: order.fundName,
                        fundCode: order.fundCode,
                        side: side,
                        action: order.label,
                        tradeUnit: order.tradeUnit,
                        postPlanUnit: order.postPlanUnit,
                        createdAt: createdAt,
                        txnDate: txnDate,
                        createdTs: createdTs,
                        txnTs: txnTs,
                        articleURL: articleURL,
                        comment: adjustmentTitle,
                        strategyType: order.strategyType,
                        largeClass: order.largeClass,
                        buyDate: order.buyDate,
                        nav: order.nav,
                        navDate: order.navDate,
                        orderCountInAdjustment: normalizedOrders.count
                    )
                )
            }

            adjustments.append(
                NativePlatformAdjustment(
                    adjustmentID: adjustmentID,
                    title: adjustmentTitle,
                    createdTs: createdTs,
                    txnTs: txnTs,
                    orderCount: orderCount
                )
            )
        }

        actionSeeds.sort { actionTimestamp($0.txnTs, createdTs: $0.createdTs) > actionTimestamp($1.txnTs, createdTs: $1.createdTs) }
        adjustments.sort { actionTimestamp($0.txnTs, createdTs: $0.createdTs) > actionTimestamp($1.txnTs, createdTs: $1.createdTs) }

        let fundCodes = Array(Set(actionSeeds.map(\.fundCode).filter { !$0.isEmpty }))
        let (histories, quotes) = await preloadHistoriesAndQuotes(fundCodes)
        let actions = enrichPlatformActions(actionSeeds, histories: histories, quotes: quotes)
        let holdings = buildHoldings(actions: actions, histories: histories, quotes: quotes)
        let timeline = buildTimeline(actions: actions)

        let buyCount = actions.filter { $0.side == "buy" }.count
        let sellCount = actions.filter { $0.side == "sell" }.count

        return PlatformPayload(
            supported: true,
            prodCode: prodCode,
            count: actions.count,
            buyCount: buyCount,
            sellCount: sellCount,
            adjustmentCount: adjustments.count,
            latest: actions.first,
            actions: actions,
            holdings: holdings,
            timeline: timeline,
            error: nil
        )
    }

    private func enrichPlatformActions(_ seeds: [NativePlatformActionSeed], histories: [String: NativeFundHistory], quotes: [String: NativeFundQuote]) -> [PlatformActionPayload] {
        seeds.map { seed in
            let history = histories[seed.fundCode]
            let quote = quotes[seed.fundCode]

            var tradeValuation = seed.nav
            var tradeValuationDate = normalizeDateText(seed.navDate)
            var tradeValuationSource = "调仓净值"
            if tradeValuation <= 0 {
                let navEntry = lookupNav(history: history, dateText: firstNonEmpty([seed.txnDate, seed.createdAt]))
                tradeValuation = navEntry?.nav ?? 0
                tradeValuationDate = firstNonEmpty([tradeValuationDate, navEntry?.date ?? ""])
                tradeValuationSource = tradeValuation > 0 ? "历史净值回填" : ""
            } else if tradeValuationDate.isEmpty {
                tradeValuationDate = normalizeDateText(firstNonEmpty([seed.txnDate, seed.createdAt]))
            }

            let currentValuation = quote?.price ?? 0
            let currentValuationTime = quote?.priceTime ?? ""
            let currentValuationSource = firstNonEmpty([quote?.priceSourceLabel ?? "", "当前估值"])

            let valuationChangeAmount: Double?
            let valuationChangePct: Double?
            if tradeValuation > 0, currentValuation > 0 {
                valuationChangeAmount = round(currentValuation - tradeValuation, digits: 4)
                valuationChangePct = round((currentValuation / tradeValuation - 1) * 100, digits: 2)
            } else {
                valuationChangeAmount = nil
                valuationChangePct = nil
            }

            return PlatformActionPayload(
                actionKey: seed.actionKey,
                adjustmentId: seed.adjustmentID,
                adjustmentTitle: seed.adjustmentTitle,
                title: seed.title,
                actionTitle: seed.actionTitle,
                fundName: seed.fundName,
                fundCode: seed.fundCode,
                side: seed.side,
                action: seed.action,
                tradeUnit: seed.tradeUnit,
                postPlanUnit: seed.postPlanUnit,
                createdAt: seed.createdAt,
                txnDate: seed.txnDate,
                createdTs: seed.createdTs,
                txnTs: seed.txnTs,
                articleUrl: seed.articleURL,
                comment: seed.comment,
                strategyType: seed.strategyType,
                largeClass: seed.largeClass,
                buyDate: seed.buyDate,
                nav: seed.nav > 0 ? round(seed.nav, digits: 4) : nil,
                navDate: seed.navDate.isEmpty ? nil : seed.navDate,
                orderCountInAdjustment: seed.orderCountInAdjustment,
                tradeValuation: tradeValuation > 0 ? round(tradeValuation, digits: 4) : nil,
                tradeValuationDate: tradeValuationDate.isEmpty ? nil : tradeValuationDate,
                tradeValuationSource: tradeValuationSource.isEmpty ? nil : tradeValuationSource,
                currentValuation: currentValuation > 0 ? round(currentValuation, digits: 4) : nil,
                currentValuationTime: currentValuationTime.isEmpty ? nil : currentValuationTime,
                currentValuationSource: currentValuationSource.isEmpty ? nil : currentValuationSource,
                valuationChangeAmount: valuationChangeAmount,
                valuationChangePct: valuationChangePct
            )
        }
    }

    private func buildHoldings(actions: [PlatformActionPayload], histories: [String: NativeFundHistory], quotes: [String: NativeFundQuote]) -> PlatformHoldingsPayload {
        let assetBuckets = PlatformActionAssetBuckets(actions: actions)

        var items: [HoldingItemPayload] = []
        for (assetKey, latestAction) in assetBuckets.latestByAsset {
            let currentUnits = latestAction.postPlanUnit ?? 0
            guard currentUnits > 0 else { continue }
            let relevantActions = assetBuckets.sortedActions(for: assetKey)

            var simulatedUnits = 0
            var totalCost = 0.0
            var coveredActions = 0
            var missingActions = 0
            let history = histories[latestAction.fundCode ?? ""]

            for action in relevantActions {
                let tradeUnits = action.tradeUnit ?? 0
                guard tradeUnits > 0 else { continue }
                var navValue = action.tradeValuation ?? 0
                if navValue <= 0 {
                    navValue = lookupNav(history: history, dateText: firstNonEmpty([action.txnDate ?? "", action.createdAt ?? ""]))?.nav ?? 0
                }
                if navValue <= 0 {
                    missingActions += 1
                    continue
                }
                coveredActions += 1
                if action.side == "buy" {
                    simulatedUnits += tradeUnits
                    totalCost += navValue * Double(tradeUnits)
                } else if action.side == "sell", simulatedUnits > 0 {
                    let sellUnits = min(tradeUnits, simulatedUnits)
                    let averageBeforeSell = simulatedUnits > 0 ? totalCost / Double(simulatedUnits) : 0
                    totalCost -= averageBeforeSell * Double(sellUnits)
                    simulatedUnits -= sellUnits
                    if simulatedUnits <= 0 {
                        simulatedUnits = 0
                        totalCost = 0
                    }
                } else {
                    missingActions += 1
                }
            }

            let avgCost = (currentUnits > 0 && simulatedUnits == currentUnits && totalCost > 0) ? round(totalCost / Double(currentUnits), digits: 4) : nil
            let quote = quotes[latestAction.fundCode ?? ""]
            let currentPrice = (quote?.price ?? 0) > 0 ? round(quote?.price ?? 0, digits: 4) : nil
            let positionCost = (avgCost != nil && currentUnits > 0) ? round((avgCost ?? 0) * Double(currentUnits), digits: 2) : nil
            let positionValue = (currentPrice != nil && currentUnits > 0) ? round((currentPrice ?? 0) * Double(currentUnits), digits: 2) : nil
            let profitAmount = (positionCost != nil && positionValue != nil) ? round((positionValue ?? 0) - (positionCost ?? 0), digits: 2) : nil
            let profitRatio = (avgCost != nil && currentPrice != nil && (avgCost ?? 0) > 0) ? round(((currentPrice ?? 0) / (avgCost ?? 1) - 1) * 100, digits: 2) : nil

            items.append(
                HoldingItemPayload(
                    assetKey: assetKey,
                    label: firstNonEmpty([latestAction.title ?? "", latestAction.fundName ?? "", latestAction.fundCode ?? ""]).nilIfEmpty,
                    fundName: latestAction.fundName,
                    fundCode: latestAction.fundCode,
                    currentUnits: currentUnits,
                    latestAction: latestAction.action,
                    latestActionTitle: latestAction.actionTitle,
                    latestTime: latestAction.txnDate ?? latestAction.createdAt,
                    latestTs: actionTimestamp(latestAction.txnTs, createdTs: latestAction.createdTs),
                    strategyType: latestAction.strategyType,
                    largeClass: latestAction.largeClass,
                    buyDate: latestAction.buyDate,
                    avgCost: avgCost,
                    positionCost: positionCost,
                    currentPrice: currentPrice,
                    priceSource: quote?.priceSource.nilIfEmpty,
                    priceSourceLabel: quote?.priceSourceLabel.nilIfEmpty,
                    priceTime: firstNonEmpty([quote?.priceTime ?? "", quote?.officialNavDate ?? ""]).nilIfEmpty,
                    officialNav: quote?.officialNav,
                    officialNavDate: quote?.officialNavDate.nilIfEmpty,
                    estimateChangePct: quote?.estimateChangePct,
                    positionValue: positionValue,
                    profitRatio: profitRatio,
                    costMethod: avgCost != nil ? "移动平均" : nil,
                    costCoveredActions: coveredActions,
                    costMissingActions: missingActions,
                    costReady: avgCost != nil,
                    quoteReady: currentPrice != nil,
                    estimatedValue: positionValue,
                    profitAmount: profitAmount,
                    profitPct: profitRatio
                )
            )
        }

        items.sort {
            if ($0.currentUnits ?? 0) != ($1.currentUnits ?? 0) {
                return ($0.currentUnits ?? 0) > ($1.currentUnits ?? 0)
            }
            return ($0.latestTs ?? 0) > ($1.latestTs ?? 0)
        }

        let latestItem = items.max(by: { ($0.latestTs ?? 0) < ($1.latestTs ?? 0) })
        return PlatformHoldingsPayload(
            assetCount: items.count,
            totalUnits: items.compactMap(\.currentUnits).reduce(0, +),
            latestTime: latestItem?.latestTime,
            latestTs: latestItem?.latestTs,
            items: items
        )
    }

    private func buildTimeline(actions: [PlatformActionPayload]) -> [PlatformTimelinePayload] {
        var grouped: [String: [PlatformActionPayload]] = [:]
        for action in actions {
            let label = firstNonEmpty([action.title ?? "", action.fundName ?? "", action.fundCode ?? "", "未命名标的"])
            grouped[label, default: []].append(action)
        }

        return grouped.map { label, entries in
            var buyCount = 0
            var sellCount = 0
            for entry in entries {
                if entry.side == "buy" {
                    buyCount += 1
                } else if entry.side == "sell" {
                    sellCount += 1
                }
            }
            let sortedEntries = entries.sorted { actionTimestamp($0.txnTs, createdTs: $0.createdTs) > actionTimestamp($1.txnTs, createdTs: $1.createdTs) }
            return PlatformTimelinePayload(
                label: label,
                entries: Array(sortedEntries.prefix(12)),
                buyCount: buyCount,
                sellCount: sellCount,
                eventCount: entries.count,
                latestTime: sortedEntries.first?.txnDate ?? sortedEntries.first?.createdAt,
                latestTs: sortedEntries.first.map { actionTimestamp($0.txnTs, createdTs: $0.createdTs) }
            )
        }
        .sorted {
            if ($0.eventCount ?? 0) != ($1.eventCount ?? 0) {
                return ($0.eventCount ?? 0) > ($1.eventCount ?? 0)
            }
            return ($0.latestTs ?? 0) > ($1.latestTs ?? 0)
        }
    }

    private func preloadHistories(_ fundCodes: [String]) async -> [String: NativeFundHistory] {
        var results: [String: NativeFundHistory] = [:]
        let uniqueCodes = uniqueNonEmptyCodes(fundCodes)
        await withTaskGroup(of: (String, NativeFundHistory).self) { group in
            var nextIndex = 0
            func enqueue(_ code: String) {
                group.addTask {
                    if let cached = await self.cache.history(for: code, ttl: self.historyTTL) {
                        return (code, cached)
                    }
                    let history = (try? await self.fetchFundHistorySeries(code)) ?? NativeFundHistory(fundCode: code, fundName: "", series: [])
                    await self.cache.store(history: history, for: code)
                    return (code, history)
                }
            }

            while nextIndex < Swift.min(uniqueCodes.count, Self.preloadConcurrencyLimit) {
                enqueue(uniqueCodes[nextIndex])
                nextIndex += 1
            }

            while let (code, history) = await group.next() {
                results[code] = history
                if nextIndex < uniqueCodes.count {
                    enqueue(uniqueCodes[nextIndex])
                    nextIndex += 1
                }
            }
        }
        return results
    }

    private func preloadQuotes(_ fundCodes: [String], histories: [String: NativeFundHistory]) async -> [String: NativeFundQuote] {
        var results: [String: NativeFundQuote] = [:]
        let uniqueCodes = uniqueNonEmptyCodes(fundCodes)
        await withTaskGroup(of: (String, NativeFundQuote).self) { group in
            var nextIndex = 0
            func enqueue(_ code: String) {
                group.addTask {
                    if let cached = await self.cache.quote(for: code, ttl: self.quoteTTL) {
                        return (code, cached)
                    }
                    let quote = (try? await self.fetchFundQuote(code, history: histories[code])) ?? NativeFundQuote.empty(code)
                    await self.cache.store(quote: quote, for: code)
                    return (code, quote)
                }
            }

            while nextIndex < Swift.min(uniqueCodes.count, Self.preloadConcurrencyLimit) {
                enqueue(uniqueCodes[nextIndex])
                nextIndex += 1
            }

            while let (code, quote) = await group.next() {
                results[code] = quote
                if nextIndex < uniqueCodes.count {
                    enqueue(uniqueCodes[nextIndex])
                    nextIndex += 1
                }
            }
        }
        return results
    }

    /// Pipelined preload: quotes start as soon as their corresponding history completes,
    /// overlapping the two phases instead of running them sequentially.
    private func preloadHistoriesAndQuotes(
        _ fundCodes: [String],
        forceQuoteRefresh: Bool = false
    ) async -> (histories: [String: NativeFundHistory], quotes: [String: NativeFundQuote]) {
        var histories: [String: NativeFundHistory] = [:]
        var quotes: [String: NativeFundQuote] = [:]
        let uniqueCodes = uniqueNonEmptyCodes(fundCodes)
        guard !uniqueCodes.isEmpty else { return (histories, quotes) }

        await withTaskGroup(of: PreloadResult.self) { group in
            var nextHistoryIndex = 0
            let limit = Self.preloadConcurrencyLimit

            func enqueueHistory(_ code: String) {
                group.addTask {
                    let history: NativeFundHistory
                    if let cached = await self.cache.history(for: code, ttl: self.historyTTL) {
                        history = cached
                    } else {
                        history = (try? await self.fetchFundHistorySeries(code)) ?? NativeFundHistory(fundCode: code, fundName: "", series: [])
                        await self.cache.store(history: history, for: code)
                    }
                    return .history(code: code, data: history)
                }
            }

            func enqueueQuote(_ code: String, history: NativeFundHistory?) {
                group.addTask {
                    let quote: NativeFundQuote
                    if !forceQuoteRefresh,
                       let cached = await self.cache.quote(for: code, ttl: self.quoteTTL) {
                        quote = cached
                    } else {
                        quote = (try? await self.fetchFundQuote(code, history: history)) ?? NativeFundQuote.empty(code)
                        await self.cache.store(quote: quote, for: code)
                    }
                    return .quote(code: code, data: quote)
                }
            }

            while nextHistoryIndex < Swift.min(uniqueCodes.count, limit) {
                enqueueHistory(uniqueCodes[nextHistoryIndex])
                nextHistoryIndex += 1
            }

            while let result = await group.next() {
                switch result {
                case .history(let code, let data):
                    histories[code] = data
                    enqueueQuote(code, history: data)
                    if nextHistoryIndex < uniqueCodes.count {
                        enqueueHistory(uniqueCodes[nextHistoryIndex])
                        nextHistoryIndex += 1
                    }
                case .quote(let code, let data):
                    quotes[code] = data
                }
            }
        }

        return (histories, quotes)
    }

    private func preloadStockQuotes(_ stockCodes: [String]) async -> [String: NativeStockQuote] {
        var results: [String: NativeStockQuote] = [:]
        let uniqueCodes = uniqueNonEmptyCodes(stockCodes)
        await withTaskGroup(of: (String, NativeStockQuote).self) { group in
            var nextIndex = 0
            func enqueue(_ code: String) {
                group.addTask {
                    if let cached = await self.cache.stockQuote(for: code, ttl: self.quoteTTL) {
                        return (code, cached)
                    }
                    let quote = (try? await self.fetchStockQuote(code)) ?? NativeStockQuote.empty(code)
                    await self.cache.store(stockQuote: quote, for: code)
                    return (code, quote)
                }
            }

            while nextIndex < Swift.min(uniqueCodes.count, Self.preloadConcurrencyLimit) {
                enqueue(uniqueCodes[nextIndex])
                nextIndex += 1
            }

            while let (code, quote) = await group.next() {
                results[code] = quote
                if nextIndex < uniqueCodes.count {
                    enqueue(uniqueCodes[nextIndex])
                    nextIndex += 1
                }
            }
        }
        return results
    }

    private func preloadWatchlistMarketDailySeries(
        _ items: [PersonalWatchlistItem]
    ) async -> [UUID: [PersonalWatchlistDailyPoint]] {
        let requestedItems = items.filter { $0.category != .offExchangeFund }
        guard !requestedItems.isEmpty else { return [:] }

        var results: [UUID: [PersonalWatchlistDailyPoint]] = [:]
        await withTaskGroup(of: (UUID, [PersonalWatchlistDailyPoint]).self) { group in
            var nextIndex = 0

            func enqueue(_ item: PersonalWatchlistItem) {
                group.addTask {
                    if let cached = await self.cache.stockDailySeries(
                        for: item.identityKey,
                        ttl: self.stockDailySeriesTTL
                    ) {
                        return (item.id, cached)
                    }
                    let series = (try? await self.fetchWatchlistMarketDailySeries(item)) ?? []
                    await self.cache.store(stockDailySeries: series, for: item.identityKey)
                    return (item.id, series)
                }
            }

            while nextIndex < Swift.min(requestedItems.count, Self.preloadConcurrencyLimit) {
                enqueue(requestedItems[nextIndex])
                nextIndex += 1
            }

            while let (id, series) = await group.next() {
                results[id] = series
                if nextIndex < requestedItems.count {
                    enqueue(requestedItems[nextIndex])
                    nextIndex += 1
                }
            }
        }
        return results
    }

    private func fetchWatchlistMarketDailySeries(
        _ item: PersonalWatchlistItem
    ) async throws -> [PersonalWatchlistDailyPoint] {
        let market = item.category == .onExchangeFund ? StockMarket.aShare : item.detectedStockMarket
        guard let baseSymbol = tencentStockSymbol(for: item.normalizedCode, market: market) else {
            return []
        }

        let symbols: [String]
        if market == .us {
            symbols = ["\(baseSymbol).OQ", "\(baseSymbol).N", "\(baseSymbol).A", baseSymbol]
        } else {
            symbols = [baseSymbol]
        }

        for symbol in symbols {
            guard let series = try? await fetchTencentDailySeries(symbol: symbol) else {
                continue
            }
            if series.count >= 2 || symbol == symbols.last {
                return series
            }
        }
        return []
    }

    private func fetchTencentDailySeries(symbol: String) async throws -> [PersonalWatchlistDailyPoint] {
        var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/kline/kline")
        components?.queryItems = [
            URLQueryItem(name: "param", value: "\(symbol),day,,,180"),
        ]
        guard let url = components?.url else {
            throw NativePlatformError.invalidResponse
        }

        let text = try await requestText(
            hostURL: URL(string: "https://web.ifzq.gtimg.cn")!,
            absoluteURL: url,
            headers: [
                "Accept": "application/json",
                "Referer": "https://gu.qq.com/",
            ]
        )
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              intValue(object["code"]) == 0,
              let data = object["data"] as? [String: Any],
              let payload = data[symbol] as? [String: Any] else {
            return []
        }

        let rows = (payload["day"] as? [[Any]]) ?? (payload["qfqday"] as? [[Any]]) ?? []
        let points = rows.compactMap { row -> PersonalWatchlistDailyPoint? in
            guard row.count > 2 else { return nil }
            let date = PersonalWatchlistItem.normalizedDate(normalizedString(row[0]))
            guard !date.isEmpty, let close = doubleValue(row[2]), close > 0 else { return nil }
            return PersonalWatchlistDailyPoint(
                date: date,
                price: close,
                quotedAt: date,
                sourceLabel: "日线收盘"
            )
        }
        return PersonalWatchlistRecord.mergingDailyPoints(points)
    }

    private func uniqueNonEmptyCodes(_ codes: [String]) -> [String] {
        Array(Set(codes.map(normalizedString).filter { !$0.isEmpty })).sorted()
    }

    private static func watchlistCategoryOrder(_ category: PersonalWatchlistCategory) -> Int {
        PersonalWatchlistCategory.allCases.firstIndex(of: category) ?? 0
    }

    private func fetchFundHistorySeries(_ fundCode: String) async throws -> NativeFundHistory {
        let requestTime = Int(now().timeIntervalSince1970)
        let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(fundCode).js?v=\(requestTime)")!
        let text = try await requestText(hostURL: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), absoluteURL: url, headers: [
            "Referer": "https://fund.eastmoney.com/",
        ])

        let name = firstMatch(in: text, pattern: #"var\s+fS_name\s*=\s*"([^"]*)";"#) ?? ""
        guard let trendText = firstMatch(in: text, pattern: #"var\s+Data_netWorthTrend\s*=\s*(\[[\s\S]*?\]);"#),
              let data = trendText.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return NativeFundHistory(fundCode: fundCode, fundName: name, series: [])
        }

        let series = rows.compactMap { row -> NativeFundHistoryEntry? in
            guard let nav = doubleValue(row["y"]), nav > 0,
                  let ts = intValue(row["x"]), ts > 0 else {
                return nil
            }
            let date = dateTextFromTimestampMs(ts)
            guard !date.isEmpty else { return nil }
            return NativeFundHistoryEntry(
                date: date,
                dateKey: dateKey(date),
                nav: nav,
                ts: ts,
                changePct: doubleValue(row["equityReturn"])
            )
        }
        return NativeFundHistory(fundCode: fundCode, fundName: name, series: series)
    }

    private func fetchFundQuote(_ fundCode: String, history: NativeFundHistory?) async throws -> NativeFundQuote {
        let historyQuote = latestHistoryQuote(fundCode: fundCode, history: history)
        let latestOfficialQuote = try? await fetchLatestFundNavQuote(
            fundCode,
            fundName: history?.fundName ?? ""
        )

        if let latestOfficialQuote,
           latestOfficialQuote.estimateChangePct != nil,
           isCurrentMarketDate(latestOfficialQuote.officialNavDate) {
            return latestOfficialQuote
        }
        if let historyQuote,
           historyQuote.estimateChangePct != nil,
           isCurrentMarketDate(historyQuote.officialNavDate) {
            return historyQuote
        }

        let baseOfficialQuote = latestOfficialQuote ?? historyQuote
        let legacyQuote = await fetchLegacyFundQuote(fundCode)
        if let legacyQuote,
           legacyQuote.estimatePrice != nil || legacyQuote.estimateChangePct != nil {
            return mergingFundEstimate(
                fundCode: fundCode,
                base: baseOfficialQuote ?? legacyQuote,
                estimate: NativeFundEstimate(
                    fundName: legacyQuote.fundName,
                    price: legacyQuote.estimatePrice,
                    time: legacyQuote.estimateTime,
                    changePct: legacyQuote.estimateChangePct,
                    source: "eastmoney_legacy_estimate",
                    sourceLabel: "东方财富盘中估值"
                )
            )
        }

        if let sinaEstimate = try? await fetchSinaFundEstimate(fundCode) {
            return mergingFundEstimate(
                fundCode: fundCode,
                base: baseOfficialQuote ?? legacyQuote,
                estimate: sinaEstimate
            )
        }

        if let base = baseOfficialQuote ?? legacyQuote,
           let proxyEstimate = try? await fetchFundProxyEstimate(
               fundCode: fundCode,
               fundName: firstNonEmpty([base.fundName, history?.fundName ?? ""]),
               baseQuote: base
           ) {
            return mergingFundEstimate(fundCode: fundCode, base: base, estimate: proxyEstimate)
        }

        return baseOfficialQuote ?? legacyQuote ?? .empty(fundCode)
    }

    private func fetchLegacyFundQuote(_ fundCode: String) async -> NativeFundQuote? {
        let requestTime = Int(now().timeIntervalSince1970)
        let url = URL(string: "https://fundgz.1234567.com.cn/js/\(fundCode).js?rt=\(requestTime)")!
        let text = (try? await requestText(hostURL: url.deletingLastPathComponent().deletingLastPathComponent(), absoluteURL: url, headers: [
            "Referer": "https://fund.eastmoney.com/",
        ])) ?? ""

        if let payloadText = firstMatch(in: text, pattern: #"jsonpgz\((\{[\s\S]*\})\);"#),
           let data = payloadText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let officialNav = doubleValue(object["dwjz"])
            let officialNavDate = normalizedString(object["jzrq"])
            let estimateTime = normalizedString(object["gztime"])
            let isCurrentEstimate = normalizeDateText(estimateTime) == currentMarketDateText()
            let estimatePrice = isCurrentEstimate ? doubleValue(object["gsz"]) : nil
            let estimateChangePct = isCurrentEstimate ? doubleValue(object["gszzl"]) : nil
            if let officialNav, officialNav > 0 {
                return NativeFundQuote(
                    fundCode: fundCode,
                    fundName: normalizedString(object["name"]),
                    price: officialNav,
                    priceTime: officialNavDate,
                    priceSource: "official_nav",
                    priceSourceLabel: "最新净值",
                    officialNav: officialNav,
                    officialNavDate: officialNavDate,
                    estimatePrice: estimatePrice,
                    estimateTime: isCurrentEstimate ? estimateTime : "",
                    estimateChangePct: estimateChangePct
                )
            }

            if let estimatePrice, estimatePrice > 0 {
                return NativeFundQuote(
                    fundCode: fundCode,
                    fundName: normalizedString(object["name"]),
                    price: estimatePrice,
                    priceTime: estimateTime,
                    priceSource: "estimate",
                    priceSourceLabel: "盘中估值",
                    officialNav: nil,
                    officialNavDate: "",
                    estimatePrice: estimatePrice,
                    estimateTime: estimateTime,
                    estimateChangePct: estimateChangePct
                )
            }
        }
        return nil
    }

    private func fetchSinaFundEstimate(_ fundCode: String) async throws -> NativeFundEstimate? {
        let url = URL(string: "https://hq.sinajs.cn/list=fu_\(fundCode)")!
        let text = try await requestText(
            hostURL: URL(string: "https://hq.sinajs.cn")!,
            absoluteURL: url,
            headers: [
                "Accept": "text/plain,*/*",
                "Referer": "https://finance.sina.com.cn/",
            ]
        )
        guard let quoted = firstMatch(in: text, pattern: #"=\"([^\"]*)\";"#) else {
            return nil
        }
        let parts = quoted.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 7 else { return nil }

        let estimateDate = normalizeDateText(parts[safe: 7] ?? "")
        guard estimateDate == currentMarketDateText(),
              let estimatePrice = doubleValue(parts[safe: 2]),
              estimatePrice > 0 else {
            return nil
        }
        let estimateTime = firstNonEmpty([
            [estimateDate, normalizedString(parts[safe: 1])].filter { !$0.isEmpty }.joined(separator: " "),
            estimateDate,
        ])
        let reportedChangePct = doubleValue(parts[safe: 6])
        let derivedChangePct: Double?
        if let previousNav = doubleValue(parts[safe: 3]), previousNav > 0 {
            derivedChangePct = (estimatePrice / previousNav - 1) * 100
        } else {
            derivedChangePct = nil
        }

        return NativeFundEstimate(
            fundName: normalizedString(parts[safe: 0]),
            price: estimatePrice,
            time: estimateTime,
            changePct: reportedChangePct ?? derivedChangePct,
            source: "sina_estimate",
            sourceLabel: "新浪盘中估值"
        )
    }

    private func fetchFundProxyEstimate(
        fundCode: String,
        fundName: String,
        baseQuote: NativeFundQuote
    ) async throws -> NativeFundEstimate? {
        guard let officialNav = baseQuote.officialNav, officialNav > 0 else { return nil }
        let proxy = fundEstimateProxy(for: fundName)
        let officialNavDate = normalizeDateText(baseQuote.officialNavDate)

        if let quote = try? await fetchSingleTencentQuote(symbol: proxy.symbol, stockCode: fundCode),
           quote.hasUsableData,
           let changePct = quote.changePct,
           changePct.isFinite,
           abs(changePct) <= 30 {
            let quoteDate = normalizeDateText(quote.priceTime)
            if !quoteDate.isEmpty,
               officialNavDate.isEmpty || quoteDate > officialNavDate || quoteDate == currentMarketDateText() {
                return NativeFundEstimate(
                    fundName: fundName,
                    price: officialNav * (1 + changePct / 100),
                    time: quote.priceTime,
                    changePct: changePct,
                    source: "market_proxy_estimate",
                    sourceLabel: "\(proxy.label)代理估算"
                )
            }
        }

        switch proxy.intradayKind {
        case "future":
            guard let intradaySymbol = proxy.intradaySymbol else { return nil }
            return try await fetchSinaGlobalFuturesEstimate(
                symbol: intradaySymbol,
                label: proxy.intradayLabel,
                fundName: fundName,
                officialNav: officialNav
            )
        case "forex":
            return try await fetchSinaForexEstimate(
                symbol: proxy.intradaySymbol ?? "fx_susdcny",
                label: proxy.intradayLabel,
                fundName: fundName,
                officialNav: officialNav
            )
        default:
            return nil
        }
    }

    private func fundEstimateProxy(
        for fundName: String
    ) -> (symbol: String, label: String, intradaySymbol: String?, intradayLabel: String, intradayKind: String) {
        let name = fundName.uppercased()
        if (name.contains("中概") && (name.contains("互联网") || name.contains("互联")))
            || name.contains("海外互联网") {
            return ("sh513050", "中概互联网ETF", nil, "", "")
        }
        if name.contains("纳斯达克100") || name.contains("纳指100") {
            return ("usNDX", "纳斯达克100", "hf_NQ", "纳指100期货", "future")
        }
        if name.contains("标普500") {
            return ("usINX", "标普500", "hf_ES", "标普500期货", "future")
        }
        if name.contains("全球医疗保健") || name.contains("全球医疗") {
            return ("usIXJ", "全球医疗ETF", "hf_ES", "标普500期货", "future")
        }
        if name.contains("QDII"), name.contains("债") {
            return ("usAGG", "美国综合债券ETF", "fx_susdcny", "美元兑人民币", "forex")
        }
        if name.contains("国开债") || name.contains("纯债") || name.contains("债券") {
            return ("sh000012", "国债指数", nil, "", "")
        }
        if name.contains("QDII") {
            return ("usINX", "标普500", "hf_ES", "标普500期货", "future")
        }
        if name.contains("科创") { return ("sh000688", "科创50", nil, "", "") }
        if name.contains("创业板") { return ("sz399006", "创业板指", nil, "", "") }
        return ("sh000300", "沪深300", nil, "", "")
    }

    private func fetchSinaGlobalFuturesEstimate(
        symbol: String,
        label: String,
        fundName: String,
        officialNav: Double
    ) async throws -> NativeFundEstimate? {
        let parts = try await fetchSinaQuoteParts(symbol: symbol)
        guard parts.count > 12,
              normalizeDateText(parts[safe: 12] ?? "") == currentMarketDateText(),
              let price = doubleValue(parts[safe: 0]),
              let previousClose = doubleValue(parts[safe: 7]),
              price > 0,
              previousClose > 0 else {
            return nil
        }
        let changePct = (price / previousClose - 1) * 100
        guard changePct.isFinite, abs(changePct) <= 20 else { return nil }
        let quoteTime = [
            normalizedString(parts[safe: 12]),
            normalizedString(parts[safe: 6]),
        ].filter { !$0.isEmpty }.joined(separator: " ")
        return NativeFundEstimate(
            fundName: fundName,
            price: officialNav * (1 + changePct / 100),
            time: quoteTime,
            changePct: changePct,
            source: "market_proxy_estimate",
            sourceLabel: "\(label)代理估算"
        )
    }

    private func fetchSinaForexEstimate(
        symbol: String,
        label: String,
        fundName: String,
        officialNav: Double
    ) async throws -> NativeFundEstimate? {
        let parts = try await fetchSinaQuoteParts(symbol: symbol)
        guard parts.count > 17,
              normalizeDateText(parts[safe: 17] ?? "") == currentMarketDateText(),
              let price = doubleValue(parts[safe: 8]),
              let previousClose = doubleValue(parts[safe: 3]),
              price > 0,
              previousClose > 0 else {
            return nil
        }
        let changePct = (price / previousClose - 1) * 100
        guard changePct.isFinite, abs(changePct) <= 10 else { return nil }
        let quoteTime = [
            normalizedString(parts[safe: 17]),
            normalizedString(parts[safe: 0]),
        ].filter { !$0.isEmpty }.joined(separator: " ")
        return NativeFundEstimate(
            fundName: fundName,
            price: officialNav * (1 + changePct / 100),
            time: quoteTime,
            changePct: changePct,
            source: "market_proxy_estimate",
            sourceLabel: "\(label)代理估算"
        )
    }

    private func fetchSinaQuoteParts(symbol: String) async throws -> [String] {
        let url = URL(string: "https://hq.sinajs.cn/list=\(symbol)")!
        let text = try await requestText(
            hostURL: URL(string: "https://hq.sinajs.cn")!,
            absoluteURL: url,
            headers: [
                "Accept": "text/plain,*/*",
                "Referer": "https://finance.sina.com.cn/",
            ]
        )
        guard let quoted = firstMatch(in: text, pattern: #"=\"([^\"]*)\";"#) else {
            return []
        }
        return quoted.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private func latestHistoryQuote(fundCode: String, history: NativeFundHistory?) -> NativeFundQuote? {
        guard let latest = history?.series.last else { return nil }
        let previousNav = history?.series.dropLast().last?.nav
        let changePct = resolvedChangePct(
            reported: latest.changePct,
            latest: latest.nav,
            previous: previousNav
        )
        return NativeFundQuote(
            fundCode: fundCode,
            fundName: history?.fundName ?? "",
            price: latest.nav,
            priceTime: latest.date,
            priceSource: "official_nav",
            priceSourceLabel: isCurrentMarketDate(latest.date) ? "当日确认净值" : "最近净值",
            officialNav: latest.nav,
            officialNavDate: latest.date,
            estimatePrice: nil,
            estimateTime: "",
            estimateChangePct: changePct
        )
    }

    private func mergingFundEstimate(
        fundCode: String,
        base: NativeFundQuote?,
        estimate: NativeFundEstimate
    ) -> NativeFundQuote {
        guard let base else {
            return NativeFundQuote(
                fundCode: fundCode,
                fundName: estimate.fundName,
                price: estimate.price ?? 0,
                priceTime: estimate.time,
                priceSource: estimate.source,
                priceSourceLabel: estimate.sourceLabel,
                officialNav: nil,
                officialNavDate: "",
                estimatePrice: estimate.price,
                estimateTime: estimate.time,
                estimateChangePct: estimate.changePct
            )
        }

        return NativeFundQuote(
            fundCode: base.fundCode,
            fundName: firstNonEmpty([estimate.fundName, base.fundName]),
            price: base.price,
            priceTime: base.priceTime,
            priceSource: base.priceSource,
            priceSourceLabel: "\(base.priceSourceLabel) · \(estimate.sourceLabel)",
            officialNav: base.officialNav,
            officialNavDate: base.officialNavDate,
            estimatePrice: estimate.price,
            estimateTime: estimate.time,
            estimateChangePct: estimate.changePct
        )
    }

    private func fetchLatestFundNavQuote(_ fundCode: String, fundName: String) async throws -> NativeFundQuote? {
        var components = URLComponents(string: "https://api.fund.eastmoney.com/f10/lsjz")
        components?.queryItems = [
            URLQueryItem(name: "fundCode", value: fundCode),
            URLQueryItem(name: "pageIndex", value: "1"),
            URLQueryItem(name: "pageSize", value: "2"),
        ]
        guard let url = components?.url else {
            throw NativePlatformError.invalidResponse
        }

        let text = try await requestText(
            hostURL: URL(string: "https://api.fund.eastmoney.com")!,
            absoluteURL: url,
            headers: [
                "Accept": "application/json",
                "Referer": "https://fund.eastmoney.com/",
            ]
        )
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              intValue(object["ErrCode"]) == 0,
              let payload = object["Data"] as? [String: Any],
              let rows = payload["LSJZList"] as? [[String: Any]],
              let latest = rows.first,
              let officialNav = doubleValue(latest["DWJZ"]),
              officialNav > 0 else {
            return nil
        }

        let officialNavDate = normalizedString(latest["FSRQ"])
        let previousNav = rows.dropFirst()
            .compactMap { doubleValue($0["DWJZ"]) }
            .first(where: { $0 > 0 })
        let changePct = resolvedChangePct(
            reported: doubleValue(latest["JZZZL"]),
            latest: officialNav,
            previous: previousNav
        )
        return NativeFundQuote(
            fundCode: fundCode,
            fundName: fundName,
            price: officialNav,
            priceTime: officialNavDate,
            priceSource: "official_nav",
            priceSourceLabel: isCurrentMarketDate(officialNavDate) ? "当日确认净值" : "最近净值",
            officialNav: officialNav,
            officialNavDate: officialNavDate,
            estimatePrice: nil,
            estimateTime: "",
            estimateChangePct: changePct
        )
    }

    private func fetchStockQuote(_ stockCode: String) async throws -> NativeStockQuote {
        if let quote = try? await fetchEastmoneyStockQuote(stockCode), quote.hasUsableData {
            return quote
        }
        if let quote = try? await fetchTencentStockQuote(stockCode), quote.hasUsableData {
            return quote
        }
        return .empty(stockCode)
    }

    private func fetchMarketIndexQuote(_ kind: MarketIndexKind) async throws -> MarketIndexQuote? {
        let quote = try await fetchSingleTencentQuote(symbol: kind.tencentSymbol, stockCode: kind.rawValue)
        guard quote.hasUsableData, quote.price > 0 else { return nil }
        let changeAmount = quote.previousClose.map { quote.price - $0 }

        return MarketIndexQuote(
            kind: kind,
            name: kind.label,
            price: round(quote.price, digits: 2),
            previousClose: quote.previousClose.map { round($0, digits: 2) },
            changeAmount: changeAmount.map { round($0, digits: 2) },
            changePct: quote.changePct.map { round($0, digits: 2) },
            quotedAt: quote.priceTime,
            sourceLabel: quote.priceSourceLabel.nilIfEmpty ?? "大盘行情"
        )
    }

    private func fetchEastmoneyStockQuote(_ stockCode: String) async throws -> NativeStockQuote {
        guard let secid = stockSecID(for: stockCode) else {
            return .empty(stockCode)
        }
        let url = URL(string: "https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&fields=f43,f57,f58,f59,f60,f86,f169,f170")!
        let text = try await requestText(hostURL: url, absoluteURL: url, headers: [
            "Accept": "application/json",
            "Referer": "https://quote.eastmoney.com/",
        ])
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [:]
        guard let object = payload as? [String: Any],
              let data = object["data"] as? [String: Any],
              let code = normalizedString(data["f57"]).nilIfEmpty else {
            return .empty(stockCode)
        }

        let scale = pow(10.0, Double(intValue(data["f59"]) ?? 2))
        let price = scaledQuoteValue(data["f43"], scale: scale)
        let previousClose = scaledQuoteValue(data["f60"], scale: scale)
        let changePct = resolvedChangePct(
            reported: scaledQuoteValue(data["f170"], scale: 100),
            latest: price,
            previous: previousClose
        )
        let quoteTime = intValue(data["f86"]).flatMap { seconds -> String? in
            guard seconds > 0 else { return nil }
            return isoDateTime(Date(timeIntervalSince1970: TimeInterval(seconds)))
        }

        return NativeStockQuote(
            stockCode: code,
            stockName: normalizedString(data["f58"]),
            price: price ?? 0,
            priceTime: quoteTime ?? isoTimestampNow(),
            priceSource: "stock_quote",
            priceSourceLabel: "股票行情",
            previousClose: previousClose,
            changePct: changePct
        )
    }

    private func fetchTencentStockQuote(_ stockCode: String) async throws -> NativeStockQuote {
        let market = UserPortfolioHolding.detectStockMarket(from: stockCode)

        guard let symbol = tencentStockSymbol(for: stockCode, market: market) else {
            return .empty(stockCode)
        }

        let quote = try await fetchSingleTencentQuote(symbol: symbol, stockCode: stockCode)
        if quote.hasUsableData { return quote }

        if market == .us {
            for suffix in [".O", ".N", ".A"] {
                let altSymbol = "\(symbol)\(suffix)"
                let altQuote = try? await fetchSingleTencentQuote(symbol: altSymbol, stockCode: stockCode)
                if let altQuote, altQuote.hasUsableData { return altQuote }
            }
        }

        return quote
    }

    private func fetchSingleTencentQuote(symbol: String, stockCode: String) async throws -> NativeStockQuote {
        let url = URL(string: "https://qt.gtimg.cn/q=\(symbol)")!
        let text = try await requestText(hostURL: url, absoluteURL: url, headers: [
            "Accept": "text/plain,*/*",
            "Referer": "https://gu.qq.com/",
        ])
        guard let quoted = firstMatch(in: text, pattern: #"="([^"]*)";"#) else {
            return .empty(stockCode)
        }
        let parts = quoted.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 32 else {
            return .empty(stockCode)
        }
        let code = normalizedString(parts[safe: 2]).nilIfEmpty ?? stockCode
        let price = doubleValue(parts[safe: 3]) ?? 0
        let previousClose = doubleValue(parts[safe: 4])
        let changePct = resolvedChangePct(
            reported: doubleValue(parts[safe: 32]),
            latest: price,
            previous: previousClose
        )

        return NativeStockQuote(
            stockCode: code,
            stockName: normalizedString(parts[safe: 1]),
            price: price,
            priceTime: formattedTencentQuoteTime(parts[safe: 30]),
            priceSource: "tencent_stock_quote",
            priceSourceLabel: "股票行情",
            previousClose: previousClose,
            changePct: changePct
        )
    }

    private func lookupNav(history: NativeFundHistory?, dateText: String) -> NativeFundHistoryEntry? {
        guard let history else { return nil }
        let targetKey = dateKey(dateText)
        guard targetKey > 0, !history.series.isEmpty else { return nil }
        var low = 0
        var high = history.series.count
        while low < high {
            let mid = (low + high) / 2
            if history.series[mid].dateKey <= targetKey {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        guard index >= 0, index < history.series.count else { return nil }
        return history.series[index]
    }

    private func normalizePlatformOrder(_ order: [String: Any], adjustmentID: Int) -> NativePlatformOrder {
        let orderCode = normalizedString(order["orderCode"])
        let side: String
        let label: String
        switch orderCode {
        case "022":
            side = "buy"
            label = "买入"
        case "024":
            side = "sell"
            label = "卖出"
        default:
            side = "unknown"
            label = orderCode.isEmpty ? "未知" : orderCode
        }
        let fund = order["fund"] as? [String: Any] ?? [:]
        let title = firstNonEmpty([
            normalizedString(order["variety"]),
            normalizedString(fund["fundName"]),
            normalizedString(fund["fundCode"]),
            "未命名标的",
        ])
        return NativePlatformOrder(
            adjustmentID: adjustmentID,
            side: side,
            label: label,
            fundCode: normalizedString(fund["fundCode"]),
            fundName: normalizedString(fund["fundName"]),
            title: title,
            tradeUnit: intValue(order["tradeUnit"]) ?? 0,
            postPlanUnit: intValue(order["postPlanUnit"]) ?? 0,
            strategyType: normalizedString(order["strategyType"]),
            largeClass: normalizedString(order["largeClass"]),
            nav: doubleValue(order["nav"]) ?? 0,
            navDate: formatTime(firstNonEmpty([formatTimestampMs(order["navDate"]), normalizedString(order["navDate"])])),
            buyDate: formatTime(formatTimestampMs(((order["gridDetail"] as? [String: Any])?["buyDate"]))),
            orderCountInAdjustment: 0
        )
    }

    // HTTP 请求 / 响应解析 / 时间格式化 / 数值归一化等工具方法已抽出到
    // QiemanPlatformNativeClient+Support.swift，避免主体文件承担过高的认知负荷。

}
