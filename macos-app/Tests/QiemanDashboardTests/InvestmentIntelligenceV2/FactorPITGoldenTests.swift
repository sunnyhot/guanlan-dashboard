import XCTest
@testable import QiemanDashboard

/// FAC-8：Factor PIT golden 套件（固定序列 → 固定输出，跨 vintage 一致）。
///
/// 端到端验证整条链：InMemoryRepository（economicKnowledge 择优）→
/// FactorEngine（全 5 个 calculator）→ FactorSnapshot。覆盖：
/// 1. 确定性序列的 golden 字面量（等差序列闭式解，跨运行不漂移）
/// 2. 重算幂等（同 repo 状态 + 同 asOf + 同 producedAt → byte-identical）
/// 3. 跨 vintage 一致（ADR-DATA008）：T+1 算的 snapshot 在 T 的修订 vintage
///    发布后重算不变（v2 不可见）；asOf 前移到 v2 可见后才变化
/// 4. 未来数据不泄漏：完整 repo 与截断 repo 在同一 asOf 的 snapshot 相同
///    （信息集相同 → 因子相同，与库里还有多少未来 bar 无关）
final class FactorPITGoldenTests: XCTestCase {

    // MARK: - 测试基建

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool { true }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            date.addingTimeInterval(Double(offset) * 86400)
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date { date }
    }

    private let assetListing = ListingID(rawValue: "asset")
    private let benchmarkListing = ListingID(rawValue: "bench")
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ i: Int) -> Date { epoch.addingTimeInterval(Double(i) * 86400) }

    private func makeProv(_ at: Date) -> AvailabilityProvenance {
        AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: epoch)
    }

    /// 单根 bar：availableAt = 当日收盘（day×86400 + 15h），asOf 取 16h 即可见。
    private func bar(
        id: String, listing: ListingID, index i: Int, close: Decimal,
        availableFrom availableDay: Int? = nil, publisherVersion: Int = 1
    ) -> DailyBar {
        let effective = day(i)
        let available = day(availableDay ?? i).addingTimeInterval(15 * 3600)
        return DailyBar(
            id: ObservationID(rawValue: id),
            listingID: listing,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: effective, publishedAt: available, availableAt: available,
                ingestedAt: available
            ),
            availabilityProvenance: makeProv(available),
            dataQuality: .from(.officialStable, providerID: .stooq),
            vintage: Vintage(announcementDate: available, publisherVersion: publisherVersion),
            rawOpen: Price(value: close, currency: .cny),
            rawHigh: Price(value: close, currency: .cny),
            rawLow: Price(value: close, currency: .cny),
            rawClose: Price(value: close, currency: .cny),
            volume: 1000, adjustmentFactor: 1
        )
    }

    /// 等差 fixture：asset close = 100+i，benchmark close = 200+i（i = 0..<count）。
    private func makeRepo(count: Int) -> InMemoryRepository {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        for i in 0..<count {
            repo.upsert(bar(id: "a\(i)", listing: assetListing, index: i, close: Decimal(100 + i)))
            repo.upsert(bar(id: "bm\(i)", listing: benchmarkListing, index: i, close: Decimal(200 + i)))
        }
        return repo
    }

    /// 全引擎（5 calculator）。
    private func makeEngine() -> FactorEngine {
        FactorEngine(calculators: [
            TrendFactorCalculator(),
            MomentumFactorCalculator(),
            VolatilityFactorCalculator(),
            DrawdownFactorCalculator(),
            RelativeStrengthFactorCalculator(benchmarkListingID: benchmarkListing),
        ])
    }

    private func snapshot(
        _ repo: InMemoryRepository, asOfDay: Int, producedAtDay: Int? = nil
    ) -> FactorSnapshot {
        makeEngine().snapshot(
            listingID: assetListing,
            asOf: day(asOfDay).addingTimeInterval(16 * 3600),
            repository: repo,
            benchmarkListingID: benchmarkListing,
            producedAt: day(producedAtDay ?? asOfDay).addingTimeInterval(16 * 3600)
        )
    }

    private func metricMap(_ snap: FactorSnapshot) -> [String: FactorMetric] {
        Dictionary(uniqueKeysWithValues: snap.metrics.map { ($0.definition.key, $0) })
    }

    // MARK: - 1. golden 字面量（等差序列闭式解）

    func testGoldenValues_fullEngineOnDeterministicSeries() {
        let snap = snapshot(makeRepo(count: 70), asOfDay: 69)
        let m = metricMap(snap)

        // asset close = 100+i（i=0..69），t = 69（close 169）
        XCTAssertEqual(m["trend.closeVsMA20"]?.value, Decimal(string: "0.059561128527"))  // 169/159.5 − 1
        XCTAssertEqual(m["trend.ma20Slope"]?.value, Decimal(string: "0.032362459547"))    // 159.5/154.5 − 1
        XCTAssertEqual(m["momentum.return20"]?.value, Decimal(string: "0.134228187919"))  // 169/149 − 1 = 20/149
        XCTAssertEqual(m["momentum.return60"]?.value, Decimal(string: "0.550458715596"))  // 169/109 − 1 = 60/109
        XCTAssertEqual(m["momentum.return120"]?.insufficiency?.reason, .insufficientBars)  // 70 < 121
        XCTAssertEqual(m["drawdown.current252"]?.value, 0)                                 // 单调上涨
        XCTAssertEqual(m["drawdown.max252"]?.value, 0)
        // asset ret20 − bench ret20 = 20/149 − 20/249 = 2000/37101
        //（asset close 169/149，benchmark close 269/249）
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.value, Decimal(string: "0.053906902779"))
        // volatility 无闭式：断言存在且与独立重算一致（见下）
        XCTAssertNotNil(m["volatility.realized20"]?.value)

        // coverage / provenance
        XCTAssertEqual(snap.assetCoverage.barCount, 70)
        XCTAssertEqual(snap.benchmarkCoverage?.barCount, 70)
        XCTAssertEqual(snap.sourceObservationIDs.count, 140)
        XCTAssertEqual(snap.metrics.count, 13)  // 4 trend + 3 momentum + 2 vol + 2 drawdown + 2 RS
    }

    // MARK: - 2. 重算幂等（byte-identical）

    func testRecomputationIsIdempotent() {
        let repo = makeRepo(count: 70)
        let first = snapshot(repo, asOfDay: 69)
        let second = snapshot(repo, asOfDay: 69)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.factorVersion, second.factorVersion)
    }

    // MARK: - 3. 跨 vintage 一致（ADR-DATA008 核心）

    func testVintageRevisionInvisibleUntilAvailable() {
        let repo = makeRepo(count: 70)

        // T = day 69 的修订 bar：v2 close 180，day 74 才 available
        repo.upsert(bar(
            id: "a69_v2", listing: assetListing, index: 69, close: 180,
            availableFrom: 74, publisherVersion: 2
        ))

        // asOf day 69：v2 不可见，snapshot 用 v1（与无修订时 byte-identical）
        let baseline = snapshot(makeRepo(count: 70), asOfDay: 69)
        let withInvisibleRevision = snapshot(repo, asOfDay: 69)
        XCTAssertEqual(withInvisibleRevision, baseline, "不可见 vintage 不得影响重算")
        XCTAssertFalse(
            withInvisibleRevision.sourceObservationIDs.contains(ObservationID(rawValue: "a69_v2")),
            "v2 不得进入 provenance"
        )

        // asOf day 75：v2 可见且择优（同 effectiveAt 新 vintage 胜出）
        let afterRevisionVisible = snapshot(repo, asOfDay: 75)
        let m = metricMap(afterRevisionVisible)
        // close 169→180 修订：return20 = 180/149 − 1
        XCTAssertEqual(m["momentum.return20"]?.value, Decimal(string: "0.208053691275"))
        XCTAssertTrue(
            afterRevisionVisible.sourceObservationIDs.contains(ObservationID(rawValue: "a69_v2")),
            "可见后 v2 进入 provenance"
        )
        XCTAssertFalse(
            afterRevisionVisible.sourceObservationIDs.contains(ObservationID(rawValue: "a69_v1")),
            "同 effectiveAt 旧 vintage 被择优淘汰，不双计"
        )
    }

    func testBenchmarkRevisionRespectsPITToo() {
        let repo = makeRepo(count: 70)
        repo.upsert(bar(
            id: "bm69_v2", listing: benchmarkListing, index: 69, close: 300,
            availableFrom: 74, publisherVersion: 2
        ))

        // asOf day 69：benchmark 修订不可见 → RS 与基线一致
        let baseline = snapshot(makeRepo(count: 70), asOfDay: 69)
        XCTAssertEqual(snapshot(repo, asOfDay: 69), baseline)

        // asOf day 75：benchmark close 300 → benchRet20 = 300/249 − 1，
        // RS = 20/149 − 51/249 = −2619/37101 = −0.070591089189...
        let m = metricMap(snapshot(repo, asOfDay: 75))
        XCTAssertEqual(m["relativeStrength.vsBenchmark20"]?.value, Decimal(string: "-0.070591089189"))
    }

    // MARK: - 4. 未来数据不泄漏（截断 repo 等价）

    func testFutureBarsDoNotLeakIntoHistoricalAsOf() {
        let fullRepo = makeRepo(count: 70)
        let prefixRepo = makeRepo(count: 55)   // 只有前 55 根（day 0..54）

        // 同一 asOf（day 54）：完整库的未来 15 根 bar 不可见 → 两库信息集相同
        let fromFull = snapshot(fullRepo, asOfDay: 54)
        let fromPrefix = snapshot(prefixRepo, asOfDay: 54)
        XCTAssertEqual(fromFull, fromPrefix, "信息集相同 → 因子相同（未来数据不泄漏）")
        XCTAssertEqual(fromFull.assetCoverage.barCount, 55)

        // 再抽一个 asOf（day 30）验证滚动一致性
        let fromFull30 = snapshot(fullRepo, asOfDay: 30)
        let fromPrefix30 = snapshot(makeRepo(count: 31), asOfDay: 30)
        XCTAssertEqual(fromFull30, fromPrefix30)
    }

    // MARK: - 5. volatility 跨运行一致（确定性 sqrt）

    func testVolatilityDeterministicAcrossRuns() {
        let repo = makeRepo(count: 70)
        let v1 = metricMap(snapshot(repo, asOfDay: 69))["volatility.realized20"]?.value
        let v2 = metricMap(snapshot(repo, asOfDay: 69))["volatility.realized20"]?.value
        XCTAssertEqual(v1, v2)
        // 独立引擎实例（同 definition 集合 → 同 factorVersion）
        let otherEngine = makeEngine()
        let v3 = metricMap(otherEngine.snapshot(
            listingID: assetListing,
            asOf: day(69).addingTimeInterval(16 * 3600),
            repository: repo,
            benchmarkListingID: benchmarkListing,
            producedAt: day(69).addingTimeInterval(16 * 3600)
        ))["volatility.realized20"]?.value
        XCTAssertEqual(v1, v3)
    }
}
