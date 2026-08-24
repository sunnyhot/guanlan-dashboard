import XCTest
@testable import QiemanDashboard

/// SYNC-6a 单元测试：持仓 universe 历史回填（≥252 交易日）+ 覆盖率验证。
final class HistoricalBackfillTests: XCTestCase {

    private var repository: GRDBRepository!
    private var pipeline: CanonicalPipeline!
    private var dataDirectory: URL!
    private var spoolURL: URL!

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
            .appendingPathComponent("backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "backfill", in: dataDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func cst(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func est(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - NAV 回填

    func testNAVBackfillReachesSufficientCoverage() async throws {
        // asOf = 周三 2026-08-19 20:00 CST → NAV 锚点 = 周二 08-18
        // 期望窗口 = 锚点往回 252 个交易日（跨 2026 春节等休市）
        let expectedDays = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: cst(2026, 8, 18), count: 252, jurisdiction: .chinaMainland
        )
        XCTAssertEqual(expectedDays.count, 252)
        // 窗口应跨春节（2026-02 休市前后都在窗口内）
        XCTAssertTrue(expectedDays.contains { $0 < cst(2026, 2, 16) })

        let stub = StubBackfillNAVAdapter(days: expectedDays)
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 252, now: { self.cst(2026, 8, 19, hour: 20) }
        )
        let result = await backfill.backfill(
            navFunds: [NAVBackfillTarget(
                code: ProviderCode(scheme: "fund_code", value: "110022"),
                shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
                adapter: stub
            )],
            barTargets: [], spoolURL: spoolURL
        )

