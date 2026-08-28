import XCTest
@testable import QiemanDashboard

// MARK: - 东财日 K 解析

final class EastmoneyKlineProviderTests: XCTestCase {
    func testParseKlinesMapsColumnsAndScalesVolume() {
        let klines = [
            "2026-08-27,10.00,10.50,10.60,9.90,123456,1299000.00,7.00,5.00,0.50,1.20",
            "2026-08-28,10.50,10.30,10.80,10.10,150000,1545000.00,6.73,-1.90,-0.20,1.46",
        ]
        let bars = EastmoneyKlineProvider.parseKlines(klines)
        XCTAssertEqual(bars.count, 2)

        let first = bars[0]
        XCTAssertEqual(first.date, "2026-08-27")
        XCTAssertEqual(first.open, 10.0)
        XCTAssertEqual(first.close, 10.5)
        XCTAssertEqual(first.high, 10.6)
        XCTAssertEqual(first.low, 9.9)
        XCTAssertEqual(first.volume, 12_345_600, accuracy: 1, "成交量手 → 股（×100）")
        XCTAssertEqual(first.amount ?? 0, 1_299_000.0, accuracy: 0.01)
        XCTAssertEqual(first.pctChg ?? 0, 5.0, accuracy: 0.0001)

        XCTAssertEqual(bars[1].pctChg ?? 0, -1.9, accuracy: 0.0001)
    }

    func testParseKlinesSkipsMalformedRows() {
        let klines = [
            "坏行",
            "2026-08-28,10.00,10.50,10.60,9.90,100",
        ]
        let bars = EastmoneyKlineProvider.parseKlines(klines)
        XCTAssertEqual(bars.count, 1, "缺成交额的短行仍可解析（amount 补 0）")
        XCTAssertEqual(bars[0].amount, 0)
        XCTAssertNil(bars[0].pctChg)
    }

    func testSecidRules() {
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "600519"), "1.600519")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "510300"), "1.510300")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "000001"), "0.000001")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "300750"), "0.300750")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "688981"), "1.688981")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "830799"), "0.830799")
        XCTAssertEqual(EastmoneyKlineProvider.secid(forBareCode: "920001"), "0.920001", "北交所 92 号段走 0.")
        XCTAssertNil(EastmoneyKlineProvider.secid(forBareCode: "AAPL"))
    }

    func testDateSpanClampsAndFormats() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let anchor = formatter.date(from: "2026-08-28 12:00:00")!
        let span = EastmoneyKlineProvider.dateSpan(forDays: 90, from: anchor)
        XCTAssertEqual(span.end.count, 8)
        XCTAssertEqual(span.end, "20260829", "end 留一天余量")
        // begin ≈ 90×2+20=200 天前：2026-01-09 附近
        XCTAssertEqual(span.begin.prefix(6), "202602", "200 天前 ≈ 2026-02-09")
    }
}

// MARK: - 腾讯日 K 解析

final class TencentKlineProviderTests: XCTestCase {
    func testParsePayloadPrefersQfqDayAndScalesVolume() {
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "sh600519": [
                    "qfqday": [
                        ["2026-08-27", "10.00", "10.50", "10.60", "9.90", "12345.00", "1299000.00"],
                        ["2026-08-28", "10.50", "10.30", "10.80", "10.10", "15000"],
                    ],
                    "day": [["2026-08-28", "999.00", "999.00", "999.00", "999.00", "1"]],
                ]
            ]
        ]
        let bars = TencentKlineProvider.parsePayload(payload, symbol: "sh600519")
        XCTAssertEqual(bars.count, 2, "qfqday 优先于 day")
        XCTAssertEqual(bars[0].open, 10.0)
        XCTAssertEqual(bars[0].close, 10.5)
        XCTAssertEqual(bars[0].volume, 1_234_500, accuracy: 1, "手 → 股")
        XCTAssertEqual(bars[0].amount ?? 0, 1_299_000.0, accuracy: 0.01)
        XCTAssertNil(bars[1].pctChg, "腾讯 K 线无涨跌幅字段，由相邻收盘价计算")
    }

    func testParsePayloadFallsBackToDayAndToleratesMissing() {
        let payload: [String: Any] = [
            "data": ["sz000001": ["day": [["2026-08-28", "10.0", "10.2", "10.3", "9.9", "5000"]]]]
        ]
        let bars = TencentKlineProvider.parsePayload(payload, symbol: "sz000001")
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].volume, 500_000, accuracy: 1)

        XCTAssertEqual(TencentKlineProvider.parsePayload(["data": [:]], symbol: "sh600519"), [])
        XCTAssertEqual(TencentKlineProvider.parsePayload("bad", symbol: "sh600519"), [])
    }
}

