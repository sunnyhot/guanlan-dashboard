import XCTest
@testable import QiemanDashboard

/// REPO-2 单元测试：InMemoryRepository 的 PIT 过滤 + multi-vintage 语义。
///
/// 重点验证 ADR-DATA002 三种 query mode + ADR-DATA008 vintage 排序。
final class InMemoryRepositoryTests: XCTestCase {

    // 桩日历：周一周五交易日，tradingDay(after:offset:) 跳周末
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

    private func makeRepo() -> InMemoryRepository { InMemoryRepository(calendarBackend: WeekdayCalendar()) }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    // MARK: - Identity 域

    func testInstrumentRepository_basicLookup() {
        let repo = makeRepo()
        let instrument = Instrument(
            id: InstrumentID(rawValue: "inst_600519"),
            issuerID: LegalEntityID(rawValue: "ent_kweichow"),
            kind: .stock, displayName: "贵州茅台",
            baseCurrency: .cny, assetClass: .equity
        )
        let listing = Listing(
            id: ListingID(rawValue: "list_sh600519"),
            instrumentID: instrument.id,
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
        )
        repo.upsert(instrument).upsert(listing)

        XCTAssertEqual(repo.instrument(instrument.id)?.displayName, "贵州茅台")
        XCTAssertEqual(repo.listing(listing.id)?.symbol, "600519")
        XCTAssertEqual(repo.listings(forInstrument: instrument.id).count, 1)
        XCTAssertNil(repo.instrument(InstrumentID(rawValue: "inst_missing")))
    }

    func testResolve_returnsCanonicalRef() {
        let repo = makeRepo()
        let shareClassID = FundShareClassID(rawValue: "sc_110022_A")
        let pid = ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_code",
            identifierValue: "110022",
            canonical: .fundShareClass(shareClassID),
            resolutionMethod: .manualVerified,
            resolvedAt: date(2024, 7, 1)
        )
        repo.upsert(pid)

