import XCTest
@testable import QiemanDashboard

// WF-2：Market Discovery Workflow 测试。
//
// 锁定：本地因子排序（同数据 → 同排名）、coverage gap 显式记录
// （不猜分）、top-K 截断与 tie-break、确定性 report ID（重跑幂等）、
// GRDB 落库读回、top-K → ResearchTask 选择性研究接线、内置 universe
// 策展完整性。

private let discoveryEpoch = Date(timeIntervalSince1970: 1_850_000_000)

private struct DiscoveryWeekdayCalendar: TradingCalendar {
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool { true }
    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
        date.addingTimeInterval(Double(offset) * 86400)
    }
    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date { date }
}

final class MarketDiscoveryWorkflowTests: XCTestCase {

    private let day = discoveryEpoch
    private let now = discoveryEpoch.addingTimeInterval(16 * 3600)

    /// 标准测试 universe：3 条目（us-up / us-flat / us-empty）。
    private var universe: MarketUniverse {
        MarketUniverse(universeVersion: 1, entries: [
            MarketUniverseEntry(
                key: "us-up", code: ProviderCode(scheme: "stock_symbol", value: "UP"),
                jurisdiction: .unitedStates,
                listingID: ListingID(rawValue: "lst_up"),
                displayName: "上升标的", priority: 1, fetchDirectly: true
            ),
            MarketUniverseEntry(
                key: "us-flat", code: ProviderCode(scheme: "stock_symbol", value: "FLAT"),
                jurisdiction: .unitedStates,
                listingID: ListingID(rawValue: "lst_flat"),
                displayName: "横盘标的", priority: 1, fetchDirectly: true
            ),
            MarketUniverseEntry(
                key: "us-empty", code: ProviderCode(scheme: "stock_symbol", value: "EMPTY"),
                jurisdiction: .unitedStates,
                listingID: ListingID(rawValue: "lst_empty"),
                displayName: "无数据标的", priority: 2, fetchDirectly: true
            ),
        ])
    }

    /// 66 根 bar 的仓库：up 等差上升（100+i）、flat 恒定 100、empty 无数据。
    private func makeRepository() -> InMemoryRepository {
        let repo = InMemoryRepository(calendarBackend: DiscoveryWeekdayCalendar())
        let available = day.addingTimeInterval(15 * 3600)
        func bar(_ id: String, _ listing: ListingID, _ i: Int, _ close: Decimal) -> DailyBar {
            DailyBar(
                id: ObservationID(rawValue: id),
                listingID: listing,
                temporalEnvelope: TemporalEnvelope(
                    effectiveAt: discoveryEpoch.addingTimeInterval(Double(i) * 86400),
                    publishedAt: available, availableAt: available, ingestedAt: available
                ),
                availabilityProvenance: AvailabilityProvenance(
                    policyID: "market_close", policyVersion: "v1", derivedAt: available
                ),
                dataQuality: .from(.officialStable, providerID: .stooq),
                vintage: Vintage(announcementDate: available, publisherVersion: 1),
                rawOpen: Price(value: close, currency: .usd),
                rawHigh: Price(value: close, currency: .usd),
                rawLow: Price(value: close, currency: .usd),
                rawClose: Price(value: close, currency: .usd),
                volume: 1000, adjustmentFactor: 1
            )
        }
        let up = ListingID(rawValue: "lst_up")
        let flat = ListingID(rawValue: "lst_flat")
        for i in 0..<66 {
            repo.upsert(bar("up\(i)", up, i, Decimal(100 + i)))
            repo.upsert(bar("flat\(i)", flat, i, Decimal(100)))
        }
        return repo
    }

    private func makeWorkflow(
        topK: Int = 8, repository: (any MarketTimeSeriesRepository)? = nil
    ) -> MarketDiscoveryWorkflow {
        var policy = DiscoveryRankingPolicy()
        policy.topK = topK
        return MarketDiscoveryWorkflow(
            universe: universe,
            repository: repository ?? makeRepository(),
            policy: policy
        )
    }

    // MARK: - 排名与 coverage

    func testRanksCandidatesFromLocalFactors() throws {
        let outcome = makeWorkflow().run(asOf: now, now: now)
        XCTAssertTrue(outcome.succeeded, outcome.errorDetail ?? "")
        let report = try XCTUnwrap(outcome.report)

        // 有数据的两个标的进入候选；无数据标的进 coverage gap（不猜分）
        XCTAssertEqual(report.candidates.count, 2)
        XCTAssertEqual(report.coverageGaps.count, 1)
        XCTAssertEqual(report.coverageGaps.first?.universeKey, "us-empty")
        XCTAssertEqual(report.coverageGaps.first?.reason, "EMPTY_SERIES(required=61 actual=0)")

        // 上升标的（momentum/trend/drawdown 全优）排第一
        XCTAssertEqual(report.candidates.first?.universeKey, "us-up")
        XCTAssertEqual(report.candidates.first?.rank, 1)
        XCTAssertEqual(report.candidates.last?.universeKey, "us-flat")
        XCTAssertEqual(report.candidates.last?.rank, 2)

        // 分数来自 metric：up 的 momentum.return60 = 165/105 - 1 > 0
        let upScore = try XCTUnwrap(report.candidates.first?.score)
        XCTAssertTrue(upScore > 0, "上升标的综合分为正（动量+趋势+零回撤）")
        let flatScore = try XCTUnwrap(report.candidates.last?.score)
        XCTAssertEqual(flatScore, 0, "横盘标的动量/趋势/回撤全 0 → 综合分 0")

        // job 状态与依赖（两个因子快照）
        XCTAssertEqual(outcome.job.state, .completed)
        XCTAssertEqual(report.dependencies.count, 2)
        XCTAssertEqual(report.universeVersion, 1)
        XCTAssertEqual(report.rankingPolicy.identityToken, "market-discovery-ranking@v1")
    }

