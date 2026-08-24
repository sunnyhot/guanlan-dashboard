import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-4 测试：Fund 域 schema（holding_snapshots / holding_positions /
/// allocation_snapshots）——表结构、持仓多 vintage、positions 子表保序、
/// 外键链（snapshot → product / position → snapshot+listing）、往返。
final class FundSchemaTests: XCTestCase {

    private var db: CanonicalDatabase!

    override func setUpWithError() throws {
        db = try CanonicalDatabase()
        try seedIdentity()
    }

    // MARK: - 迁移与表结构

    func testV4Migration_RegistersAfterMarket() throws {
        XCTAssertEqual(
            CanonicalDatabase.makeMigrations().migrations.prefix(4),
            ["v1_baseline", "v2_identity", "v3_market", "v4_fund"]
        )
        XCTAssertEqual(CanonicalDatabase.schemaVersion, 4)
        XCTAssertEqual(try db.appliedMigrations().suffix(1), ["v4_fund"])
    }

    func testAllThreeTablesExist() throws {
        try db.queue.read { d in
            XCTAssertTrue(try d.tableExists("holding_snapshots"))
            XCTAssertTrue(try d.tableExists("holding_positions"))
            XCTAssertTrue(try d.tableExists("allocation_snapshots"))
        }
    }

    // MARK: - 持仓快照往返（含 positions 保序）

    func testRoundTrip_holdingSnapshotWithPositions() throws {
        let snapshot = Self.holdingSnapshot()
        try db.queue.write { d in
            try FundHoldingSnapshotRow.from(snapshot).insert(d)
            for (index, position) in snapshot.positions.enumerated() {
                try FundHoldingPositionRow.from(position, snapshotID: snapshot.id, index: index).insert(d)
            }
        }
        try db.queue.read { d in
            let skeleton = try FundHoldingSnapshotRow.fetchOne(d, key: snapshot.id.rawValue)!.toDomain()
            let positions = try FundHoldingPositionRow
                .fetchAll(d, sql: "SELECT * FROM holding_positions WHERE snapshot_id = ? ORDER BY position_index",
                          arguments: [snapshot.id.rawValue])
                .map { try $0.toDomain() }
            var reassembled = skeleton
            reassembled = FundHoldingSnapshot(
                id: skeleton.id,
                productID: skeleton.productID,
                temporalEnvelope: skeleton.temporalEnvelope,
                availabilityProvenance: skeleton.availabilityProvenance,
                dataQuality: skeleton.dataQuality,
                vintage: skeleton.vintage,
                reportPeriod: skeleton.reportPeriod,
                positions: positions,
                disclosedWeightTotal: skeleton.disclosedWeightTotal
            )
            XCTAssertEqual(reassembled, snapshot, "快照 + 按序 positions 应完整还原")
        }
    }

    /// position_index 保序：乱序插入（先 index 2 再 0 再 1），读回仍按披露顺序。
    func testPositions_orderPreservedRegardlessOfInsertOrder() throws {
        let snapshot = Self.holdingSnapshot()
        try db.queue.write { d in
            try FundHoldingSnapshotRow.from(snapshot).insert(d)
            for index in [2, 0, 1] {
                try FundHoldingPositionRow.from(
                    snapshot.positions[index], snapshotID: snapshot.id, index: index
                ).insert(d)
            }
        }
        let symbols = try db.queue.read { d in
            try String.fetchAll(
                d,
                sql: """
                SELECT p.listing_id FROM holding_positions p
                WHERE p.snapshot_id = ? ORDER BY p.position_index
                """,
                arguments: [snapshot.id.rawValue]
            )
        }
        XCTAssertEqual(
            symbols,
            ["lst_600519", "lst_000858", "lst_601318"],
            "读回顺序 = position_index 顺序 = 披露顺序"
        )
    }

    // MARK: - DATA008 multi-vintage

