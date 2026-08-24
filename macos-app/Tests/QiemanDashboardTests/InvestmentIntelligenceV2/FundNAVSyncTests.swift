import XCTest
@testable import QiemanDashboard

/// SYNC-3 单元测试：FundNAVSync 增量同步引擎。
///
/// 覆盖：首轮全量入库 + 游标推进 / 增量窗口 / upToDate 跳过 / 游标保守不推进
/// （拒收、无新数据、commit 失败）/ 单基金失败隔离 / ProviderHealth 降级入口 /
/// state 原子持久化与 fail-closed / spool 事实源积累与幂等重放。
final class FundNAVSyncTests: XCTestCase {

    private var repository: GRDBRepository!
    private var pipeline: CanonicalPipeline!
    private var dataDirectory: URL!
    private var spoolURL: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        repository = GRDBRepository(database: try CanonicalDatabase(), calendarBackend: HolidayTableTradingCalendar.bundled)
        try seedFundIdentity()
        pipeline = CanonicalPipeline(repository: repository, calendar: HolidayTableTradingCalendar.bundled)

        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fund-nav-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "eastmoney-nav", in: dataDirectory)
        stateURL = DirectSyncPaths.stateURL(name: "fund-nav", in: dataDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    // MARK: - 日期辅助（CST 交易日）

    private func cst(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - 首轮 + 增量

    func testFreshSyncCommitsAndAdvancesCursor() async throws {
        // now = 周三 2026-08-19 20:00 → 锚点（保证已公布）= 周二 08-18
        let adapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            Self.navRecord(effectiveAt: cst(2026, 8, 18)),
        ])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })

        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )

        XCTAssertEqual(result.anchor, cst(2026, 8, 18))
        guard case let .committed(count, newCursor, dropped) = result.outcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newCursor, cst(2026, 8, 18))
        XCTAssertEqual(dropped, 0)

        // 游标已持久化；spool 两条（ADR-DATA004 事实源）
        let state = try SyncStateStore<FundNAVSyncState>().load(from: stateURL)
        XCTAssertEqual(state?.lastIngestedEffectiveDates["110022"], cst(2026, 8, 18))
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 2)

        // 库内可查（economic asOf 晚于 availableAt）
        let navs = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 8, 25))
        )
        XCTAssertEqual(navs.count, 2)
    }

    func testSecondRoundUpToDateSkipsFetch() async throws {
        let adapter = StubNAVAdapter(records: [Self.navRecord(effectiveAt: cst(2026, 8, 18))])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let funds = [ProviderCode(scheme: "fund_code", value: "110022")]

        _ = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(adapter.fetchCount, 1)

        // 同一 asOf 再跑一轮：游标 ≥ 锚点，直接跳过（零抓取）
        let second = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(adapter.fetchCount, 1, "upToDate 不应发起抓取")
        XCTAssertEqual(second.outcomes["110022"], .upToDate)
    }

    func testIncrementalWindowOnlyFetchesNewDates() async throws {
        // 第一轮：now 周三 08-19 20:00，游标到 08-18
        let adapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            Self.navRecord(effectiveAt: cst(2026, 8, 18)),
        ])
        let first = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let funds = [ProviderCode(scheme: "fund_code", value: "110022")]
        _ = try await first.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        // 第二轮：now 周五 08-21 20:00 → 锚点 = 周四 08-20；Provider 有 08-19/08-20
        let secondAdapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),   // 窗口外（≤ 游标）
            Self.navRecord(effectiveAt: cst(2026, 8, 19)),
            Self.navRecord(effectiveAt: cst(2026, 8, 20)),
        ])
        XCTAssertEqual(secondAdapter.lastWindowFrom, nil)
        let second = FundNAVSync(adapter: secondAdapter, pipeline: pipeline, now: { self.cst(2026, 8, 21, hour: 20) })
        let result = try await second.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        // 窗口从游标次日（08-19）起——08-17 被窗口排除，不重复入库
        XCTAssertEqual(secondAdapter.lastWindowFrom, cst(2026, 8, 19))
        XCTAssertEqual(secondAdapter.lastWindowThrough, cst(2026, 8, 20))
        guard case let .committed(count, newCursor, _) = result.outcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newCursor, cst(2026, 8, 20))

        // 幂等：库里 4 行（2 + 2），spool 积累 4 条
        let rows = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 8, 25))
        )
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 4)
    }

    // MARK: - 游标保守语义

    func testNoNewDataHoldsCursor() async throws {
        // Provider 窗口内无数据（QDII T+2 滞后形态）——游标不动，下轮重试
        let adapter = StubNAVAdapter(records: [Self.navRecord(effectiveAt: cst(2026, 8, 18))])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let funds = [ProviderCode(scheme: "fund_code", value: "110022")]
        _ = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        let laterAdapter = StubNAVAdapter(records: [Self.navRecord(effectiveAt: cst(2026, 8, 18))])   // 无新日期
        let later = FundNAVSync(adapter: laterAdapter, pipeline: pipeline, now: { self.cst(2026, 8, 21, hour: 20) })
        let result = try await later.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        guard case .noNewData = result.outcomes["110022"] else {
            return XCTFail("期望 noNewData，实际 \(String(describing: result.outcomes["110022"]))")
        }
        let state = try SyncStateStore<FundNAVSyncState>().load(from: stateURL)
        XCTAssertEqual(state?.lastIngestedEffectiveDates["110022"], cst(2026, 8, 18), "游标不推进")
    }

    func testPipelineRejectionHoldsCursorAndRetryIsIdempotent() async throws {
        // 好记录（08-17）+ 坏记录（08-18，NAV 负值被 CanonicalDataValidator 拒收）
        let adapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            Self.navRecord(effectiveAt: cst(2026, 8, 18), nav: Decimal(string: "-1")!),
        ])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let funds = [ProviderCode(scheme: "fund_code", value: "110022")]
        let result = try await sync.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)

        guard case let .rejectedCursorHeld(committed, rejectionCount, dropped) = result.outcomes["110022"] else {
            return XCTFail("期望 rejectedCursorHeld，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(committed, 1, "坏记录拒收不阻塞好记录")
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections[0].stage, .dataValidation)

        // 游标不动；库里只有 08-17 一行
        let state = try SyncStateStore<FundNAVSyncState>().load(from: stateURL)
        XCTAssertNil(state?.lastIngestedEffectiveDates["110022"], "有拒收游标不推进")
        let rows = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 8, 25))
        )
        XCTAssertEqual(rows.count, 1)

        // 重试（Provider 修正了坏记录）：全量窗口重抓，旧行幂等不翻倍
        let fixed = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            Self.navRecord(effectiveAt: cst(2026, 8, 18)),
        ])
        let retry = FundNAVSync(adapter: fixed, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let retryResult = try await retry.syncOnce(funds: funds, spoolURL: spoolURL, stateURL: stateURL)
        guard case let .committed(count, newCursor, _) = retryResult.outcomes["110022"] else {
            return XCTFail("期望 committed，实际 \(String(describing: retryResult.outcomes["110022"]))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newCursor, cst(2026, 8, 18))
        let after = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 8, 25))
        )
        XCTAssertEqual(after.count, 2, "重试幂等不翻倍")
    }

    func testSchemaInvalidRecordsNeverReachSpool() async throws {
        // 结构闸门分桶：垃圾 payload 不污染 spool，游标不动
        var bad = Self.navRecord(effectiveAt: cst(2026, 8, 18))
        bad = ProviderRecord(
            providerID: bad.providerID, providerCode: bad.providerCode,
            effectiveAt: bad.effectiveAt, publishedAt: bad.publishedAt, ingestedAt: bad.ingestedAt,
            kind: .navObservation,
            rawPayload: Data(#"{"warp":true}"#.utf8),
            reliabilityClass: bad.reliabilityClass, jurisdiction: bad.jurisdiction
        )
        let adapter = StubNAVAdapter(records: [bad])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .rejectedCursorHeld(committed, rejectionCount, _) = result.outcomes["110022"] else {
            return XCTFail("期望 rejectedCursorHeld，实际 \(String(describing: result.outcomes["110022"]))")
        }
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(rejectionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolURL.path), "非法记录不落 spool")
    }

    func testMixedValidAndInvalidHoldsCursorDespitePartialCommit() async throws {
        // P1 修复回归：T（08-17）合法、T+1（08-18）结构非法——合法行入库，
        // 但游标不得推进（推进会永久跳过 08-18）
        var bad = Self.navRecord(effectiveAt: cst(2026, 8, 18))
        bad = ProviderRecord(
            providerID: bad.providerID, providerCode: bad.providerCode,
            effectiveAt: bad.effectiveAt, publishedAt: bad.publishedAt, ingestedAt: bad.ingestedAt,
            kind: .navObservation,
            rawPayload: Data(#"{"warp":true}"#.utf8),
            reliabilityClass: bad.reliabilityClass, jurisdiction: bad.jurisdiction
        )
        let adapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            bad,
        ])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .rejectedCursorHeld(committed, rejectionCount, _) = result.outcomes["110022"] else {
            return XCTFail("期望 rejectedCursorHeld（混合 invalid），实际 \(String(describing: result.outcomes))")
        }
        XCTAssertEqual(committed, 1, "合法行仍入库")
        XCTAssertEqual(rejectionCount, 1)
        let state = try SyncStateStore<FundNAVSyncState>().load(from: stateURL)
        XCTAssertNil(state?.lastIngestedEffectiveDates["110022"], "混合 invalid 游标不推进")
        let rows = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: cst(2026, 8, 25))
        )
        XCTAssertEqual(rows.count, 1)
    }

    func testUpstreamDroppedRowsHoldCursor() async throws {
        // P1 修复回归：adapter 诊断报告上游丢行（如 T+1 解析失败被 LSJZ 丢弃）
        // —— 即使返回的记录全部合法，游标也不推进
        let adapter = StubNAVAdapter(records: [
            Self.navRecord(effectiveAt: cst(2026, 8, 17)),
            Self.navRecord(effectiveAt: cst(2026, 8, 18)),
        ], droppedMalformed: 1)
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .rejectedCursorHeld(committed, rejectionCount, dropped) = result.outcomes["110022"] else {
            return XCTFail("期望 rejectedCursorHeld（上游丢行），实际 \(String(describing: result.outcomes))")
        }
        XCTAssertEqual(committed, 2, "返回的合法行照常入库")
        XCTAssertEqual(rejectionCount, 0)
        XCTAssertEqual(dropped, 1)
        let state = try SyncStateStore<FundNAVSyncState>().load(from: stateURL)
        XCTAssertNil(state?.lastIngestedEffectiveDates["110022"], "上游丢行时游标不推进")
    }

    // MARK: - 失败隔离与健康降级

    func testPerFundFailureIsolation() async throws {
        // 第一只抓取失败（unavailable），第二只正常入库
        let adapter = StubNAVAdapter(
            records: [Self.navRecord(effectiveAt: cst(2026, 8, 18))],
            failureForFundCodes: ["000001"]
        )
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            funds: [
                ProviderCode(scheme: "fund_code", value: "000001"),
                ProviderCode(scheme: "fund_code", value: "110022"),
            ],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .failed(reason) = result.outcomes["000001"] else {
            return XCTFail("期望 failed，实际 \(String(describing: result.outcomes["000001"]))")
        }
        XCTAssertTrue(reason.contains("unavailable"), "失败原因应含 unavailable：\(reason)")
        guard case .committed = result.outcomes["110022"] else {
            return XCTFail("单只失败不应影响他者：\(String(describing: result.outcomes["110022"]))")
        }
    }

    func testProviderNotCallableSkipsFetch() async throws {
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 19, hour: 20) })
        await monitor.register(.eastmoney, reliabilityClass: .communityAggregated)
        // 连续失败 ≥5 → unavailable（HealthDegradationPolicy v1）
        for _ in 0..<5 {
            await monitor.recordFailure(.eastmoney, error: .unavailable(providerID: .eastmoney, underlying: "test"))
        }
        let adapter = StubNAVAdapter(records: [Self.navRecord(effectiveAt: cst(2026, 8, 18))])
        let sync = FundNAVSync(
            adapter: adapter, pipeline: pipeline, healthMonitor: monitor,
            now: { self.cst(2026, 8, 19, hour: 20) }
        )
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "fund_code", value: "110022")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(result.outcomes["110022"], .providerNotCallable)
        XCTAssertEqual(adapter.fetchCount, 0, "不可调用不发起抓取")
    }

    func testNonFundCodeSchemeFails() async throws {
        let adapter = StubNAVAdapter(records: [])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        let result = try await sync.syncOnce(
            funds: [ProviderCode(scheme: "stock_symbol", value: "600519")],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case .failed = result.outcomes["600519"] else {
            return XCTFail("期望 failed")
        }
    }

    // MARK: - state 持久化语义

    func testCorruptStateFailsClosed() async throws {
        try Data("not json".utf8).write(to: stateURL)
        let adapter = StubNAVAdapter(records: [])
        let sync = FundNAVSync(adapter: adapter, pipeline: pipeline, now: { self.cst(2026, 8, 19, hour: 20) })
        do {
            _ = try await sync.syncOnce(
                funds: [ProviderCode(scheme: "fund_code", value: "110022")],
                spoolURL: spoolURL, stateURL: stateURL
            )
            XCTFail("坏状态应抛错")
        } catch let error as SyncStateError {
            guard case .corrupt = error else {
                return XCTFail("期望 corrupt，实际 \(error)")
            }
        }
    }

    func testStateRoundTripKeepsISO8601MillisecondDates() async throws {
        let store = SyncStateStore<FundNAVSyncState>()
        var state = FundNAVSyncState()
        state.lastIngestedEffectiveDates["110022"] = cst(2026, 8, 18)
        try store.save(state, to: stateURL)
        let loaded = try store.load(from: stateURL)
        XCTAssertEqual(loaded?.lastIngestedEffectiveDates["110022"], cst(2026, 8, 18))
        // 日期落盘为 ISO8601 毫秒字符串（人可读，与 CanonicalColumnCodec 约定一致）
        let raw = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("2026-08-17T16:00:00.000Z"), "落盘形态：\(raw)")
    }

    // MARK: - 目录布局

    func testDirectSyncPathsLayout() {
        XCTAssertEqual(
            spoolURL.lastPathComponent, "eastmoney-nav.jsonl"
        )
        XCTAssertEqual(
            spoolURL.deletingLastPathComponent().lastPathComponent, "sync-spool"
        )
        XCTAssertEqual(stateURL.deletingLastPathComponent().lastPathComponent, "sync-state")
        // 与 canonical.sqlite3 / remote-staging 同住 V2 工作目录
        XCTAssertTrue(
            spoolURL.deletingLastPathComponent().deletingLastPathComponent()
                .path.hasSuffix("investment-intelligence-v2")
        )
    }

    // MARK: - 测试基础设施

    /// 可控桩 adapter：预置记录按窗口过滤；可注入指定 fundCode 的抓取失败。
    private final class StubNAVAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .eastmoney
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        private let records: [ProviderRecord]
        private let failureForFundCodes: Set<String>
        private let droppedMalformed: Int
        private let lock = NSLock()
        private(set) var fetchCount: Int = 0
        private(set) var lastWindowFrom: Date?
        private(set) var lastWindowThrough: Date?

        init(
            records: [ProviderRecord],
            failureForFundCodes: Set<String> = [],
            droppedMalformed: Int = 0
        ) {
            self.records = records
            self.failureForFundCodes = failureForFundCodes
            self.droppedMalformed = droppedMalformed
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
            if failureForFundCodes.contains(code.value) {
                throw ProviderError.unavailable(providerID: .eastmoney, underlying: "stub failure")
            }
            let inWindow = records.filter { $0.providerCode == code && $0.effectiveAt >= from && $0.effectiveAt <= to }
            return ProviderFetchResult(
                records: inWindow,
                diagnostics: ProviderFetchDiagnostics(
                    completeness: .complete,
                    droppedMalformedBySource: droppedMalformed > 0 ? ["stub": droppedMalformed] : [:]
                )
            )
        }
    }

    private static func navRecord(effectiveAt: Date, nav: Decimal = Decimal(string: "2.8315")!) -> ProviderRecord {
        ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: effectiveAt,
            publishedAt: effectiveAt.addingTimeInterval(22 * 3600),
            ingestedAt: effectiveAt.addingTimeInterval(26 * 3600),
            kind: .navObservation,
            rawPayload: {
                let payload = NAVPayload(
                    unitNAV: Price(value: nav, currency: .cny),
                    accumulatedNAV: nil,
                    cumulativeDividendPerShare: nil
                )
                return try! JSONEncoder().encode(payload)
            }(),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    /// identity 底座：fund_code 110022 → fsc_110022_A（对齐 CanonicalPipelineTests）
    private func seedFundIdentity() throws {
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
    }
}
