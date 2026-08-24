import XCTest
@testable import QiemanDashboard

/// SYNC-7 单元测试：Provider 降级链（primary → secondary → local 兜底）。
///
/// 覆盖：成功直取 / primary 失败降级 secondary / 全失败 allFailed（不抛错，
/// 本地读取面不受影响）/ isCallable 前置闸门（零网络跳过）/ quota 耗尽换家 /
/// ProviderHealth 上报（成功、失败、quota +1）/ 诊断摘要。
final class ProviderFallbackChainTests: XCTestCase {

    private func cst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 成功与降级

    func testPrimarySucceedsDirectly() async {
        let primary = StubChainAdapter(providerID: .stooq, records: [Self.barRecord()])
        let secondary = StubChainAdapter(providerID: .alphaVantage, records: [Self.barRecord()])
        let chain = ProviderFallbackChain(adapters: [primary, secondary])

        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .succeeded(s) = outcome else {
            return XCTFail("期望 succeeded")
        }
        XCTAssertEqual(s.usedRole, .primary)
        XCTAssertEqual(s.providerID, .stooq)
        XCTAssertEqual(s.records.count, 1)
        XCTAssertEqual(s.attempts.count, 1, "primary 成功不触达 secondary")
        XCTAssertEqual(primary.fetchCount, 1)
        XCTAssertEqual(secondary.fetchCount, 0)
    }