// MARK: - 东财快照/单股解析

final class EastmoneyProviderParsingTests: XCTestCase {
    func testSnapshotParseItemMapsFields() {
        let item: [String: Any] = [
            "SECUCODE": "600519.SH",
            "SECURITY_CODE": "600519",
            "SECURITY_NAME_ABBR": "贵州茅台",
            "NEW_PRICE": 1435.0,
            "CHANGE_RATE": 0.87,
            "VOLUME_RATIO": 1.05,
            "DEAL_AMOUNT": 6_300_000_000.0,
            "TURNOVERRATE": 0.35,
            "PE9": 20.5,
            "PBNEWMRQ": 8.2,
            "TOTAL_MARKET_CAP": 1_801_000_000_000.0,
            "CIRCULATION_MARKET_CAP": 1_800_000_000_000.0,
        ]
        guard let quote = EastmoneySnapshotProvider.parseItem(item) else {
            return XCTFail("应解析成功")
        }
        XCTAssertEqual(quote.code, "600519")
        XCTAssertEqual(quote.price ?? 0, 1435.0)
        XCTAssertEqual(quote.changePct ?? 0, 0.87)
        XCTAssertNil(quote.previousClose, "东财快照无昨收，由 effectivePreviousClose 反推")
        XCTAssertEqual(quote.effectivePreviousClose ?? 0, 1422.62, accuracy: 0.05, "反推精度受两位涨跌幅限制")
        XCTAssertEqual(quote.volumeRatio ?? 0, 1.05)
        XCTAssertEqual(quote.peRatio ?? 0, 20.5)
        XCTAssertEqual(quote.totalMarketCap ?? 0, 1.801e12)
        XCTAssertEqual(quote.board, .shMain)
        XCTAssertEqual(quote.source, "eastmoney")
    }

    func testSnapshotParseSkipsInvalidRows() {
        XCTAssertNil(EastmoneySnapshotProvider.parseItem(["SECURITY_CODE": "AAPL"]))
        XCTAssertNil(EastmoneySnapshotProvider.parseItem(["SECURITY_CODE": "60051"]))
        // 字符串数值也能解析
        let item: [String: Any] = ["SECURITY_CODE": "300750", "SECURITY_NAME_ABBR": "宁德时代", "NEW_PRICE": "200.00", "CHANGE_RATE": "1.01"]
        let quote = EastmoneySnapshotProvider.parseItem(item)
        XCTAssertEqual(quote?.price ?? 0, 200.0)
        XCTAssertEqual(quote?.board, .chiNext)
    }

