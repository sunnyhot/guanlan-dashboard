import XCTest
@testable import QiemanDashboard

/// 审查 P1 修复的回归测试。
///
/// 验证：
/// - economic/operational 查询每 (canonicalID, effectiveAt) 只返最新 vintage
///   （不再泄漏旧 vintage 到时间序列，审查 P1）
/// - exactSnapshot 仍返回全部 vintage
/// - resolve 拒绝 fuzzyCandidate（防火墙 1，审查 P1）
final class RepositorySemanticsFixTests: XCTestCase {

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return w >= 2 && w <= 6
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date; var remaining = max(offset, 0); var safety = 0
            while remaining > 0 && safety < 14 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
                safety += 1
            }
            return current
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return cal.startOfDay(for: date)
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private func makeRepo() -> InMemoryRepository { InMemoryRepository(calendarBackend: WeekdayCalendar()) }

    private func price(_ v: Decimal) -> Price { Price(value: v, currency: .cny) }

    // MARK: - economic 查询不泄漏旧 vintage（审查 P1 核心）

    func testEconomicKnowledge_returnsOnlyLatestVintagePerDay() {
        // 同一 effectiveAt 的 v1（原版 close=100）+ v2（修订 close=102）
        let repo = makeRepo()
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff, publishedAt: v.announcementDate,
                availableAt: v.announcementDate, ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: false, isSuperseded: true),
            vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: true, isSuperseded: false),
            vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        // economicKnowledge(asOf: 9-01)：只返回 1 条（v2，最新 vintage），不含 v1
        let econ = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        XCTAssertEqual(econ.count, 1, "economicKnowledge 应只返回最新 vintage，不应泄漏旧 vintage")
        XCTAssertEqual(econ.first?.id, ObservationID(rawValue: "v2"))
        XCTAssertEqual(econ.first?.rawClose.value, 102)
    }

    func testOperationalKnowledge_alsoDeduplicatesVintage() {
        let repo = makeRepo()
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff, publishedAt: v.announcementDate,
                availableAt: v.announcementDate, ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: false, isSuperseded: true),
            vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: true, isSuperseded: false),
            vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        let oper = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .operationalKnowledge(asOf: date(2024, 9, 1))
        )
        XCTAssertEqual(oper.count, 1)
        XCTAssertEqual(oper.first?.id, ObservationID(rawValue: "v2"))
    }

    func testExactSnapshot_stillReturnsAllVintages() {
        // exactSnapshot 行为不变：返回该 effectiveAt 的全部 vintage
        let repo = makeRepo()
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff, publishedAt: v.announcementDate,
                availableAt: v.announcementDate, ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable, providerID: .stooq), vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable, providerID: .stooq), vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        let snaps = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .exactSnapshot(at: eff)
        )
        XCTAssertEqual(snaps.count, 2, "exactSnapshot 应返回全部 vintage")
    }

    func testEconomicKnowledge_multiDaySeries_dedupPerDay() {
        // 多日序列：每天各自有 v1/v2 修订，economicKnowledge 应每天只返最新
        let repo = makeRepo()
        let day1 = date(2024, 7, 18)
        let day2 = date(2024, 7, 19)
        let mkBar: (Date, Vintage, Decimal) -> DailyBar = { day, vintage, close in
            DailyBar(
                id: ObservationID(rawValue: "bar_\(Int(day.timeIntervalSince1970))_v\(vintage.publisherVersion)"),
                listingID: ListingID(rawValue: "L"),
                temporalEnvelope: TemporalEnvelope(
                    effectiveAt: day, publishedAt: vintage.announcementDate,
                    availableAt: vintage.announcementDate, ingestedAt: vintage.announcementDate
                ),
                availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: day),
                dataQuality: .from(.officialStable, providerID: .stooq), vintage: vintage,
                rawOpen: Price(value: close, currency: .cny),
                rawHigh: Price(value: close, currency: .cny),
                rawLow: Price(value: close, currency: .cny),
                rawClose: Price(value: close, currency: .cny),
                volume: 1000, adjustmentFactor: 1.0
            )
        }
        repo.upsert(mkBar(day1, Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1), 100))
        repo.upsert(mkBar(day1, Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1), 101))
        repo.upsert(mkBar(day2, Vintage(announcementDate: date(2024, 7, 21), publisherVersion: 1), 105))
        repo.upsert(mkBar(day2, Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1), 106))

        let econ = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        // 2 天，每天只取最新 vintage → 2 条
        XCTAssertEqual(econ.count, 2)
        XCTAssertEqual(econ[0].temporalEnvelope.effectiveAt, day1)
        XCTAssertEqual(econ[0].rawClose.value, 101)   // day1 v2
        XCTAssertEqual(econ[1].temporalEnvelope.effectiveAt, day2)
        XCTAssertEqual(econ[1].rawClose.value, 106)   // day2 v2
    }

    func testVintageFilter_returnsOnlyMatchingVintage() {
        // 指定 vintageFilter 时只返回那一条
        let repo = makeRepo()
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff, publishedAt: v.announcementDate,
                availableAt: v.announcementDate, ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable, providerID: .stooq), vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable, providerID: .stooq), vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        let filtered = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: KnowledgeContext(mode: .economicKnowledge(asOf: date(2024, 9, 1)), vintageFilter: v1)
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.vintage, v1)   // 强制取 v1，而非最新 v2
    }

    // MARK: - resolve 拒绝 fuzzyCandidate（防火墙 1，审查 P1）

    func testResolve_rejectsFuzzyCandidate() {
        // fuzzyCandidate 登记后，resolve 必须返回 nil（不绕过 Verification）
        let repo = makeRepo()
        let fuzzyPID = ProviderIdentifier(
            providerID: .akshare, identifierScheme: "name_match", identifierValue: "茅台",
            canonical: .listing(ListingID(rawValue: "list_600519")),
            resolutionMethod: .fuzzyCandidate,   // 非 authoritative
            resolvedAt: Date()
        )
        repo.upsert(fuzzyPID)

        // Repository.resolve 必须拒绝 fuzzy
        XCTAssertNil(repo.resolve(providerID: .akshare, scheme: "name_match", value: "茅台"),
                     "resolve 必须拒绝 fuzzyCandidate，不能绕过 Verification 防火墙")
    }

    func testResolve_acceptsAuthoritative() {
        let repo = makeRepo()
        let verified = ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_code", identifierValue: "110022",
            canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")),
            resolutionMethod: .manualVerified,   // authoritative
            resolvedAt: Date()
        )
        repo.upsert(verified)
        XCTAssertEqual(
            repo.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022"),
            .fundShareClass(FundShareClassID(rawValue: "sc_110022_A"))
        )
    }

    // MARK: - upsert 幂等（审查 P2 修复点）

    func testUpsert_listing_isIdempotent() {
        // 同一 listing 多次 upsert 不应在 instrumentsToListings 索引产生重复
        let repo = makeRepo()
        let listing = Listing(
            id: ListingID(rawValue: "list_x"),
            instrumentID: InstrumentID(rawValue: "inst_x"),
            exchange: .sse, symbol: "X", tradingCurrency: .cny
        )
        repo.upsert(listing)
        repo.upsert(listing)
        repo.upsert(listing)

        XCTAssertEqual(repo.listings(forInstrument: InstrumentID(rawValue: "inst_x")).count, 1)
    }

    func testUpsert_observation_isIdempotent() {
        // 同一 observation（同 id）多次 upsert 应替换而非追加
        let repo = makeRepo()
        let d718 = date(2024, 7, 18)
        let d719 = date(2024, 7, 19)
        let env = TemporalEnvelope(
            effectiveAt: d718, publishedAt: d718,
            availableAt: d719, ingestedAt: d719
        )
        let p = { (v: Decimal) -> Price in Price(value: v, currency: .cny) }
        let mkBar: (Decimal) -> DailyBar = { close in
            DailyBar(
                id: ObservationID(rawValue: "bar_1"),   // 固定 id
                listingID: ListingID(rawValue: "L"),
                temporalEnvelope: env,
                availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: d718),
                dataQuality: .from(.officialStable, providerID: .stooq),
                vintage: Vintage(announcementDate: d719, publisherVersion: 1),
                rawOpen: p(100), rawHigh: p(101), rawLow: p(99), rawClose: p(close),
                volume: 1000, adjustmentFactor: 1.0
            )
        }
        repo.upsert(mkBar(100))
        repo.upsert(mkBar(101))   // 同 id，应替换
        repo.upsert(mkBar(102))   // 同 id，应替换

        let bars = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        XCTAssertEqual(bars.count, 1, "同 id observation 多次 upsert 应替换，不应追加")
        XCTAssertEqual(bars.first?.rawClose.value, 102)   // 最后一次的值
    }

    func testUpsert_fixtureReloadDoesNotDuplicate() throws {
        // 重复加载 fixture 不应产生重复条目（REPO-3 fixture 多次 load 的幂等性）
        let bundle = Bundle.module
        let loadOnce = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider", calendarBackend: WeekdayCalendar(), bundle: bundle
        )
        // 再加载一次到同一 repo
        let fixtureData = try Data(contentsOf: bundle.url(
            forResource: "v2-identity-cross-provider", withExtension: "json", subdirectory: "Fixtures"
        )!)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fixture = try decoder.decode(RepositoryFixture.self, from: fixtureData)
        loadOnce.load(fixture)

        // instruments 不应有重复（按 id 字典天然去重）
        XCTAssertNotNil(loadOnce.instrument(InstrumentID(rawValue: "inst_110022")))
        // listings forInstrument 不应有重复条目
        let listings = loadOnce.listings(forInstrument: InstrumentID(rawValue: "inst_600519"))
        XCTAssertEqual(listings.count, 1, "重复加载 fixture 不应在 instrumentsToListings 索引产生重复")
    }
}
