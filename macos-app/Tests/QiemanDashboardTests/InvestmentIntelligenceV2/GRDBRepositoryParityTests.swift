import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-7 测试：GRDBRepository 与 InMemoryRepository 的**行为 parity**
///（M4 验收「golden test 同样过」的落地形式）——同一 fixture 灌进两套实现，
/// 全部查询 API 在多种 KnowledgeContext 下的输出必须相等。
/// 另含：v7 迁移的数据存活断言、多 Provider 共存、幂等重摄入。
final class GRDBRepositoryParityTests: XCTestCase {

    private var inMemory: InMemoryRepository!
    private var grdb: GRDBRepository!

    override func setUpWithError() throws {
        inMemory = InMemoryRepository(calendarBackend: WeekdayCalendar())
        grdb = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: WeekdayCalendar()
        )
        try loadFixture(into: grdb)
        loadFixture(into: inMemory)
    }

    // MARK: - parity（行为等价 = golden 同过）

    func testParity_identityLookups() {
        XCTAssertEqual(grdb.instrument(Self.instMaotai), inMemory.instrument(Self.instMaotai))
        XCTAssertEqual(grdb.listing(Self.lstMaotai), inMemory.listing(Self.lstMaotai))
        XCTAssertEqual(
            grdb.listings(forInstrument: Self.instMaotai),
            inMemory.listings(forInstrument: Self.instMaotai)
        )
        XCTAssertEqual(grdb.legalEntity(Self.leX), inMemory.legalEntity(Self.leX))
        XCTAssertEqual(grdb.fundProduct(Self.fp110022), inMemory.fundProduct(Self.fp110022))
        XCTAssertEqual(grdb.fundShareClass(Self.scA), inMemory.fundShareClass(Self.scA))
        XCTAssertNil(grdb.instrument(InstrumentID(rawValue: "inst_none")))
    }

    func testParity_resolveAndRelationships() {
        XCTAssertEqual(
            grdb.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519"),
            inMemory.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519")
        )
        XCTAssertEqual(
            grdb.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "MISSING"),
            inMemory.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "MISSING")
        )
        // fuzzy 映射：两套实现都必须拒绝返回 canonical（防火墙 1）
        XCTAssertEqual(
            grdb.resolve(providerID: .eastmoney, scheme: "fuzzy_name", value: "茅台"),
            inMemory.resolve(providerID: .eastmoney, scheme: "fuzzy_name", value: "茅台")
        )
        XCTAssertNil(
            grdb.resolve(providerID: .eastmoney, scheme: "fuzzy_name", value: "茅台"),
            "fuzzy 不得直接给 canonical"
        )

        XCTAssertEqual(
            Set(grdb.relationships(for: Self.instEtf)),
            Set(inMemory.relationships(for: Self.instEtf))
        )
        XCTAssertEqual(
            Set(grdb.relationships(for: Self.instMaotai)),
            Set(inMemory.relationships(for: Self.instMaotai))
        )
    }

    /// 全 context 矩阵跑 Market 域：economic（asOf 三个时点）/ operational /
    /// exact / vintageFilter。
    func testParity_dailyBars_allContexts() {
        let contexts: [KnowledgeContext] = [
            .economicKnowledge(asOf: Self.day(0)),
            .economicKnowledge(asOf: Self.day(1)),
            .economicKnowledge(asOf: Self.day(5)),
            .economicKnowledge(asOf: Self.day(50)),
            .operationalKnowledge(asOf: Self.day(2)),
            .operationalKnowledge(asOf: Self.day(10)),
            .exactSnapshot(at: Self.day(0)),
            .exactSnapshot(at: Self.day(1)),
            KnowledgeContext(mode: .economicKnowledge(asOf: Self.day(50)), vintageFilter: Self.v1),
            KnowledgeContext(mode: .economicKnowledge(asOf: Self.day(50)), vintageFilter: Self.v2),
        ]
        for context in contexts {
            XCTAssertEqual(
                grdb.dailyBars(listingID: Self.lstMaotai, context: context),
                inMemory.dailyBars(listingID: Self.lstMaotai, context: context),
                "dailyBars parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.dailyBar(listingID: Self.lstMaotai, on: Self.day(0), context: context),
                inMemory.dailyBar(listingID: Self.lstMaotai, on: Self.day(0), context: context),
                "dailyBar parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.navObservations(shareClassID: Self.scA, context: context),
                inMemory.navObservations(shareClassID: Self.scA, context: context),
                "nav parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.navObservation(shareClassID: Self.scA, on: Self.day(0), context: context),
                inMemory.navObservation(shareClassID: Self.scA, on: Self.day(0), context: context),
                "nav 单点 parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.holdingSnapshots(productID: Self.fp110022, context: context),
                inMemory.holdingSnapshots(productID: Self.fp110022, context: context),
                "holdings parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.latestHoldingSnapshot(productID: Self.fp110022, context: context),
                inMemory.latestHoldingSnapshot(productID: Self.fp110022, context: context),
                "latestHolding parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.macroObservations(indicatorID: Self.instGdp, context: context),
                inMemory.macroObservations(indicatorID: Self.instGdp, context: context),
                "macro parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.corporateActions(listingID: Self.lstMaotai, context: context),
                inMemory.corporateActions(listingID: Self.lstMaotai, context: context),
                "corporateActions parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.fundamentalObservations(entityID: Self.leSec, metricKey: nil, context: context),
                inMemory.fundamentalObservations(entityID: Self.leSec, metricKey: nil, context: context),
                "fundamentals parity 失败：\(context)"
            )
            XCTAssertEqual(
                grdb.fundamentalObservations(entityID: Self.leSec, metricKey: "revenue", context: context),
                inMemory.fundamentalObservations(entityID: Self.leSec, metricKey: "revenue", context: context),
                "fundamentals(revenue) parity 失败：\(context)"
            )
        }
    }

    /// allProviderIdentifiers 语义相等（InMemory 无序，Set 比较）。
    func testParity_allProviderIdentifiers() {
        XCTAssertEqual(
            Set(grdb.allProviderIdentifiers()),
            Set(inMemory.allProviderIdentifiers())
        )
    }

    // MARK: - v7 迁移语义

    /// 同 Provider 同 (维度, effectiveAt, vintage) 幂等重摄入：替换不报错，
    /// 值更新。
    /// 审查 P1 修复后的写入契约：
    /// - 同身份同内容重摄入 → 幂等，**保留最早 ingestedAt**（不漂移历史可知边界）；
    /// - 同身份不同内容 → 拒收（observationContentConflict），原行不被覆盖。
    func testUpsert_sameIdentity_conflictAndIngestionPreservation() throws {
        let w = Self.lstWuliangye   // 独立 listing：不受 parity fixture 预载行影响
        let base = Self.bar(close: Decimal(string: "10.62")!,
                            id: ObservationID(rawValue: "obs_w-1"), listing: w)
        try grdb.upsert(base)

        // (a) 同内容、更晚 ingestedAt 的重摄入：保留最早 ingestedAt
        try grdb.upsert(Self.reingest(base, ingestedAt: Self.day(30)))
        var exact = grdb.dailyBars(listingID: w, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(exact[0].temporalEnvelope.ingestedAt, Self.day(1),
                       "重摄入不得推迟首次可知时间")

        // (b) 同内容、更早 ingestedAt 的补录：前移到真实首抓时间
        try grdb.upsert(Self.reingest(base, ingestedAt: Self.day(0.5)))
        exact = grdb.dailyBars(listingID: w, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(exact[0].temporalEnvelope.ingestedAt, Self.day(0.5),
                       "更早的首抓时间应前移（真实历史）")

        // (c) 同身份不同内容（改收盘价）：拒收，原行不被覆盖
        var tampered = Self.bar(close: Decimal(string: "99.99")!,
                                id: ObservationID(rawValue: "obs_w-1"), listing: w)
        tampered = Self.reingest(tampered, ingestedAt: Self.day(40))
        XCTAssertThrowsError(try grdb.upsert(tampered)) { error in
            guard case .observationContentConflict = error as? GRDBRepositoryError else {
                return XCTFail("应为 observationContentConflict，实际 \(error)")
            }
        }
        exact = grdb.dailyBars(listingID: w, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(exact[0].rawClose.value, Decimal(string: "10.62"), "原行未被覆盖")
        XCTAssertEqual(exact[0].temporalEnvelope.ingestedAt, Self.day(0.5))
    }

    /// 不同 vintage（更正公告）的同身份重摄入不受冲突规则影响：新 vintage 新行。
    func testUpsert_newVintageNotConflicting() throws {
        let w = Self.lstWuliangye
        let base = Self.bar(close: Decimal(string: "10.62")!,
                            id: ObservationID(rawValue: "obs_w2-1"), listing: w)
        try grdb.upsert(base)
        try grdb.upsert(Self.revise(base, publishedAt: Self.day(3), ingestedAt: Self.day(4)))
        let exact = grdb.dailyBars(listingID: w, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(exact.count, 2, "新 vintage 是新行，不是冲突")
    }

    /// 审查 P1-2 契约：preferredProvider 在同 vintage 跨源间生效
    ///（高于 reliability），vintage 修订仍最优先。
    func testPreferredProvider_overridesReliabilityWithinSameVintage() throws {
        let w = Self.lstWuliangye   // 无 fixture 预载行：跨源比较不被 v2 修订干扰
        try grdb.upsert(Self.bar(close: Decimal(string: "10.62")!,
                                 id: ObservationID(rawValue: "obs_w3-em"), listing: w))
        try grdb.upsert(Self.bar(close: Decimal(string: "10.99")!, provider: .stooq,
                                 reliability: .documentFreeAPI,
                                 id: ObservationID(rawValue: "obs_w3-stooq"), listing: w))
        let contexts: [KnowledgeContext] = [
            KnowledgeContext(mode: .economicKnowledge(asOf: Self.day(5))),
            KnowledgeContext(mode: .economicKnowledge(asOf: Self.day(5)), preferredProvider: .eastmoney),
        ]
        // 无偏好：reliability 高者胜（stooq documentFreeAPI）
        XCTAssertEqual(
            grdb.dailyBars(listingID: w, context: contexts[0]).first?.dataQuality.sourceProviderID,
            .stooq
        )
        // 偏好 eastmoney：覆盖 reliability（同 vintage 间）
        XCTAssertEqual(
            grdb.dailyBars(listingID: w, context: contexts[1]).first?.dataQuality.sourceProviderID,
            .eastmoney
        )
        // 单点查询同样尊重偏好（P1-3）
        XCTAssertEqual(
            grdb.dailyBar(listingID: w, on: Self.day(0), context: contexts[1])?
                .dataQuality.sourceProviderID,
            .eastmoney
        )
        // InMemory 同 fixture 同结果（共享语义，双实现一致）
        inMemory.upsert(Self.bar(close: Decimal(string: "10.62")!,
                                 id: ObservationID(rawValue: "obs_w3-em"), listing: w))
        inMemory.upsert(Self.bar(close: Decimal(string: "10.99")!, provider: .stooq,
                                 reliability: .documentFreeAPI,
                                 id: ObservationID(rawValue: "obs_w3-stooq"), listing: w))
        XCTAssertEqual(
            inMemory.dailyBars(listingID: w, context: contexts[1]).first?.dataQuality.sourceProviderID,
            .eastmoney
        )
    }

    /// 审查 P1-3 契约：单点查询尊重 vintageFilter（此前被旁路）。
    func testPointQuery_honorsVintageFilter() throws {
        let w = Self.lstWuliangye
        let base = Self.bar(close: Decimal(string: "10.62")!,
                            id: ObservationID(rawValue: "obs_w4-1"), listing: w)
        try grdb.upsert(base)   // v1
        try grdb.upsert(Self.revise(base, publishedAt: Self.day(3), ingestedAt: Self.day(4)))   // v2
        let context = KnowledgeContext(
            mode: .economicKnowledge(asOf: Self.day(50)), vintageFilter: Self.v1
        )
        XCTAssertEqual(
            grdb.dailyBar(listingID: w, on: Self.day(0), context: context)?.vintage,
            Self.v1,
            "vintageFilter=v1 的单点查询应返回 v1，不被 v2 修订覆盖"
        )
        // InMemory 同语义（修复同步落地双实现）
        inMemory.upsert(base)
        inMemory.upsert(Self.revise(base, publishedAt: Self.day(3), ingestedAt: Self.day(4)))
        XCTAssertEqual(
            inMemory.dailyBar(listingID: w, on: Self.day(0), context: context)?.vintage,
            Self.v1
        )
    }

    /// 跨 Provider 同 (维度, effectiveAt, vintage) 共存（REPO-2b 的存储前提，
    /// v7 修正的语义），查询按 reliability 择优。
    func testMultiProvider_sameKeyCoexist_queryPrefersReliability() throws {
        let stooqBar = Self.bar(close: Decimal(string: "10.99")!, provider: .stooq,
                                reliability: .documentFreeAPI,
                                id: ObservationID(rawValue: "obs_bar-stooq"))
        try grdb.upsert(stooqBar)

        // exact 查询全部 vintage 都在（v1 + v2 修订 + stooq 跨源；跨源不去重）
        let exact = grdb.dailyBars(listingID: Self.lstMaotai, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(exact.count, 3, "跨 Provider 同键共存 + 各 vintage 保留")

        // economic 择优：vintage 优先于 reliability（REPO-2b 全序第一层）——
        // eastmoney 的 v2 修订胜过 stooq 的 v1
        let economic = grdb.dailyBars(listingID: Self.lstMaotai, context: .economicKnowledge(asOf: Self.day(5)))
        XCTAssertEqual(economic.count, 1)
        XCTAssertEqual(economic.first?.dataQuality.sourceProviderID, .eastmoney,
                       "更高 vintage 胜（ADR-DATA008 修订优先于跨源 reliability）")
        XCTAssertEqual(economic.first?.vintage, Self.v2)

        // InMemory 同 fixture 同结果（parity 已在 setUp 覆盖无 stooq 情形，
        // 这里单独灌入再对一次）
        inMemory.upsert(stooqBar)
        XCTAssertEqual(
            grdb.dailyBars(listingID: Self.lstMaotai, context: .economicKnowledge(asOf: Self.day(5))),
            inMemory.dailyBars(listingID: Self.lstMaotai, context: .economicKnowledge(asOf: Self.day(5)))
        )
    }

    /// v7 表重建迁移的存量数据存活：造 v6 库灌数据，v7 代码打开后数据还在、
    /// 新唯一语义生效。
    func testV7Migration_preservesExistingData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb7-v7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v6.sqlite3").path

        // 手工构造「v6 时代」的迁移清单（只登记到 v6）
        var v6Migrator = DatabaseMigrator()
        v6Migrator.registerMigration("v1_baseline") { _ in }
        v6Migrator.registerMigration("v2_identity") { db in try IdentitySchema.create(in: db) }
        v6Migrator.registerMigration("v3_market") { db in try MarketSchema.create(in: db) }
        v6Migrator.registerMigration("v4_fund") { db in try FundSchema.create(in: db) }
        v6Migrator.registerMigration("v5_fundamental_macro") { db in try FundamentalMacroSchema.create(in: db) }
        v6Migrator.registerMigration("v6_intelligence") { db in try IntelligenceSchema.create(in: db) }
        let v6Queue = try DatabaseQueue(path: path)
        try v6Migrator.migrate(v6Queue)

        // v6 库里灌一仧行情 + 持仓（走 row codec）
        try v6Queue.write { db in
            try LegalEntityRow.from(Self.entity).insert(db)
            try InstrumentRow.from(Self.instrument).insert(db)
            try ListingRow.from(Self.listing).insert(db)
            try InstrumentRow.from(Self.instrumentFund).insert(db)
            try FundProductRow.from(Self.product).insert(db)
            try FundShareClassRow.from(Self.shareClass).insert(db)
            try DailyBarRow.from(Self.bar(close: Decimal(string: "10.62")!)).insert(db)
            try FundHoldingSnapshotRow.from(Self.snapshot()).insert(db)
            try FundHoldingPositionRow.from(
                Self.snapshot().positions[0], snapshotID: Self.snapshot().id, index: 0
            ).insert(db)
        }

        // v7 代码打开：v7_provider_unique 自动跑，数据存活
        let upgraded = try GRDBRepository(
            database: CanonicalDatabase(path: path), calendarBackend: WeekdayCalendar()
        )
        XCTAssertEqual(
            upgraded.dailyBars(listingID: Self.lstMaotai, context: .economicKnowledge(asOf: Self.day(5))).count,
            1, "迁移后存量行情存活"
        )
        XCTAssertEqual(
            upgraded.holdingSnapshots(productID: Self.fp110022, context: .economicKnowledge(asOf: Self.day(50))).count,
            1, "迁移后存量持仓存活（holding_positions FK 经 rename 改写仍完整）"
        )
        XCTAssertEqual(
            upgraded.holdingSnapshots(productID: Self.fp110022, context: .economicKnowledge(asOf: Self.day(50))).first?.positions.count,
            1, "positions 子表数据存活"
        )

        // 新唯一语义：跨 provider 同键共存
        try upgraded.upsert(Self.bar(close: Decimal(string: "10.99")!, provider: .stooq,
                                     reliability: .documentFreeAPI,
                                     id: ObservationID(rawValue: "obs_bar-stooq")))
        XCTAssertEqual(
            upgraded.dailyBars(listingID: Self.lstMaotai, context: .exactSnapshot(at: Self.day(0))).count,
            2
        )
    }

    /// 持仓快照幂等重摄入：positions 整组替换，不累积重复。
    func testUpsertHolding_positionsReplacedNotAccumulated() throws {
        try grdb.upsert(Self.snapshot())
        try grdb.upsert(Self.snapshot())
        let snaps = grdb.holdingSnapshots(productID: Self.fp110022, context: .exactSnapshot(at: Self.day(0)))
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.positions.count, 2, "重摄入后 positions 不翻倍")
    }

    /// 读取诊断面：正常查询后 lastQueryError 为 nil（有错误可查、无错误不残留）。
    func testDiagnostics_cleanWhenHealthy() {
        _ = grdb.dailyBars(listingID: Self.lstMaotai, context: .economicKnowledge(asOf: Self.day(5)))
        XCTAssertNil(grdb.lastQueryError)
    }

    // MARK: - fixture

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return w >= 2 && w <= 6
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var current = date; var remaining = max(offset, 0); var safety = 0
            while remaining > 0 && safety < 14 {
                current = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: current)!
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

    private static let day0 = Date(timeIntervalSince1970: 1_756_000_000)

    private static func day(_ offset: Double) -> Date {
        day0.addingTimeInterval(offset * 86_400)
    }

    private static let v1 = Vintage(announcementDate: day(0), publisherVersion: 1)
    private static let v2 = Vintage(announcementDate: day(3), publisherVersion: 2)

    private static let leX = LegalEntityID(rawValue: "le_x")
    private static let leSec = LegalEntityID(rawValue: "le_sec")
    private static let instMaotai = InstrumentID(rawValue: "inst_600519")
    private static let lstMaotai = ListingID(rawValue: "lst_600519")
    private static let instFund = InstrumentID(rawValue: "inst_110022")
    private static let fp110022 = FundProductID(rawValue: "fp_110022")
    private static let scA = FundShareClassID(rawValue: "fsc_110022_A")
    private static let instEtf = InstrumentID(rawValue: "inst_510300")
    private static let instGdp = InstrumentID(rawValue: "inst_gdp")

    private static let entity = LegalEntity(
        id: leX, displayName: "某基金管理有限公司",
        jurisdiction: .chinaMainland, kind: .fundManager
    )

    private static let instrument = Instrument(
        id: instMaotai, issuerID: leX, kind: .stock,
        displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
    )

    private static let listing = Listing(
        id: lstMaotai, instrumentID: instMaotai, exchange: .sse,
        symbol: "600519", tradingCurrency: .cny
    )

    private static let instrumentFund = Instrument(
        id: instFund, issuerID: leX, kind: .fund,
        displayName: "易方达消费行业股票", baseCurrency: .cny, assetClass: .equity
    )

    private static let product = FundProduct(
        id: fp110022, instrumentID: instFund, fundType: .openEnd,
        displayName: "易方达消费行业股票（产品）"
    )

    private static let shareClass = FundShareClass(
        id: scA, productID: fp110022, instrumentID: instFund,
        shareClassCode: "A", displayName: "A",
        feeStructure: .init(frontEndLoad: nil, backEndLoad: nil,
                            annualSalesFee: nil, managementFee: nil, custodyFee: nil)
    )

    /// 两日 × 各自 vintage 修订 + 跨日序列的行情。
    private static func bar(
        close: Decimal,
        provider: DataProviderID = .eastmoney,
        reliability: ProviderReliabilityClass = .communityAggregated,
        id: ObservationID = ObservationID(rawValue: "obs_bar-1"),
        listing: ListingID = lstMaotai
    ) -> DailyBar {
        DailyBar(
            id: id,
            listingID: listing,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(0),
                availableAt: day(1), ingestedAt: day(1)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "market_close", policyVersion: "v1", derivedAt: day(0)
            ),
            dataQuality: DataQuality(providerReliability: reliability, sourceProviderID: provider),
            vintage: v1,
            rawOpen: Price(value: Decimal(string: "10.50")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.80")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "10.40")!, currency: .cny),
            rawClose: Price(value: close, currency: .cny),
            volume: 1_000_000,
            adjustmentFactor: Decimal(string: "1.0")!,
            fxRate: nil
        )
    }

    /// 同 vintage 重摄入：只改 ingestedAt（身份键不变）。
    private static func reingest(_ bar: DailyBar, ingestedAt: Date) -> DailyBar {
        DailyBar(
            id: bar.id, listingID: bar.listingID,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: bar.temporalEnvelope.effectiveAt,
                publishedAt: bar.temporalEnvelope.publishedAt,
                availableAt: bar.temporalEnvelope.availableAt,
                ingestedAt: ingestedAt
            ),
            availabilityProvenance: bar.availabilityProvenance,
            dataQuality: bar.dataQuality, vintage: bar.vintage,
            rawOpen: bar.rawOpen, rawHigh: bar.rawHigh, rawLow: bar.rawLow, rawClose: bar.rawClose,
            volume: bar.volume, adjustmentFactor: bar.adjustmentFactor, fxRate: bar.fxRate
        )
    }

    /// 更正公告：新 publishedAt（= 新 vintage）+ 可选新收盘价。
    private static func revise(_ bar: DailyBar, publishedAt: Date, ingestedAt: Date,
                               close: Decimal? = nil) -> DailyBar {
        DailyBar(
            id: ObservationID(rawValue: bar.id.rawValue + "-v2"),
            listingID: bar.listingID,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: bar.temporalEnvelope.effectiveAt,
                publishedAt: publishedAt,
                availableAt: max(publishedAt, bar.temporalEnvelope.availableAt),
                ingestedAt: ingestedAt
            ),
            availabilityProvenance: bar.availabilityProvenance,
            dataQuality: bar.dataQuality,
            vintage: Vintage(announcementDate: publishedAt, publisherVersion: 1),
            rawOpen: bar.rawOpen, rawHigh: bar.rawHigh, rawLow: bar.rawLow,
            rawClose: close.map { Price(value: $0, currency: .cny) } ?? bar.rawClose,
            volume: bar.volume, adjustmentFactor: bar.adjustmentFactor, fxRate: bar.fxRate
        )
    }

    private static func nav(effectiveDay: Double, vintage: Vintage) -> NAVObservation {
        NAVObservation(
            id: ObservationID(rawValue: "obs_nav-\(Int(effectiveDay))-\(vintage.publisherVersion)"),
            shareClassID: scA,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(effectiveDay), publishedAt: day(effectiveDay),
                availableAt: day(effectiveDay + 1), ingestedAt: day(effectiveDay + 1)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "fund_nav", policyVersion: "v1", derivedAt: day(effectiveDay)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated, sourceProviderID: .eastmoney
            ),
            vintage: vintage,
            unitNAV: Price(value: Decimal(string: "2.8315")!, currency: .cny),
            accumulatedNAV: nil,
            cumulativeDividendPerShare: nil
        )
    }

    private static func snapshot() -> FundHoldingSnapshot {
        FundHoldingSnapshot(
            id: ObservationID(rawValue: "obs_hold-1"),
            productID: fp110022,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(18),
                availableAt: day(21), ingestedAt: day(19)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "fund_disclosure", policyVersion: "v1", derivedAt: day(18)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated, sourceProviderID: .eastmoney
            ),
            vintage: v1,
            reportPeriod: .q2,
            positions: [
                FundHoldingPosition(
                    listingID: lstMaotai,
                    weight: Ratio(value: Decimal(string: "0.0987")!),
                    shares: nil, marketValue: nil, isDisclosed: true
                ),
                FundHoldingPosition(
                    listingID: ListingID(rawValue: "lst_000858"),
                    weight: Ratio(value: Decimal(string: "0.0765")!),
                    shares: nil, marketValue: nil, isDisclosed: true
                ),
            ],
            disclosedWeightTotal: Ratio(value: Decimal(string: "0.1752")!)
        )
    }

    /// 完整 fixture（identity + 各域观测），静态工厂集中定义、两套装载器消费。
    private static let entitySec = LegalEntity(
        id: leSec, displayName: "Apple Inc.", jurisdiction: .unitedStates,
        kind: .listedCompany
    )
    private static let fixtureEntities: [LegalEntity] = [entity, entitySec]
    private static let instrumentWuliangye = Instrument(
        id: InstrumentID(rawValue: "inst_000858"), issuerID: leX, kind: .stock,
        displayName: "五粮液", baseCurrency: .cny, assetClass: .equity
    )
    private static let lstWuliangye = ListingID(rawValue: "lst_000858")
    private static let listingWuliangye = Listing(
        id: lstWuliangye, instrumentID: InstrumentID(rawValue: "inst_000858"),
        exchange: .szse, symbol: "000858", tradingCurrency: .cny
    )
    private static let instrumentGdp = Instrument(
        id: instGdp, issuerID: leX, kind: .index,
        displayName: "US GDP Growth Rate", baseCurrency: .usd, assetClass: .alternative
    )
    private static let fixtureInstruments: [Instrument] = [instrument, instrumentFund, instrumentWuliangye, instrumentGdp]
    private static let fixtureListings: [Listing] = [listing, listingWuliangye]
    private static let fixtureProducts: [FundProduct] = [product]
    private static let fixtureShareClasses: [FundShareClass] = [shareClass]
    private static let fixtureProviderIdentifiers: [ProviderIdentifier] = [
        ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(lstMaotai),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: day(0)
        ),
        ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fuzzy_name",
            identifierValue: "茅台", canonical: .listing(lstMaotai),
            resolutionMethod: .fuzzyCandidate, resolvedAt: day(0)
        ),
    ]
    private static let fixtureRelationships: [InstrumentRelationship] = [
        .tracksIndex(.init(
            id: DomainID(rawValue: "rel_01"), etf: instEtf,
            index: InstrumentID(rawValue: "inst_hs300"),
            strength: nil, provenance: .manual
        )),
    ]
    private static let fixtureBars: [DailyBar] = [
        bar(close: Decimal(string: "10.62")!),
        DailyBar(
            id: ObservationID(rawValue: "obs_bar-1-v2"),
            listingID: lstMaotai,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(3),
                availableAt: day(4), ingestedAt: day(4)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "market_close", policyVersion: "v1", derivedAt: day(3)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated, sourceProviderID: .eastmoney
            ),
            vintage: v2,
            rawOpen: Price(value: Decimal(string: "10.51")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.81")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "10.41")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "10.70")!, currency: .cny),
            volume: 1_100_000, adjustmentFactor: Decimal(string: "1.0")!, fxRate: nil
        ),
    ]
    private static let fixtureNAVs: [NAVObservation] = [
        nav(effectiveDay: 0, vintage: v1),
        nav(effectiveDay: 1, vintage: v1),
    ]
    private static let fixtureHoldings: [FundHoldingSnapshot] = [snapshot()]
    private static let fixtureMacros: [MacroObservation] = [
        MacroObservation(
            id: ObservationID(rawValue: "obs_gdp-1"),
            indicatorID: instGdp,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(30),
                availableAt: day(33), ingestedAt: day(31)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "macro_release", policyVersion: "v1", derivedAt: day(30)
            ),
            dataQuality: DataQuality(
                providerReliability: .officialStable, sourceProviderID: .fred
            ),
            vintage: v1,
            value: Decimal(string: "3.0")!, unit: .percent, frequency: .quarterly,
            isSeasonallyAdjusted: true, basePeriod: nil
        ),
    ]
    private static let fixtureActions: [CorporateAction] = [
        CorporateAction(
            id: ObservationID(rawValue: "obs_act-1"),
            listingID: lstMaotai,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(0),
                availableAt: day(1), ingestedAt: day(1)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "market_close", policyVersion: "v1", derivedAt: day(0)
            ),
            dataQuality: DataQuality(
                providerReliability: .communityAggregated, sourceProviderID: .eastmoney
            ),
            vintage: v1,
            kind: .cashDividend, exDate: day(5),
            recordDate: nil, payDate: nil,
            ratio: Decimal(string: "2.56")!, currency: .cny
        ),
    ]
    private static let fixtureFundamentals: [FundamentalObservation] = [
        fundamental(id: "obs_fund-rev-v1", metricKey: "revenue",
                    concept: "us-gaap:Revenues", value: Decimal(string: "119580000")!,
                    periodStart: day(-91), frame: "CY2026Q2"),
        fundamental(id: "obs_fund-ast-v1", metricKey: "assets",
                    concept: "us-gaap:Assets", value: Decimal(string: "3525840000")!,
                    periodStart: nil, frame: nil),
    ]

    private static func fundamental(
        id: String, metricKey: String, concept: String,
        value: Decimal, periodStart: Date?, frame: String?
    ) -> FundamentalObservation {
        FundamentalObservation(
            id: ObservationID(rawValue: id),
            entityID: leSec,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day(0), publishedAt: day(30),
                availableAt: day(33), ingestedAt: day(31)
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: "filing_release", policyVersion: "v1", derivedAt: day(30)
            ),
            dataQuality: DataQuality(
                providerReliability: .officialStable, sourceProviderID: .sec
            ),
            vintage: v1,
            metricKey: metricKey, concept: concept,
            value: value, unit: "USD",
            periodStart: periodStart, periodEnd: day(0),
            form: .form10Q, frame: frame, extractionMethod: .xbrlFact
        )
    }

    private func loadFixture(into repo: GRDBRepository) throws {
        for e in Self.fixtureEntities { try repo.upsert(e) }
        for i in Self.fixtureInstruments { try repo.upsert(i) }
        for l in Self.fixtureListings { try repo.upsert(l) }
        for p in Self.fixtureProducts { try repo.upsert(p) }
        for sc in Self.fixtureShareClasses { try repo.upsert(sc) }
        for pid in Self.fixtureProviderIdentifiers { try repo.upsert(pid) }
        for r in Self.fixtureRelationships { try repo.add(r) }
        for b in Self.fixtureBars { try repo.upsert(b) }
        for n in Self.fixtureNAVs { try repo.upsert(n) }
        for h in Self.fixtureHoldings { try repo.upsert(h) }
        for m in Self.fixtureMacros { try repo.upsert(m) }
        for a in Self.fixtureActions { try repo.upsert(a) }
        for f in Self.fixtureFundamentals { try repo.upsert(f) }
    }

    private func loadFixture(into repo: InMemoryRepository) {
        for e in Self.fixtureEntities { repo.upsert(e) }
        for i in Self.fixtureInstruments { repo.upsert(i) }
        for l in Self.fixtureListings { repo.upsert(l) }
        for p in Self.fixtureProducts { repo.upsert(p) }
        for sc in Self.fixtureShareClasses { repo.upsert(sc) }
        for pid in Self.fixtureProviderIdentifiers { repo.upsert(pid) }
        for r in Self.fixtureRelationships { repo.add(r) }
        for b in Self.fixtureBars { repo.upsert(b) }
        for n in Self.fixtureNAVs { repo.upsert(n) }
        for h in Self.fixtureHoldings { repo.upsert(h) }
        for m in Self.fixtureMacros { repo.upsert(m) }
        for a in Self.fixtureActions { repo.upsert(a) }
        for f in Self.fixtureFundamentals { repo.upsert(f) }
    }
}