        let resolved = repo.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022")
        XCTAssertEqual(resolved, .fundShareClass(shareClassID))
        XCTAssertNil(repo.resolve(providerID: .qieman, scheme: "prodCode", value: "missing"))
    }

    // MARK: - DailyBar PIT 三模式（REPO-2 核心）

    func testDailyBars_economicKnowledge_filtersByAvailableAt() {
        let repo = makeRepo()
        // 7-18 NAV：effectiveAt=7-18, publishedAt=7-18, availableAt=7-19, ingestedAt=7-19
        let env1 = TemporalEnvelope(
            effectiveAt: date(2024, 7, 18), publishedAt: date(2024, 7, 18),
            availableAt: date(2024, 7, 19), ingestedAt: date(2024, 7, 19)
        )
        // 7-19 NAV：availableAt=7-22（次交易日），ingestedAt=7-22
        let env2 = TemporalEnvelope(
            effectiveAt: date(2024, 7, 19), publishedAt: date(2024, 7, 19),
            availableAt: date(2024, 7, 22), ingestedAt: date(2024, 7, 22)
        )
        let price = { Price(value: $0, currency: .cny) }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "b1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: env1, availabilityProvenance: makeProv(),
            dataQuality: .from(.officialStable),
            vintage: Vintage(announcementDate: date(2024, 7, 18), publisherVersion: 1),
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        )).upsert(DailyBar(
            id: ObservationID(rawValue: "b2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: env2, availabilityProvenance: makeProv(),
            dataQuality: .from(.officialStable),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1),
            rawOpen: price(105), rawHigh: price(106), rawLow: price(104), rawClose: price(105),
            volume: 1100, adjustmentFactor: 1.0
        ))

        // economicKnowledge(asOf: 7-19)：availableAt ≤ 7-19 → 只含 7-18 bar
        let at719 = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 7, 19))
        )
        XCTAssertEqual(at719.count, 1)
        XCTAssertEqual(at719.first?.id, ObservationID(rawValue: "b1"))

        // economicKnowledge(asOf: 7-22)：含两条
        let at722 = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 7, 22))
        )
        XCTAssertEqual(at722.count, 2)
    }

    func testDailyBars_operationalKnowledge_requiresIngestedAt() {
        let repo = makeRepo()
        // 7-19 NAV：availableAt=7-22，但 ingestedAt=8-01（Provider 故障延迟）
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 7, 19), publishedAt: date(2024, 7, 19),
            availableAt: date(2024, 7, 22), ingestedAt: date(2024, 8, 1)
        )
        let price = { Price(value: $0, currency: .cny) }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "b1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: env, availabilityProvenance: makeProv(),
            dataQuality: .from(.officialStable),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1),
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        ))

        // economicKnowledge(asOf: 7-22)：availableAt 7-22 ≤ 7-22 → 含
        let econ = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .economicKnowledge(asOf: date(2024, 7, 22))
        )
        XCTAssertEqual(econ.count, 1)

        // operationalKnowledge(asOf: 7-22)：ingestedAt 8-01 > 7-22 → 排除
        let oper = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .operationalKnowledge(asOf: date(2024, 7, 22))
        )
        XCTAssertEqual(oper.count, 0)

        // operationalKnowledge(asOf: 8-01)：两条件都满足 → 含
        let operAug = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .operationalKnowledge(asOf: date(2024, 8, 1))
        )
        XCTAssertEqual(operAug.count, 1)
    }

    func testDailyBars_exactSnapshot_returnsAllVintages() {
        let repo = makeRepo()
        // 同一 effectiveAt 的两个 vintage（v1 原始 + v2 修订）
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let price = { Price(value: $0, currency: .cny) }
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff,
                publishedAt: v.announcementDate,
                availableAt: v.announcementDate,
                ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1), availabilityProvenance: makeProv(),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: false, isSuperseded: true),
            vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        )).upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2), availabilityProvenance: makeProv(),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: true, isSuperseded: false),
            vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        // exactSnapshot(at: 7-18)：返回 effectiveAt == 7-18 的所有 vintage（2 条）
        let snaps = repo.dailyBars(
            listingID: ListingID(rawValue: "L"),
            context: .exactSnapshot(at: eff)
        )
        XCTAssertEqual(snaps.count, 2)
    }

    func testDailyBar_singlePoint_picksLatestVintage() {
        let repo = makeRepo()
        let eff = date(2024, 7, 18)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        let price = { Price(value: $0, currency: .cny) }
        let mkEnv: (Vintage) -> TemporalEnvelope = { v in
            TemporalEnvelope(
                effectiveAt: eff, publishedAt: v.announcementDate,
                availableAt: v.announcementDate, ingestedAt: v.announcementDate
            )
        }
        repo.upsert(DailyBar(
            id: ObservationID(rawValue: "v1"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v1), availabilityProvenance: makeProv(),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: false, isSuperseded: true),
            vintage: v1,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(100),
            volume: 1000, adjustmentFactor: 1.0
        )).upsert(DailyBar(
            id: ObservationID(rawValue: "v2"), listingID: ListingID(rawValue: "L"),
            temporalEnvelope: mkEnv(v2), availabilityProvenance: makeProv(),
            dataQuality: DataQuality(providerReliability: .officialStable, isRevised: true, isSuperseded: false),
            vintage: v2,
            rawOpen: price(100), rawHigh: price(101), rawLow: price(99), rawClose: price(102),
            volume: 1000, adjustmentFactor: 1.0
        ))

        // economicKnowledge(asOf: 9-01) 应能看到 v1 + v2，单点查询取最新 vintage（v2）
        let bar = repo.dailyBar(
            listingID: ListingID(rawValue: "L"),
            on: eff,
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        XCTAssertEqual(bar?.id, ObservationID(rawValue: "v2"))
        XCTAssertEqual(bar?.rawClose.value, 102)   // 修订后值
    }

    // MARK: - FundHolding（multi-vintage 必备，M2 场景 5 预演）

    func testHoldingSnapshot_revisionSupersedesButHistoricalQuerySeesV1() {
        let repo = makeRepo()
        // Q2 持仓：v1 在 7-20 公告，v2 在 8-15 修订
        let productID = FundProductID(rawValue: "prod_110022")
        let eff = date(2024, 6, 30)
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)

        let mkSnap: (Vintage, Decimal) -> FundHoldingSnapshot = { vintage, total in
            FundHoldingSnapshot(
                id: ObservationID(rawValue: "snap_\(vintage.publisherVersion)"),
                productID: productID,
                temporalEnvelope: TemporalEnvelope(
                    effectiveAt: eff, publishedAt: vintage.announcementDate,
                    availableAt: vintage.announcementDate, ingestedAt: vintage.announcementDate
                ),
                availabilityProvenance: AvailabilityProvenance(
                    policyID: "fund_disclosure", policyVersion: "v1", derivedAt: Date()
                ),
                dataQuality: DataQuality(
                    providerReliability: .communityAggregated,
                    isRevised: vintage.publisherVersion > 1,
                    isSuperseded: false
                ),
                vintage: vintage,
                reportPeriod: .q2,
                positions: [],
                disclosedWeightTotal: Ratio(value: total)
            )
        }
        repo.upsert(mkSnap(v1, 0.45)).upsert(mkSnap(v2, 0.48))

        // M2 场景 5：economicKnowledge(asOf: 8-01) 应只看到 v1（v2 availableAt=8-15 > 8-01）
        let at801 = repo.holdingSnapshots(
            productID: productID,
            context: .economicKnowledge(asOf: date(2024, 8, 1))
        )
        XCTAssertEqual(at801.count, 1)
        XCTAssertEqual(at801.first?.disclosedWeightTotal.value, 0.45)   // v1 原始值

        // economicKnowledge(asOf: 9-01) 看到 v1 + v2，latest 取 effectiveAt 最新
        let at901 = repo.latestHoldingSnapshot(
            productID: productID,
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        // effectiveAt 都是 6-30，取 vintage 最新
        XCTAssertEqual(at901?.disclosedWeightTotal.value, 0.48)   // v2 修订值
    }

    // MARK: - Calendar

    func testCalendar_isTradingDay() {
        let repo = makeRepo()
        XCTAssertTrue(repo.isTradingDay(date(2024, 7, 22), jurisdiction: .chinaMainland))   // 周一
        XCTAssertFalse(repo.isTradingDay(date(2024, 7, 20), jurisdiction: .chinaMainland))  // 周六
    }

    func testCalendar_tradingDayAfterOffset() {
        let repo = makeRepo()
        // 7-19 周五 + offset 1 → 7-22 周一
        let next = repo.tradingDay(after: date(2024, 7, 19), offset: 1, jurisdiction: .chinaMainland)
        XCTAssertEqual(repo.tradingDayStart(next, jurisdiction: .chinaMainland), date(2024, 7, 22))
    }

    // MARK: - 空数据返回空（不返回默认值，ADR-DATA006）

    func testEmptyData_returnsEmpty_notDefault() {
        let repo = makeRepo()
        let empty = repo.dailyBars(
            listingID: ListingID(rawValue: "missing"),
            context: .economicKnowledge(asOf: Date())
        )
        XCTAssertEqual(empty.count, 0)   // 空，不是默认 bar
        XCTAssertNil(repo.dailyBar(
            listingID: ListingID(rawValue: "missing"),
            on: Date(), context: .economicKnowledge(asOf: Date())
        ))
        XCTAssertNil(repo.latestHoldingSnapshot(
            productID: FundProductID(rawValue: "missing"),
            context: .economicKnowledge(asOf: Date())
        ))
    }

    // MARK: - Provider 映射稳定 key（防火墙 1 入口）

    func testProviderKey_stableAndUnique() {
        let k1 = InMemoryRepository.providerKey(.eastmoney, scheme: "fund_code", value: "110022")
        let k2 = InMemoryRepository.providerKey(.qieman, scheme: "fund_code", value: "110022")
        let k3 = InMemoryRepository.providerKey(.eastmoney, scheme: "fund_code", value: "110022")
        XCTAssertEqual(k1, "eastmoney::fund_code::110022")
        XCTAssertNotEqual(k1, k2)   // 不同 provider 不冲突
        XCTAssertEqual(k1, k3)      // 相同入参稳定
    }

    // MARK: - 辅助

    private func makeProv() -> AvailabilityProvenance {
        AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: Date())
    }
}
