import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-2 测试：Identity 域 schema（7 表）——表结构、迁移追加语义、
/// domain ↔ row 往返、外键/唯一约束（防火墙的 schema 层保证）、
/// 关系端点契约校验（fail-closed）。
final class IdentitySchemaTests: XCTestCase {

    /// 固定时间锚（毫秒精度，验证时间戳列无损往返）。
    private static let anchor = Date(timeIntervalSince1970: 1_756_028_400.123)

    private var db: CanonicalDatabase!

    override func setUpWithError() throws {
        db = try CanonicalDatabase()
    }

    // MARK: - 迁移与表结构

    func testV2Migration_RegistersAfterBaseline() throws {
        // 全量清单随后续 story 追加而变，此处只断言 v2 的位置语义
        //（排在 v1 基线之后、不被后续 migration 顶掉）
        let migrations = CanonicalDatabase.makeMigrations().migrations
        XCTAssertEqual(migrations.prefix(2), ["v1_baseline", "v2_identity"])
        XCTAssertEqual(CanonicalDatabase.schemaVersion, migrations.count)
        XCTAssertEqual(try db.appliedMigrations(), Array(migrations))
    }

    /// 升级路径：只有 v1 的旧库（GRDB-1 时代发布）打开后自动补 v2，不重跑 v1。
    func testUpgradePath_v1OnlyDatabaseAppliesV2() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb2-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v1-only.sqlite3").path

        // 手工构造「GRDB-1 时代」的迁移清单（只登记 v1_baseline）
        var v1Migrator = DatabaseMigrator()
        v1Migrator.registerMigration("v1_baseline") { _ in }
        try v1Migrator.migrate(DatabaseQueue(path: path))

