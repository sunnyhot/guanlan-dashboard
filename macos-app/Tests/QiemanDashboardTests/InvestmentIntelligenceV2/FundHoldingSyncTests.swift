import XCTest
@testable import QiemanDashboard

/// SYNC-4 单元测试：FundHoldingSync 披露检测引擎 + FundDisclosureSchedule
/// 披露时限保守计算。
final class FundHoldingSyncTests: XCTestCase {

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
            .appendingPathComponent("fund-holding-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "eastmoney-holding", in: dataDirectory)
        stateURL = DirectSyncPaths.stateURL(name: "fund-holding", in: dataDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func cst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - FundReportPeriod

    func testPeriodOrderingAndNavigation() {
        XCTAssertEqual(FundReportPeriod(year: 2026, quarter: 2).label, "2026Q2")
        XCTAssertTrue(FundReportPeriod(year: 2026, quarter: 1) < FundReportPeriod(year: 2026, quarter: 2))
        XCTAssertTrue(FundReportPeriod(year: 2026, quarter: 4) < FundReportPeriod(year: 2027, quarter: 1))
        XCTAssertEqual(FundReportPeriod(year: 2026, quarter: 4).next, FundReportPeriod(year: 2027, quarter: 1))
        XCTAssertEqual(FundReportPeriod(year: 2027, quarter: 1).previous, FundReportPeriod(year: 2026, quarter: 4))
        // periodEnd：Q1=03-31 / Q2=06-30 / Q3=09-30 / Q4=12-31
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(FundReportPeriod(year: 2026, quarter: 2).periodEnd(in: cal), cst(2026, 6, 30))
        XCTAssertEqual(FundReportPeriod(year: 2026, quarter: 4).periodEnd(in: cal), cst(2026, 12, 31))
    }

    func testPeriodCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FundReportPeriod(year: 2026, quarter: 2))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2026Q2\"")
        XCTAssertEqual(try JSONDecoder().decode(FundReportPeriod.self, from: data),
                       FundReportPeriod(year: 2026, quarter: 2))
        XCTAssertThrowsError(try JSONDecoder().decode(FundReportPeriod.self, from: Data("\"2026Q9\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FundReportPeriod.self, from: Data("\"garbage\"".utf8)))
    }

    // MARK: - FundDisclosureSchedule（保守披露时限）

    func testQuarterDeadlineIsQuarterEndPlus15TradingDays() {
        let schedule = FundDisclosureSchedule()
        // 2026Q2：06-30（周二）+15 交易日（跳过周末，7 月无法定节假日）= 07-21
        XCTAssertEqual(
            schedule.deadline(for: FundReportPeriod(year: 2026, quarter: 2)),
            cst(2026, 7, 21)
        )
        // 2026Q1：03-31 +15 交易日，跳过清明 04-06 与周末 = 04-22
        XCTAssertEqual(
            schedule.deadline(for: FundReportPeriod(year: 2026, quarter: 1)),
            cst(2026, 4, 22)
        )
        // 2026 春节在 Q1 内：03-31 已过节，+15 不跨春节——若从 02-13 起算才跨，
        // 这里验证季度报告时限不受季度内早期节假日影响
        XCTAssertEqual(
            schedule.deadline(for: FundReportPeriod(year: 2025, quarter: 1)),
            cst(2025, 4, 22)
        )
    }

    func testAnnualDeadlineIsThreeCalendarMonths() {
        let schedule = FundDisclosureSchedule()
        XCTAssertEqual(
            schedule.deadline(for: FundReportPeriod(year: 2025, quarter: 4)),
            cst(2026, 3, 31)
        )
    }

    func testLatestGuaranteedPublishedPeriod() {
        let schedule = FundDisclosureSchedule()
        // 2026-08-24：Q2 时限 07-21 已过 → 锚点 2026Q2
        XCTAssertEqual(
            schedule.latestGuaranteedPublishedPeriod(asOf: cst(2026, 8, 24)),
            FundReportPeriod(year: 2026, quarter: 2)
        )
        // 2026-07-20：Q2 时限（07-21）未到 → 锚点 2026Q1
        XCTAssertEqual(
            schedule.latestGuaranteedPublishedPeriod(asOf: cst(2026, 7, 20)),
            FundReportPeriod(year: 2026, quarter: 1)
        )
        // 2026Q2 时限当天（07-21）已到期 → 锚点 2026Q2
        XCTAssertEqual(
            schedule.latestGuaranteedPublishedPeriod(asOf: cst(2026, 7, 21)),
            FundReportPeriod(year: 2026, quarter: 2)
        )
    }

    // MARK: - 引擎

    func testFirstRoundBackfillsAndAdvancesCursor() async throws {
        let stub = StubHoldingAdapter()
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let funds = [ProviderCode(scheme: "fund_product_code", value: "110022")]

        let result = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        XCTAssertEqual(result.anchorPeriod, FundReportPeriod(year: 2026, quarter: 2))
        guard case let .committed(periodCount, recordCount, newCursor) = result.outcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes["110022"]))")
        }
        // 首轮回看 8 期窗口内共 7 个到期报告期（2024Q4..2026Q2）
        XCTAssertEqual(periodCount, 7)
        XCTAssertEqual(recordCount, 7)
        XCTAssertEqual(newCursor, FundReportPeriod(year: 2026, quarter: 2))

        // 状态持久化 + 库内 7 份快照 + spool 7 条
        let state = try SyncStateStore<FundHoldingSyncState>().load(from: stateURL)
        XCTAssertEqual(state?.lastIngestedPeriods["110022"], FundReportPeriod(year: 2026, quarter: 2))
        let snapshots = repository.holdingSnapshots(
            productID: FundProductID(rawValue: "fp_110022"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(snapshots.count, 7)
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 7)
    }

    func testSecondRoundUpToDateSkipsFetch() async throws {
        let stub = StubHoldingAdapter()
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let funds = [ProviderCode(scheme: "fund_product_code", value: "110022")]
        _ = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertGreaterThanOrEqual(stub.fetchCount, 7)

        let second = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(second.outcomes["110022"], .upToDate)
        XCTAssertEqual(stub.fetchCount, 7, "upToDate 不应再抓取")
    }

    func testNewQuarterDetectionCommitsOnlyMissingPeriod() async throws {
        // 预置游标 2026Q1；锚点 2026Q2 → 只补一期
        var state = FundHoldingSyncState()
        state.lastIngestedPeriods["110022"] = FundReportPeriod(year: 2026, quarter: 1)
        try SyncStateStore<FundHoldingSyncState>().save(state, to: stateURL)

        let stub = StubHoldingAdapter()
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_product_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .committed(periodCount, recordCount, newCursor) = result.outcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(periodCount, 1)
        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(newCursor, FundReportPeriod(year: 2026, quarter: 2))
        XCTAssertEqual(stub.fetchCount, 1, "只抓缺失的一期")

        let snapshots = repository.holdingSnapshots(
            productID: FundProductID(rawValue: "fp_110022"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(snapshots.count, 1)
    }

    func testAnnouncementNotFoundHoldsCursor() async throws {
        var state = FundHoldingSyncState()
        state.lastIngestedPeriods["110022"] = FundReportPeriod(year: 2026, quarter: 1)
        try SyncStateStore<FundHoldingSyncState>().save(state, to: stateURL)

        // 2026Q2 公告未出（时限是下界不是承诺）
        let stub = StubHoldingAdapter(missingPeriods: [FundReportPeriod(year: 2026, quarter: 2)])
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_product_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(
            result.outcomes["110022"],
            .notYetPublished(
                heldAt: FundReportPeriod(year: 2026, quarter: 1),
                nextCandidate: FundReportPeriod(year: 2026, quarter: 2)
            )
        )
        let after = try SyncStateStore<FundHoldingSyncState>().load(from: stateURL)
        XCTAssertEqual(after?.lastIngestedPeriods["110022"],
                       FundReportPeriod(year: 2026, quarter: 1), "游标不动")
    }

    func testPipelineRejectionHoldsCursor() async throws {
        var state = FundHoldingSyncState()
        state.lastIngestedPeriods["110022"] = FundReportPeriod(year: 2026, quarter: 1)
        try SyncStateStore<FundHoldingSyncState>().save(state, to: stateURL)

        // 持仓权重合计超界（0.6+0.6）会被 CanonicalDataValidator 拒收
        let stub = StubHoldingAdapter(
            customPayloadPeriods: [FundReportPeriod(year: 2026, quarter: 2)]
        )
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_product_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .rejectedCursorHeld(committedPeriods, rejectionCount) = result.outcomes["110022"] else {
            return XCTFail("期望 rejectedCursorHeld，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(committedPeriods, 0)
        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(result.rejections.first?.stage, .dataValidation)
        let after = try SyncStateStore<FundHoldingSyncState>().load(from: stateURL)
        XCTAssertEqual(after?.lastIngestedPeriods["110022"],
                       FundReportPeriod(year: 2026, quarter: 1), "有拒收游标不推进")
    }

    func testFailureIsolationAcrossFunds() async throws {
        let stub = StubHoldingAdapter(failureForFunds: ["000001"])
        let sync = makeSync(stub: stub, now: cst(2026, 8, 24))
        let result = try await sync.syncOnce(
            funds: [
                ProviderCode(scheme: "fund_product_code", value: "000001"),
                ProviderCode(scheme: "fund_product_code", value: "110022"),
            ],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case .failed = result.outcomes["000001"] else {
            return XCTFail("期望 failed，实际 \(String(describing: result.outcomes["000001"]))")
        }
        guard case .committed = result.outcomes["110022"] else {
            return XCTFail("单只失败不应影响他者")
        }
    }

    func testProviderNotCallableSkipsFetch() async throws {
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 24) })
        await monitor.register(.eastmoney, reliabilityClass: .communityAggregated)
        for _ in 0..<5 {
            await monitor.recordFailure(.eastmoney, error: .unavailable(providerID: .eastmoney, underlying: "test"))
        }
        let stub = StubHoldingAdapter()
        let sync = FundHoldingSync(
            makeAdapter: { _ in stub }, pipeline: pipeline, healthMonitor: monitor,
            now: { self.cst(2026, 8, 24) }
        )
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_product_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(result.outcomes["110022"], .providerNotCallable)
        XCTAssertEqual(stub.fetchCount, 0)
    }

    // MARK: - 测试基础设施

    private func makeSync(stub: StubHoldingAdapter, now: Date) -> FundHoldingSync {
        FundHoldingSync(
            makeAdapter: { _ in stub }, pipeline: pipeline,
            now: { now }
        )
    }

    /// 可控桩：默认所有期返回单持仓合法记录；可注入「公告未出」期 /
    /// 指定基金抓取失败 / 走坏 payload 的期。
    private final class StubHoldingAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .eastmoney
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let missingPeriods: Set<String>
        private let customPayloadPeriods: Set<String>
        private let failureForFunds: Set<String>
        private let lock = NSLock()
        private(set) var fetchCount = 0

        init(
            missingPeriods: Set<FundReportPeriod> = [],
            customPayloadPeriods: Set<FundReportPeriod> = [],
            failureForFunds: Set<String> = []
        ) {
            self.missingPeriods = Set(missingPeriods.map(\.label))
            self.customPayloadPeriods = Set(customPayloadPeriods.map(\.label))
            self.failureForFunds = failureForFunds
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
            if failureForFunds.contains(code.value) {
                throw ProviderError.unavailable(providerID: .eastmoney, underlying: "stub failure")
            }
            // from = 报告期截止日（引擎按期调用）
            let period = Self.period(of: from)
            if missingPeriods.contains(period.label) {
                throw EastmoneyHistoricalHoldingError.announcementNotFound(reportDate: from)
            }
            let bad = customPayloadPeriods.contains(period.label)
            return ProviderFetchResult(
                records: [Self.holdingRecord(
                    fund: code, reportDate: from,
                    weights: bad ? [Decimal(string: "0.6")!, Decimal(string: "0.6")!] : [Decimal(string: "0.0987")!]
                )],
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }

        /// 报告期截止日 → FundReportPeriod（Q1=03-31 / Q2=06-30 / Q3=09-30 / Q4=12-31）。
        static func period(of reportDate: Date) -> FundReportPeriod {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let c = cal.dateComponents([.year, .month, .day], from: reportDate)
            return FundReportPeriod(year: c.year!, quarter: (c.month! - 1) / 3 + 1)
        }

        static func holdingRecord(fund: ProviderCode, reportDate: Date, weights: [Decimal]) -> ProviderRecord {
            let positions = weights.map {
                FundHoldingPayload.Position(
                    providerID: .eastmoney,
                    providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                    weight: Ratio(value: $0),
                    shares: nil, marketValue: nil, isDisclosed: true
                )
            }
            let payload = FundHoldingPayload(
                reportPeriod: {
                    let p = period(of: reportDate)
                    switch p.quarter {
                    case 1: return .q1
                    case 2: return .q2
                    case 3: return .q3
                    default: return .q4
                    }
                }(),
                positions: positions,
                disclosedWeightTotal: Ratio(value: weights.reduce(Decimal.zero, +))
            )
            return ProviderRecord(
                providerID: .eastmoney,
                providerCode: fund,
                effectiveAt: reportDate,
                publishedAt: reportDate.addingTimeInterval(20 * 86_400),
                ingestedAt: reportDate.addingTimeInterval(21 * 86_400),
                kind: .fundHoldingSnapshot,
                rawPayload: try! JSONEncoder().encode(payload),
                reliabilityClass: .communityAggregated,
                jurisdiction: .chinaMainland
            )
        }
    }

    /// identity 底座：fund_product_code 110022 → fp_110022 + 持仓股票 600519
    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_x"), displayName: "某基金管理有限公司",
            jurisdiction: .chinaMainland, kind: .fundManager
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .stock, displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_600519"), instrumentID: InstrumentID(rawValue: "inst_600519"),
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
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
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_product_code",
            identifierValue: "110022", canonical: .fundProduct(FundProductID(rawValue: "fp_110022")),
            resolutionMethod: .manualVerified, resolvedAt: cst(2026, 1, 1)
        ))
    }
}