    func testUnique_productPlusEffectiveAtPlusVintage_holdingSnapshots() throws {
        try insertSnapshot()
        XCTAssertThrowsError(
            try insertSnapshot(idSuffix: "-dupe"),
            "同 (product, effectiveAt, vintage) 的第二条必须拒收"
        )
        // 不同 vintage（修订）共存
        try insertSnapshot(idSuffix: "-v2", vintage: Vintage(announcementDate: Self.day(10), publisherVersion: 2))
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM holding_snapshots")!
        }
        XCTAssertEqual(count, 2, "修订行追加，不覆盖")
    }

    func testUnique_allocationSnapshots() throws {
        try db.queue.write { d in
            try AllocationSnapshotRow.from(Self.allocation()).insert(d)
        }
        XCTAssertThrowsError(try db.queue.write { d in
            try AllocationSnapshotRow.from(Self.allocation(idSuffix: "-dupe")).insert(d)
        })
    }

    // MARK: - 外键链

    func testForeignKeys_fullChainEnforced() throws {
        // 1) snapshot 引用不存在的 product
        var row = FundHoldingSnapshotRow.from(Self.holdingSnapshot())
        row = FundHoldingSnapshotRow(
            id: row.id, productID: "fp_no_such", envelope: row.envelope,
            reportPeriod: row.reportPeriod, disclosedWeightTotal: row.disclosedWeightTotal
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) })

        // 2) position 引用不存在的 snapshot
        let orphan = FundHoldingPositionRow(
            snapshotID: "obs_no_such", positionIndex: 0, listingID: "lst_600519",
            weight: "0.1", shares: nil, marketValue: nil, marketValueCurrency: nil,
            isDisclosed: true
        )
        XCTAssertThrowsError(try db.queue.write { d in try orphan.insert(d) })

        // 3) position 引用不存在的 listing（REPO-5b：未解析 position 拒收的库级兜底）
        try insertSnapshot()
        let badListing = FundHoldingPositionRow(
            snapshotID: Self.holdingSnapshot().id.rawValue, positionIndex: 9,
            listingID: "lst_no_such", weight: "0.1", shares: nil,
            marketValue: nil, marketValueCurrency: nil, isDisclosed: true
        )
        XCTAssertThrowsError(try db.queue.write { d in try badListing.insert(d) })
    }

    /// (snapshot_id, position_index) 主键：同快照同 index 重复拒收。
    func testPositions_primaryKeyRejectsDuplicateIndex() throws {
        let snapshot = Self.holdingSnapshot()
        try db.queue.write { d in
            try FundHoldingSnapshotRow.from(snapshot).insert(d)
            for (index, position) in snapshot.positions.enumerated() {
                try FundHoldingPositionRow.from(position, snapshotID: snapshot.id, index: index).insert(d)
            }
        }
        let duplicate = FundHoldingPositionRow(
            snapshotID: snapshot.id.rawValue, positionIndex: 0,
            listingID: "lst_601318", weight: "0.05", shares: nil,
            marketValue: nil, marketValueCurrency: nil, isDisclosed: true
        )
        XCTAssertThrowsError(try db.queue.write { d in try duplicate.insert(d) })
    }

    // MARK: - allocation 往返与 fail-closed

    func testRoundTrip_allocationSnapshot() throws {
        let allocation = Self.allocation()
        try db.queue.write { d in
            try AllocationSnapshotRow.from(allocation).insert(d)
        }
        try db.queue.read { d in
            let fetched = try AllocationSnapshotRow.fetchOne(d, key: allocation.id.rawValue)!.toDomain()
            XCTAssertEqual(fetched, allocation)
        }
    }

    /// 未知 report_period 枚举值：fail-closed 拒收。
    func testDecode_unknownReportPeriodRejected() throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO allocation_snapshots (id, product_id, report_period, allocations_json,
                    effective_at, published_at, available_at, ingested_at,
                    policy_id, policy_version, policy_derived_at,
                    reliability_class, source_provider_id, is_revised, is_superseded,
                    vintage_announcement_date, vintage_publisher_version)
                VALUES ('obs_alloc_bad', 'fp_110022', 'Q9', '[]',
                    '2026-06-30T00:00:00.000Z', '2026-07-18T00:00:00.000Z', '2026-07-21T00:00:00.000Z', '2026-07-19T01:00:00.000Z',
                    'fund_disclosure', 'v1', '2026-07-18T00:00:00.000Z',
                    'COMMUNITY_AGGREGATED', 'eastmoney', 0, 0,
                    '2026-07-18T00:00:00.000Z', 1)
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in
                try AllocationSnapshotRow.fetchOne(d, key: "obs_alloc_bad")!.toDomain()
            }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "report_period", rawValue: "Q9")
            )
        }
    }

    /// 可选 Price 双列不配套（value 有 currency 无）：fail-closed 拒收。
    func testDecode_priceColumnsDisagreeRejected() throws {
        try insertSnapshot()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO holding_positions
                    (snapshot_id, position_index, listing_id, weight, shares,
                     market_value, market_value_currency, is_disclosed)
                VALUES (?, 9, 'lst_601318', '0.05', NULL, '123.45', NULL, 1)
                """, arguments: [Self.holdingSnapshot().id.rawValue])
        }
        XCTAssertThrowsError(
            try db.queue.read { d in
                try FundHoldingPositionRow.fetchOne(
                    d,
                    sql: "SELECT * FROM holding_positions WHERE position_index = 9"
                )!.toDomain()
            }
        ) { error in
            guard case .priceColumnsDisagree = error as? MarketSchemaError else {
                return XCTFail("应为 priceColumnsDisagree，实际 \(error)")
            }
        }
    }

    // MARK: - fixture

    private static let day0 = Date(timeIntervalSince1970: 1_756_000_000)

    private static func day(_ offset: Double) -> Date {
        day0.addingTimeInterval(offset * 86_400)
    }

    private static let v1Vintage = Vintage(announcementDate: day(18), publisherVersion: 1)

    private static func holdingSnapshot(
        idSuffix: String = "",
        vintage: Vintage = Vintage(announcementDate: day(18), publisherVersion: 1)
    ) -> FundHoldingSnapshot {
        FundHoldingSnapshot(
            id: ObservationID(rawValue: "obs_hold\(idSuffix)"),
            productID: FundProductID(rawValue: "fp_110022"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(18),
                availableAt: day(21), ingestedAt: day(19)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "fund_disclosure", policyVersion: "v1", derivedAt: day(18)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated,
                sourceProviderID: .eastmoney
            ),
            vintage: vintage,
            reportPeriod: .q2,
            positions: [
                // 有 shares / marketValue 的完整披露
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "lst_600519"),
                    weight: Ratio(value: Decimal(string: "0.0987")!),
                    shares: Decimal(string: "4200000")!,
                    marketValue: Price(value: Decimal(string: "631800000")!, currency: .cny),
                    isDisclosed: true
                ),
                // 只有 weight（天天基金持仓披露的真实形态）
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "lst_000858"),
                    weight: Ratio(value: Decimal(string: "0.0765")!),
                    shares: nil,
                    marketValue: nil,
                    isDisclosed: true
                ),
                // 未披露 position（非前十大）
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "lst_601318"),
                    weight: Ratio(value: Decimal(string: "0.0123")!),
                    shares: nil,
                    marketValue: nil,
                    isDisclosed: false
                ),
            ],
            disclosedWeightTotal: Ratio(value: Decimal(string: "0.1752")!)
        )
    }

    private static func allocation(idSuffix: String = "") -> AllocationSnapshot {
        AllocationSnapshot(
            id: ObservationID(rawValue: "obs_alloc\(idSuffix)"),
            productID: FundProductID(rawValue: "fp_110022"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(18),
                availableAt: day(21), ingestedAt: day(19)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "fund_disclosure", policyVersion: "v1", derivedAt: day(18)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated,
                sourceProviderID: .eastmoney
            ),
            vintage: Vintage(announcementDate: day(18), publisherVersion: 1),
            reportPeriod: .q2,
            allocations: [
                .init(assetClass: .equity, ratio: Ratio(value: Decimal(string: "0.8543")!)),
                .init(assetClass: .fixedIncome, ratio: Ratio(value: Decimal(string: "0.0512")!)),
                .init(assetClass: .cash, ratio: Ratio(value: Decimal(string: "0.0789")!)),
            ]
        )
    }

    private func insertSnapshot(
        idSuffix: String = "",
        vintage: Vintage = v1Vintage
    ) throws {
        let snapshot = Self.holdingSnapshot(idSuffix: idSuffix, vintage: vintage)
        try db.queue.write { d in
            try FundHoldingSnapshotRow.from(snapshot).insert(d)
        }
    }

    /// identity 底座：legal entity + 3 只股票 instrument/listing + 基金 product 链。
    private func seedIdentity() throws {
        try db.queue.write { d in
            try LegalEntityRow.from(LegalEntity(
                id: LegalEntityID(rawValue: "le_x"),
                displayName: "某基金管理有限公司",
                jurisdiction: .chinaMainland,
                kind: .fundManager
            )).insert(d)
            let stocks: [(String, String, String)] = [
                ("inst_600519", "lst_600519", "600519"),
                ("inst_000858", "lst_000858", "000858"),
                ("inst_601318", "lst_601318", "601318"),
            ]
            for (inst, lst, symbol) in stocks {
                try InstrumentRow.from(Instrument(
                    id: InstrumentID(rawValue: inst),
                    issuerID: LegalEntityID(rawValue: "le_x"),
                    kind: .stock, displayName: symbol, baseCurrency: .cny, assetClass: .equity
                )).insert(d)
                try ListingRow.from(Listing(
                    id: ListingID(rawValue: lst),
                    instrumentID: InstrumentID(rawValue: inst),
                    exchange: symbol.hasPrefix("6") ? .sse : .szse,
                    symbol: symbol, tradingCurrency: .cny
                )).insert(d)
            }
            try InstrumentRow.from(Instrument(
                id: InstrumentID(rawValue: "inst_110022"),
                issuerID: LegalEntityID(rawValue: "le_x"),
                kind: .fund, displayName: "易方达消费行业股票",
                baseCurrency: .cny, assetClass: .equity
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
                shareClassCode: "A", displayName: "A",
                feeStructure: .init(frontEndLoad: nil, backEndLoad: nil,
                                    annualSalesFee: nil, managementFee: nil, custodyFee: nil)
            )).insert(d)
        }
    }
}
