import XCTest
@testable import QiemanDashboard

/// REPO-8 + M2 验收测试（★ go/no-go，rollout §4.1）。
///
/// M2 是整个项目最关键的验收。五个场景必须全过：
/// 1. 同一基金在 Qieman 和天天基金代码不同 → 解析到同一 InstrumentID
/// 2. 同一股票在两个 Provider symbol 不同 → 解析到同一 ListingID
/// 3. 基金 Q2 持仓 7-20 公告 → economicKnowledge(asOf: 7-10) 查不到
/// 4. Provider 故障延迟到 8-01 抓到 → availableAt=7-22（客观）、
///    ingestedAt=8-01；economicKnowledge(asOf: 7-22) 可见、
///    operationalKnowledge(asOf: 7-22) 不可见
/// 5. 模拟一次 data revision（v1→v2）→ 历史 vintage 查询仍看到 v1
///
/// M2 不过不进 Epic 5（GRDB schema 冻结）。
final class M2AcceptanceTests: XCTestCase {

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

    private let calendar = WeekdayCalendar()
    private let normalizer = TemporalNormalizer(calendar: WeekdayCalendar())

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    // MARK: - M2 场景 1：基金跨 Provider 同一 InstrumentID

    func testM2Scenario1_fundCrossProviderSameCanonical() throws {
        // 加载 fixture（含 eastmoney + qieman → 同一 FundShareClass 的映射）
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: calendar,
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        // 天天基金用 "110022"（fund_code 体系）
        let em = resolver.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022")
        // 且慢用 "CONSUMER_STOCK"（prodCode 体系）
        let qm = resolver.resolve(providerID: .qieman, scheme: "prodCode", value: "CONSUMER_STOCK")

        guard case .resolved(let emRef, _) = em, case .resolved(let qmRef, _) = qm else {
            XCTFail("两个 Provider 都应解析成功"); return
        }
        // 期望：解析到同一 Canonical（FundShareClass）
        XCTAssertEqual(emRef, qmRef)
        XCTAssertEqual(emRef, .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")))
        // 背后的 ShareClass / Product / Instrument 可查
        XCTAssertEqual(repo.fundShareClass(FundShareClassID(rawValue: "sc_110022_A"))?.shareClassCode, "A")
        XCTAssertEqual(repo.fundProduct(FundProductID(rawValue: "prod_110022"))?.displayName, "易方达消费行业股票")
    }

    // MARK: - M2 场景 2：股票跨 Provider 同一 ListingID

    func testM2Scenario2_stockCrossProviderSameListing() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: calendar,
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        // 天天基金体系用 "600519"（stock_symbol）
        let em = resolver.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519")
        // Stooq 用 "600519.SS"
        let sq = resolver.resolve(providerID: .stooq, scheme: "stock_symbol", value: "600519.SS")

        guard case .resolved(let emRef, _) = em, case .resolved(let sqRef, _) = sq else {
            XCTFail("两个 Provider 都应解析成功"); return
        }
        // 期望：解析到同一 Listing
        XCTAssertEqual(emRef, sqRef)
        XCTAssertEqual(emRef, .listing(ListingID(rawValue: "list_sh600519")))
    }

    // MARK: - M2 场景 3：基金 Q2 持仓 7-22 才可知，7-10 查不到

    func testM2Scenario3_fundQ2HoldingNotVisibleAt710() {
        // TemporalNormalizer + DataQueryMode 联动验证 PIT
        let result = normalizer.normalizeFundDisclosure(
            effectiveAt: date(2024, 6, 30),     // Q2 报告期
            publishedAt: date(2024, 7, 20),     // 公告日（周六）
            ingestedAt: date(2024, 7, 22),      // 当日抓到
            jurisdiction: .chinaMainland
        )!
        // availableAt = nextTradingDay(7-20) = 7-22（周一）
        XCTAssertEqual(result.envelope.availableAt, date(2024, 7, 22))

        // economicKnowledge(asOf: 7-10) 必须查不到（防 lookahead bias）
        let mode = DataQueryMode.economicKnowledge(asOf: date(2024, 7, 10))
        XCTAssertFalse(mode.includes(envelope: result.envelope))

        // economicKnowledge(asOf: 7-22) 应可见
        XCTAssertTrue(DataQueryMode.economicKnowledge(asOf: date(2024, 7, 22)).includes(envelope: result.envelope))
    }