        let upgraded = try CanonicalDatabase(path: path)
        XCTAssertEqual(try upgraded.appliedMigrations(), Array(CanonicalDatabase.makeMigrations().migrations))
        XCTAssertEqual(try upgraded.migrationState(), .current)
        // v2 表已建（抽查一张）
        try upgraded.queue.read { d in
            XCTAssertTrue(try d.tableExists("provider_identifiers"))
        }
    }

    func testAllSevenTablesExistWithExpectedColumns() throws {
        try db.queue.read { d in
            let expected: [String: [String]] = [
                "legal_entities": ["id", "display_name", "jurisdiction", "kind", "regulatory_ids"],
                "instruments": ["id", "issuer_id", "kind", "display_name", "base_currency", "asset_class", "isin"],
                "listings": ["id", "instrument_id", "exchange", "symbol", "trading_currency", "is_active"],
                "fund_products": ["id", "instrument_id", "fund_type", "display_name", "regulatory_ids"],
                "fund_share_classes": ["id", "product_id", "instrument_id", "share_class_code", "display_name", "fee_structure", "regulatory_ids"],
                "provider_identifiers": ["provider_id", "identifier_scheme", "identifier_value", "canonical_entity_type", "canonical_entity_id", "resolution_method", "resolved_at"],
                "instrument_relationships": ["id", "relationship_type", "source_type", "source_id", "target_type", "target_id", "strength", "provenance"],
            ]
            for (table, columns) in expected.sorted(by: { $0.key < $1.key }) {
                XCTAssertTrue(try d.tableExists(table), "表 \(table) 应存在")
                let actual = try String.fetchAll(d, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid")
                XCTAssertEqual(actual, columns, "表 \(table) 列清单（顺序含语义）不符")
            }
        }
    }

    // MARK: - domain ↔ row 往返

    /// 插入完整 identity 图（五层 + 映射 + 4 类关系），读回后逐个相等。
    func testRoundTrip_fullIdentityGraph() throws {
        try insertFullIdentityGraph()

        try db.queue.read { d in
            let entity = try LegalEntityRow.fetchOne(d, key: "le_efund")!.toDomain()
            XCTAssertEqual(entity, Self.expectedLegalEntity)

            let instrument = try InstrumentRow.fetchOne(d, key: "inst_110022")!.toDomain()
            XCTAssertEqual(instrument, Self.expectedFundInstrument)

            let stock = try InstrumentRow.fetchOne(d, key: "inst_600519")!.toDomain()
            XCTAssertEqual(stock, Self.expectedStockInstrument)

            let listing = try ListingRow.fetchOne(d, key: "lst_600519")!.toDomain()
            XCTAssertEqual(listing, Self.expectedListing)

            let product = try FundProductRow.fetchOne(d, key: "fp_110022")!.toDomain()
            XCTAssertEqual(product, Self.expectedFundProduct)

            let shareClass = try FundShareClassRow.fetchOne(d, key: "fsc_110022_A")!.toDomain()
            XCTAssertEqual(shareClass, Self.expectedShareClass)

            let pid = try ProviderIdentifierRow.fetchOne(
                d,
                key: ["provider_id": "eastmoney", "identifier_scheme": "fund_code", "identifier_value": "110022"]
            )!.toDomain()
            XCTAssertEqual(pid, Self.expectedProviderIdentifier)

            let relationships = try InstrumentRelationshipRow
                .fetchAll(d, sql: "SELECT * FROM instrument_relationships ORDER BY id")
                .map { try $0.toDomain() }
            XCTAssertEqual(Set(relationships), Set(Self.expectedRelationships()))
        }
    }

    /// 时间戳列毫秒精度无损（resolvedAt 毫秒位不丢）。
    func testTimestampColumn_millisecondPrecisionPreserved() throws {
        try insertFullIdentityGraph()
        try db.queue.read { d in
            let raw: String = try String.fetchOne(
                d, sql: "SELECT resolved_at FROM provider_identifiers WHERE identifier_value = '110022'"
            )!
            XCTAssertTrue(raw.hasSuffix(".123Z"), "毫秒位应保留：\(raw)")
            let decoded = try CanonicalColumnCodec.decodeTimestamp(raw)
            XCTAssertEqual(
                decoded.timeIntervalSinceReferenceDate,
                Self.anchor.timeIntervalSinceReferenceDate,
                accuracy: 0.0005,
                "毫秒精度应无损往返"
            )
        }
    }

    // MARK: - schema 层防火墙

    /// 外键：listings 引用不存在的 instrument 直接拒收（GRDB 默认启用 FK）。
    func testForeignKey_danglingInstrumentReferenceRejected() throws {
        try insertFullIdentityGraph()
        var row = try ListingRow.from(Self.expectedListing)
        row = ListingRow(
            id: "lst_dangling",
            instrumentID: row.instrumentID + "-no-such",
            exchange: row.exchange,
            symbol: "999999",
            tradingCurrency: row.tradingCurrency,
            isActive: true
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) }) { error in
            guard let databaseError = error as? DatabaseError else {
                return XCTFail("应为 DatabaseError（FK violation），实际 \(error)")
            }
            XCTAssertEqual(
                databaseError.extendedResultCode, .SQLITE_CONSTRAINT_FOREIGNKEY,
                "应为外键约束失败"
            )
        }
    }

    /// 复合主键：(provider, scheme, value) 三元组重复登记被拒——
    /// IdentityResolver lookup 层「一个 Provider 代码至多一条映射」的 schema 保证。
    func testProviderIdentifiers_compositeKeyRejectsDuplicates() throws {
        try insertFullIdentityGraph()
        // 同三元组、指向不同 canonical —— 仍然必须拒收
        var row = try ProviderIdentifierRow.from(Self.expectedProviderIdentifier)
        row = ProviderIdentifierRow(
            providerID: row.providerID,
            identifierScheme: row.identifierScheme,
            identifierValue: row.identifierValue,
            canonicalEntityType: "instrument",
            canonicalEntityID: "inst_other",
            resolutionMethod: row.resolutionMethod,
            resolvedAt: row.resolvedAt
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) })
    }

    /// 同 Provider 不同 scheme 可各自登记（复合主键只锁三元组整体）。
    func testProviderIdentifiers_differentSchemeCoexist() throws {
        try insertFullIdentityGraph()
        let row = ProviderIdentifierRow(
            providerID: "eastmoney",
            identifierScheme: "csrch_code",
            identifierValue: "110022",
            canonicalEntityType: "fundShareClass",
            canonicalEntityID: "fsc_110022_A",
            resolutionMethod: "PROVIDER_AUTHORITATIVE",
            resolvedAt: CanonicalColumnCodec.encodeTimestamp(Self.anchor)
        )
        try db.queue.write { d in try row.insert(d) }
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM provider_identifiers")!
        }
        XCTAssertEqual(count, 2)
    }

    /// active 挂牌 (exchange, symbol) 唯一；退市（is_active=0）与活跃共存不冲突。
    func testListings_activeExchangeSymbolUnique_onlyForActive() throws {
        try insertFullIdentityGraph()

        // 同 exchange+symbol 的第二个 active 挂牌：拒收
        let dupe = ListingRow(
            id: "lst_600519_dupe",
            instrumentID: "inst_600519",
            exchange: "SSE",
            symbol: "600519",
            tradingCurrency: "CNY",
            isActive: true
        )
        XCTAssertThrowsError(try db.queue.write { d in try dupe.insert(d) }, "活跃挂牌同码重复应拒收")

        // 退市挂牌同码：允许（历史保留，ID 不删——ADR-DATA001）
        let delisted = ListingRow(
            id: "lst_600519_old",
            instrumentID: "inst_600519",
            exchange: "SSE",
            symbol: "600519",
            tradingCurrency: "CNY",
            isActive: false
        )
        try db.queue.write { d in try delisted.insert(d) }
    }

    /// shareClass 的 (product_id, share_class_code) 唯一：同一产品两个 "A" 类拒收。
    func testFundShareClasses_productPlusCodeUnique() throws {
        try insertFullIdentityGraph()
        var template = try FundShareClassRow.from(Self.expectedShareClass)
        template = FundShareClassRow(
            id: "fsc_110022_A2",
            productID: template.productID,
            instrumentID: template.instrumentID,
            shareClassCode: template.shareClassCode,
            displayName: template.displayName,
            feeStructureJSON: template.feeStructureJSON,
            regulatoryIDsJSON: template.regulatoryIDsJSON
        )
        XCTAssertThrowsError(try db.queue.write { d in try template.insert(d) })
    }

    // MARK: - fail-closed 解码

    /// 枚举列出现未知 rawValue：解码拒收，不静默回落默认值。
    func testDecode_unknownEnumValueRejected() throws {
        try insertFullIdentityGraph()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO legal_entities (id, display_name, jurisdiction, kind, regulatory_ids)
                VALUES ('le_bad', '坏行', 'XX', 'FUND_MANAGER', '[]')
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in try LegalEntityRow.fetchOne(d, key: "le_bad")!.toDomain() }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "jurisdiction", rawValue: "XX")
            )
        }
    }

    /// 关系端点契约：TRACKS_INDEX 的 source 必须是 instrument，
    /// 端点类型错配的行（外部改库才会产生）解码拒收。
    func testDecode_relationshipEndpointMismatchRejected() throws {
        try insertFullIdentityGraph()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO instrument_relationships
                    (id, relationship_type, source_type, source_id, target_type, target_id, strength, provenance)
                VALUES
                    ('rel_bad', 'TRACKS_INDEX', 'fundShareClass', 'fsc_110022_A', 'instrument', 'inst_hs300', NULL, 'MANUAL')
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in try InstrumentRelationshipRow.fetchOne(d, key: "rel_bad")!.toDomain() }
        ) { error in
            guard case .relationshipEndpointMismatch = error as? IdentitySchemaError else {
                return XCTFail("应为 relationshipEndpointMismatch，实际 \(error)")
            }
        }
    }

    /// 未知实体类型列值：CanonicalRef 还原拒收。
    func testDecode_unknownEntityTypeRejected() throws {
        XCTAssertThrowsError(try CanonicalRef(entityType: "warp", entityIDRawValue: "x")) { error in
            XCTAssertEqual(error as? IdentitySchemaError, .unknownEntityType("warp"))
        }
    }

    /// 时间戳列非法值：拒收（不静默回落秒级解析）。
    func testDecode_malformedTimestampRejected() {
        XCTAssertThrowsError(try CanonicalColumnCodec.decodeTimestamp("2026-08-24 09:30:00"))
    }

    // MARK: - 查询路径（GRDB-7 resolve 的 schema 前置）

    /// provider_identifiers 三元组查询走复合主键（schema 索引即热路径）。
    func testProviderIdentifierLookup_byCompositeKey() throws {
        try insertFullIdentityGraph()
        let row = try db.queue.read { d in
            try ProviderIdentifierRow.fetchOne(
                d,
                sql: "SELECT * FROM provider_identifiers WHERE provider_id = ? AND identifier_scheme = ? AND identifier_value = ?",
                arguments: ["eastmoney", "fund_code", "110022"]
            )
        }
        XCTAssertEqual(try row?.toDomain(), Self.expectedProviderIdentifier)
        // 未映射的三元组返回 nil（lookup 层 unresolved 的库侧形态）
        let miss = try db.queue.read { d in
            try ProviderIdentifierRow.fetchOne(
                d,
                sql: "SELECT * FROM provider_identifiers WHERE provider_id = ? AND identifier_scheme = ? AND identifier_value = ?",
                arguments: ["stooq", "stock_symbol", "NOPE"]
            )
        }
        XCTAssertNil(miss)
    }

    // MARK: - fixture

    private static let expectedLegalEntity = LegalEntity(
        id: LegalEntityID(rawValue: "le_efund"),
        displayName: "易方达基金管理有限公司",
        jurisdiction: .chinaMainland,
        kind: .fundManager,
        regulatoryIDs: [RegulatoryID(scheme: "CSRC_MANAGER_CODE", value: "08-00061")]
    )

    private static let expectedFundInstrument = Instrument(
        id: InstrumentID(rawValue: "inst_110022"),
        issuerID: LegalEntityID(rawValue: "le_efund"),
        kind: .fund,
        displayName: "易方达消费行业股票",
        baseCurrency: .cny,
        assetClass: .equity,
        isin: nil
    )

    private static let expectedStockInstrument = Instrument(
        id: InstrumentID(rawValue: "inst_600519"),
        issuerID: LegalEntityID(rawValue: "le_maotai"),
        kind: .stock,
        displayName: "贵州茅台",
        baseCurrency: .cny,
        assetClass: .equity,
        isin: "CNE0000018H8"
    )

    private static let expectedListing = Listing(
        id: ListingID(rawValue: "lst_600519"),
        instrumentID: InstrumentID(rawValue: "inst_600519"),
        exchange: .sse,
        symbol: "600519",
        tradingCurrency: .cny,
        isActive: true
    )

    private static let expectedFundProduct = FundProduct(
        id: FundProductID(rawValue: "fp_110022"),
        instrumentID: InstrumentID(rawValue: "inst_110022"),
        fundType: .openEnd,
        displayName: "易方达消费行业股票（产品）",
        regulatoryIDs: [RegulatoryID(scheme: "CSRC_FUND_CODE", value: "110022")]
    )

    private static let expectedShareClass = FundShareClass(
        id: FundShareClassID(rawValue: "fsc_110022_A"),
        productID: FundProductID(rawValue: "fp_110022"),
        instrumentID: InstrumentID(rawValue: "inst_110022"),
        shareClassCode: "A",
        displayName: "易方达消费行业股票 A",
        feeStructure: .init(
            frontEndLoad: Decimal(string: "0.15"),
            backEndLoad: nil,
            annualSalesFee: nil,
            managementFee: Decimal(string: "0.015"),
            custodyFee: Decimal(string: "0.0005")
        ),
        regulatoryIDs: [RegulatoryID(scheme: "ISIN", value: "CNE0000018R2")]
    )

    private static let expectedProviderIdentifier = ProviderIdentifier(
        providerID: .eastmoney,
        identifierScheme: "fund_code",
        identifierValue: "110022",
        canonical: .fundShareClass(FundShareClassID(rawValue: "fsc_110022_A")),
        resolutionMethod: .manualVerified,
        resolvedAt: anchor
    )

    /// 4 类关系各一条（引用的实体在 insertFullIdentityGraph 里全部落库）。
    private static func expectedRelationships() -> [InstrumentRelationship] {
        [
            .tracksIndex(.init(
                id: DomainID(rawValue: "rel_01"),
                etf: InstrumentID(rawValue: "inst_510300"),
                index: InstrumentID(rawValue: "inst_hs300"),
                strength: Decimal(string: "0.999"),
                provenance: .provider
            )),
            .shareClassOf(.init(
                id: DomainID(rawValue: "rel_02"),
                shareClass: FundShareClassID(rawValue: "fsc_110022_A"),
                product: FundProductID(rawValue: "fp_110022"),
                provenance: .derived
            )),
            .issuedBy(.init(
                id: DomainID(rawValue: "rel_03"),
                instrument: InstrumentID(rawValue: "inst_600519"),
                issuer: LegalEntityID(rawValue: "le_maotai"),
                provenance: .manual
            )),
            .adrUnderlying(.init(
                id: DomainID(rawValue: "rel_04"),
                adr: InstrumentID(rawValue: "inst_baba_adr"),
                underlying: InstrumentID(rawValue: "inst_baba_hk"),
                provenance: .provider
            )),
        ]
    }

    /// 落一套完整合法的 identity 图（父表先于子表，满足外键）。
    private func insertFullIdentityGraph() throws {
        try db.queue.write { d in
            // LegalEntity（茅台发行人 + 易方达）
            try LegalEntityRow.from(Self.expectedLegalEntity).insert(d)
            try LegalEntityRow.from(LegalEntity(
                id: LegalEntityID(rawValue: "le_maotai"),
                displayName: "贵州茅台股份有限公司",
                jurisdiction: .chinaMainland,
                kind: .listedCompany
            )).insert(d)

            // Instrument（基金 + 股票 + 关系图用到的 4 只）
            for instrument in [
                Self.expectedFundInstrument,
                Self.expectedStockInstrument,
                Instrument(id: InstrumentID(rawValue: "inst_510300"), issuerID: LegalEntityID(rawValue: "le_efund"),
                           kind: .exchangeTradedFund, displayName: "沪深300ETF", baseCurrency: .cny, assetClass: .equity),
                Instrument(id: InstrumentID(rawValue: "inst_hs300"), issuerID: LegalEntityID(rawValue: "le_efund"),
                           kind: .index, displayName: "沪深300指数", baseCurrency: .cny, assetClass: .equity),
                Instrument(id: InstrumentID(rawValue: "inst_baba_adr"), issuerID: LegalEntityID(rawValue: "le_efund"),
                           kind: .stock, displayName: "阿里巴巴 ADR", baseCurrency: .usd, assetClass: .equity),
                Instrument(id: InstrumentID(rawValue: "inst_baba_hk"), issuerID: LegalEntityID(rawValue: "le_efund"),
                           kind: .stock, displayName: "阿里巴巴-SW", baseCurrency: .hkd, assetClass: .equity),
            ] {
                try InstrumentRow.from(instrument).insert(d)
            }

            try ListingRow.from(Self.expectedListing).insert(d)
            try FundProductRow.from(Self.expectedFundProduct).insert(d)
            try FundShareClassRow.from(Self.expectedShareClass).insert(d)
            try ProviderIdentifierRow.from(Self.expectedProviderIdentifier).insert(d)
            for relationship in Self.expectedRelationships() {
                try InstrumentRelationshipRow.from(relationship).insert(d)
            }
        }
    }
}
