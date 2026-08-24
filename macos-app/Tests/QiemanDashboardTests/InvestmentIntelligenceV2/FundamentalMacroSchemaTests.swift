import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-5 测试：Fundamental / Macro 域 schema——事实身份唯一键（含
/// period_start NULL 陷阱封口）、FRED vintage 语义、往返、外键、fail-closed。
final class FundamentalMacroSchemaTests: XCTestCase {

    private var db: CanonicalDatabase!

    override func setUpWithError() throws {
        db = try CanonicalDatabase()
        try seedIdentity()
    }

    // MARK: - 迁移与表结构

    func testV5Migration_RegistersAfterFund() throws {
        let migrations = CanonicalDatabase.makeMigrations().migrations
        XCTAssertEqual(
            migrations.prefix(5),
            ["v1_baseline", "v2_identity", "v3_market", "v4_fund", "v5_fundamental_macro"]
        )
        XCTAssertEqual(CanonicalDatabase.schemaVersion, migrations.count)
        XCTAssertEqual(CanonicalDatabase.makeMigrations().migrations.dropFirst(4).first, "v5_fundamental_macro",
                       "v5_fundamental_macro 固定排在第 5 位（不可变清单）")
    }

    func testBothTablesExist() throws {
        try db.queue.read { d in
            XCTAssertTrue(try d.tableExists("fundamental_observations"))
            XCTAssertTrue(try d.tableExists("macro_observations"))
        }
    }

    // MARK: - 往返

    func testRoundTrip_fundamental_flowFact() throws {
        // 流量项（Revenue：periodStart 非 nil，frame 有值）
        let fact = Self.revenueFact()
        try db.queue.write { d in try FundamentalObservationRow.from(fact).insert(d) }
        try db.queue.read { d in
            let fetched = try FundamentalObservationRow.fetchOne(d, key: fact.id.rawValue)!.toDomain()
            XCTAssertEqual(fetched, fact)
        }
    }

    func testRoundTrip_fundamental_pointInTimeFact() throws {
        // 时点项（Assets：periodStart nil）
        let fact = Self.assetsFact()
        try db.queue.write { d in try FundamentalObservationRow.from(fact).insert(d) }
        try db.queue.read { d in
            let fetched = try FundamentalObservationRow.fetchOne(d, key: fact.id.rawValue)!.toDomain()
            XCTAssertEqual(fetched, fact)
            XCTAssertNil(fetched.periodStart)
        }
    }

    func testRoundTrip_macro() throws {
        try db.queue.write { d in
            try MacroObservationRow.from(Self.gdp(basePeriod: MacroObservation.MacroBasePeriod(
                periodLabel: "2017", baseValue: Decimal(string: "100")!
            ))).insert(d)
            try MacroObservationRow.from(Self.gdp(basePeriod: nil, idSuffix: "-2", effectiveDay: 91)).insert(d)
        }
        try db.queue.read { d in
            let withBase = try MacroObservationRow.fetchOne(d, key: "obs_gdp")!.toDomain()
            XCTAssertEqual(
                withBase.basePeriod,
                MacroObservation.MacroBasePeriod(periodLabel: "2017", baseValue: Decimal(string: "100")!)
            )
            let withoutBase = try MacroObservationRow.fetchOne(d, key: "obs_gdp-2")!.toDomain()
            XCTAssertNil(withoutBase.basePeriod)
            XCTAssertEqual(withoutBase.isSeasonallyAdjusted, true)
        }
    }

    // MARK: - 事实身份唯一键

    /// 同事实同 vintage 重复入库拒收——**period_start 为 NULL 时同样拒收**
    ///（SQLite 唯一索引把 NULL 视为互不相等，表达式索引 COALESCE 封口）。
    func testFactIdentity_uniqueIncludingNullPeriodStart() throws {
        let fact = Self.assetsFact()
        try db.queue.write { d in try FundamentalObservationRow.from(fact).insert(d) }
        XCTAssertThrowsError(
            try db.queue.write { d in
                try FundamentalObservationRow.from(Self.assetsFact(idSuffix: "-dupe")).insert(d)
            },
            "NULL period_start 的事实重复也必须拒收"
        )
    }