    // MARK: - M2 场景 4：Provider 故障 ingestedAt ≠ availableAt

    func testM2Scenario4_providerDelayObjectiveVsOperational() {
        let result = normalizer.normalizeFundDisclosure(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 8, 1),       // Provider 故障延迟
            jurisdiction: .chinaMainland
        )!
        // availableAt 仍记客观可知 = 7-22（不受 ingestedAt 影响）
        XCTAssertEqual(result.envelope.availableAt, date(2024, 7, 22))
        XCTAssertEqual(result.envelope.ingestedAt, date(2024, 8, 1))
        XCTAssertNotEqual(result.envelope.availableAt, result.envelope.ingestedAt)

        // economicKnowledge(asOf: 7-22) 可见（客观可知即可）
        XCTAssertTrue(DataQueryMode.economicKnowledge(asOf: date(2024, 7, 22)).includes(envelope: result.envelope))
        // operationalKnowledge(asOf: 7-22) 不可见（本机还没抓到）
        XCTAssertFalse(DataQueryMode.operationalKnowledge(asOf: date(2024, 7, 22)).includes(envelope: result.envelope))
        // operationalKnowledge(asOf: 8-01) 可见（两条件都满足）
        XCTAssertTrue(DataQueryMode.operationalKnowledge(asOf: date(2024, 8, 1)).includes(envelope: result.envelope))
    }

    // MARK: - M2 场景 5：data revision v1→v2，历史 vintage 仍可查

    func testM2Scenario5_dataRevisionHistoricalVintagePreserved() {
        let repo = InMemoryRepository(calendarBackend: calendar)
        let productID = FundProductID(rawValue: "prod_110022")
        let eff = date(2024, 6, 30)

        // v1：7-20 公告（ingestedAt 也是 7-22，正常情况）
        let v1Env = normalizer.normalizeFundDisclosure(
            effectiveAt: eff, publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 7, 22), jurisdiction: .chinaMainland
        )!
        // v2：8-15 修订
        let v2Env = TemporalEnvelope(
            effectiveAt: eff,
            publishedAt: date(2024, 8, 15),
            availableAt: date(2024, 8, 16),    // nextTradingDay(8-15 周四) = 8-16 周五
            ingestedAt: date(2024, 8, 16)
        )

        repo.upsert(FundHoldingSnapshot(
            id: ObservationID(rawValue: "snap_v1"), productID: productID,
            temporalEnvelope: v1Env.envelope,
            availabilityProvenance: v1Env.provenance,
            dataQuality: DataQuality(providerReliability: .communityAggregated, isRevised: false, isSuperseded: true),
            vintage: Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1),
            reportPeriod: .q2, positions: [],
            disclosedWeightTotal: Ratio(value: 0.45)
        ))
        repo.upsert(FundHoldingSnapshot(
            id: ObservationID(rawValue: "snap_v2"), productID: productID,
            temporalEnvelope: v2Env,
            availabilityProvenance: AvailabilityProvenance(policyID: "fund_disclosure", policyVersion: "v1", derivedAt: date(2024, 8, 16)),
            dataQuality: DataQuality(providerReliability: .communityAggregated, isRevised: true, isSuperseded: false),
            vintage: Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1),
            reportPeriod: .q2, positions: [],
            disclosedWeightTotal: Ratio(value: 0.48)
        ))

        // economicKnowledge(asOf: 8-01) 只看到 v1（v2 availableAt=8-16 > 8-01）
        let at801 = repo.holdingSnapshots(
            productID: productID,
            context: .economicKnowledge(asOf: date(2024, 8, 1))
        )
        XCTAssertEqual(at801.count, 1)
        XCTAssertEqual(at801.first?.disclosedWeightTotal.value, 0.45)   // v1 原始值

        // economicKnowledge(asOf: 9-01) 看到 v1 + v2，latest 取 vintage 最新
        let latest = repo.latestHoldingSnapshot(
            productID: productID,
            context: .economicKnowledge(asOf: date(2024, 9, 1))
        )
        XCTAssertEqual(latest?.disclosedWeightTotal.value, 0.48)   // v2 修订值

        // exactSnapshot(at: 6-30) 返回两个 vintage
        let allVintages = repo.holdingSnapshots(
            productID: productID,
            context: .exactSnapshot(at: eff)
        )
        XCTAssertEqual(allVintages.count, 2)
    }

    // MARK: - M2 验收：5 场景全过

    func testM2_allScenariosPass() throws {
        // 这是 M2 go/no-go 的整体断言：所有 5 个场景都必须通过。
        // 若任一场景失败，不应进 Epic 5（GRDB schema 冻结，ADR-DATA009）。
        // 实际场景由上面 5 个 testM2Scenario* 分别覆盖，这里只做汇总断言。
        try testM2Scenario1_fundCrossProviderSameCanonical()
        try testM2Scenario2_stockCrossProviderSameListing()
        testM2Scenario3_fundQ2HoldingNotVisibleAt710()
        testM2Scenario4_providerDelayObjectiveVsOperational()
        testM2Scenario5_dataRevisionHistoricalVintagePreserved()
        // 全过即 M2 通过
    }
}

