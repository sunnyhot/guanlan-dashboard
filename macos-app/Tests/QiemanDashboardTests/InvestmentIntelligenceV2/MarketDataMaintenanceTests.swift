import XCTest
@testable import QiemanDashboard

/// 十八轮审查 P1-1 生产接线验收：市场数据维护引擎把 universe 回填真正
/// 写进 daily_bars（identity 按 stooq/alphaVantage 数据 Provider 登记 →
/// 回填 → 收盘增量），随后 MarketDiscoveryWorkflow 能从库内算出真实候选
/// ——「立即扫描」不再恒 coverage gap / 空 candidates。
final class MarketDataMaintenanceTests: XCTestCase {

    private var repository: GRDBRepository!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled
        )
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "market-maintenance-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    /// 满覆盖 stub：窗口内每个日历日一根 bar（覆盖口径按交易日交集计，
    /// 非交易日行不计覆盖——与 MarketUniverseBackfillTests 同款语义）。
    private final class FullCoverageStubAdapter: ProviderAdapter, @unchecked Sendable {
        let providerID: DataProviderID = .stooq
        let reliabilityClass: ProviderReliabilityClass = .communityAggregated

        func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
            try await fetchWithDiagnostics(code: code, from: from, to: to).records
        }

        func fetchWithDiagnostics(
            code: ProviderCode, from: Date, to: Date
        ) async throws -> ProviderFetchResult {
            let payload = DailyBarPayload(
                rawOpen: Price(value: Decimal(string: "100")!, currency: .usd),
                rawHigh: Price(value: Decimal(string: "101")!, currency: .usd),
                rawLow: Price(value: Decimal(string: "99")!, currency: .usd),
                rawClose: Price(value: Decimal(string: "100.5")!, currency: .usd),
                volume: 1_000,
                adjustmentFactor: Decimal(1),
                fxRate: nil
            )
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            var records: [ProviderRecord] = []
            var day = from
            while day <= to {
                records.append(ProviderRecord(
                    providerID: .stooq,
                    providerCode: ProviderCode(scheme: "stock_symbol", value: code.value),
                    effectiveAt: day,
                    publishedAt: day,
                    ingestedAt: day.addingTimeInterval(86_400),
                    kind: .dailyBar,
                    rawPayload: try! JSONEncoder().encode(payload),
                    reliabilityClass: .communityAggregated,
                    jurisdiction: .unitedStates
                ))
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
            return ProviderFetchResult(
                records: records,
                diagnostics: ProviderFetchDiagnostics(completeness: .complete)
            )
        }
    }

    private func makeEngine() -> MarketDataMaintenanceEngine {
        let stub = FullCoverageStubAdapter()
        return MarketDataMaintenanceEngine(
            repository: repository,
            dataDirectory: dataDirectory,
            chainFactory: { _ in ProviderFallbackChain(adapters: [stub]) }
        )
    }

    func testMaintenanceBackfillsUniverseAndDiscoveryFindsCandidates() async throws {
        let engine = makeEngine()
        let summary = try await engine.runMaintenance(backfillRounds: 3)
        XCTAssertTrue(summary.contains("universe 覆盖 17/31"), "直抓美股 17 条全部达标：\(summary)")

        // identity 按数据 Provider 登记（resolver 查表键）——行情行不再卡
        // identity 防火墙（此前只登记 universe-catalog，Stooq 行必被拒收）
        let spyEntry = try XCTUnwrap(
            MarketUniverseCatalog.v1.entries.first { $0.key == "us-spy" }
        )
        XCTAssertNotNil(
            repository.resolve(
                providerID: .stooq, scheme: "stock_symbol", value: spyEntry.code.value
            ),
            "Stooq 行情行的 providerCode→canonical 映射必须可解析"
        )

        // 回填真实落库：SPY 的 252 交易日窗口有日线
        let bars = repository.dailyBars(
            listingID: spyEntry.listingID,
            context: .economicKnowledge(asOf: Date().addingTimeInterval(30 * 86_400))
        )
        XCTAssertGreaterThanOrEqual(bars.count, 250, "满覆盖 stub 下 SPY 应有完整历史")

        // 端到端验收：discovery 从库内数据算出真实候选——美股 17 条进排名
        // （topK=8 截断），A 股 14 条 remote 通道未启用 → 显式 coverage gap
        let workflow = MarketDiscoveryWorkflow(repository: repository)
        let outcome = workflow.run(asOf: Date(), now: Date())
        let report = try XCTUnwrap(outcome.report, outcome.errorDetail ?? "run failed")
        XCTAssertEqual(report.candidates.count, 8, "topK 截断的候选应来自真实日线因子")
        XCTAssertEqual(report.coverageGaps.count, 14, "A 股 remote 通道未启用 = 全量缺口")
    }

    func testMaintenanceIsIdempotentAcrossRounds() async throws {
        let engine = makeEngine()
        _ = try await engine.runMaintenance(backfillRounds: 3)
        let barsBefore = repository.dailyBars(
            listingID: MarketUniverseCatalog.v1.entries[0].listingID,
            context: .economicKnowledge(asOf: Date().addingTimeInterval(30 * 86_400))
        ).count
        // 第二轮维护（全达标 → 空批次）+ 增量 upToDate：行数不翻倍
        let summary = try await engine.runMaintenance(backfillRounds: 1)
        let barsAfter = repository.dailyBars(
            listingID: MarketUniverseCatalog.v1.entries[0].listingID,
            context: .economicKnowledge(asOf: Date().addingTimeInterval(30 * 86_400))
        ).count
        XCTAssertEqual(barsBefore, barsAfter, "幂等：重复维护不产生重复行")
        XCTAssertTrue(summary.contains("增量通道"), "摘要应携带增量通道状态：\(summary)")
    }
}