        guard case let .committed(count) = result.navOutcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.navOutcomes))")
        }
        XCTAssertEqual(count, 252)
        let coverage = try XCTUnwrap(result.coverage["nav|110022"])
        XCTAssertEqual(coverage.covered, 252)
        XCTAssertTrue(coverage.isSufficient, coverage.summary)
        XCTAssertTrue(result.allSufficient)
        XCTAssertEqual(stub.lastWindowFrom, expectedDays.first, "窗口起点 = 252 个交易日的首日")
    }

    func testNAVBackfillInsufficientCoverageReportsGaps() async throws {
        // Provider 只给 100 天 → 覆盖不足，缺口如实报告
        let expectedDays = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: cst(2026, 8, 18), count: 252, jurisdiction: .chinaMainland
        )
        let partial = Array(expectedDays.suffix(100))
        let stub = StubBackfillNAVAdapter(days: partial)
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 252, now: { self.cst(2026, 8, 19, hour: 20) }
        )
        let result = await backfill.backfill(
            navFunds: [NAVBackfillTarget(
                code: ProviderCode(scheme: "fund_code", value: "110022"),
                shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
                adapter: stub
            )],
            barTargets: [], spoolURL: spoolURL
        )
        let coverage = try XCTUnwrap(result.coverage["nav|110022"])
        XCTAssertEqual(coverage.covered, 100)
        XCTAssertFalse(coverage.isSufficient)
        XCTAssertFalse(result.allSufficient)
        XCTAssertEqual(coverage.required, 252)
        // 缺口样本：最早的 5 个缺失日（期望窗口头部）
        let gaps = coverage.recentGaps
        XCTAssertEqual(gaps.count, 5)
        XCTAssertTrue(gaps.allSatisfy { $0 < partial.first! }, "缺口在窗口头部（未覆盖段）")
    }

    func testBackfillIsIdempotentOnRerun() async throws {
        let expectedDays = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: cst(2026, 8, 18), count: 252, jurisdiction: .chinaMainland
        )
        let stub = StubBackfillNAVAdapter(days: expectedDays)
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 252, now: { self.cst(2026, 8, 19, hour: 20) }
        )
        let fund = NAVBackfillTarget(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            adapter: stub
        )
        _ = await backfill.backfill(navFunds: [fund], barTargets: [], spoolURL: spoolURL)
        let second = await backfill.backfill(navFunds: [fund], barTargets: [], spoolURL: spoolURL)
        guard case let .committed(count) = second.navOutcomes["110022"] else {
            return XCTFail("期望 committed（幂等重放合法）")
        }
        XCTAssertEqual(count, 252, "重放仍计 committed")
        let navs = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(navs.count, 252, "重跑不翻倍")
        XCTAssertTrue(second.coverage["nav|110022"]!.isSufficient)
    }

    // MARK: - 行情回填（降级链）

    func testBarBackfillViaChainWithSufficientCoverage() async throws {
        // asOf = 美股周三 2026-08-19 20:00 ET → 行情锚点 = 周二 08-18
        let expectedDays = HolidayTableTradingCalendar.bundled.tradingDays(
            endingAt: est(2026, 8, 18), count: 252, jurisdiction: .unitedStates
        )
        let stub = StubBackfillBarAdapter(days: expectedDays)
        let chain = ProviderFallbackChain(adapters: [stub])
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 252, now: { self.est(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        let result = await backfill.backfill(
            navFunds: [],
            barTargets: [BarBackfillTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates,
                listingID: ListingID(rawValue: "lst_aapl"),
                chain: chain
            )],
            spoolURL: spoolURL
        )
        guard case let .committed(count) = result.barOutcomes["AAPL"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.barOutcomes))")
        }
        XCTAssertEqual(count, 252)
        let coverage = try XCTUnwrap(result.coverage["bar|AAPL"])
        XCTAssertTrue(coverage.isSufficient, coverage.summary)
        // 期望窗口跨 2026 美股节假日（耶稣受难日 04-03、独立日补休 07-03 都被跳过）
        XCTAssertTrue(expectedDays.allSatisfy { !Set(["2026-04-03", "2026-07-03"]).contains(dayKey($0, tz: "America/New_York")) })
    }

    func testBarBackfillAllFailedReportsInsufficient() async throws {
        let failing = StubBackfillBarAdapter(
            days: [],
            error: ProviderError.quotaExhausted(providerID: .stooq)
        )
        let chain = ProviderFallbackChain(adapters: [failing])
        let backfill = HistoricalBackfill(
            pipeline: pipeline, repository: repository,
            requiredTradingDays: 252, now: { self.est(2026, 8, 19).addingTimeInterval(20 * 3600) }
        )
        let result = await backfill.backfill(
            navFunds: [],
            barTargets: [BarBackfillTarget(
                code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                jurisdiction: .unitedStates,
                listingID: ListingID(rawValue: "lst_aapl"),
                chain: chain
            )],
            spoolURL: spoolURL
        )
        guard case let .failed(summary) = result.barOutcomes["AAPL"] else {
            return XCTFail("期望 failed")
        }
        XCTAssertTrue(summary.contains("local canonical only"))
        let coverage = try XCTUnwrap(result.coverage["bar|AAPL"])
        XCTAssertEqual(coverage.covered, 0)
        XCTAssertFalse(coverage.isSufficient)
        XCTAssertFalse(result.allSufficient)
    }

    // MARK: - 测试基础设施

    private func dayKey(_ date: Date, tz: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private final class StubBackfillNAVAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .eastmoney
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let records: [ProviderRecord]
        private let lock = NSLock()
        private(set) var lastWindowFrom: Date?

        init(days: [Date]) {
            records = days.map { day in
                ProviderRecord(
                    providerID: .eastmoney,
                    providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
                    effectiveAt: day,
                    publishedAt: day.addingTimeInterval(22 * 3600),
                    ingestedAt: day.addingTimeInterval(26 * 3600),
                    kind: .navObservation,
                    rawPayload: {
                        let payload = NAVPayload(
                            unitNAV: Price(value: Decimal(string: "2.8315")!, currency: .cny),
                            accumulatedNAV: nil,
                            cumulativeDividendPerShare: nil
                        )
                        return try! JSONEncoder().encode(payload)
                    }(),
                    reliabilityClass: .communityAggregated,
                    jurisdiction: .chinaMainland
                )
            }
        }

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            lock.lock()
            lastWindowFrom = from
            lock.unlock()
            return ProviderFetchResult(
                records: records.filter { $0.effectiveAt >= from && $0.effectiveAt <= to },
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }
    }

    private final class StubBackfillBarAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .stooq
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let records: [ProviderRecord]
        private let error: Error?

        init(days: [Date], error: Error? = nil) {
            self.error = error
            records = days.map { day in
                ProviderRecord(
                    providerID: .stooq,
                    providerCode: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
                    effectiveAt: day,
                    publishedAt: day,
                    ingestedAt: day.addingTimeInterval(86_400),
                    kind: .dailyBar,
                    rawPayload: {
                        let payload = DailyBarPayload(
                            rawOpen: Price(value: Decimal(string: "200")!, currency: .usd),
                            rawHigh: Price(value: Decimal(string: "202")!, currency: .usd),
                            rawLow: Price(value: Decimal(string: "199")!, currency: .usd),
                            rawClose: Price(value: Decimal(string: "201")!, currency: .usd),
                            volume: 5_000,
                            adjustmentFactor: Decimal(1),
                            fxRate: nil
                        )
                        return try! JSONEncoder().encode(payload)
                    }(),
                    reliabilityClass: .communityAggregated,
                    jurisdiction: .unitedStates
                )
            }
        }

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            if let error { throw error }
            return ProviderFetchResult(
                records: records.filter { $0.effectiveAt >= from && $0.effectiveAt <= to },
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }
    }

    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_x"), displayName: "某基金管理有限公司",
            jurisdiction: .chinaMainland, kind: .fundManager
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_110022"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .fund, displayName: "易方达消费行业股票", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(FundProduct(
            id: FundProductID(rawValue: "fp_110022"), instrumentID: InstrumentID(rawValue: "inst_110022"),
            fundType: .openEnd, displayName: "易方达消费行业股票（产品）"
        ))
        try repository.upsert(FundShareClass(
            id: FundShareClassID(rawValue: "fsc_110022_A"), productID: FundProductID(rawValue: "fp_110022"),
            instrumentID: InstrumentID(rawValue: "inst_110022"), shareClassCode: "A", displayName: "A",
            feeStructure: .init(frontEndLoad: nil, backEndLoad: nil,
                                annualSalesFee: nil, managementFee: nil, custodyFee: nil)
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_code",
            identifierValue: "110022", canonical: .fundShareClass(FundShareClassID(rawValue: "fsc_110022_A")),
            resolutionMethod: .manualVerified, resolvedAt: cst(2026, 1, 1)
        ))

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
    }
}