// MARK: - REPO-6/7 Provider Adapter 桩测试

final class ProviderAdapterTests: XCTestCase {

    func testQiemanProviderAdapter_stubReturnsFilteredRecords() async throws {
        let stub = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "SI000192"),
            effectiveAt: Date(timeIntervalSince1970: 1_720_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000),
            kind: .navObservation,
            rawPayload: Data(),
            reliabilityClass: .undocumentedPublicEndpoint,
            jurisdiction: .chinaMainland
        )
        let adapter = QiemanProviderAdapter(stubRecords: [stub])

        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "prodCode", value: "SI000192"),
            from: Date(timeIntervalSince1970: 1_719_000_000),
            to: Date(timeIntervalSince1970: 1_721_000_000)
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.providerID, .qieman)
        XCTAssertEqual(records.first?.kind, .navObservation)
    }

    func testEastmoneyProviderAdapter_stubFiltersByCode() async throws {
        let r1 = ProviderRecord(
            providerID: .eastmoney, providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: Date(timeIntervalSince1970: 1_720_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000),
            kind: .navObservation, rawPayload: Data(),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
        let r2 = ProviderRecord(
            providerID: .eastmoney, providerCode: ProviderCode(scheme: "fund_code", value: "110023"),
            effectiveAt: Date(timeIntervalSince1970: 1_720_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000),
            kind: .navObservation, rawPayload: Data(),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
        let adapter = EastmoneyProviderAdapter(stubRecords: [r1, r2])

        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 1_719_000_000),
            to: Date(timeIntervalSince1970: 1_721_000_000)
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.providerCode.value, "110022")
    }

    func testProviderRecord_doesNotContainAvailableAt() {
        // ProviderRecord 不含 availableAt（由 TemporalNormalizer 推导，ADR-DATA005）
        let record = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "X"),
            effectiveAt: Date(), publishedAt: Date(),
            kind: .navObservation, rawPayload: Data(),
            reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland
        )
        // Mirror 反射：字段名不应含 availableAt
        let fieldNames = Mirror(reflecting: record).children.compactMap(\.label)
        XCTAssertFalse(fieldNames.contains("availableAt"),
                       "ProviderRecord 不应含 availableAt（由 TemporalNormalizer 推导）")
        XCTAssertTrue(fieldNames.contains("effectiveAt"))
        XCTAssertTrue(fieldNames.contains("publishedAt"))
    }

    func testProviderAdapterProtocol_reliabilityClass() {
        // 每个 Adapter 声明 reliabilityClass（ADR-DATA006）
        XCTAssertEqual(QiemanProviderAdapter().reliabilityClass, .undocumentedPublicEndpoint)
        XCTAssertEqual(EastmoneyProviderAdapter().reliabilityClass, .communityAggregated)
    }
}
