import Foundation

/// 市场数据引擎门面（actor）：组装 Provider fallback 链 + 熔断 + TTL 缓存。
///
/// 链路（对拍总体计划 5.1.4）：
/// - 行情：腾讯（全字段）→ 东财（价格三件套补充缺失代码）
/// - 日 K：东财 → 腾讯
/// - 全市场快照（广度原料）：新浪 → 东财
/// - 热榜：NewsNow 单源，失败即失败（增强数据）
///
/// 单一数据源失败不拖垮整体（除单源能力外全部多源），熔断中的源直接跳过。
actor MarketDataEngine {
    private let session: MarketDataSession
    private let quoteProviders: [any MarketQuoteProviding]
    private let klineProviders: [any MarketKlineProviding]
    private let snapshotProviders: [any MarketSnapshotProviding]
    private let feedProvider: NewsNowFeedProvider
    private let breaker: MarketDataCircuitBreaker
    private let cache: MarketDataCache
    private let now: () -> Date

    init(
        session: MarketDataSession = MarketDataSession(),
        breaker: MarketDataCircuitBreaker = MarketDataCircuitBreaker(),
        cache: MarketDataCache = MarketDataCache(),
        quoteProviders: (any Sequence<any MarketQuoteProviding>)? = nil,
        klineProviders: (any Sequence<any MarketKlineProviding>)? = nil,
        snapshotProviders: (any Sequence<any MarketSnapshotProviding>)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.session = session
        self.breaker = breaker
        self.cache = cache
        self.quoteProviders = quoteProviders.map { Array($0) } ?? [
            TencentQuoteProvider(session: session),
            EastmoneyQuoteProvider(session: session),
        ]
        self.klineProviders = klineProviders.map { Array($0) } ?? [
            EastmoneyKlineProvider(session: session),
            TencentKlineProvider(session: session),
        ]
        self.snapshotProviders = snapshotProviders.map { Array($0) } ?? [
            // 东财 xuangu 主源：每页 500 只（新浪 100），且 filter 含北交所，全量约 11 页
            EastmoneySnapshotProvider(session: session),
            SinaSnapshotProvider(session: session),
        ]
        self.feedProvider = NewsNowFeedProvider(session: session)
        self.now = now
    }

    // MARK: - 单股/批量行情

    /// 批量行情（尽力而为）：按 fallback 链取，前面源没覆盖到的代码由后续源补。
    /// 返回实际取得的行情；调用方通过对比请求数量判断覆盖。
    func quotes(codes: [String]) async -> [MarketQuote] {
        let cacheKey = "quotes:\(codes.map { MarketCodeNormalizer.canonicalKey(for: $0) }.sorted().joined(separator: ","))"
        if let cached = await cache.quotes(forKey: cacheKey) {
            return cached
        }
        var collected: [String: MarketQuote] = [:]
        var remaining = codes.map { MarketCodeNormalizer.canonicalKey(for: $0) }
        for provider in quoteProviders where !remaining.isEmpty {
            let breakerKey = "\(provider.name):quote"
            guard await breaker.canAttempt(breakerKey) else { continue }
            do {
                let wanted = remaining.compactMap { code -> String? in
                    MarketCodeNormalizer.bareACode(from: code).count == 6 ? MarketCodeNormalizer.bareACode(from: code) : nil
                }
                let fetched = try await provider.quotes(codes: wanted)
                await breaker.recordSuccess(breakerKey)
                for quote in fetched where quote.hasUsablePrice {
                    let key = MarketCodeNormalizer.canonicalKey(for: quote.code)
                    if collected[key] == nil {
                        collected[key] = quote
                    }
                }
                remaining = remaining.filter { collected[$0] == nil }
            } catch {
                await breaker.recordFailure(breakerKey)
            }
        }
        let result = collected.values.sorted { $0.code < $1.code }
        if !result.isEmpty {
            await cache.setQuotes(result, forKey: cacheKey)
        }
        return result
    }

    // MARK: - 日 K

    func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
        let bare = MarketCodeNormalizer.bareACode(from: code)
        let cacheKey = "bars:\(bare):\(days)"
        if let cached = await cache.bars(forKey: cacheKey) {
            return cached
        }
        var failures: [String] = []
        for provider in klineProviders {
            let breakerKey = "\(provider.name):kline"
            guard await breaker.canAttempt(breakerKey) else {
                failures.append("\(provider.name): 熔断中")
                continue
            }
            do {
                let bars = try await provider.dailyBars(code: bare, days: days)
                if bars.isEmpty {
                    await breaker.recordFailure(breakerKey)
                    failures.append("\(provider.name): 返回为空")
                    continue
                }
                await breaker.recordSuccess(breakerKey)
                await cache.setBars(bars, forKey: cacheKey)
                return bars
            } catch {
                await breaker.recordFailure(breakerKey)
                failures.append("\(provider.name): \(describe(error))")
            }
        }
        throw MarketDataError.allSourcesFailed(details: failures)
    }

    // MARK: - 市场广度

    /// 全市场广度统计（TTL 10 分钟）。新浪快照为主源，东财快照兜底。
    func marketBreadth(forceRefresh: Bool = false) async throws -> MarketBreadthStats {
        if !forceRefresh, let cached = await cache.breadth(forKey: "breadth:daily") {
            return cached
        }
        var failures: [String] = []
        for provider in snapshotProviders {
            let breakerKey = "\(provider.name):snapshot"
            guard await breaker.canAttempt(breakerKey) else {
                failures.append("\(provider.name): 熔断中")
                continue
            }
            do {
                let quotes = try await provider.fullMarketSnapshot()
                guard quotes.count > 100 else {
                    await breaker.recordFailure(breakerKey)
                    failures.append("\(provider.name): 样本过少(\(quotes.count))")
                    continue
                }
                await breaker.recordSuccess(breakerKey)
                let coverage = provider.name == "eastmoney" ? "含北交所" : "不含北交所"
                let stats = MarketBreadthCalculator.compute(
                    quotes: quotes,
                    computedAt: isoNow(),
                    boundaryNote: "来源:\(provider.name)全市场快照(\(coverage))"
                )
                await cache.setBreadth(stats, forKey: "breadth:daily")
                return stats
            } catch {
                await breaker.recordFailure(breakerKey)
                failures.append("\(provider.name): \(describe(error))")
            }
        }
        throw MarketDataError.allSourcesFailed(details: failures)
    }

    // MARK: - 热榜

    func newsFeed(_ source: NewsFeedSource, forceRefresh: Bool = false) async throws -> [NewsFeedItem] {
        let cacheKey = "feed:\(source.rawValue)"
        // 热榜条目没有稳定 itemID → 缓存在 feedProvider 侧不好逐条 TTL，这里按整体缓存
        if !forceRefresh, let cached = await cachedFeeds[source.rawValue] {
            if now().timeIntervalSince(cached.storedAt) < MarketDataCache.feedTTL {
                return cached.items
            }
        }
        let items = try await feedProvider.fetch(source: source)
        cachedFeeds[source.rawValue] = (items, now())
        return items
    }

    private var cachedFeeds: [String: (items: [NewsFeedItem], storedAt: Date)] = [:]

    // MARK: - 维护

    func invalidateCaches() async {
        await cache.invalidateAll()
        cachedFeeds.removeAll()
    }

    // MARK: - 内部

    private func isoNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: now())
    }

    private func describe(_ error: Error) -> String {
        if let marketError = error as? MarketDataError {
            return marketError.errorDescription ?? "\(marketError)"
        }
        return error.localizedDescription
    }
}