    func testQuoteParseScalesPriceByF59() {
        let payload: [String: Any] = [
            "data": [
                "f43": 143500, "f57": "600519", "f58": "贵州茅台",
                "f59": 2, "f60": 142266, "f86": 1_787_900_400, // 2026-08-28 15:00 北京时间
                "f169": 1234, "f170": 87,
            ] as [String: Any]
        ]
        guard let quote = EastmoneyQuoteProvider.parseQuote(payload, fallbackCode: "600519") else {
            return XCTFail("应解析成功")
        }
        XCTAssertEqual(quote.code, "600519")
        XCTAssertEqual(quote.price ?? 0, 1435.0, accuracy: 0.001, "f43 按 f59=2 精度缩放")
        XCTAssertEqual(quote.previousClose ?? 0, 1422.66, accuracy: 0.001)
        XCTAssertEqual(quote.changePct ?? 0, 0.87, accuracy: 0.0001, "f170 为百分点×100")
        XCTAssertTrue(quote.quotedAt.hasPrefix("2026"), "f86 秒级时间戳转北京时间")
        // 无 f59 时默认精度 2
        let noScale: [String: Any] = ["data": ["f43": 1000, "f57": "000001", "f58": "平安银行", "f60": 990, "f170": 101]]
        let scaled = EastmoneyQuoteProvider.parseQuote(noScale, fallbackCode: "000001")
        XCTAssertEqual(scaled?.price ?? 0, 10.0, accuracy: 0.001)
        XCTAssertNil(EastmoneyQuoteProvider.parseQuote(["data": [String: Any]()], fallbackCode: "x"))
    }
}

// MARK: - NewsNow 热榜解析

final class NewsNowFeedProviderTests: XCTestCase {
    func testParseItemsToleratesIDTypes() {
        let payload: [String: Any] = [
            "code": 200,
            "data": [
                ["id": "abc-1", "title": "财联社 headline", "url": "https://example.com/1"],
                ["id": 12345, "title": "数字 id 条目"],
                ["rank": 3, "title": "无 id 用 rank"],
                ["id": "bad", "title": "   ", "url": ""],  // 空标题跳过
            ]
        ]
        let items = NewsNowFeedProvider.parseItems(payload, source: .cailiansheHot)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "财联社 headline")
        XCTAssertEqual(items[0].url, "https://example.com/1")
        XCTAssertEqual(items[0].sourceName, "财联社热榜")
        XCTAssertEqual(items[1].itemID, "cls-hot:12345", "数字 id 规范成字符串")
        XCTAssertEqual(items[2].itemID, "cls-hot:rank-3")
        XCTAssertEqual(NewsNowFeedProvider.parseItems(["data": "bad"], source: .jin10), [])
        XCTAssertEqual(NewsNowFeedProvider.parseItems("bad", source: .jin10), [])
    }
}

// MARK: - 引擎 fallback 行为（fake 注入）

final class MarketDataEngineTests: XCTestCase {
    private struct FailingQuoteProvider: MarketQuoteProviding {
        let name = "failing"
        func quotes(codes: [String]) async throws -> [MarketQuote] {
            throw MarketDataError.badStatus(status: 502, snippet: "boom")
        }
    }

    private struct PartialQuoteProvider: MarketQuoteProviding {
        let name = "partial"
        func quotes(codes: [String]) async throws -> [MarketQuote] {
            codes.filter { $0 == "600519" }.map { MarketQuote(code: $0, price: 1435.0, source: "partial") }
        }
    }

    private struct StubQuoteProvider: MarketQuoteProviding {
        let name = "stub"
        func quotes(codes: [String]) async throws -> [MarketQuote] {
            codes.map { MarketQuote(code: $0, price: 1.0, source: "stub") }
        }
    }