    func testPrimaryFailsDegradesToSecondary() async {
        let primary = StubChainAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.unavailable(providerID: .stooq, underlying: "anti-bot challenge")
        )
        let secondary = StubChainAdapter(providerID: .alphaVantage, records: [Self.barRecord()])
        let chain = ProviderFallbackChain(adapters: [primary, secondary])

        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .succeeded(s) = outcome else {
            return XCTFail("期望 succeeded（降级）")
        }
        XCTAssertEqual(s.usedRole, .secondary)
        XCTAssertEqual(s.providerID, .alphaVantage)
        XCTAssertEqual(s.attempts.count, 2)
        XCTAssertEqual(s.attempts[0].result, .failed)
        XCTAssertTrue(
            s.attempts[0].failureReason?.contains("unavailable") ?? false,
            "anti-bot 失败：\(String(describing: s.attempts[0].failureReason))"
        )
        XCTAssertEqual(s.attempts[1].result, .succeeded)
        XCTAssertEqual(primary.fetchCount, 1)
        XCTAssertEqual(secondary.fetchCount, 1)
        XCTAssertEqual(
            outcome.localFallbackSummary,
            "provider=alpha-vantage role=secondary records=1"
        )
    }

    func testAllFailIsNonFatalAndReportsLocalFallback() async {
        let primary = StubChainAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.rateLimited(providerID: .stooq, retryAfter: nil)
        )
        let secondary = StubChainAdapter(
            providerID: .alphaVantage, records: [],
            error: ProviderError.quotaExhausted(providerID: .alphaVantage)
        )
        let chain = ProviderFallbackChain(adapters: [primary, secondary])

        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .allFailed(attempts) = outcome else {
            return XCTFail("期望 allFailed")
        }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.map(\.result), [.failed, .failed])
        XCTAssertTrue(outcome.records.isEmpty)
        // 降级语义的可观测出口：明示「本地兜底」
        XCTAssertTrue(outcome.localFallbackSummary.contains("local canonical only"))
        XCTAssertTrue(outcome.localFallbackSummary.contains("stooq"))
        XCTAssertTrue(outcome.localFallbackSummary.contains("alpha-vantage"),
                      "rawValue 带连字符：\(outcome.localFallbackSummary)")
    }

    // MARK: - isCallable 前置闸门

    func testNotCallableCandidateSkippedWithoutNetwork() async {
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 19) })
        await monitor.register(.stooq, reliabilityClass: .communityAggregated)
        await monitor.register(.alphaVantage, reliabilityClass: .documentFreeAPI)
        // 连续失败 ≥5 → unavailable
        for _ in 0..<5 {
            await monitor.recordFailure(.stooq, error: .unavailable(providerID: .stooq, underlying: "test"))
        }
        let primary = StubChainAdapter(providerID: .stooq, records: [Self.barRecord()])
        let secondary = StubChainAdapter(providerID: .alphaVantage, records: [Self.barRecord()])
        let chain = ProviderFallbackChain(adapters: [primary, secondary], healthMonitor: monitor)

        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .succeeded(s) = outcome else {
            return XCTFail("期望 succeeded（primary 被跳过，secondary 接手）")
        }
        XCTAssertEqual(s.usedRole, .secondary)
        XCTAssertEqual(primary.fetchCount, 0, "不可调用候选零网络")
        XCTAssertEqual(s.attempts[0].result, .skippedNotCallable)
    }

    func testQuotaExhaustedMarksProviderAndFallsThrough() async {
        // quota 声明的 provider：额度用尽 → isCallable false → 跳过（零网络）
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 19) })
        await monitor.register(.stooq, reliabilityClass: .communityAggregated)
        await monitor.register(
            .alphaVantage, reliabilityClass: .documentFreeAPI,
            quota: .init(period: .daily, total: 25)
        )
        await monitor.recordQuota(.alphaVantage, used: 25)

        let primary = StubChainAdapter(providerID: .stooq, records: [])
        let secondary = StubChainAdapter(providerID: .alphaVantage, records: [Self.barRecord()])
        let chain = ProviderFallbackChain(adapters: [primary, secondary], healthMonitor: monitor)

        // primary 正常成功，secondary 根本轮不到
        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case .succeeded(let s) = outcome else { return XCTFail("期望 succeeded") }
        XCTAssertEqual(s.providerID, .stooq)

        // primary 失败时：secondary 额度尽被跳过 → allFailed
        let failingPrimary = StubChainAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.unavailable(providerID: .stooq, underlying: "down")
        )
        let chain2 = ProviderFallbackChain(adapters: [failingPrimary, secondary], healthMonitor: monitor)
        let outcome2 = await chain2.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .allFailed(attempts) = outcome2 else { return XCTFail("期望 allFailed") }
        XCTAssertEqual(attempts.map(\.result), [.failed, .skippedNotCallable])
        XCTAssertEqual(secondary.fetchCount, 0, "额度尽零网络")
    }

    // MARK: - ProviderHealth 上报

    func testHealthReportingOnSuccessAndFailure() async {
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 19) })
        await monitor.register(.stooq, reliabilityClass: .communityAggregated)
        await monitor.register(.alphaVantage, reliabilityClass: .documentFreeAPI)

        let primary = StubChainAdapter(
            providerID: .stooq, records: [],
            error: ProviderError.rateLimited(providerID: .stooq, retryAfter: 60)
        )
        let secondary = StubChainAdapter(providerID: .alphaVantage, records: [Self.barRecord()])
        let chain = ProviderFallbackChain(adapters: [primary, secondary], healthMonitor: monitor)

        _ = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )

        // 限流的 primary 进入冷却（degraded），成功的 secondary healthy
        let stooq = await monitor.health(for: .stooq)
        XCTAssertEqual(stooq?.status, .degraded)
        let av = await monitor.health(for: .alphaVantage)
        XCTAssertEqual(av?.status, .healthy)
    }

    func testLocalReadsUnaffectedWhenAllProvidersFail() async throws {
        // 「local 兜底」的结构性验证：allFailed 后读取面照常服务。
        // 先入库一根 bar，再让链全失败——查询仍返回已入库数据。
        let repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled
        )
        try seedBarIdentity(repository: repository)
        let pipeline = CanonicalPipeline(
            repository: repository, calendar: HolidayTableTradingCalendar.bundled
        )
        let commit = pipeline.commit(records: [Self.cnBarRecord()])
        XCTAssertNil(commit.commitError)
        XCTAssertEqual(commit.committedCount, 1)

        let primary = StubChainAdapter(
            providerID: .stooq, records: [Self.cnBarRecord()],
            error: ProviderError.unavailable(providerID: .stooq, underlying: "down")
        )
        let chain = ProviderFallbackChain(adapters: [primary])
        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "600519"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case .allFailed = outcome else { return XCTFail("期望 allFailed") }

        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(bars.count, 1, "sync 全失败不影响本地读取（local 兜底）")
    }

    func testEmptyChainFallsStraightToLocal() async {
        // 空链 = 无远程候选：不崩溃、不抓取，直接 allFailed → local 兜底
        let chain = ProviderFallbackChain(adapters: [])
        let outcome = await chain.fetch(
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            from: cst(2026, 8, 1), to: cst(2026, 8, 19)
        )
        guard case let .allFailed(attempts) = outcome else {
            return XCTFail("期望 allFailed")
        }
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(outcome.localFallbackSummary.contains("local canonical only"))
    }

    // MARK: - 测试基础设施

    private final class StubChainAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID
        let reliabilityClass: ProviderReliabilityClass

        private let records: [ProviderRecord]
        private let error: Error?
        private let lock = NSLock()
        private(set) var fetchCount = 0

        init(providerID: DataProviderID, records: [ProviderRecord], error: Error? = nil) {
            self.providerID = providerID
            self.reliabilityClass = .communityAggregated
            self.records = records
            self.error = error
        }

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            lock.lock()
            fetchCount += 1
            lock.unlock()
            if let error {
                throw error
            }
            let inWindow = records.filter { $0.providerCode == code }
            return ProviderFetchResult(
                records: inWindow,
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }
    }

    private static func barRecord() -> ProviderRecord {
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
            providerCode: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            effectiveAt: Date(timeIntervalSince1970: 1_700_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ingestedAt: Date(timeIntervalSince1970: 1_700_086_400),
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .unitedStates
        )
    }

    /// A 股 bar（identity seed：stooq stock_symbol 600519 → lst_600519，CNY）。
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
            providerID: .stooq,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: Date(timeIntervalSince1970: 1_700_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ingestedAt: Date(timeIntervalSince1970: 1_700_086_400),
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private func seedBarIdentity(repository: GRDBRepository) throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_a"), displayName: "A Corp",
            jurisdiction: .chinaMainland, kind: .listedCompany
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_a"),
            kind: .stock, displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_600519"), instrumentID: InstrumentID(rawValue: "inst_600519"),
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .stooq, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))
    }
}
