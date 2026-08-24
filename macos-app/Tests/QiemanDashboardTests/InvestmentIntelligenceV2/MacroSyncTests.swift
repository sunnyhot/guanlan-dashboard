import XCTest
@testable import QiemanDashboard

/// SYNC-5 单元测试：MacroSync 宏观同步引擎（节奏 gate / 全窗口修订语义 /
/// 幂等重放 / vintage 共存 / 失败隔离）。
final class MacroSyncTests: XCTestCase {

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
            .appendingPathComponent("macro-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)
        spoolURL = DirectSyncPaths.spoolURL(name: "fred-macro", in: dataDirectory)
        stateURL = DirectSyncPaths.stateURL(name: "macro", in: dataDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func cst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 首轮 + 节奏

    func testFirstRoundCommitsAndReportsNewDates() async throws {
        let stub = StubMacroAdapter(records: [
            Self.macroRecord(effectiveAt: cst(2026, 4, 1), publishedAt: cst(2026, 4, 25)),
            Self.macroRecord(effectiveAt: cst(2026, 7, 1), publishedAt: cst(2026, 7, 25)),
        ])
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        let result = try await sync.syncOnce(
            targets: [MacroSyncTarget(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                adapter: stub, refreshInterval: 604_800
            )],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .committed(recordCount, newDates, newCursor) = result.outcomes["GDP"] else {
            return XCTFail("期望 committed，实际 \(String(describing: result.outcomes["GDP"]))")
        }
        XCTAssertEqual(recordCount, 2)
        XCTAssertEqual(newDates, 2)
        XCTAssertEqual(newCursor, cst(2026, 7, 1))

        let state = try SyncStateStore<MacroSyncState>().load(from: stateURL)
        XCTAssertEqual(state?.lastIngestedEffectiveAt["GDP"], cst(2026, 7, 1))
        let rows = repository.macroObservations(
            indicatorID: InstrumentID(rawValue: "inst_gdp"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(rows.count, 2)
    }

    func testCadenceGateSkipsWithinInterval() async throws {
        let stub = StubMacroAdapter(records: [
            Self.macroRecord(effectiveAt: cst(2026, 7, 1), publishedAt: cst(2026, 7, 25)),
        ])
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        let target = MacroSyncTarget(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            adapter: stub, refreshInterval: 604_800   // 一周
        )
        _ = try await sync.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(stub.fetchCount, 1)

        // 三天后（未满一周）：skippedCadence，零抓取
        let later = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 27) })
        let result = try await later.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(result.outcomes["GDP"], .skippedCadence)
        XCTAssertEqual(stub.fetchCount, 1)

        // 八天后（满一周）：重新抓取；无新数据 → upToDate，行数不翻倍
        let muchLater = MacroSync(pipeline: pipeline, now: { self.cst(2026, 9, 1) })
        let rerun = try await muchLater.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL)
        XCTAssertEqual(rerun.outcomes["GDP"], .upToDate)
        XCTAssertEqual(stub.fetchCount, 2)
        let rows = repository.macroObservations(
            indicatorID: InstrumentID(rawValue: "inst_gdp"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(rows.count, 1, "幂等重放不翻倍")
    }

    // MARK: - 修订（real-time vintage）

    func testRevisionCreatesNewVintageEconomicTakesLatest() async throws {
        let initial = StubMacroAdapter(records: [
            Self.macroRecord(effectiveAt: cst(2026, 4, 1), publishedAt: cst(2026, 4, 25), value: "2.5"),
        ])
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        let target = MacroSyncTarget(
            code: ProviderCode(scheme: "fred_series", value: "GDP"),
            adapter: initial, refreshInterval: 0
        )
        _ = try await sync.syncOnce(targets: [target], spoolURL: spoolURL, stateURL: stateURL)

        // 二次发布：同 effectiveAt、新 realtime_start、修订值 3.1（advance 修订）
        let revised = StubMacroAdapter(records: [
            Self.macroRecord(effectiveAt: cst(2026, 4, 1), publishedAt: cst(2026, 5, 28), value: "3.1"),
        ])
        let second = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 25) })
        let revisedTarget = MacroSyncTarget(
            code: target.code, adapter: revised, refreshInterval: 0
        )
        let result = try await second.syncOnce(
            targets: [revisedTarget], spoolURL: spoolURL, stateURL: stateURL
        )

        // 修订行不是新 effectiveAt → upToDate（报告口径），但 vintage 行落地
        XCTAssertEqual(result.outcomes["GDP"], .upToDate)
        let exact = repository.macroObservations(
            indicatorID: InstrumentID(rawValue: "inst_gdp"),
            context: .exactSnapshot(at: cst(2026, 4, 1))
        )
        XCTAssertEqual(exact.count, 2, "原版 + 修订版共存（DATA008）")
        let economic = repository.macroObservations(
            indicatorID: InstrumentID(rawValue: "inst_gdp"),
            context: .economicKnowledge(asOf: cst(2026, 12, 31))
        )
        XCTAssertEqual(economic.count, 1)
        XCTAssertEqual(economic.first?.value, Decimal(string: "3.1"), "economic 取最新修订")
    }

    // MARK: - 失败隔离与降级

