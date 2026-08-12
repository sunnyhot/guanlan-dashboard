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
            dataQuality: .from(.officialStable), vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable), vintage: v2,
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
                dataQuality: .from(.officialStable), vintage: vintage,
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
            dataQuality: .from(.officialStable), vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2),
            availabilityProvenance: AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: eff),
            dataQuality: .from(.officialStable), vintage: v2,
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
}
