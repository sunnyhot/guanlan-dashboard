import XCTest
@testable import QiemanDashboard

/// SYNC-2 单元测试：MarketDailySync 收盘后增量引擎。
///
/// 覆盖：直接抓取通道（降级链消费 / 法域感知锚点 / 游标保守）+
/// 远程 staging 提交通道（A 股记录经 remote spool 进 canonical，幂等）。
final class MarketDailySyncTests: XCTestCase {

    private var repository: GRDBRepository!
    private var pipeline: CanonicalPipeline!
    private var dataDirectory: URL!
    private var spoolURL: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled
        )
        try seedIdentity()
        pipeline = CanonicalPipeline(
            repository: repository, calendar: HolidayTableTradingCalendar.bundled
        )
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("market-daily-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "market-daily", in: dataDirectory)
        stateURL = DirectSyncPaths.stateURL(name: "market-daily", in: dataDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func cst(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func est(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - 直接抓取通道

    func testFreshSyncViaPrimaryCommitsAndAdvances() async throws {
        // asOf = 美股周三 2026-08-19 20:00 ET → 锚点 = 周二 08-18（T+1 语义）
        let primary = StubBarAdapter(providerID: .stooq, records: [
            Self.usBarRecord(day: est(2026, 8, 17)),
            Self.usBarRecord(day: est(2026, 8, 18)),
        ])
        let chain = ProviderFallbackChain(adapters: [primary])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })

        let result = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: chain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )

        guard case let .committed(count, newCursor, usedRole) = result.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newCursor, est(2026, 8, 18))
        XCTAssertEqual(usedRole, .primary)
        XCTAssertNil(result.remoteSpoolCommit)

        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_aapl"),
            context: .economicKnowledge(asOf: est(2026, 8, 25))
        )
        XCTAssertEqual(bars.count, 2)
    }

    func testSecondaryUsedWhenPrimaryFails() async throws {
        let primary = StubBarAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.unavailable(providerID: .stooq, underlying: "anti-bot")
        )
        let secondary = StubBarAdapter(providerID: .alphaVantage, records: [
            Self.usBarRecord(day: est(2026, 8, 18), providerID: .alphaVantage),
        ])
        let chain = ProviderFallbackChain(adapters: [primary, secondary])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })

        let result = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: chain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        guard case let .committed(_, _, usedRole) = result.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 committed（降级 secondary）")
        }
        XCTAssertEqual(usedRole, .secondary)
    }

    func testAnchorSkipsUSHoliday() async throws {
        // asOf = 感恩节后周五 2026-11-27 20:00：最近交易日 11-27（周五），
        // 锚点 = 11-25（周三，感恩节 11-26 休市）
        let primary = StubBarAdapter(providerID: .stooq, records: [])
        let chain = ProviderFallbackChain(adapters: [primary])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 11, 27, hour: 20) })
        _ = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: chain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        XCTAssertEqual(primary.lastWindowThrough, est(2026, 11, 25), "锚点跨过感恩节休市")
    }

    func testAllProvidersFailedIsLocalOnlyAndCursorHeld() async throws {
        let primary = StubBarAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.quotaExhausted(providerID: .stooq)
        )
        let chain = ProviderFallbackChain(adapters: [primary])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })

        let result = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: chain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        guard case let .allProvidersFailed(summary) = result.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 allProvidersFailed")
        }
        XCTAssertTrue(summary.contains("local canonical only"))
        let state = try SyncStateStore<MarketDailySyncState>().load(from: stateURL)
        XCTAssertNil(state?.lastIngestedEffectiveDates["stock_symbol|AAPL"], "游标不动")
    }

    func testUpToDateAndIncrementalWindow() async throws {
        let primary = StubBarAdapter(providerID: .stooq, records: [
            Self.usBarRecord(day: est(2026, 8, 18)),
        ])
        let chain = ProviderFallbackChain(adapters: [primary])
        let target = MarketDailyTarget(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            jurisdiction: .unitedStates, chain: chain
        )
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })
        _ = try await sync.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil)
        XCTAssertEqual(primary.fetchCount, 1)

        // 同 asOf 二轮：upToDate 零抓取
        let second = try await sync.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil)
        XCTAssertEqual(second.outcomes["stock_symbol|AAPL"], .upToDate)
        XCTAssertEqual(primary.fetchCount, 1)

        // asOf 前进两日（周五 20:00）：锚点 08-19，窗口从 08-19 起
        let laterPrimary = StubBarAdapter(providerID: .stooq, records: [
            Self.usBarRecord(day: est(2026, 8, 18)),   // 窗口外
            Self.usBarRecord(day: est(2026, 8, 19)),
        ])
        let laterChain = ProviderFallbackChain(adapters: [laterPrimary])
        let laterTarget = MarketDailyTarget(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            jurisdiction: .unitedStates, chain: laterChain
        )
        let later = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 21, hour: 20) })
        let third = try await later.syncOnce(
            targets: [laterTarget], spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        XCTAssertEqual(laterPrimary.lastWindowFrom, est(2026, 8, 19))
        guard case let .committed(count, newCursor, _) = third.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 committed")
        }
        XCTAssertEqual(count, 1, "窗口外旧 bar 不重复入库")
        XCTAssertEqual(newCursor, est(2026, 8, 19))
        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_aapl"),
            context: .economicKnowledge(asOf: est(2026, 8, 25))
        )
        XCTAssertEqual(bars.count, 2)
    }

    func testIncompleteDiagnosticsHoldCursor() async throws {
        // P1 修复回归 a：混合结构非法——合法行入库、游标不动
        var bad = Self.usBarRecord(day: est(2026, 8, 18))
        bad = ProviderRecord(
            providerID: bad.providerID, providerCode: bad.providerCode,
            effectiveAt: bad.effectiveAt, publishedAt: bad.publishedAt, ingestedAt: bad.ingestedAt,
            kind: .dailyBar,
            rawPayload: Data(#"{"warp":true}"#.utf8),
            reliabilityClass: bad.reliabilityClass, jurisdiction: bad.jurisdiction
        )
        let primary = StubBarAdapter(providerID: .stooq, records: [
            Self.usBarRecord(day: est(2026, 8, 17)),
            bad,
        ])
        let chain = ProviderFallbackChain(adapters: [primary])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: chain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        guard case let .rejectedCursorHeld(committed, rejectionCount, _) = result.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 rejectedCursorHeld，实际 \(String(describing: result.outcomes))")
        }
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(rejectionCount, 1)
        let state = try SyncStateStore<MarketDailySyncState>().load(from: stateURL)
        XCTAssertNil(state?.lastIngestedEffectiveDates["stock_symbol|AAPL"], "混合 invalid 游标不推进")

        // P1 修复回归 b：上游丢行诊断（降级链透传）——记录全合法也不推进
        let droppedPrimary = StubBarAdapter(
            providerID: .stooq,
            records: [Self.usBarRecord(day: est(2026, 8, 17)), Self.usBarRecord(day: est(2026, 8, 18))],
            droppedMalformed: 1
        )
        let droppedChain = ProviderFallbackChain(adapters: [droppedPrimary])
        let result2 = try await sync.syncOnce(
            targets: [MarketDailyTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates, chain: droppedChain
            )],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
        )
        guard case let .rejectedCursorHeld(committed2, rejectionCount2, dropped2) = result2.outcomes["stock_symbol|AAPL"] else {
            return XCTFail("期望 rejectedCursorHeld（上游丢行）")
        }
        XCTAssertEqual(committed2, 2, "合法行照常入库（幂等）")
        XCTAssertEqual(rejectionCount2, 0)
        XCTAssertEqual(dropped2, 1)
        let state2 = try SyncStateStore<MarketDailySyncState>().load(from: stateURL)
        XCTAssertNil(state2?.lastIngestedEffectiveDates["stock_symbol|AAPL"], "上游丢行游标不推进")
    }

    func testMergeDropAndUnsupportedDiagnosticsHoldCursor() async throws {
        // 二轮 P1 修复回归：merge 丢行 / unsupported 诊断 → 游标不动
        for scenario in ["merge", "unsupported"] {
            try? FileManager.default.removeItem(at: stateURL)
            let stub = StubBarAdapter(
                providerID: .stooq,
                records: [Self.usBarRecord(day: est(2026, 8, 18))],
                droppedOnMerge: scenario == "merge" ? 1 : 0,
                unsupportedDiagnostics: scenario == "unsupported"
            )
            let chain = ProviderFallbackChain(adapters: [stub])
            let sync = MarketDailySync(pipeline: pipeline, now: { self.est(2026, 8, 19, hour: 20) })
            let result = try await sync.syncOnce(
                targets: [MarketDailyTarget(
                    code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                    jurisdiction: .unitedStates, chain: chain
                )],
                spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: nil
            )
            guard case .rejectedCursorHeld = result.outcomes["stock_symbol|AAPL"] else {
                return XCTFail("[\(scenario)] 期望 rejectedCursorHeld，实际 \(String(describing: result.outcomes))")
            }
            let state = try SyncStateStore<MarketDailySyncState>().load(from: stateURL)
            XCTAssertNil(state?.lastIngestedEffectiveDates["stock_symbol|AAPL"],
                         "[\(scenario)] 游标不推进")
        }
    }

    // MARK: - 远程 staging 提交通道（A 股）

    func testRemoteSpoolCommitsIntoCanonical() async throws {
        // 预写一条 A 股 bar 进 remote spool（RemoteStagingSyncLoop 产出的形态）
        let remoteSpool = dataDirectory.appendingPathComponent("remote-spool.jsonl")
        try ProviderStagingWriter().write([Self.cnBarRecord()], to: remoteSpool)

        let chain = ProviderFallbackChain(adapters: [StubBarAdapter(providerID: .stooq, records: [])])
        let sync = MarketDailySync(pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            targets: [],
            spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: remoteSpool
        )
        let commit = try XCTUnwrap(result.remoteSpoolCommit)
        XCTAssertEqual(commit.committedCount, 1)
        XCTAssertNil(commit.commitError)

        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(bars.count, 1)

        // 幂等：再跑一轮同 spool，行数不翻倍
        let again = try await sync.syncOnce(
            targets: [], spoolURL: spoolURL, stateURL: stateURL, remoteSpoolURL: remoteSpool
        )
        XCTAssertEqual(again.remoteSpoolCommit?.committedCount, 1, "重放合法仍计 committed")
        let barsAfter = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(barsAfter.count, 1, "幂等不翻倍")
    }

    func testMissingRemoteSpoolSkipsGracefully() async throws {
        let sync = MarketDailySync(pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            targets: [],
            spoolURL: spoolURL, stateURL: stateURL,
            remoteSpoolURL: dataDirectory.appendingPathComponent("not-exist.jsonl")
        )
        XCTAssertNil(result.remoteSpoolCommit, "spool 不存在 = 远程通道未启用（正常形态）")
    }

    // MARK: - 测试基础设施

    private final class StubBarAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let records: [ProviderRecord]
        private let error: Error?
        private let droppedMalformed: Int
        private let droppedOnMerge: Int
        private let unsupportedDiagnostics: Bool
        private let lock = NSLock()
        private(set) var fetchCount = 0
        private(set) var lastWindowFrom: Date?
        private(set) var lastWindowThrough: Date?

        init(
            providerID: DataProviderID,
            records: [ProviderRecord],
            error: Error? = nil,
            droppedMalformed: Int = 0,
            droppedOnMerge: Int = 0,
            unsupportedDiagnostics: Bool = false
        ) {
            self.providerID = providerID
            self.records = records
            self.error = error
            self.droppedMalformed = droppedMalformed
            self.droppedOnMerge = droppedOnMerge
            self.unsupportedDiagnostics = unsupportedDiagnostics
        }

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            lock.lock()
            fetchCount += 1
            lastWindowFrom = from
            lastWindowThrough = to
            lock.unlock()
            if let error { throw error }
            let inWindow = records.filter {
                $0.providerCode == code && $0.effectiveAt >= from && $0.effectiveAt <= to
            }
            return ProviderFetchResult(
                records: inWindow,
                diagnostics: ProviderFetchDiagnostics(
                    completeness: unsupportedDiagnostics ? .unsupported : .complete,
                    droppedMalformedBySource: droppedMalformed > 0 ? ["stub": droppedMalformed] : [:],
                    droppedOnMerge: droppedOnMerge
                )
            )
        }
    }

    private static func usBarRecord(day: Date, providerID: DataProviderID = .stooq) -> ProviderRecord {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "200")!, currency: .usd),
            rawHigh: Price(value: Decimal(string: "202")!, currency: .usd),
            rawLow: Price(value: Decimal(string: "199")!, currency: .usd),
            rawClose: Price(value: Decimal(string: "201")!, currency: .usd),
            volume: 5_000,
            adjustmentFactor: Decimal(1),
            fxRate: nil
        )
        return ProviderRecord(
            providerID: providerID,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            effectiveAt: day,
            publishedAt: day,
            ingestedAt: day.addingTimeInterval(86_400),
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .unitedStates
        )
    }

    private static func cstDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private static func cnBarRecord() -> ProviderRecord {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "1500")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "1520")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "1490")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "1510")!, currency: .cny),
            volume: 9_000,
            adjustmentFactor: Decimal(1),
            fxRate: nil
        )
        return ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: Self.cstDay(2026, 8, 18),
            publishedAt: Self.cstDay(2026, 8, 18),
            ingestedAt: Self.cstDay(2026, 8, 19),
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_a"), displayName: "A Corp",
            jurisdiction: .unitedStates, kind: .listedCompany
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_aapl"), issuerID: LegalEntityID(rawValue: "le_a"),
            kind: .stock, displayName: "Apple Inc.", baseCurrency: .usd, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_aapl"), instrumentID: InstrumentID(rawValue: "inst_aapl"),
            exchange: .nasdaq, symbol: "AAPL", tradingCurrency: .usd
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .stooq, identifierScheme: "stock_symbol",
            identifierValue: "AAPL", canonical: .listing(ListingID(rawValue: "lst_aapl")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .alphaVantage, identifierScheme: "stock_symbol",
            identifierValue: "AAPL", canonical: .listing(ListingID(rawValue: "lst_aapl")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))

        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_b"), displayName: "B Corp",
            jurisdiction: .chinaMainland, kind: .listedCompany
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_b"),
            kind: .stock, displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_600519"), instrumentID: InstrumentID(rawValue: "inst_600519"),
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))
    }
}