    func testFailureIsolationAcrossSeries() async throws {
        let stub = StubMacroAdapter(
            records: [Self.macroRecord(effectiveAt: cst(2026, 7, 1), publishedAt: cst(2026, 7, 25))],
            failureForSeries: ["CPIAUCSL"]
        )
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        let result = try await sync.syncOnce(
            targets: [
                MacroSyncTarget(
                    code: ProviderCode(scheme: "fred_series", value: "CPIAUCSL"),
                    adapter: stub, refreshInterval: 0
                ),
                MacroSyncTarget(
                    code: ProviderCode(scheme: "fred_series", value: "GDP"),
                    adapter: stub, refreshInterval: 0
                ),
            ],
            spoolURL: spoolURL, stateURL: stateURL
        )
        guard case let .failed(reason) = result.outcomes["CPIAUCSL"] else {
            return XCTFail("期望 failed")
        }
        XCTAssertTrue(reason.contains("unavailable"))
        guard case .committed = result.outcomes["GDP"] else {
            return XCTFail("单序列失败不应影响他者")
        }
    }

    func testProviderNotCallableSkipsFetch() async throws {
        let monitor = ProviderHealthMonitor(now: { self.cst(2026, 8, 24) })
        await monitor.register(.fred, reliabilityClass: .officialStable)
        for _ in 0..<5 {
            await monitor.recordFailure(.fred, error: .unavailable(providerID: .fred, underlying: "test"))
        }
        let stub = StubMacroAdapter(records: [])
        let sync = MacroSync(pipeline: pipeline, healthMonitor: monitor, now: { self.cst(2026, 8, 24) })
        let result = try await sync.syncOnce(
            targets: [MacroSyncTarget(
                code: ProviderCode(scheme: "fred_series", value: "GDP"),
                adapter: stub, refreshInterval: 0
            )],
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(result.outcomes["GDP"], .providerNotCallable)
        XCTAssertEqual(stub.fetchCount, 0)
    }

    func testWrongSchemeFailsIsolated() async throws {
        let stub = StubMacroAdapter(records: [])
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        let result = try await sync.syncOnce(
            targets: [MacroSyncTarget(
                code: ProviderCode(scheme: "not_fred", value: "X"),
                adapter: stub, refreshInterval: 0
            )],
            spoolURL: spoolURL, stateURL: stateURL
        )
        XCTAssertEqual(result.outcomes["X"], .upToDate, "非 fred_series 返回空 → upToDate（无数据）")
    }

    func testCorruptStateFailsClosed() async throws {
        try Data("garbage".utf8).write(to: stateURL)
        let stub = StubMacroAdapter(records: [])
        let sync = MacroSync(pipeline: pipeline, now: { self.cst(2026, 8, 24) })
        do {
            _ = try await sync.syncOnce(
                targets: [MacroSyncTarget(
                    code: ProviderCode(scheme: "fred_series", value: "GDP"),
                    adapter: stub, refreshInterval: 0
                )],
                spoolURL: spoolURL, stateURL: stateURL
            )
            XCTFail("坏状态应抛错")
        } catch let error as SyncStateError {
            guard case .corrupt = error else { return XCTFail("期望 corrupt：\(error)") }
        }
    }

    // MARK: - 测试基础设施

    private final class StubMacroAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .fred
        let reliabilityClass: ProviderReliabilityClass = .officialStable

        private let records: [ProviderRecord]
        private let failureForSeries: Set<String>
        private let lock = NSLock()
        private(set) var fetchCount = 0

        init(records: [ProviderRecord], failureForSeries: Set<String> = []) {
            self.records = records
            self.failureForSeries = failureForSeries
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
            if failureForSeries.contains(code.value) {
                throw ProviderError.unavailable(providerID: .fred, underlying: "stub failure")
            }
            guard code.scheme == "fred_series" else {
                return ProviderFetchResult(
                    records: [], diagnostics: ProviderFetchDiagnostics(completeness: .complete)
                )
            }
            let inWindow = records.filter { $0.providerCode == code && $0.effectiveAt <= to }
            return ProviderFetchResult(
                records: inWindow,
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }
    }

    private static func macroRecord(
        effectiveAt: Date, publishedAt: Date, value: String = "2.5"
    ) -> ProviderRecord {
        ProviderRecord(
            providerID: .fred,
            providerCode: ProviderCode(scheme: "fred_series", value: "GDP"),
            effectiveAt: effectiveAt,
            publishedAt: publishedAt,
            ingestedAt: publishedAt.addingTimeInterval(86_400),
            kind: .macroObservation,
            rawPayload: {
                let payload = MacroPayload(
                    value: Decimal(string: value)!,
                    unit: .percent,
                    frequency: .quarterly,
                    isSeasonallyAdjusted: true,
                    basePeriod: nil
                )
                return try! JSONEncoder().encode(payload)
            }(),
            reliabilityClass: .officialStable,
            jurisdiction: .unitedStates
        )
    }

    /// identity 底座：fred_series GDP → inst_gdp（宏观指标 = Instrument，.index）
    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_us"), displayName: "U.S. Government",
            jurisdiction: .unitedStates, kind: .indexPublisher
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_gdp"), issuerID: LegalEntityID(rawValue: "le_us"),
            kind: .index, displayName: "US Real GDP Growth", baseCurrency: .usd, assetClass: .alternative
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .fred, identifierScheme: "fred_series",
            identifierValue: "GDP", canonical: .instrument(InstrumentID(rawValue: "inst_gdp")),
            resolutionMethod: .providerAuthoritative, resolvedAt: cst(2026, 1, 1)
        ))
    }
}