    func testTopKTruncationAndTieBreak() throws {
        // 两个同分标的（flat × 2）+ topK=1 → 只留 1 个，tie-break 按 key 升序
        let tieUniverse = MarketUniverse(universeVersion: 1, entries: [
            MarketUniverseEntry(
                key: "zz-tie", code: ProviderCode(scheme: "stock_symbol", value: "T1"),
                jurisdiction: .unitedStates, listingID: ListingID(rawValue: "lst_flat"),
                displayName: "平A", priority: 1, fetchDirectly: true
            ),
            MarketUniverseEntry(
                key: "aa-tie", code: ProviderCode(scheme: "stock_symbol", value: "T2"),
                jurisdiction: .unitedStates, listingID: ListingID(rawValue: "lst_flat"),
                displayName: "平B", priority: 1, fetchDirectly: true
            ),
        ])
        var policy = DiscoveryRankingPolicy()
        policy.topK = 1
        let workflow = MarketDiscoveryWorkflow(
            universe: tieUniverse, repository: makeRepository(), policy: policy
        )
        let report = try XCTUnwrap(workflow.run(asOf: now, now: now).report)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.candidates.first?.universeKey, "aa-tie")
        // 同 listing 数据 → dependencies 引用两个快照（逐条目独立计算）
        XCTAssertEqual(report.dependencies.count, 2)
    }

    func testDeterminismAndIdempotentRerun() throws {
        let first = try XCTUnwrap(makeWorkflow().run(asOf: now, now: now).report)
        let second = try XCTUnwrap(makeWorkflow().run(asOf: now, now: now).report)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.candidates, second.candidates)
        XCTAssertEqual(first.coverageGaps, second.coverageGaps)

        // asOf 不同 → ID 变化（输入语义变化）
        let laterAsOf = now.addingTimeInterval(86400)
        let differentAsOf = try XCTUnwrap(makeWorkflow().run(
            asOf: laterAsOf, now: laterAsOf
        ).report)
        XCTAssertNotEqual(first.id, differentAsOf.id)
    }

    // MARK: - 落库与读回

    func testGRDBRoundTrip() throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let report = try XCTUnwrap(makeWorkflow(repository: repository).run(
            asOf: now, now: now
        ).report)
        try repository.writeMarketDiscoveryReport(report)
        // 幂等重写 no-op
        try repository.writeMarketDiscoveryReport(report)
        let readBack = try repository.marketDiscoveryReport(id: report.id.rawValue)
        XCTAssertEqual(readBack, report)
        XCTAssertNil(try repository.marketDiscoveryReport(id: "mkt_nonexistent"))
    }

    // MARK: - 选择性 Research 接线

    func testResearchTasksOnlyCarryTopK() throws {
        let report = try XCTUnwrap(makeWorkflow(topK: 1).run(asOf: now, now: now).report)
        let tasks = report.researchTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.subject, .listing(ListingID(rawValue: "lst_up")))
        XCTAssertTrue(tasks.first?.objective.contains("上升标的") ?? false)

        // limit 进一步收窄
        let full = try XCTUnwrap(makeWorkflow(topK: 8).run(asOf: now, now: now).report)
        XCTAssertEqual(full.researchTasks(limit: 1).count, 1)
        XCTAssertEqual(full.researchTasks().count, full.candidates.count)
    }

    // MARK: - 内置 universe 策展完整性

    func testBuiltInCatalogIntegrity() {
        let catalog = MarketUniverseCatalog.v1
        XCTAssertEqual(catalog.universeVersion, 1)
        XCTAssertGreaterThanOrEqual(catalog.entries.count, 20, "v1 策展规模 ≥ 20（宽基+行业+资产类）")
        XCTAssertEqual(Set(catalog.entries.map(\.key)).count, catalog.entries.count, "key 唯一")
        XCTAssertEqual(
            Set(catalog.entries.map(\.listingID.rawValue)).count,
            catalog.entries.count,
            "listingID 唯一（同 listing 不同 key 会双计排名）"
        )
        // A 股条目全部走 remote 通道（fetchDirectly = false）
        for entry in catalog.entries where entry.jurisdiction == .chinaMainland {
            XCTAssertFalse(entry.fetchDirectly, "A 股条目 \(entry.key) 应走 remote 通道")
        }
    }
}
