import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-3 测试：Market 域 schema（daily_bars / nav_observations /
/// corporate_actions）——表结构、DATA008 (维度键, effectiveAt, vintage) 唯一
/// 索引、multi-vintage 行为、外键、PIT 字符串比较约定、domain↔row 往返。
final class MarketSchemaTests: XCTestCase {

    private var db: CanonicalDatabase!

    override func setUpWithError() throws {
        db = try CanonicalDatabase()
    }

    // MARK: - 迁移与表结构

    func testV3Migration_RegistersAfterIdentity() throws {
        XCTAssertEqual(
            Array(CanonicalDatabase.makeMigrations().migrations),
            ["v1_baseline", "v2_identity", "v3_market"],
            "迁移清单只追加"
        )
        XCTAssertEqual(CanonicalDatabase.schemaVersion, 3)
        XCTAssertEqual(try db.appliedMigrations(), ["v1_baseline", "v2_identity", "v3_market"])
    }

    func testAllThreeTablesExist() throws {
        try db.queue.read { d in
            XCTAssertTrue(try d.tableExists("daily_bars"))
            XCTAssertTrue(try d.tableExists("nav_observations"))
            XCTAssertTrue(try d.tableExists("corporate_actions"))
        }
    }

    /// 共享 envelope 列组在每张观测表都齐全（顺序含语义）。
    func testObservationTables_shareEnvelopeColumns() throws {
        let shared = [
            "effective_at", "published_at", "available_at", "ingested_at",
            "policy_id", "policy_version", "policy_derived_at",
            "reliability_class", "source_provider_id", "is_revised", "is_superseded",
            "vintage_announcement_date", "vintage_publisher_version",
        ]
        try db.queue.read { d in
            for table in ["daily_bars", "nav_observations", "corporate_actions"] {
                let columns = try String.fetchAll(
                    d, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid"
                )
                for column in shared {
                    XCTAssertTrue(columns.contains(column), "\(table) 缺共享列 \(column)")
                }
            }
        }
    }

    // MARK: - domain ↔ row 往返