    private struct FailingKlineProvider: MarketKlineProviding {
        let name = "failing-k"
        func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
            throw MarketDataError.invalidResponse
        }
    }

    private struct StubKlineProvider: MarketKlineProviding {
        let name = "stub-k"
        func dailyBars(code: String, days: Int) async throws -> [MarketDailyBar] {
            [MarketDailyBar(date: "2026-08-28", open: 10, high: 11, low: 9.8, close: 10.5, volume: 100, amount: 1050, pctChg: 1.2)]
        }
    }

    private struct StubSnapshotProvider: MarketSnapshotProviding {
        let name = "stub-snap"
        func fullMarketSnapshot() async throws -> [MarketQuote] {
            (0..<120).map { index in
                MarketQuote(
                    code: String(format: "%06d", index),
                    price: index % 2 == 0 ? 11.0 : 9.0,
                    previousClose: 10.0,
                    board: .shMain
                )
            }
        }
    }

    func testQuotesFallsBackAndMergesMissingCodes() async {
        let engine = MarketDataEngine(
            breaker: MarketDataCircuitBreaker(failureThreshold: 3, cooldownSeconds: 300),
            cache: MarketDataCache(),
            quoteProviders: [FailingQuoteProvider(), PartialQuoteProvider(), StubQuoteProvider()]
        )
        let quotes = await engine.quotes(codes: ["600519", "000001", "300750"])
        XCTAssertEqual(quotes.count, 3, "partial 只覆盖 600519，其余由 stub 补齐")
        XCTAssertEqual(Set(quotes.map(\.code)), Set(["600519", "000001", "300750"]))
        let maotai = quotes.first { $0.code == "600519" }
        XCTAssertEqual(maotai?.source, "partial", "前面的源结果优先，不被后面覆盖")
    }

    func testQuotesCachesResult() async {
        final class CountingProvider: MarketQuoteProviding, @unchecked Sendable {
            let name = "counting"
            private(set) var calls = 0
            private let lock = NSLock()
            func quotes(codes: [String]) async throws -> [MarketQuote] {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return codes.map { MarketQuote(code: $0, price: 2.0) }
            }
        }
        let provider = CountingProvider()
        let engine = MarketDataEngine(cache: MarketDataCache(), quoteProviders: [provider])
        _ = await engine.quotes(codes: ["600519"])
        _ = await engine.quotes(codes: ["600519"])
        let second = await engine.quotes(codes: ["600519"])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(provider.calls, 1, "第二次命中缓存不再发请求")
    }

    func testDailyBarsFallsBackAndThrowsAggregated() async throws {
        let engine = MarketDataEngine(
            cache: MarketDataCache(),
            klineProviders: [FailingKlineProvider(), StubKlineProvider()]
        )
        let bars = try await engine.dailyBars(code: "600519", days: 30)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].close, 10.5)

        let allFail = MarketDataEngine(cache: MarketDataCache(), klineProviders: [FailingKlineProvider()])
        do {
            _ = try await allFail.dailyBars(code: "600519", days: 30)
            XCTFail("应抛聚合错误")
        } catch let error as MarketDataError {
            guard case .allSourcesFailed(let details) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(details.count, 1)
            XCTAssertTrue(details[0].contains("failing-k"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testMarketBreadthComputesFromSnapshot() async throws {
        let engine = MarketDataEngine(
            cache: MarketDataCache(),
            snapshotProviders: [StubSnapshotProvider()]
        )
        let stats = try await engine.marketBreadth()
        XCTAssertEqual(stats.sampleCount, 120)
        XCTAssertEqual(stats.upCount, 60)
        XCTAssertEqual(stats.downCount, 60)
        XCTAssertTrue(stats.dataBoundary.contains("stub-snap"))
        // 缓存生效：再次读取相同结果
        let again = try await engine.marketBreadth()
        XCTAssertEqual(again.sampleCount, 120)
    }

    func testMarketBreadthSkipsCircuitOpenSource() async throws {
        let breaker = MarketDataCircuitBreaker(failureThreshold: 1, cooldownSeconds: 300)
        // 先把 eastmoney:snapshot 熔断（不在 provider 链中，直接对 key 记失败）
        await breaker.recordFailure("stub-snap:snapshot")
        let engine = MarketDataEngine(
            breaker: breaker,
            cache: MarketDataCache(),
            snapshotProviders: [StubSnapshotProvider()]
        )
        do {
            _ = try await engine.marketBreadth()
            XCTFail("唯一快照源熔断时应抛错")
        } catch let error as MarketDataError {
            guard case .allSourcesFailed = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
