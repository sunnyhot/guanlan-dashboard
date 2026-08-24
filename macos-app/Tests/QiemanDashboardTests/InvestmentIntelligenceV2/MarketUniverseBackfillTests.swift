import XCTest
@testable import QiemanDashboard

/// SYNC-6b 单元测试：全市场 universe 分批回填（批预算 / 优先级序 /
/// 进度持久化 / 双通道 / 增量补全 / 额度尽留队列）。
final class MarketUniverseBackfillTests: XCTestCase {

    private var repository: GRDBRepository!
    private var pipeline: CanonicalPipeline!
    private var dataDirectory: URL!
    private var spoolURL: URL!
    private var stateURL: URL!
    private var stub: StubUniverseBarAdapter!

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
            .appendingPathComponent("universe-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "universe-backfill", in: dataDirectory)
        stateURL = DirectSyncPaths.stateURL(name: "universe-backfill", in: dataDirectory)
        stub = StubUniverseBarAdapter()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func est(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func cst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeEngine(
        requiredTradingDays: Int = 252, maxTargetsPerRound: Int = 3
    ) -> MarketUniverseBackfill {
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: requiredTradingDays,
            now: { self.est(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        stub.fullCoverageDays = requiredTradingDays
        return MarketUniverseBackfill(
            backfill: backfill,
            makeChain: { [stub] _ in ProviderFallbackChain(adapters: [stub]) },
            maxTargetsPerRound: maxTargetsPerRound,
            now: { self.est(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
    }

    // MARK: - 分批与优先级

    func testBatchingAcrossRoundsRespectsBudgetAndPriority() async throws {
        // 7 个直接抓取标的、预算 3 → 三轮 3+3+1，priority 小者先
        let universe = MarketUniverse(universeVersion: 1, entries: (0..<7).map { i in
            Self.entry(key: "us_\(i)", symbol: "S\(i)", priority: i, fetchDirectly: true)
        })
        let engine = makeEngine(maxTargetsPerRound: 3)

        let round1 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round1.batchKeys, ["us_0", "us_1", "us_2"])
        XCTAssertEqual(round1.totalCount, 7)
        XCTAssertEqual(round1.completedCount, 3, "足覆盖批次全部完成")
        XCTAssertEqual(round1.progressSummary, "universe backfill 3/7，本轮批次 3")

        let round2 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round2.batchKeys, ["us_3", "us_4", "us_5"])

        let round3 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round3.batchKeys, ["us_6"])
        XCTAssertEqual(round3.completedCount, 7)

        // 全部完成后：空批次（不重复消耗额度）
        let round4 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertTrue(round4.batchKeys.isEmpty)
        XCTAssertEqual(round4.completedCount, 7)
    }

    // MARK: - 额度尽留队列

    func testQuotaExhaustedEntriesStayInQueue() async throws {
        // 前两个标的额度尽（chain allFailed），第三个成功
        stub.failSymbols = ["S0", "S1"]
        let universe = MarketUniverse(universeVersion: 1, entries: [
            Self.entry(key: "us_0", symbol: "S0", priority: 0, fetchDirectly: true),
            Self.entry(key: "us_1", symbol: "S1", priority: 1, fetchDirectly: true),
            Self.entry(key: "us_2", symbol: "S2", priority: 2, fetchDirectly: true),
        ])
        let engine = makeEngine(maxTargetsPerRound: 3)
        let round1 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round1.newlyCompleted, ["us_2"])
        XCTAssertEqual(Set(round1.stillInsufficient), ["us_0", "us_1"], "失败标的留队列")
        XCTAssertEqual(round1.completedCount, 1)

        // 下轮：恢复的标的重试并完成
        stub.failSymbols = []
        let round2 = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round2.batchKeys, ["us_0", "us_1"])
        XCTAssertEqual(round2.completedCount, 3)
    }

    // MARK: - remote 通道（只验证覆盖）

    func testRemoteChannelEntriesVerifyCoverageOnly() async throws {
        // CN 标的不直接抓取；数据已在库（模拟 RemoteStagingSync 已提交）→ 覆盖达标
        let cnEntry = Self.entry(key: "cn_0", symbol: "600519", priority: 0, fetchDirectly: false,
                                 exchange: .sse, jurisdiction: .chinaMainland)
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 5,
            now: { self.cst(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        // 预置 5 天 A 股 bar
        let days = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: cst(2026, 8, 18), count: 5, jurisdiction: .chinaMainland
        )
        let commit = pipeline.commit(records: days.map { Self.cnBar(day: $0) })
        XCTAssertNil(commit.commitError)

        let engine = MarketUniverseBackfill(
            backfill: backfill,
            makeChain: { _ in
                XCTFail("remote 通道标的不应构造降级链调用（fetchDirectly=false 不抓取）")
                return ProviderFallbackChain(adapters: [])
            },
            maxTargetsPerRound: 3,
            now: { self.cst(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        let universe = MarketUniverse(universeVersion: 1, entries: [cnEntry])
        let round = try await engine.syncOnce(universe: universe, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round.batchKeys, ["cn_0"])
        XCTAssertEqual(round.newlyCompleted, ["cn_0"], "已有数据覆盖达标即完成（零抓取）")
        XCTAssertEqual(round.completedCount, 1)
    }

    func testRemoteChannelInsufficientStaysQueued() async throws {
        // 库里只有 2 天（< required 5）→ 留队列
        let cnEntry = Self.entry(key: "cn_0", symbol: "600519", priority: 0, fetchDirectly: false,
                                 exchange: .sse, jurisdiction: .chinaMainland)
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 5,
            now: { self.cst(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        let days = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: cst(2026, 8, 18), count: 2, jurisdiction: .chinaMainland
        )
        _ = pipeline.commit(records: days.map { Self.cnBar(day: $0) })

        let engine = MarketUniverseBackfill(
            backfill: backfill,
            makeChain: { _ in ProviderFallbackChain(adapters: []) },
            maxTargetsPerRound: 3,
            now: { self.cst(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        let round = try await engine.syncOnce(
            universe: MarketUniverse(universeVersion: 1, entries: [cnEntry]),
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(round.stillInsufficient, ["cn_0"], "覆盖不足留队列（等 remote 链路补数）")
    }

    // MARK: - universe 增量补全

    func testUniverseGrowthIncludesNewEntriesOnly() async throws {
        let universeV1 = MarketUniverse(universeVersion: 1, entries: [
            Self.entry(key: "us_0", symbol: "S0", priority: 0, fetchDirectly: true),
        ])
        let engine = makeEngine(maxTargetsPerRound: 5)
        _ = try await engine.syncOnce(universe: universeV1, spoolURL: spoolURL, stateURL: stateURL)

        // universe v2 新增两条：已完成的不重跑，新增的进批次
        let universeV2 = MarketUniverse(universeVersion: 2, entries: [
            Self.entry(key: "us_0", symbol: "S0", priority: 0, fetchDirectly: true),
            Self.entry(key: "us_1", symbol: "S1", priority: 1, fetchDirectly: true),
            Self.entry(key: "us_2", symbol: "S2", priority: 2, fetchDirectly: true),
        ])
        let round = try await engine.syncOnce(universe: universeV2, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(round.batchKeys, ["us_1", "us_2"], "增量补全：旧完成项跳过")
        XCTAssertEqual(round.completedCount, 3)

        // universe 收缩：陈旧完成项不计入进度
        let universeV3 = MarketUniverse(universeVersion: 3, entries: [
            Self.entry(key: "us_0", symbol: "S0", priority: 0, fetchDirectly: true),
        ])
        let shrunk = try await engine.syncOnce(universe: universeV3, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(shrunk.completedCount, 1)
        XCTAssertEqual(shrunk.totalCount, 1)
    }

    func testStateFailsClosedOnCorruption() async throws {
        try Data("garbage".utf8).write(to: stateURL)
        let engine = makeEngine()
        do {
            _ = try await engine.syncOnce(
                universe: MarketUniverse(universeVersion: 1, entries: [
                    Self.entry(key: "us_0", symbol: "S0", priority: 0, fetchDirectly: true),
                ]),
                spoolURL: spoolURL, stateURL: stateURL
            )
            XCTFail("坏状态应抛错")
        } catch let error as SyncStateError {
            guard case .corrupt = error else { return XCTFail("期望 corrupt：\(error)") }
        }
    }

    // MARK: - 测试基础设施

    private static func entry(
        key: String,
        symbol: String,
        priority: Int,
        fetchDirectly: Bool,
        exchange: Exchange = .nasdaq,
        jurisdiction: Jurisdiction = .unitedStates
    ) -> MarketUniverseEntry {
        MarketUniverseEntry(
            key: key,
            code: ProviderCode(scheme: "stock_symbol", value: symbol),
            jurisdiction: jurisdiction,
            listingID: ListingID(rawValue: "lst_\(symbol.lowercased())"),
            displayName: "Entry \(symbol)",
            priority: priority,
            fetchDirectly: fetchDirectly
        )
    }

    private final class StubUniverseBarAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .stooq
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let lock = NSLock()
        var fullCoverageDays = 252
        var failSymbols: Set<String> = []

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            lock.lock(); defer { lock.unlock() }
            if failSymbols.contains(code.value) {
                throw ProviderError.quotaExhausted(providerID: .stooq)
            }
            // 给满覆盖：窗口内每个美东日都产一根 bar（含非交易日——stub 语义足够：
            // HistoricalBackfill 的覆盖口径是期望交易日 ∩ 实际，非交易日行不计覆盖）
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            var records: [ProviderRecord] = []
            var day = from
            while day <= to {
                records.append(Self.usBar(symbol: code.value, day: day))
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            return ProviderFetchResult(
                records: records,
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }

        static func usBar(symbol: String, day: Date) -> ProviderRecord {
            let payload = DailyBarPayload(
                rawOpen: Price(value: Decimal(string: "100")!, currency: .usd),
                rawHigh: Price(value: Decimal(string: "101")!, currency: .usd),
                rawLow: Price(value: Decimal(string: "99")!, currency: .usd),
                rawClose: Price(value: Decimal(string: "100.5")!, currency: .usd),
                volume: 1_000,
                adjustmentFactor: Decimal(1),
                fxRate: nil
            )
            return ProviderRecord(
                providerID: .stooq,
                providerCode: ProviderCode(scheme: "stock_symbol", value: symbol),
                effectiveAt: day,
                publishedAt: day,
                ingestedAt: day.addingTimeInterval(86_400),
                kind: .dailyBar,
                rawPayload: try! JSONEncoder().encode(payload),
                reliabilityClass: .communityAggregated,
                jurisdiction: .unitedStates
            )
        }
    }

    private static func cnBar(day: Date) -> ProviderRecord {
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
            effectiveAt: day,
            publishedAt: day,
            ingestedAt: day.addingTimeInterval(86_400),
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_us"), displayName: "US Issuers",
            jurisdiction: .unitedStates, kind: .listedCompany
        ))
        // 美股 S0..S9 挂牌
        for i in 0..<10 {
            let symbol = "S\(i)"
            try repository.upsert(Instrument(
                id: InstrumentID(rawValue: "inst_\(symbol.lowercased())"),
                issuerID: LegalEntityID(rawValue: "le_us"),
                kind: .stock, displayName: "Entry \(symbol)",
                baseCurrency: .usd, assetClass: .equity
            ))
            try repository.upsert(Listing(
                id: ListingID(rawValue: "lst_\(symbol.lowercased())"),
                instrumentID: InstrumentID(rawValue: "inst_\(symbol.lowercased())"),
                exchange: .nasdaq, symbol: symbol, tradingCurrency: .usd
            ))
            try repository.upsert(ProviderIdentifier(
                providerID: .stooq, identifierScheme: "stock_symbol",
                identifierValue: symbol,
                canonical: .listing(ListingID(rawValue: "lst_\(symbol.lowercased())")),
                resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
            ))
        }
        // A 股 600519（remote 通道验证用）
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_cn"), displayName: "B Corp",
            jurisdiction: .chinaMainland, kind: .listedCompany
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_cn"),
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
