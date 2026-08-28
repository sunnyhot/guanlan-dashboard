import Foundation

/// 市场数据 TTL 缓存（actor，纯内存）。按具体类型存取，容量上限 + 过期淘汰。
///
/// 磁盘 last-good 快照在 MarketDataEngine（M2）落，本类型只管进程内命中。
actor MarketDataCache {
    static let quoteTTL: TimeInterval = 60
    static let snapshotTTL: TimeInterval = 600
    static let klineTTL: TimeInterval = 1800
    static let feedTTL: TimeInterval = 300

    private struct TimedEntry<Value> {
        let expiresAt: Date
        let value: Value
        let sequence: Int
    }

    private var quoteEntries: [String: TimedEntry<[MarketQuote]>] = [:]
    private var breadthEntries: [String: TimedEntry<MarketBreadthStats>] = [:]
    private var barEntries: [String: TimedEntry<[MarketDailyBar]>] = [:]
    /// 单调写入序号，同时写入时用于稳定的 LRU 淘汰排序
    private var writeSequence = 0
    private let capacity: Int
    private let now: () -> Date

    init(capacity: Int = 128, now: @escaping () -> Date = { Date() }) {
        self.capacity = max(4, capacity)
        self.now = now
    }

    // MARK: - 行情

    func setQuotes(_ quotes: [MarketQuote], forKey key: String, ttl: TimeInterval = MarketDataCache.quoteTTL) {
        writeSequence += 1
        quoteEntries[key] = TimedEntry(expiresAt: now().addingTimeInterval(ttl), value: quotes, sequence: writeSequence)
        evictIfNeeded(&quoteEntries)
    }

    func quotes(forKey key: String) -> [MarketQuote]? {
        entry(&quoteEntries, key: key)?.value
    }

    // MARK: - 广度

    func setBreadth(_ stats: MarketBreadthStats, forKey key: String, ttl: TimeInterval = MarketDataCache.snapshotTTL) {
        writeSequence += 1
        breadthEntries[key] = TimedEntry(expiresAt: now().addingTimeInterval(ttl), value: stats, sequence: writeSequence)
    }

    func breadth(forKey key: String) -> MarketBreadthStats? {
        entry(&breadthEntries, key: key)?.value
    }

    // MARK: - K线

    func setBars(_ bars: [MarketDailyBar], forKey key: String, ttl: TimeInterval = MarketDataCache.klineTTL) {
        writeSequence += 1
        barEntries[key] = TimedEntry(expiresAt: now().addingTimeInterval(ttl), value: bars, sequence: writeSequence)
        evictIfNeeded(&barEntries)
    }

    func bars(forKey key: String) -> [MarketDailyBar]? {
        entry(&barEntries, key: key)?.value
    }

    // MARK: - 维护

    func invalidateAll() {
        quoteEntries.removeAll()
        breadthEntries.removeAll()
        barEntries.removeAll()
    }

    var entryCount: Int {
        quoteEntries.count + breadthEntries.count + barEntries.count
    }

    // MARK: - 内部

    private func entry<Value>(_ entries: inout [String: TimedEntry<Value>], key: String) -> TimedEntry<Value>? {
        guard let item = entries[key] else { return nil }
        if now() >= item.expiresAt {
            entries.removeValue(forKey: key)
            return nil
        }
        return item
    }

    /// 容量超限时先淘汰过期项，再按写入时间淘汰最旧。
    private func evictIfNeeded<Value>(_ entries: inout [String: TimedEntry<Value>]) {
        guard entries.count > capacity else { return }
        let current = now()
        for (key, item) in entries where current >= item.expiresAt {
            entries.removeValue(forKey: key)
        }
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
