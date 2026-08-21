import XCTest
@testable import QiemanDashboard

/// REPO-1b 单元测试：FundamentalObservation 类型 + FundamentalRepository 第八域
/// + ObservationFactory fundamentalFact 转换链（SEC 记录 → Canonical 端到端）。
///
/// 样本复用 PROV-4 的真实 wire 格式（FakeSECClient 同款 JSON，离线）；
/// identity 映射 `sec → sec_cik → LegalEntity` 按 SYNC-8 建立后的形态登记。
final class FundamentalRepositoryTests: XCTestCase {

    private let ingested = Date(timeIntervalSince1970: 1_724_000_000)

    // MARK: - 测试基建

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let weekday = cal.component(.weekday, from: date)
            return weekday != 1 && weekday != 7
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var current = cal.startOfDay(for: date)
            var remaining = offset
            while remaining > 0 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    remaining -= 1
                }
            }
            return current
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.startOfDay(for: date)
        }
    }

    private func utcDay(_ yyyyMMdd: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: yyyyMMdd)!
    }

    private let appleEntity = LegalEntityID(rawValue: "ent_apple_0000320193")

    /// `sec → sec_cik → LegalEntity` 映射（SYNC-8 建立路径的 lookup 层形态）。
    private var secCikIdentifier: ProviderIdentifier {
        ProviderIdentifier(
            providerID: .sec,
            identifierScheme: "sec_cik",
            identifierValue: "0000320193",
            canonical: .legalEntity(appleEntity),
            resolutionMethod: .isinOrCik,
            resolvedAt: utcDay("2026-08-21")
        )
    }

    private func makeFactory(
        identifiers: [ProviderIdentifier] = []
    ) -> ObservationFactory {
        ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()),
            resolver: IdentityResolver(identifiers: identifiers)
        )
    }

    /// revenue 10-Q 初报 + 10-K 修订（同期间 multi-vintage）+ netIncome + assets。
    private var companyFactsJSON: String {
        """
        {"cik":320193,"entityName":"Apple Inc","facts":{"us-gaap":{
          "RevenueFromContractWithCustomerExcludingAssessedTax":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":81418000000,
             "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-Q",
             "filed":"2023-08-04","frame":"CY2023Q2"},
            {"start":"2023-04-01","end":"2023-06-30","val":81497000000,
             "accn":"0000320193-23-000106","fy":2023,"fp":"Q3","form":"10-K","filed":"2023-11-03"}
          ]}},
          "NetIncomeLoss":{"units":{"USD":[
            {"start":"2023-04-01","end":"2023-06-30","val":19881000000,
             "form":"10-Q","filed":"2023-08-04"}
          ]}},
          "Assets":{"units":{"USD":[
            {"end":"2023-06-30","val":331613000000,"form":"10-Q","filed":"2023-08-04"}
          ]}}
        }}}
        """
    }

    /// 解析样本 → ProviderRecord（4 条：revenue×2 vintage + netIncome + assets）。
    private func makeRecords() throws -> [ProviderRecord] {
        let facts = try SECResponseParser().parseCompanyFacts(
            companyFactsJSON.data(using: .utf8)!
        )
        return SECResponseParser().toProviderRecords(
            facts, reliabilityClass: .officialStable, ingestedAt: ingested
        )
    }

    /// 记录 → Canonical 观测（调用方注入 identity 映射与 vintage 赋值策略）。
    ///
    /// ObservationID 含序号：同公司同日申报的多条事实（revenue/netIncome/assets
    /// 共享 effectiveAt+publishedAt+providerCode）必须各自有唯一 id，否则
    /// InMemory 的按 id upsert 会互相覆盖。
    private func makeObservations(
        records: [ProviderRecord],
        identifiers: [ProviderIdentifier]
    ) throws -> [FundamentalObservation] {
        let factory = makeFactory(identifiers: identifiers)
        return try records.enumerated().map { idx, record in
            let vintage = Vintage(announcementDate: record.publishedAt, publisherVersion: 1)
            let made = try factory.makeObservation(
                from: record,
                observationID: ObservationID(rawValue: "obs_fund_\(idx)_\(record.publishedAt.timeIntervalSince1970)"),
                vintage: vintage
            )
            guard case .fundamentalObservation(let obs) = made else {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "expected fundamentalObservation, got \(made)"])
            }
            return obs
        }
    }

    // MARK: - Codable round-trip（M1 验收模式）

    func testFundamentalObservation_codableRoundTrip() throws {
        let obs = FundamentalObservation(
            id: ObservationID(rawValue: "obs_f_1"),
            entityID: appleEntity,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: utcDay("2023-06-30"),
                publishedAt: utcDay("2023-08-04"),
                availableAt: utcDay("2023-08-07"),
                ingestedAt: ingested
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "filing_release", policyVersion: "v1", derivedAt: ingested
            ),
            dataQuality: DataQuality(
                providerReliability: .officialStable, sourceProviderID: .sec
            ),
            vintage: Vintage(announcementDate: utcDay("2023-08-04"), publisherVersion: 1),
            metricKey: "revenue",
            concept: "RevenueFromContractWithCustomerExcludingAssessedTax",
            value: Decimal(string: "81418000000")!,
            unit: "USD",
            periodStart: utcDay("2023-04-01"),
            periodEnd: utcDay("2023-06-30"),
            form: .form10Q,
            frame: "CY2023Q2",
            extractionMethod: .xbrlFact
        )
        let data = try JSONEncoder().encode(obs)
        let decoded = try JSONDecoder().decode(FundamentalObservation.self, from: data)
        XCTAssertEqual(decoded, obs)
    }

    // MARK: - ObservationFactory 转换链（REPO-1b 核心）

    func testFactory_convertsFundamentalFact_endToEnd() throws {
        let records = try makeRecords()
        XCTAssertEqual(records.count, 4)
        let observations = try makeObservations(
            records: records, identifiers: [secCikIdentifier]
        )
        XCTAssertEqual(observations.count, 4)
        for obs in observations {
            // 公共字段（全部 4 条一致）
            XCTAssertEqual(obs.entityID, appleEntity)
            XCTAssertEqual(obs.extractionMethod, .xbrlFact)
            XCTAssertEqual(obs.unit, "USD")
            XCTAssertEqual(obs.periodEnd, utcDay("2023-06-30"))
            XCTAssertEqual(obs.dataQuality.providerReliability, .officialStable)
            XCTAssertEqual(obs.dataQuality.sourceProviderID, .sec)
            // PIT：effectiveAt = 期间结束；availableAt = filed 次交易日（form/
            // publishedAt 随申报不同，逐行断言在下方）
            XCTAssertEqual(obs.temporalEnvelope.effectiveAt, utcDay("2023-06-30"))
            XCTAssertEqual(obs.availabilityProvenance.policyID, "filing_release")
            XCTAssertEqual(obs.availabilityProvenance.policyVersion, "v1")
        }
        // 字段级：流量项带 periodStart，时点项（Assets）periodStart == nil
        let revenue = observations.first { $0.metricKey == "revenue" && $0.value == Decimal(string: "81418000000") }
        XCTAssertNotNil(revenue)
        XCTAssertEqual(revenue?.periodStart, utcDay("2023-04-01"))
        XCTAssertEqual(revenue?.concept, "RevenueFromContractWithCustomerExcludingAssessedTax")
        XCTAssertEqual(revenue?.frame, "CY2023Q2")
        XCTAssertEqual(revenue?.form, .form10Q)
        XCTAssertEqual(revenue?.temporalEnvelope.publishedAt, utcDay("2023-08-04"))
        XCTAssertEqual(revenue?.temporalEnvelope.availableAt, utcDay("2023-08-07"))   // 08-04 周五 → 08-07 周一
        let assets = observations.first { $0.metricKey == "assets" }
        XCTAssertNotNil(assets)
        XCTAssertNil(assets?.periodStart)
        XCTAssertEqual(assets?.value, Decimal(string: "331613000000"))
        XCTAssertEqual(assets?.temporalEnvelope.availableAt, utcDay("2023-08-07"))
        // 10-K 修订行 form 映射
        let revised = observations.first { $0.value == Decimal(string: "81497000000") }
        XCTAssertEqual(revised?.form, .form10K)
        XCTAssertEqual(revised?.temporalEnvelope.publishedAt, utcDay("2023-11-03"))
        XCTAssertEqual(revised?.temporalEnvelope.availableAt, utcDay("2023-11-06"))   // 11-03 周五 → 11-06 周一
    }

    func testFactory_identityMustBeLegalEntity() throws {
        // sec_cik 映射到 Listing（错误维度）→ identityUnresolved 拒收
        let wrongDimension = ProviderIdentifier(
            providerID: .sec,
            identifierScheme: "sec_cik",
            identifierValue: "0000320193",
            canonical: .listing(ListingID(rawValue: "list_aapl")),
            resolutionMethod: .isinOrCik,
            resolvedAt: utcDay("2026-08-21")
        )
        let records = try makeRecords()
        XCTAssertThrowsError(
            try makeObservations(records: records, identifiers: [wrongDimension])
        ) { error in
            guard case ObservationFactoryError.identityUnresolved = error else {
                return XCTFail("expected identityUnresolved, got \(error)")
            }
        }
    }

    func testFactory_identityUnregisteredStillRejected() throws {
        // 未登记映射（SYNC-8 前的常态）→ 拒收，不静默落库
        let records = try makeRecords()
        XCTAssertThrowsError(
            try makeObservations(records: records, identifiers: [])
        ) { error in
            guard case ObservationFactoryError.identityUnresolved = error else {
                return XCTFail("expected identityUnresolved, got \(error)")
            }
        }
    }

    func testFactory_unknownFilingFormRejected() throws {
        // staging 可含任意来源记录：payload form 超出封闭 enum 范围 → 拒收
        let payload = FundamentalFactPayload(
            concept: "Revenues", metricKey: "revenue",
            value: Decimal(string: "1")!, unit: "USD",
            start: utcDay("2023-04-01"), end: utcDay("2023-06-30"),
            form: "8-K", frame: nil, extractionMethod: .xbrlFact
        )
        let record = ProviderRecord(
            providerID: .sec,
            providerCode: ProviderCode(scheme: "sec_cik", value: "0000320193"),
            effectiveAt: utcDay("2023-06-30"),
            publishedAt: utcDay("2023-08-04"),
            ingestedAt: ingested,
            kind: .fundamentalFact,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .officialStable,
            jurisdiction: .unitedStates
        )
        XCTAssertThrowsError(
            try makeFactory(identifiers: [secCikIdentifier]).makeObservation(
                from: record,
                observationID: ObservationID(rawValue: "obs_x"),
                vintage: Vintage(announcementDate: record.publishedAt, publisherVersion: 1)
            )
        ) { error in
            guard case ObservationFactoryError.payloadDecodeFailed = error else {
                return XCTFail("expected payloadDecodeFailed, got \(error)")
            }
        }
    }

    // MARK: - InMemoryRepository：第八域 PIT 语义

    private func makeRepo() throws -> InMemoryRepository {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        let observations = try makeObservations(
            records: try makeRecords(), identifiers: [secCikIdentifier]
        )
        observations.forEach { repo.upsert($0) }
        return repo
    }

    func testRepository_multiVintage_revisionTakesEffectEconomically() throws {
        let repo = try makeRepo()
        // 修订后（10-K 2023-11-03 filed）视角：revenue 只剩修订值 81.497B
        let afterRevision = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "revenue",
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertEqual(afterRevision.count, 1)
        XCTAssertEqual(afterRevision[0].value, Decimal(string: "81497000000")!)
        XCTAssertEqual(afterRevision[0].form, .form10K)

        // 初报后、修订前（08-07 ≤ asOf < 11-06）视角：还是初报值 81.418B
        let beforeRevision = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "revenue",
            context: .economicKnowledge(asOf: utcDay("2023-09-01"))
        )
        XCTAssertEqual(beforeRevision.count, 1)
        XCTAssertEqual(beforeRevision[0].value, Decimal(string: "81418000000")!)
        XCTAssertEqual(beforeRevision[0].form, .form10Q)

        // availableAt 前不可见（08-04 filed → 08-07 可知）
        let beforeAvailable = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "revenue",
            context: .economicKnowledge(asOf: utcDay("2023-08-05"))
        )
        XCTAssertTrue(beforeAvailable.isEmpty)

        // exactSnapshot：同期间两 vintage 全保留（ADR-DATA008）
        let all = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "revenue",
            context: .exactSnapshot(at: utcDay("2023-06-30"))
        )
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.value)), [
            Decimal(string: "81418000000")!, Decimal(string: "81497000000")!
        ])
    }

    func testRepository_differentMetricsSamePeriodDoNotCollapse() throws {
        let repo = try makeRepo()
        // revenue / netIncome / assets 共享 effectiveAt 06-30——按期间键分组，
        // economic 查询三条都在（若按 effectiveAt 分组会互相吞掉）
        let all = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: nil,
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertEqual(Set(all.map(\.metricKey)), ["revenue", "netIncome", "assets"])
        XCTAssertEqual(all.count, 3)   // revenue 已修并为 1 条
    }

    func testRepository_quarterAndSemiAnnualSameEndBothSurvive() throws {
        // Q2（04-01~06-30）与 H1（01-01~06-30）共享 periodEnd 但期间起点不同，
        // 是两个事实——期间键含 periodStart，不互相覆盖
        let repo = try makeRepo()
        let h1Payload = FundamentalFactPayload(
            concept: "RevenueFromContractWithCustomerExcludingAssessedTax",
            metricKey: "revenue",
            value: Decimal(string: "166533000000")!, unit: "USD",
            start: utcDay("2023-01-01"), end: utcDay("2023-06-30"),
            form: "10-Q", frame: "CY2023H1", extractionMethod: .xbrlFact
        )
        let record = ProviderRecord(
            providerID: .sec,
            providerCode: ProviderCode(scheme: "sec_cik", value: "0000320193"),
            effectiveAt: utcDay("2023-06-30"),
            publishedAt: utcDay("2023-08-04"),
            ingestedAt: ingested,
            kind: .fundamentalFact,
            rawPayload: try JSONEncoder().encode(h1Payload),
            reliabilityClass: .officialStable,
            jurisdiction: .unitedStates
        )
        let h1 = try makeObservations(records: [record], identifiers: [secCikIdentifier])
        repo.upsert(h1[0])

        let revenues = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "revenue",
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertEqual(revenues.count, 2)   // Q2 修订值 + H1
        let periods = Set(revenues.map { $0.periodStart })
        XCTAssertTrue(periods.contains(utcDay("2023-04-01")))
        XCTAssertTrue(periods.contains(utcDay("2023-01-01")))
    }

    func testRepository_metricKeyFilterAndEmptyEntity() throws {
        let repo = try makeRepo()
        let onlyAssets = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "assets",
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertEqual(onlyAssets.count, 1)
        XCTAssertEqual(onlyAssets[0].metricKey, "assets")

        // 未登记实体：空数组，不抛错（缺口语义，ADR-DATA006）
        let none = repo.fundamentalObservations(
            entityID: LegalEntityID(rawValue: "ent_unknown"),
            metricKey: nil,
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertTrue(none.isEmpty)
    }

    func testRepository_upsertIdempotent() throws {
        let repo = try makeRepo()
        let first = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "assets",
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )[0]
        repo.upsert(first)   // 同 id 重复 upsert 不产生重复条目
        let again = repo.fundamentalObservations(
            entityID: appleEntity, metricKey: "assets",
            context: .economicKnowledge(asOf: utcDay("2024-01-01"))
        )
        XCTAssertEqual(again.count, 1)
    }
}
