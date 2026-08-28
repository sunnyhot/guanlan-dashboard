import XCTest
@testable import QiemanDashboard

// MARK: - 熔断器

final class MarketDataCircuitBreakerTests: XCTestCase {
    /// 可推进的测试时钟。
    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    func testOpensAfterConsecutiveFailures() async {
        let clock = TestClock()
        let breaker = MarketDataCircuitBreaker(failureThreshold: 3, cooldownSeconds: 300, now: clock.now)

        let canAttemptValue1 = await breaker.canAttempt("sina:snapshot")
        XCTAssertTrue(canAttemptValue1)
        await breaker.recordFailure("sina:snapshot")
        await breaker.recordFailure("sina:snapshot")
        let canAttemptValue2 = await breaker.canAttempt("sina:snapshot")
        XCTAssertTrue(canAttemptValue2, "两次失败未到阈值仍闭合")
        await breaker.recordFailure("sina:snapshot")
        let canAttemptValue3 = await breaker.canAttempt("sina:snapshot")
        XCTAssertFalse(canAttemptValue3, "连续三次失败进入熔断")
        let stateValue4 = await breaker.state("sina:snapshot")
        XCTAssertEqual(stateValue4, .open(until: clock.current.addingTimeInterval(300)))
    }

    func testSuccessResetsCounter() async {
        let clock = TestClock()
        let breaker = MarketDataCircuitBreaker(failureThreshold: 3, cooldownSeconds: 300, now: clock.now)

        await breaker.recordFailure("k")
        await breaker.recordFailure("k")
        await breaker.recordSuccess("k")
        await breaker.recordFailure("k")
        await breaker.recordFailure("k")
        let canAttemptValue5 = await breaker.canAttempt("k")
        XCTAssertTrue(canAttemptValue5, "成功后计数归零，需重新累计三次才熔断")
    }

    func testHalfOpenAfterCooldownThenRecoverOrReopen() async {
        let clock = TestClock()
        let breaker = MarketDataCircuitBreaker(failureThreshold: 2, cooldownSeconds: 100, now: clock.now)

        await breaker.recordFailure("k")
        await breaker.recordFailure("k")
        let canAttemptValue6 = await breaker.canAttempt("k")
        XCTAssertFalse(canAttemptValue6)

        clock.advance(100)
        let canAttemptValue7 = await breaker.canAttempt("k")
        XCTAssertTrue(canAttemptValue7, "冷却期结束转半开，放行探测")
        let stateValue8 = await breaker.state("k")
        XCTAssertEqual(stateValue8, .halfOpen)

        // 探测失败：重新熔断
        await breaker.recordFailure("k")
        let canAttemptValue9 = await breaker.canAttempt("k")
        XCTAssertFalse(canAttemptValue9)
        let stateValue10 = await breaker.state("k")
        XCTAssertEqual(stateValue10, .open(until: clock.current.addingTimeInterval(100)))

        // 再次冷却后探测成功：闭合
        clock.advance(100)
        let canAttemptValue11 = await breaker.canAttempt("k")
        XCTAssertTrue(canAttemptValue11)
        await breaker.recordSuccess("k")
        let stateValue12 = await breaker.state("k")
        XCTAssertEqual(stateValue12, .closed)
        let canAttemptValue13 = await breaker.canAttempt("k")
        XCTAssertTrue(canAttemptValue13)
    }

    func testKeysAreIsolated() async {
        let clock = TestClock()
        let breaker = MarketDataCircuitBreaker(failureThreshold: 1, cooldownSeconds: 300, now: clock.now)
        await breaker.recordFailure("tencent:quote")
        let canAttemptValue14 = await breaker.canAttempt("tencent:quote")
        XCTAssertFalse(canAttemptValue14)
        let canAttemptValue15 = await breaker.canAttempt("sina:snapshot")
        XCTAssertTrue(canAttemptValue15, "维度独立互不影响")
    }
}

// MARK: - TTL 缓存

final class MarketDataCacheTests: XCTestCase {
    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    func testQuoteTTLExpiry() async {
        let clock = TestClock()
        let cache = MarketDataCache(now: clock.now)
        let quotes = [MarketQuote(code: "600519", price: 1435.0)]

        await cache.setQuotes(quotes, forKey: "tencent:600519", ttl: 60)
        let hit = await cache.quotes(forKey: "tencent:600519")
        XCTAssertEqual(hit?.count, 1)

        clock.advance(61)
        let expired = await cache.quotes(forKey: "tencent:600519")
        XCTAssertNil(expired)
    }

    func testBreadthAndBarsRoundTrip() async {
        let clock = TestClock()
        let cache = MarketDataCache(now: clock.now)
        let stats = MarketBreadthStats(upCount: 3, downCount: 2)
        await cache.setBreadth(stats, forKey: "daily")
        let loaded = await cache.breadth(forKey: "daily")
        XCTAssertEqual(loaded?.upCount, 3)

        let bars = [MarketDailyBar(date: "2026-08-28", open: 10, high: 11, low: 9.8, close: 10.5, volume: 1000, amount: 10500, pctChg: 1.2)]
        await cache.setBars(bars, forKey: "k:600519")
        let loadedBars = await cache.bars(forKey: "k:600519")
        XCTAssertEqual(loadedBars?.count, 1)
        XCTAssertEqual(loadedBars?.first?.close ?? 0, 10.5)
    }

    func testCapacityEviction() async {
        let clock = TestClock()
        let cache = MarketDataCache(capacity: 8, now: clock.now)
        for index in 0..<12 {
            await cache.setQuotes([MarketQuote(code: "60000\(index)")], forKey: "q\(index)", ttl: 600)
        }
        let count = await cache.entryCount
        XCTAssertLessThanOrEqual(count, 8, "超出容量的最旧条目被淘汰")
        let oldest = await cache.quotes(forKey: "q0")
        XCTAssertNil(oldest, "最早写入的 q0 已被淘汰")
        let newest = await cache.quotes(forKey: "q11")
        XCTAssertEqual(newest?.count, 1)
    }

    func testInvalidateAll() async {
        let clock = TestClock()
        let cache = MarketDataCache(now: clock.now)
        await cache.setQuotes([MarketQuote(code: "600519")], forKey: "q")
        await cache.setBreadth(MarketBreadthStats(), forKey: "b")
        await cache.invalidateAll()
        let count = await cache.entryCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - 会话层

final class MarketDataSessionTests: XCTestCase {
    func testDecodeTextPrefersUTF8ThenGB18030() {
        let utf8 = "v_sh600519=\"贵州茅台~600519\";"
        XCTAssertEqual(MarketDataSession.decodeText(Data(utf8.utf8)), utf8)

        // GB18030 编码的中文：UTF-8 解码必然失败，走 GBK 兜底
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let chinese = "贵州茅台"
        if let gbkData = chinese.data(using: gb18030) {
            XCTAssertEqual(MarketDataSession.decodeText(gbkData), chinese)
        } else {
            XCTFail("测试环境不支持 GB18030 编码")
        }
    }

    func testHostPoliciesCoverKnownHosts() {
        let eastmoney = MarketDataSession.defaultPolicies["data.eastmoney.com"]
        XCTAssertEqual(eastmoney?.minInterval ?? 0, 1.0, "东财 dataapi 必须串行 ≥1s")
        XCTAssertNotNil(MarketDataSession.defaultPolicies["qt.gtimg.cn"])
        XCTAssertNotNil(MarketDataSession.fallbackPolicy)
    }
}
