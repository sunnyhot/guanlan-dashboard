import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-8 测试：CanonicalPipeline——四防火墙在 commit 前、拒收不阻塞批次、
/// 确定性 ID/Vintage 幂等重放、spool 直连、整批事务回滚。
final class CanonicalPipelineTests: XCTestCase {

    private var repository: GRDBRepository!
    private var pipeline: CanonicalPipeline!

    override func setUpWithError() throws {
        repository = GRDBRepository(database: try CanonicalDatabase(), calendarBackend: WeekdayCalendar())
        try seedIdentity()
        pipeline = CanonicalPipeline(repository: repository, calendar: WeekdayCalendar())
    }

    // MARK: - 端到端

    func testEndToEnd_validRecordsCommitAndQuery() {
        let result = pipeline.commit(records: [Self.barRecord(), Self.navRecord()])
        XCTAssertNil(result.commitError)
        XCTAssertEqual(result.committedCount, 2)
        XCTAssertTrue(result.rejections.isEmpty)

        // 查询可见（economic asOf 覆盖 availableAt）
        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: Self.day(10))
        )
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.rawClose.value, Decimal(string: "10.62"))
        let navs = repository.navObservations(
            shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
            context: .economicKnowledge(asOf: Self.day(10))
        )
        XCTAssertEqual(navs.count, 1)
    }

    /// 幂等重放：同批 commit 两次，行数不翻倍、ID 不变（ADR-DATA004）。
    func testIdempotentReplay_sameRecordsNoDuplication() {
        let first = pipeline.commit(records: [Self.barRecord()])
        XCTAssertEqual(first.committedCount, 1)
        let second = pipeline.commit(records: [Self.barRecord()])
        XCTAssertEqual(second.committedCount, 1, "重放合法，仍算 committed")
        XCTAssertEqual(second.commitError, nil)

        let exact = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .exactSnapshot(at: Self.day(0))
        )
        XCTAssertEqual(exact.count, 1, "重放不产生重复行")

        // 确定性：两轮派生的 ObservationID 相同
        XCTAssertEqual(
            CanonicalPipeline.deriveObservationID(from: Self.barRecord()),
            CanonicalPipeline.deriveObservationID(from: Self.barRecord())
        )
    }

    /// Provider 更正重公布（publishedAt 变）→ 新 vintage 行，旧行保留（DATA008）。
    func testRepublishedCorrection_createsNewVintage() {
        _ = pipeline.commit(records: [Self.barRecord()])
        let correctionResult = pipeline.commit(records: [Self.correctedBarRecord()])
        XCTAssertEqual(correctionResult.committedCount, 1, "修订版应提交：\(correctionResult)")
        let exact = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .exactSnapshot(at: Self.day(0))
        )
        XCTAssertEqual(exact.count, 2, "原版 + 修订版共存")
        let economic = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: Self.day(20))
        )
        XCTAssertEqual(economic.count, 1)
        XCTAssertEqual(economic.first?.rawClose.value, Decimal(string: "10.80"),
                       "economic 取修订最新")
    }

    // MARK: - 四防火墙

    /// ① 结构：payload 与声明 kind 不匹配 → 拒收，不阻塞批内其他记录。
    func testFirewall1_schemaMismatchRejected() {
        var bad = Self.barRecord()
        bad = ProviderRecord(
            providerID: bad.providerID, providerCode: bad.providerCode,
            effectiveAt: bad.effectiveAt, publishedAt: bad.publishedAt, ingestedAt: bad.ingestedAt,
            kind: bad.kind,
            rawPayload: Data(#"{"warp":true}"#.utf8),   // 不是 DailyBarPayload
            reliabilityClass: bad.reliabilityClass, jurisdiction: bad.jurisdiction
        )
        let result = pipeline.commit(records: [bad, Self.navRecord()])
        XCTAssertEqual(result.committedCount, 1, "坏记录拒收不阻塞好记录")
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections[0].stage, .schema)
        XCTAssertEqual(result.rejections[0].provider, "eastmoney")
    }

    /// ② identity：未登记的 Provider 代码 → 拒收（防火墙 1：fuzzy 不进 canonical）。
    func testFirewall2_identityUnresolvedRejected() {
        var unknown = Self.barRecord()
        unknown = ProviderRecord(
            providerID: unknown.providerID,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "999999"),
            effectiveAt: unknown.effectiveAt, publishedAt: unknown.publishedAt,
            ingestedAt: unknown.ingestedAt, kind: unknown.kind,
            rawPayload: unknown.rawPayload,
            reliabilityClass: unknown.reliabilityClass, jurisdiction: unknown.jurisdiction
        )
        let result = pipeline.commit(records: [unknown])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertEqual(result.rejections[0].stage, .identityTemporal)

        // fuzzy 登记的代码同样拒收（必须经 Verification）
        try! seedFuzzyIdentifier()
        let fuzzy = unknown
        let fuzzyResult = pipeline.commit(records: [fuzzy])
        XCTAssertEqual(fuzzyResult.committedCount, 0, "fuzzy 不得进 canonical")
    }

    /// ③ 语义：OHLC 拓扑不一致（low > open）→ 拒收。
    func testFirewall3_dataValidationRejected() {
        let bad = Self.barRecord(rawLow: Decimal(string: "99.99")!)
        let result = pipeline.commit(records: [bad])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertEqual(result.rejections[0].stage, CanonicalPipeline.RejectionStage.dataValidation)
        XCTAssertTrue(result.rejections[0].reason.contains("OHLC"))
    }

    /// ③ 语义：持仓权重出界（> 1）→ 拒收整条 snapshot。
    func testFirewall3_holdingWeightOutOfRange() {
        let bad = Self.holdingRecord(weight: Decimal(string: "1.5")!)
        let result = pipeline.commit(records: [bad])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertEqual(result.rejections[0].stage, CanonicalPipeline.RejectionStage.dataValidation)
    }

    /// ④ 提交事务：identity 映射存在但 FK 目标行缺失（listing 表没有该行）→
    /// 整批回滚，未提交任何行（含防火墙通过的记录）。
    func testFirewall4_commitFKViolationRollsBackWholeBatch() throws {
        // 悬空映射现在会被 upsert 的目标存在性验证拦截（见
        // testUpsertProviderIdentifier_danglingTargetRejected）；本测试用
        // 原生 SQL 注入一条悬空映射（模拟外部改库 / 旧版库），验证 commit 级
        // FK 仍然是兜底防火墙
        try repository.database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO provider_identifiers (provider_id, identifier_scheme, identifier_value,
                    canonical_entity_type, canonical_entity_id, resolution_method, resolved_at)
                VALUES ('eastmoney', 'stock_symbol', '888888', 'listing', 'lst_ghost',
                    'MANUAL_VERIFIED', '2025-08-24T01:46:40.000Z')
                """)
        }
        var ghost = Self.barRecord()
        ghost = ProviderRecord(
            providerID: ghost.providerID,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "888888"),
            effectiveAt: ghost.effectiveAt, publishedAt: ghost.publishedAt,
            ingestedAt: ghost.ingestedAt, kind: ghost.kind,
            rawPayload: ghost.rawPayload,
            reliabilityClass: ghost.reliabilityClass, jurisdiction: ghost.jurisdiction
        )
        let result = pipeline.commit(records: [ghost, Self.navRecord()])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertNotNil(result.commitError, "FK 违例 → 整批回滚")
        // 好记录（NAV）也未入库（单事务原子性）
        XCTAssertEqual(
            repository.navObservations(
                shareClassID: FundShareClassID(rawValue: "fsc_110022_A"),
                context: .economicKnowledge(asOf: Self.day(10))
            ).count,
            0
        )
    }

    // MARK: - spool 直连

    func testCommitFromSpool_readsJSONLAndCommits() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        try ProviderStagingWriter().write([Self.barRecord(), Self.navRecord()], to: spool)

        let result = try pipeline.commitRecords(fromSpool: spool)
        XCTAssertEqual(result.committedCount, 2)
        XCTAssertNil(result.commitError)
    }

    // MARK: - 审查修复新增（P2-4 / 内容冲突 / P2-5 / 晚发布闭环）

    /// P2-4：upsert ProviderIdentifier 指向不存在的 canonical 实体 → 事务内拒收。
    func testUpsertProviderIdentifier_danglingTargetRejected() {
        XCTAssertThrowsError(
            try repository.upsert(ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "stock_symbol",
                identifierValue: "777777", canonical: .listing(ListingID(rawValue: "lst_never")),
                resolutionMethod: .manualVerified, resolvedAt: Self.day(0)
            ))
        ) { error in
            guard case .danglingCanonicalTarget = error as? GRDBRepositoryError else {
                return XCTFail("应为 danglingCanonicalTarget，实际 \(error)")
            }
        }
        // 未落库
        XCTAssertNil(repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "777777"))
    }

    /// 审查 P1：同身份不同内容的重摄入经 Pipeline 逐条拒收（contentConflict），
    /// 不阻塞批内其他记录、不覆盖既有行。
    func testPipeline_contentConflictRejectedPerRecord() {
        _ = pipeline.commit(records: [Self.barRecord()])
        // 篡改收盘价的重摄入（同 providerCode / effective / published → 同身份）
        let tampered = Self.barRecord(close: Decimal(string: "10.63")!)   // 拓扑合法的不同内容
        let freshNAV = Self.navRecord()
        let result = pipeline.commit(records: [tampered, freshNAV])
        XCTAssertNil(result.commitError)
        XCTAssertEqual(result.committedCount, 1, "批内合法记录照常提交")
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections[0].stage, .contentConflict)
        // 二轮审查 P2：拒收携带原始记录身份（诊断 / 按记录重试的契约）
        XCTAssertEqual(result.rejections[0].provider, "eastmoney")
        XCTAssertEqual(result.rejections[0].scheme, "stock_symbol")
        XCTAssertEqual(result.rejections[0].value, "600519")
        XCTAssertEqual(result.rejections[0].kind, "DAILY_BAR")
        // 原行未被覆盖
        let exact = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .exactSnapshot(at: Self.day(0))
        )
        XCTAssertEqual(exact.first?.rawClose.value, Decimal(string: "10.62"))
    }

    /// P2-5：单项权重合法但合计 0.6+0.6 越界 → 语义闸门拒收。
    func testFirewall3_positionsSumExceedsHundredPercent() {
        let bad = Self.holdingRecord(weights: [Decimal(string: "0.6")!, Decimal(string: "0.6")!],
                                     total: Decimal(string: "1.0")!)
        let result = pipeline.commit(records: [bad])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertTrue(result.rejections[0].reason.contains("合计超过 100%"))
    }

    /// P2-5：披露总权与已披露明细合计不一致 → 拒收。
    func testFirewall3_disclosedTotalMismatch() {
        let bad = Self.holdingRecord(weights: [Decimal(string: "0.4")!, Decimal(string: "0.3")!],
                                     total: Decimal(string: "0.9")!)   // 明细 0.7 ≠ 0.9
        let result = pipeline.commit(records: [bad])
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertTrue(result.rejections[0].reason.contains("不一致"))
    }

    /// 晚发布闭环：publishedAt 晚于 policy 可知窗口的行情记录不再被拒收，
    /// availableAt 上抬到 publishedAt（DATA005 客观可知）。
    func testLatePublishedRecord_acceptedWithLiftedAvailability() {
        var late = Self.barRecord()
        late = ProviderRecord(
            providerID: late.providerID, providerCode: late.providerCode,
            effectiveAt: Self.day(0), publishedAt: Self.day(5), ingestedAt: Self.day(5),
            kind: late.kind, rawPayload: late.rawPayload,
            reliabilityClass: late.reliabilityClass, jurisdiction: late.jurisdiction
        )
        let result = pipeline.commit(records: [late])
        XCTAssertEqual(result.committedCount, 1, "晚发布不再被 temporalNormalizeFailed 拒收")
        let bars = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .economicKnowledge(asOf: Self.day(6))
        )
        XCTAssertEqual(bars.first?.temporalEnvelope.availableAt, Self.day(5),
                       "availableAt = max(下界, publishedAt)")
        // 可知窗口之前仍不可见（PIT 语义保持）
        XCTAssertNil(repository.dailyBar(
            listingID: ListingID(rawValue: "lst_600519"),
            on: Self.day(0),
            context: .economicKnowledge(asOf: Self.day(4))
        ))
    }

    /// 二轮审查 P1：同一事实经同 Provider 的另一个精确 identifier alias 摄入
    ///（派生不同 ObservationID）→ 业务身份幂等归并，不误判内容冲突。
    func testAliasIngestion_differentObservationID_idempotent() throws {
        // 登记 alias：ticker "600519.SH" 也指向 lst_600519（authoritative）
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "ticker",
            identifierValue: "600519.SH", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: Self.day(0)
        ))
        _ = pipeline.commit(records: [Self.barRecord()])
        var alias = Self.barRecord()
        alias = ProviderRecord(
            providerID: alias.providerID,
            providerCode: ProviderCode(scheme: "ticker", value: "600519.SH"),
            effectiveAt: alias.effectiveAt, publishedAt: alias.publishedAt,
            ingestedAt: alias.ingestedAt, kind: alias.kind,
            rawPayload: alias.rawPayload,
            reliabilityClass: alias.reliabilityClass, jurisdiction: alias.jurisdiction
        )
        let result = pipeline.commit(records: [alias])
        XCTAssertEqual(result.committedCount, 1, "alias 摄入幂等归并，非冲突")
        XCTAssertTrue(result.rejections.isEmpty)
        let exact = repository.dailyBars(
            listingID: ListingID(rawValue: "lst_600519"),
            context: .exactSnapshot(at: Self.day(0))
        )
        XCTAssertEqual(exact.count, 1, "业务身份一行，不因 alias 翻倍")
    }

    // MARK: - fixture

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let w = cal.component(.weekday, from: date)
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

    private static func barPayload(
        rawLow: Decimal = Decimal(string: "10.40")!,
        close: Decimal = Decimal(string: "10.62")!
    ) -> Data {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "10.50")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.80")!, currency: .cny),
            rawLow: Price(value: rawLow, currency: .cny),
            rawClose: Price(value: close, currency: .cny),
            volume: 1_000_000,
            adjustmentFactor: Decimal(string: "1.0")!,
            fxRate: nil
        )
        let encoder = JSONEncoder()
        return try! encoder.encode(payload)
    }

    private static func barRecord(
        rawLow: Decimal = Decimal(string: "10.40")!,
        close: Decimal = Decimal(string: "10.62")!
    ) -> ProviderRecord {
        ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: day(0), publishedAt: day(0), ingestedAt: day(1),
            kind: .dailyBar,
            rawPayload: barPayload(rawLow: rawLow, close: close),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    /// 更正重公布：publishedAt 晚 3 天（超出 MarketClose 的 T+1 可知窗口）。
    /// 审查遗留闭环：normalizer 现按 availableAt = max(policy 下界, publishedAt)
    /// 处理晚发布（DATA005「客观可知」），此类修订不再被拒收。
    private static func correctedBarRecord() -> ProviderRecord {
        let base = barRecord()
        return ProviderRecord(
            providerID: base.providerID, providerCode: base.providerCode,
            effectiveAt: base.effectiveAt, publishedAt: day(3), ingestedAt: day(4),
            kind: base.kind,
            rawPayload: {
                let payload = DailyBarPayload(
                    rawOpen: Price(value: Decimal(string: "10.51")!, currency: .cny),
                    rawHigh: Price(value: Decimal(string: "10.81")!, currency: .cny),
                    rawLow: Price(value: Decimal(string: "10.41")!, currency: .cny),
                    rawClose: Price(value: Decimal(string: "10.80")!, currency: .cny),
                    volume: 1_100_000,
                    adjustmentFactor: Decimal(string: "1.0")!,
                    fxRate: nil
                )
                return try! JSONEncoder().encode(payload)
            }(),
            reliabilityClass: base.reliabilityClass, jurisdiction: base.jurisdiction
        )
    }

    private static func navRecord() -> ProviderRecord {
        ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: day(0), publishedAt: day(0), ingestedAt: day(1),
            kind: .navObservation,
            rawPayload: {
                let payload = NAVPayload(
                    unitNAV: Price(value: Decimal(string: "2.8315")!, currency: .cny),
                    accumulatedNAV: nil,
                    cumulativeDividendPerShare: nil
                )
                return try! JSONEncoder().encode(payload)
            }(),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private static func holdingRecord(
        weight: Decimal? = nil, weights: [Decimal]? = nil, total: Decimal? = nil
    ) -> ProviderRecord {
        let positionWeights = weights ?? [weight ?? Decimal(string: "0.0987")!]
        let disclosedTotal = total ?? positionWeights.reduce(Decimal.zero, +)
        return holdingRecordRaw(weights: positionWeights, total: disclosedTotal)
    }

    private static func holdingRecordRaw(weights: [Decimal], total: Decimal) -> ProviderRecord {
        ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_product_code", value: "110022"),
            effectiveAt: day(0), publishedAt: day(18), ingestedAt: day(19),
            kind: .fundHoldingSnapshot,
            rawPayload: {
                let payload = FundHoldingPayload(
                    reportPeriod: .q2,
                    positions: weights.map {
                        FundHoldingPayload.Position(
                            providerID: .eastmoney,
                            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                            weight: Ratio(value: $0),
                            shares: nil, marketValue: nil, isDisclosed: true
                        )
                    },
                    disclosedWeightTotal: Ratio(value: total)
                )
                return try! JSONEncoder().encode(payload)
            }(),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private func seedFuzzyIdentifier() throws {
        // fuzzy 映射指向真实存在的 listing（目标存在性验证是 P2-4 新增；
        // fuzzy 的拒收语义在 resolutionMethod，与目标真假无关）
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "999999", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .fuzzyCandidate, resolvedAt: Self.day(0)
        ))
    }

    /// identity 底座（FK 前置）+ provider identifiers（resolver 前置）。
    private func seedIdentity() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_x"), displayName: "某基金管理有限公司",
            jurisdiction: .chinaMainland, kind: .fundManager
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .stock, displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_600519"), instrumentID: InstrumentID(rawValue: "inst_600519"),
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_110022"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .fund, displayName: "易方达消费行业股票", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(FundProduct(
            id: FundProductID(rawValue: "fp_110022"), instrumentID: InstrumentID(rawValue: "inst_110022"),
            fundType: .openEnd, displayName: "易方达消费行业股票（产品）"
        ))
        try repository.upsert(FundShareClass(
            id: FundShareClassID(rawValue: "fsc_110022_A"), productID: FundProductID(rawValue: "fp_110022"),
            instrumentID: InstrumentID(rawValue: "inst_110022"), shareClassCode: "A", displayName: "A",
            feeStructure: .init(frontEndLoad: nil, backEndLoad: nil,
                                annualSalesFee: nil, managementFee: nil, custodyFee: nil)
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: Self.day(0)
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_code",
            identifierValue: "110022", canonical: .fundShareClass(FundShareClassID(rawValue: "fsc_110022_A")),
            resolutionMethod: .manualVerified, resolvedAt: Self.day(0)
        ))
        // 持仓快照是 Product 维度（A/C 共享），用独立的 product 级 scheme
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "fund_product_code",
            identifierValue: "110022", canonical: .fundProduct(FundProductID(rawValue: "fp_110022")),
            resolutionMethod: .manualVerified, resolvedAt: Self.day(0)
        ))
    }
}