    func testRoundTrip_dailyBar() throws {
        try seedIdentity()
        try db.queue.write { d in
            try DailyBarRow.from(Self.bar(volume: 12_345_600, fxRate: Decimal(string: "7.1"))).insert(d)
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil, effectiveDay: 1, idSuffix: "-2")).insert(d)
        }
        try db.queue.read { d in
            let fetched = try DailyBarRow.fetchOne(d, key: "obs_bar-1")!.toDomain()
            XCTAssertEqual(fetched, Self.bar(volume: 12_345_600, fxRate: Decimal(string: "7.1")))
            let nils = try DailyBarRow.fetchOne(d, key: "obs_bar-2")!.toDomain()
            XCTAssertNil(nils.volume)
            XCTAssertNil(nils.fxRate)
        }
    }

    func testRoundTrip_navObservation() throws {
        try seedIdentity()
        try db.queue.write { d in
            try NAVObservationRow.from(Self.nav(accumulated: Decimal(string: "3.2100"),
                                                dividend: Decimal(string: "0.42"))).insert(d)
            try NAVObservationRow.from(Self.nav(accumulated: nil, dividend: nil, effectiveDay: 1, idSuffix: "-2")).insert(d)
        }
        try db.queue.read { d in
            let full = try NAVObservationRow.fetchOne(d, key: "obs_nav-1")!.toDomain()
            XCTAssertEqual(full, Self.nav(accumulated: Decimal(string: "3.2100"),
                                          dividend: Decimal(string: "0.42")))
            let sparse = try NAVObservationRow.fetchOne(d, key: "obs_nav-2")!.toDomain()
            XCTAssertNil(sparse.accumulatedNAV, "累计净值缺失保持 nil，不伪造")
            XCTAssertNil(sparse.cumulativeDividendPerShare)
        }
    }

    func testRoundTrip_corporateAction() throws {
        try seedIdentity()
        try db.queue.write { d in
            try CorporateActionRow.from(Self.action(recordDate: Self.day(-3), payDate: Self.day(7))).insert(d)
            try CorporateActionRow.from(Self.action(recordDate: nil, payDate: nil, effectiveDay: 1, idSuffix: "-2")).insert(d)
        }
        try db.queue.read { d in
            let full = try CorporateActionRow.fetchOne(d, key: "obs_act-1")!.toDomain()
            XCTAssertEqual(full, Self.action(recordDate: Self.day(-3), payDate: Self.day(7)))
            let sparse = try CorporateActionRow.fetchOne(d, key: "obs_act-2")!.toDomain()
            XCTAssertNil(sparse.recordDate)
            XCTAssertNil(sparse.payDate)
        }
    }

    // MARK: - DATA008 唯一索引（合规项）

    /// (维度键, effectiveAt, vintage) 唯一：同 listing 同日同 vintage 重复入库拒收。
    func testUniqueDimensionPlusEffectiveAtPlusVintage_dailyBars() throws {
        try seedIdentity()
        try db.queue.write { d in
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil)).insert(d)
        }
        XCTAssertThrowsError(
            try db.queue.write { d in
                try DailyBarRow.from(Self.bar(volume: 100, fxRate: nil, idSuffix: "-dupe")).insert(d)
            },
            "同 (listing, effectiveAt, vintage) 的第二条必须拒收"
        )
    }

    func testUniqueDimensionPlusEffectiveAtPlusVintage_navAndActions() throws {
        try seedIdentity()
        try db.queue.write { d in
            try NAVObservationRow.from(Self.nav(accumulated: nil, dividend: nil)).insert(d)
            try CorporateActionRow.from(Self.action(recordDate: nil, payDate: nil)).insert(d)
        }
        XCTAssertThrowsError(try db.queue.write { d in
            try NAVObservationRow.from(Self.nav(accumulated: nil, dividend: nil, idSuffix: "-dupe")).insert(d)
        })
        XCTAssertThrowsError(try db.queue.write { d in
            try CorporateActionRow.from(Self.action(recordDate: nil, payDate: nil, idSuffix: "-dupe")).insert(d)
        })
    }

    /// multi-vintage：同 effectiveAt 不同 vintage 共存（DATA008 修订追加行；
    /// exactSnapshot 查询应能看到两条）。
    func testMultiVintage_rowsCoexist() throws {
        try seedIdentity()
        let v1 = Vintage(announcementDate: Self.day(0), publisherVersion: 1)
        let v2 = Vintage(announcementDate: Self.day(1), publisherVersion: 2)
        try db.queue.write { d in
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil, vintage: v1)).insert(d)
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil, vintage: v2, idSuffix: "-v2")).insert(d)
        }
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM daily_bars")!
        }
        XCTAssertEqual(count, 2, "同 effectiveAt 两个 vintage 都保留")
    }

    // MARK: - 外键

    func testForeignKeys_danglingDimensionRejected() throws {
        try seedIdentity()
        let bar = DailyBarRow(
            id: "obs_dangling",
            listingID: "lst_no_such",
            envelope: ObservationEnvelopeColumns(
                envelope: Self.envelope, provenance: Self.provenance,
                quality: Self.quality, vintage: Self.v1
            ),
            rawCurrency: "CNY",
            rawOpen: "1", rawHigh: "1", rawLow: "1", rawClose: "1",
            volume: nil, adjustmentFactor: "1", fxRate: nil
        )
        XCTAssertThrowsError(try db.queue.write { d in try bar.insert(d) }) { error in
            XCTAssertEqual(
                (error as? DatabaseError)?.extendedResultCode,
                .SQLITE_CONSTRAINT_FOREIGNKEY
            )
        }
    }

    // MARK: - PIT 字符串比较约定

    /// 核心约定：available_at 是 ISO8601 UTC 毫秒字符串，字典序 = 时间序，
    /// `available_at <= ?` 直接在 SQL 比较即 PIT 语义（GRDB-7 查询依赖）。
    func testPIT_stringComparisonInSQL() throws {
        try seedIdentity()
        // 两根 bar：availableAt = day(1) / day(2)；asOf = day(1) 应只见第一根
        try db.queue.write { d in
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil, availableDay: 1)).insert(d)
            try DailyBarRow.from(Self.bar(volume: nil, fxRate: nil, effectiveDay: 1, availableDay: 2, idSuffix: "-late")).insert(d)
        }
        let asOf = CanonicalColumnCodec.encodeTimestamp(Self.day(1))
        let visible = try db.queue.read { d in
            try String.fetchAll(
                d,
                sql: "SELECT id FROM daily_bars WHERE listing_id = ? AND available_at <= ? ORDER BY id",
                arguments: ["lst_600519", asOf]
            )
        }
        XCTAssertEqual(visible, ["obs_bar-1"], "asOf=day1 只应看到 availableAt<=day1 的行")

        let asOfLate = CanonicalColumnCodec.encodeTimestamp(Self.day(2))
        let visibleLate = try db.queue.read { d in
            try String.fetchAll(
                d,
                sql: "SELECT id FROM daily_bars WHERE listing_id = ? AND available_at <= ? ORDER BY id",
                arguments: ["lst_600519", asOfLate]
            )
        }
        XCTAssertEqual(visibleLate, ["obs_bar-1", "obs_bar-late"])
    }

    /// 时间戳编码的字典序与时间序一致（跨整段日期域抽样）。
    func testTimestampLexicographicOrder_equalsChronological() {
        var previous: Date? = nil
        for offset in stride(from: -400.0, through: 400.0, by: 0.37) {
            let date = Date(timeIntervalSince1970: 1_756_000_000 + offset * 86_400)
            if let prev = previous {
                let a = CanonicalColumnCodec.encodeTimestamp(prev)
                let b = CanonicalColumnCodec.encodeTimestamp(date)
                XCTAssertTrue(a < b, "字典序应与时间序一致：\(a) vs \(b)")
            }
            previous = date
        }
    }

    // MARK: - fail-closed

    /// 多 Price 币种不一致：编解码拒收（单 currency 列完整性前提）。
    func testMixedPriceCurrency_rejected() throws {
        var bar = Self.bar(volume: nil, fxRate: nil)
        bar = DailyBar(
            id: bar.id,
            listingID: bar.listingID,
            temporalEnvelope: bar.temporalEnvelope,
            availabilityProvenance: bar.availabilityProvenance,
            dataQuality: bar.dataQuality,
            vintage: bar.vintage,
            rawOpen: Price(value: bar.rawOpen.value, currency: .usd),   // 与其余不一致
            rawHigh: bar.rawHigh,
            rawLow: bar.rawLow,
            rawClose: bar.rawClose,
            volume: bar.volume,
            adjustmentFactor: bar.adjustmentFactor,
            fxRate: bar.fxRate
        )
        XCTAssertThrowsError(try DailyBarRow.from(bar)) { error in
            XCTAssertEqual(
                error as? MarketSchemaError,
                .mixedPriceCurrency(table: "daily_bars", id: bar.id.rawValue)
            )
        }
    }

    /// 未知枚举列值（corporate_actions.kind）：解码拒收。
    func testDecode_unknownActionKindRejected() throws {
        try seedIdentity()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO corporate_actions (id, listing_id, kind, ex_date, ratio, action_currency,
                    effective_at, published_at, available_at, ingested_at,
                    policy_id, policy_version, policy_derived_at,
                    reliability_class, source_provider_id, is_revised, is_superseded,
                    vintage_announcement_date, vintage_publisher_version)
                VALUES ('obs_bad', 'lst_600519', 'WARP_EVENT', '2026-01-05T00:00:00.000Z', '1', NULL,
                    '2026-01-04T16:00:00.000Z', '2026-01-05T00:00:00.000Z', '2026-01-06T00:00:00.000Z', '2026-01-05T01:00:00.000Z',
                    'market_close', 'v1', '2026-01-05T00:00:00.000Z',
                    'DOCUMENT_FREE_API', 'stooq', 0, 0,
                    '2026-01-05T00:00:00.000Z', 1)
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in try CorporateActionRow.fetchOne(d, key: "obs_bad")!.toDomain() }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "kind", rawValue: "WARP_EVENT")
            )
        }
    }

    // MARK: - fixture

    private static let day0 = Date(timeIntervalSince1970: 1_756_000_000)

    private static func day(_ offset: Double) -> Date {
        day0.addingTimeInterval(offset * 86_400)
    }

    private static let envelope = TemporalEnvelope(
        effectiveAt: day(0),
        publishedAt: day(0),
        availableAt: day(1),
        ingestedAt: day(1)
    )

    private static let provenance = AvailabilityProvenance(
        policyID: "market_close", policyVersion: "v1", derivedAt: day(0)
    )

    private static let quality = DataQuality(
        providerReliability: .documentFreeAPI,
        sourceProviderID: .stooq
    )

    private static let v1 = Vintage(announcementDate: day(0), publisherVersion: 1)

    private static func bar(
        volume: Int64?,
        fxRate: Decimal?,
        vintage: Vintage = v1,
        effectiveDay: Double = 0,
        availableDay: Double = 1,
        idSuffix: String = "-1"
    ) -> DailyBar {
        let envelope = TemporalEnvelope(
            effectiveAt: Self.day(effectiveDay), publishedAt: Self.day(effectiveDay),
            availableAt: Self.day(availableDay), ingestedAt: Self.day(availableDay)
        )
        return DailyBar(
            id: ObservationID(rawValue: "obs_bar\(idSuffix)"),
            listingID: ListingID(rawValue: "lst_600519"),
            temporalEnvelope: envelope,
            availabilityProvenance: provenance,
            dataQuality: quality,
            vintage: vintage,
            rawOpen: Price(value: Decimal(string: "10.50")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.80")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "10.40")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "10.62")!, currency: .cny),
            volume: volume,
            adjustmentFactor: Decimal(string: "1.0")!,
            fxRate: fxRate
        )
    }

    private static func nav(
        accumulated: Decimal?,
        dividend: Decimal?,
        effectiveDay: Double = 0,
        idSuffix: String = "-1"
    ) -> NAVObservation {
        NAVObservation(
            id: ObservationID(rawValue: "obs_nav\(idSuffix)"),
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: Self.day(effectiveDay), publishedAt: Self.day(effectiveDay),
                availableAt: Self.day(1), ingestedAt: Self.day(1)
            ),
            availabilityProvenance: provenance,
            dataQuality: DataQuality(
                providerReliability: .communityAggregated,
                sourceProviderID: .eastmoney
            ),
            vintage: v1,
            unitNAV: Price(value: Decimal(string: "2.8315")!, currency: .cny),
            accumulatedNAV: accumulated.map { Price(value: $0, currency: .cny) },
            cumulativeDividendPerShare: dividend.map { Price(value: $0, currency: .cny) }
        )
    }

    private static func action(
        recordDate: Date?,
        payDate: Date?,
        effectiveDay: Double = 0,
        idSuffix: String = "-1"
    ) -> CorporateAction {
        CorporateAction(
            id: ObservationID(rawValue: "obs_act\(idSuffix)"),
            listingID: ListingID(rawValue: "lst_600519"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: Self.day(effectiveDay), publishedAt: Self.day(effectiveDay),
                availableAt: Self.day(1), ingestedAt: Self.day(1)
            ),
            availabilityProvenance: provenance,
            dataQuality: quality,
            vintage: v1,
            kind: .cashDividend,
            exDate: day(5),
            recordDate: recordDate,
            payDate: payDate,
            ratio: Decimal(string: "2.56")!,
            currency: .cny
        )
    }

    /// 建观测表引用的 identity（FK 前置）：listing + fund_share_class。
    private func seedIdentity() throws {
        try db.queue.write { d in
            try LegalEntityRow.from(LegalEntity(
                id: LegalEntityID(rawValue: "le_maotai"),
                displayName: "贵州茅台股份有限公司",
                jurisdiction: .chinaMainland,
                kind: .listedCompany
            )).insert(d)
            try InstrumentRow.from(Instrument(
                id: InstrumentID(rawValue: "inst_600519"),
                issuerID: LegalEntityID(rawValue: "le_maotai"),
                kind: .stock,
                displayName: "贵州茅台",
                baseCurrency: .cny,
                assetClass: .equity
            )).insert(d)
            try ListingRow.from(Listing(
                id: ListingID(rawValue: "lst_600519"),
                instrumentID: InstrumentID(rawValue: "inst_600519"),
                exchange: .sse,
                symbol: "600519",
                tradingCurrency: .cny
            )).insert(d)
            // NAV 需要 fund_share_classes（连带 fund_products / instruments）
            try InstrumentRow.from(Instrument(
                id: InstrumentID(rawValue: "inst_110022"),
                issuerID: LegalEntityID(rawValue: "le_maotai"),
                kind: .fund,
                displayName: "易方达消费行业股票",
                baseCurrency: .cny,
                assetClass: .equity
            )).insert(d)
            try FundProductRow.from(FundProduct(
                id: FundProductID(rawValue: "fp_110022"),
                instrumentID: InstrumentID(rawValue: "inst_110022"),
                fundType: .openEnd,
                displayName: "易方达消费行业股票（产品）"
            )).insert(d)
            try FundShareClassRow.from(FundShareClass(
                id: FundShareClassID(rawValue: "fsc_110022_A"),
                productID: FundProductID(rawValue: "fp_110022"),
                instrumentID: InstrumentID(rawValue: "inst_110022"),
                shareClassCode: "A",
                displayName: "易方达消费行业股票 A",
                feeStructure: .init(
                    frontEndLoad: nil, backEndLoad: nil, annualSalesFee: nil,
                    managementFee: nil, custodyFee: nil
                )
            )).insert(d)
        }
    }
}