    /// 同事实不同 vintage（10-Q 初报 → 10-K 修订）共存；不同 concept 不影响
    /// 事实归并（换标签年份的两段历史都保留）。
    func testFactIdentity_revisionAndConceptChangeCoexist() throws {
        let initial = Self.revenueFact()
        let revision = Self.revenueFact(
            idSuffix: "-v2",
            vintage: Vintage(announcementDate: Self.day(200), publisherVersion: 2),
            concept: "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
            value: Decimal(string: "123400000")!
        )
        try db.queue.write { d in
            try FundamentalObservationRow.from(initial).insert(d)
            try FundamentalObservationRow.from(revision).insert(d)
        }
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM fundamental_observations")!
        }
        XCTAssertEqual(count, 2, "修订 + 换标签是共存的 vintage 行")

        // 同 metric 不同期间（Q2 vs H1）不互斥（REPO-1b 分组语义）
        let h1 = Self.revenueFact(
            idSuffix: "-h1",
            periodStart: Self.day(-181),
            value: Decimal(string: "200000000")!
        )
        try db.queue.write { d in try FundamentalObservationRow.from(h1).insert(d) }
    }

    /// 宏观 (indicator, effectiveAt, vintage) 唯一 + FRED 修订共存。
    func testMacroIdentity_uniqueAndVintageCoexist() throws {
        try db.queue.write { d in
            try MacroObservationRow.from(Self.gdp(basePeriod: nil)).insert(d)
        }
        XCTAssertThrowsError(try db.queue.write { d in
            try MacroObservationRow.from(Self.gdp(basePeriod: nil, idSuffix: "-dupe")).insert(d)
        })
        // FRED second estimate = 新 vintage，共存
        try db.queue.write { d in
            try MacroObservationRow.from(Self.gdp(
                basePeriod: nil, idSuffix: "-second",
                vintage: Vintage(announcementDate: Self.day(60), publisherVersion: 2),
                value: Decimal(string: "3.1")!
            )).insert(d)
        }
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM macro_observations")!
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - 外键

    func testForeignKeys_rejected() throws {
        var row = FundamentalObservationRow.from(Self.revenueFact())
        row = FundamentalObservationRow(
            id: row.id, entityID: "le_no_such", envelope: row.envelope,
            metricKey: row.metricKey, concept: row.concept, value: row.value,
            unit: row.unit, periodStart: row.periodStart, periodEnd: row.periodEnd,
            form: row.form, frame: row.frame, extractionMethod: row.extractionMethod
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) })

        let macro = MacroObservationRow(
            id: "obs_macro_bad", indicatorID: "inst_no_such",
            envelope: ObservationEnvelopeColumns(
                envelope: Self.envelope, provenance: Self.provenance,
                quality: Self.quality, vintage: Self.v1
            ),
            value: "3.0", unit: "PERCENT", frequency: "QUARTERLY",
            isSeasonallyAdjusted: true, basePeriodJSON: nil
        )
        XCTAssertThrowsError(try db.queue.write { d in try macro.insert(d) })
    }

    // MARK: - fail-closed

    func testDecode_unknownFormRejected() throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO fundamental_observations (id, entity_id, metric_key, concept, value, unit,
                    period_start, period_end, form, frame, extraction_method,
                    effective_at, published_at, available_at, ingested_at,
                    policy_id, policy_version, policy_derived_at,
                    reliability_class, source_provider_id, is_revised, is_superseded,
                    vintage_announcement_date, vintage_publisher_version)
                VALUES ('obs_fund_bad', 'le_sec', 'revenue', 'us-gaap:Revenues', '1000', 'USD',
                    '2026-01-01T00:00:00.000Z', '2026-06-30T00:00:00.000Z', '10-X', NULL, 'XBRL_FACT',
                    '2026-06-30T00:00:00.000Z', '2026-07-25T00:00:00.000Z', '2026-07-28T00:00:00.000Z', '2026-07-26T02:00:00.000Z',
                    'filing_release', 'v1', '2026-07-25T00:00:00.000Z',
                    'OFFICIAL_STABLE', 'sec', 0, 0,
                    '2026-07-25T00:00:00.000Z', 1)
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in
                try FundamentalObservationRow.fetchOne(d, key: "obs_fund_bad")!.toDomain()
            }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "form", rawValue: "10-X")
            )
        }
    }

    func testDecode_unknownMacroUnitRejected() throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO macro_observations (id, indicator_id, value, unit, frequency,
                    is_seasonally_adjusted, base_period_json,
                    effective_at, published_at, available_at, ingested_at,
                    policy_id, policy_version, policy_derived_at,
                    reliability_class, source_provider_id, is_revised, is_superseded,
                    vintage_announcement_date, vintage_publisher_version)
                VALUES ('obs_macro_bad2', 'inst_gdp', '3.0', 'SMURF', 'QUARTERLY',
                    1, NULL,
                    '2026-06-30T00:00:00.000Z', '2026-07-27T00:00:00.000Z', '2026-07-28T00:00:00.000Z', '2026-07-27T12:00:00.000Z',
                    'macro_release', 'v1', '2026-07-27T00:00:00.000Z',
                    'OFFICIAL_STABLE', 'fred', 0, 0,
                    '2026-07-27T00:00:00.000Z', 1)
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in
                try MacroObservationRow.fetchOne(d, key: "obs_macro_bad2")!.toDomain()
            }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "unit", rawValue: "SMURF")
            )
        }
    }

    // MARK: - fixture

    private static let day0 = Date(timeIntervalSince1970: 1_756_000_000)

    private static func day(_ offset: Double) -> Date {
        day0.addingTimeInterval(offset * 86_400)
    }

    private static let v1 = Vintage(announcementDate: day(30), publisherVersion: 1)

    private static let envelope = TemporalEnvelope(
        effectiveAt: day(0), publishedAt: day(30), availableAt: day(33), ingestedAt: day(31)
    )

    private static let provenance = AvailabilityProvenance(
        policyID: "filing_release", policyVersion: "v1", derivedAt: day(30)
    )

    private static let quality = DataQuality(
        providerReliability: .officialStable, sourceProviderID: .sec
    )

    private static func revenueFact(
        idSuffix: String = "",
        vintage: Vintage = v1,
        concept: String = "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
        periodStart: Date? = day(-91),
        value: Decimal = Decimal(string: "119580000")!
    ) -> FundamentalObservation {
        FundamentalObservation(
            id: ObservationID(rawValue: "obs_rev\(idSuffix)"),
            entityID: LegalEntityID(rawValue: "le_sec"),
            temporalEnvelope: envelope,
            availabilityProvenance: provenance,
            dataQuality: quality,
            vintage: vintage,
            metricKey: "revenue",
            concept: concept,
            value: value,
            unit: "USD",
            periodStart: periodStart,
            periodEnd: day(0),
            form: .form10Q,
            frame: "CY2026Q2",
            extractionMethod: .xbrlFact
        )
    }

    private static func assetsFact(idSuffix: String = "") -> FundamentalObservation {
        FundamentalObservation(
            id: ObservationID(rawValue: "obs_ast\(idSuffix)"),
            entityID: LegalEntityID(rawValue: "le_sec"),
            temporalEnvelope: envelope,
            availabilityProvenance: provenance,
            dataQuality: quality,
            vintage: v1,
            metricKey: "assets",
            concept: "us-gaap:Assets",
            value: Decimal(string: "3525840000")!,
            unit: "USD",
            periodStart: nil,
            periodEnd: day(0),
            form: .form10Q,
            frame: nil,
            extractionMethod: .xbrlFact
        )
    }

    private static func gdp(
        basePeriod: MacroObservation.MacroBasePeriod?,
        idSuffix: String = "",
        effectiveDay: Double = 0,
        vintage: Vintage = v1,
        value: Decimal = Decimal(string: "3.0")!
    ) -> MacroObservation {
        MacroObservation(
            id: ObservationID(rawValue: "obs_gdp\(idSuffix)"),
            indicatorID: InstrumentID(rawValue: "inst_gdp"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(effectiveDay), publishedAt: day(30),
                availableAt: day(33), ingestedAt: day(31)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "macro_release", policyVersion: "v1", derivedAt: day(30)
            ),
            dataQuality: DataQuality(providerReliability: .officialStable, sourceProviderID: .fred),
            vintage: vintage,
            value: value,
            unit: .percent,
            frequency: .quarterly,
            isSeasonallyAdjusted: true,
            basePeriod: basePeriod
        )
    }

    private func seedIdentity() throws {
        try db.queue.write { d in
            try LegalEntityRow.from(LegalEntity(
                id: LegalEntityID(rawValue: "le_sec"),
                displayName: "Apple Inc.",
                jurisdiction: .unitedStates,
                kind: .listedCompany,
                regulatoryIDs: [RegulatoryID(scheme: "SEC_CIK", value: "0000320193")]
            )).insert(d)
            try InstrumentRow.from(Instrument(
                id: InstrumentID(rawValue: "inst_gdp"),
                issuerID: LegalEntityID(rawValue: "le_sec"),
                kind: .index, displayName: "US GDP Growth Rate",
                baseCurrency: .usd, assetClass: .alternative
            )).insert(d)
        }
    }
}
