import XCTest
@testable import QiemanDashboard

/// REPO-5 完整链测试：ObservationFactory 把 ProviderRecord 转成 CanonicalObservation。
///
/// 验证审查 P1 修复：ProviderRecord → policy 选择 → PIT 标注 → identity 解析 →
/// CanonicalObservation 端到端转换。
final class ObservationFactoryTests: XCTestCase {

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

    private var factory: ObservationFactory {
        // 预登记：eastmoney fund_code 110022 → FundShareClass
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "fund_code", identifierValue: "110022",
                canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")),
                resolutionMethod: .manualVerified, resolvedAt: date(2024, 7, 1)
            ),
            ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "stock_symbol", identifierValue: "600519",
                canonical: .listing(ListingID(rawValue: "list_sh600519")),
                resolutionMethod: .exchangeSymbolExact, resolvedAt: date(2024, 7, 1)
            )
        ])
        return ObservationFactory(normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver)
    }

    // MARK: - NAVObservation 完整链

    func testMakeObservation_navObservation_fullChain() throws {
        // Provider 给的 NAV raw payload
        let payload = NAVPayload(
            unitNAV: Price(value: 3.5, currency: .cny),
            accumulatedNAV: Price(value: 4.2, currency: .cny),
            cumulativeDividendPerShare: Price(value: 0.7, currency: .cny)
        )
        let record = ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: date(2024, 7, 18),   // 周四 navDate
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .navObservation,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )

        let result = try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs_nav_1"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )

        guard case .navObservation(let nav) = result else {
            XCTFail("expected .navObservation"); return
        }
        // identity 解析：fund_code 110022 → sc_110022_A
        XCTAssertEqual(nav.shareClassID, FundShareClassID(rawValue: "sc_110022_A"))
        // PIT：FundNAV policy，navDate 7-18 → availableAt 7-19
        XCTAssertEqual(nav.temporalEnvelope.availableAt, date(2024, 7, 19))
        XCTAssertEqual(nav.temporalEnvelope.ingestedAt, date(2024, 7, 19))
        // raw payload 解析
        XCTAssertEqual(nav.unitNAV.value, 3.5)
        XCTAssertEqual(nav.accumulatedNAV?.value, 4.2)
        // provenance 来自 FundNAV policy
        XCTAssertEqual(nav.availabilityProvenance.policyID, "fund_nav")
        // dataQuality 来自 Provider reliabilityClass
        XCTAssertEqual(nav.dataQuality.providerReliability, .communityAggregated)
    }

    // MARK: - DailyBar 完整链

    func testMakeObservation_dailyBar_fullChain() throws {
        let payload = DailyBarPayload(
            rawOpen: Price(value: 1700, currency: .cny),
            rawHigh: Price(value: 1720, currency: .cny),
            rawLow: Price(value: 1695, currency: .cny),
            rawClose: Price(value: 1710, currency: .cny),
            volume: 1_200_000,
            adjustmentFactor: 1.0,
            fxRate: nil
        )
        let record = ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: date(2024, 7, 18),   // 周四交易日
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .dailyBar,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )

        let result = try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs_bar_1"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )

        guard case .dailyBar(let bar) = result else {
            XCTFail("expected .dailyBar"); return
        }
        // identity 解析
        XCTAssertEqual(bar.listingID, ListingID(rawValue: "list_sh600519"))
        // PIT：MarketClose policy，7-18 → availableAt 7-19
        XCTAssertEqual(bar.temporalEnvelope.availableAt, date(2024, 7, 19))
        // raw payload
        XCTAssertEqual(bar.rawClose.value, 1710)
        XCTAssertEqual(bar.volume, 1_200_000)
        // provenance 来自 MarketClose policy
        XCTAssertEqual(bar.availabilityProvenance.policyID, "market_close")
    }

    // MARK: - 失败路径

    func testMakeObservation_throwsWhenIdentityUnresolved() throws {
        // 未登记的 Provider 代码
        let record = ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "UNKNOWN"),
            effectiveAt: date(2024, 7, 18),
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .dailyBar,
            rawPayload: try JSONEncoder().encode(DailyBarPayload(
                rawOpen: Price(value: 100, currency: .cny),
                rawHigh: Price(value: 101, currency: .cny),
                rawLow: Price(value: 99, currency: .cny),
                rawClose: Price(value: 100, currency: .cny),
                volume: 1000, adjustmentFactor: 1.0, fxRate: nil
            )),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )

        XCTAssertThrowsError(try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "x"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )) { err in
            XCTAssertEqual(err as? ObservationFactoryError, .identityUnresolved(providerCode: record.providerCode))
        }
    }

    func testMakeObservation_throwsWhenFuzzyNotResolved() throws {
        // fuzzy candidate 登记的代码不能直接 resolve（必须经 Verification）
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .akshare, identifierScheme: "name_match", identifierValue: "茅台",
                canonical: .listing(ListingID(rawValue: "list_600519")),
                resolutionMethod: .fuzzyCandidate, resolvedAt: date(2024, 7, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        let record = ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "name_match", value: "茅台"),
            effectiveAt: date(2024, 7, 18),
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .dailyBar,
            rawPayload: try JSONEncoder().encode(DailyBarPayload(
                rawOpen: Price(value: 100, currency: .cny),
                rawHigh: Price(value: 101, currency: .cny),
                rawLow: Price(value: 99, currency: .cny),
                rawClose: Price(value: 100, currency: .cny),
                volume: 1000, adjustmentFactor: 1.0, fxRate: nil
            )),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )

        // fuzzy 不应被 resolve → identityUnresolved
        XCTAssertThrowsError(try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "x"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )) { err in
            XCTAssertEqual(err as? ObservationFactoryError, .identityUnresolved(providerCode: record.providerCode))
        }
    }

    func testMakeObservation_throwsWhenPayloadCorrupt() throws {
        // rawPayload 不是合法 DailyBarPayload JSON
        let record = ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: date(2024, 7, 18),
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .dailyBar,
            rawPayload: Data("not json".utf8),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )

        XCTAssertThrowsError(try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "x"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )) { err in
            if case .payloadDecodeFailed = err as? ObservationFactoryError {
                // ok
            } else {
                XCTFail("expected payloadDecodeFailed, got \(err)")
            }
        }
    }

    // MARK: - ProviderRecord 含 ingestedAt（审查 P1 修复点）

    func testProviderRecord_containsIngestedAt() {
        let record = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "X"),
            effectiveAt: date(2024, 7, 18),
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 8, 1),   // Provider 故障延迟
            kind: .navObservation, rawPayload: Data(),
            reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland
        )
        let fieldNames = Mirror(reflecting: record).children.compactMap(\.label)
        XCTAssertTrue(fieldNames.contains("ingestedAt"), "ProviderRecord 必须含 ingestedAt")
        XCTAssertEqual(record.ingestedAt, date(2024, 8, 1))
    }

    // MARK: - M2 场景 4 完整链：Provider 故障 ingestedAt ≠ availableAt

    func testM2Scenario4_fullChain_ingestedAtDistinctFromAvailableAt() throws {
        let payload = NAVPayload(
            unitNAV: Price(value: 3.5, currency: .cny),
            accumulatedNAV: Price(value: 4.2, currency: .cny),
            cumulativeDividendPerShare: Price(value: 0.7, currency: .cny)
        )
        // Q2 持仓 effectiveAt=6-30，公告 publishedAt=7-20，Provider 故障 ingestedAt=8-01
        // 但这里是 NAVObservation 走 FundNAV policy，简化用 NAV 日历演示
        let record = ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
            effectiveAt: date(2024, 7, 19),   // 周五 navDate
            publishedAt: date(2024, 7, 19),
            ingestedAt: date(2024, 8, 1),     // Provider 故障延迟
            kind: .navObservation,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
        let result = try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs"),
            vintage: Vintage(announcementDate: date(2024, 8, 1), publisherVersion: 1)
        )
        guard case .navObservation(let nav) = result else { XCTFail(); return }
        // availableAt = nextTradingDay(7-19) = 7-22（周一），不受 ingestedAt 影响
        XCTAssertEqual(nav.temporalEnvelope.availableAt, date(2024, 7, 22))
        XCTAssertEqual(nav.temporalEnvelope.ingestedAt, date(2024, 8, 1))
        XCTAssertNotEqual(nav.temporalEnvelope.availableAt, nav.temporalEnvelope.ingestedAt)
        // economicKnowledge(asOf: 7-22) 可见，operationalKnowledge(asOf: 7-22) 不可见
        XCTAssertTrue(DataQueryMode.economicKnowledge(asOf: date(2024, 7, 22)).includes(envelope: nav.temporalEnvelope))
        XCTAssertFalse(DataQueryMode.operationalKnowledge(asOf: date(2024, 7, 22)).includes(envelope: nav.temporalEnvelope))
    }

    // MARK: - REPO-5b：FundHoldingSnapshot 完整链

    /// 构造含基金持仓所需 identity 的 factory（prodCode → fundProduct + 持仓 listings）。
    private func holdingFactory(positionListed: Bool = true) -> ObservationFactory {
        var identifiers: [ProviderIdentifier] = [
            // 基金产品：长赢 prodCode → fundProduct
            ProviderIdentifier(
                providerID: .qieman, identifierScheme: "prodCode", identifierValue: "LONG_WIN",
                canonical: .fundProduct(FundProductID(rawValue: "fp_longwin")),
                resolutionMethod: .providerAuthoritative, resolvedAt: date(2024, 7, 1)
            ),
            // 持仓 1：茅台 600519 → listing
            ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "stock_symbol", identifierValue: "600519",
                canonical: .listing(ListingID(rawValue: "list_sh600519")),
                resolutionMethod: .exchangeSymbolExact, resolvedAt: date(2024, 7, 1)
            )
        ]
        if positionListed {
            // 持仓 2：美的 000333 → listing
            identifiers.append(ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "stock_symbol", identifierValue: "000333",
                canonical: .listing(ListingID(rawValue: "list_sz000333")),
                resolutionMethod: .exchangeSymbolExact, resolvedAt: date(2024, 7, 1)
            ))
        }
        return ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()),
            resolver: IdentityResolver.from(identifiers)
        )
    }

    func testMakeObservation_fundHoldingSnapshot_fullChain() throws {
        // Q2 持仓：effectiveAt=6-30，公告 publishedAt=7-20（周六）
        let payload = FundHoldingPayload(
            reportPeriod: .q2,
            positions: [
                .init(providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                      weight: Ratio(value: 0.08), shares: 1000,
                      marketValue: Price(value: 1_700_000, currency: .cny), isDisclosed: true),
                .init(providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "000333"),
                      weight: Ratio(value: 0.05), shares: 2000,
                      marketValue: Price(value: 220_000, currency: .cny), isDisclosed: true)
            ],
            disclosedWeightTotal: Ratio(value: 0.13)
        )
        let record = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "LONG_WIN"),
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),   // 周六公告
            ingestedAt: date(2024, 7, 21),
            kind: .fundHoldingSnapshot,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland
        )
        let result = try holdingFactory().makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs_hold_1"),
            vintage: Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        )
        guard case .fundHoldingSnapshot(let snap) = result else {
            XCTFail("expected .fundHoldingSnapshot"); return
        }
        // identity：prodCode LONG_WIN → fundProduct
        XCTAssertEqual(snap.productID, FundProductID(rawValue: "fp_longwin"))
        // 持仓 position 的 Provider 代码已解析为 Canonical ListingID（防火墙 1）
        XCTAssertEqual(snap.positions.count, 2)
        XCTAssertEqual(snap.positions[0].listingID, ListingID(rawValue: "list_sh600519"))
        XCTAssertEqual(snap.positions[1].listingID, ListingID(rawValue: "list_sz000333"))
        XCTAssertEqual(snap.disclosedWeightTotal.value, 0.13)
        // PIT：FundDisclosure policy，base=publishedAt=7-20（周六）→ availableAt=7-22（周一）
        XCTAssertEqual(snap.temporalEnvelope.availableAt, date(2024, 7, 22))
        XCTAssertEqual(snap.availabilityProvenance.policyID, "fund_disclosure")
    }

    func testMakeObservation_fundHoldingSnapshot_throwsWhenPositionUnresolved() throws {
        // 第二个 position（000333）未在 resolver 登记 → 整条 snapshot 拒收
        let factory = holdingFactory(positionListed: false)
        let payload = FundHoldingPayload(
            reportPeriod: .q2,
            positions: [
                .init(providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                      weight: Ratio(value: 0.08), shares: 1000,
                      marketValue: Price(value: 1_700_000, currency: .cny), isDisclosed: true),
                .init(providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "000333"),
                      weight: Ratio(value: 0.05), shares: 2000,
                      marketValue: Price(value: 220_000, currency: .cny), isDisclosed: true)
            ],
            disclosedWeightTotal: Ratio(value: 0.13)
        )
        let record = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "LONG_WIN"),
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 7, 21),
            kind: .fundHoldingSnapshot,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland
        )
        XCTAssertThrowsError(try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "x"),
            vintage: Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        )) { err in
            // 应指向未解析的 position 代码，而非快照本身的 prodCode
            XCTAssertEqual(
                err as? ObservationFactoryError,
                .identityUnresolved(providerCode: ProviderCode(scheme: "stock_symbol", value: "000333"))
            )
        }
    }

    func testMakeObservation_fundHoldingSnapshot_throwsOnIdentityTypeMismatch() throws {
        // prodCode 解析到 fundShareClass（而非 fundProduct）→ 类型不匹配，拒收
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .qieman, identifierScheme: "prodCode", identifierValue: "LONG_WIN",
                canonical: .fundShareClass(FundShareClassID(rawValue: "sc_longwin_a")),
                resolutionMethod: .manualVerified, resolvedAt: date(2024, 7, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        let payload = FundHoldingPayload(
            reportPeriod: .q2, positions: [], disclosedWeightTotal: Ratio(value: 0)
        )
        let record = ProviderRecord(
            providerID: .qieman,
            providerCode: ProviderCode(scheme: "prodCode", value: "LONG_WIN"),
            effectiveAt: date(2024, 6, 30), publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 7, 21), kind: .fundHoldingSnapshot,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland
        )
        XCTAssertThrowsError(try factory.makeObservation(
            from: record, observationID: ObservationID(rawValue: "x"),
            vintage: Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        )) { err in
            XCTAssertEqual(err as? ObservationFactoryError, .identityUnresolved(providerCode: record.providerCode))
        }
    }

    // MARK: - REPO-5b：MacroObservation 完整链

    func testMakeObservation_macroObservation_fullChain() throws {
        let payload = MacroPayload(
            value: 2.5, unit: .percent, frequency: .quarterly,
            isSeasonallyAdjusted: true, basePeriod: nil
        )
        let record = ProviderRecord(
            providerID: .fred,
            providerCode: ProviderCode(scheme: "fred_series", value: "GDP"),
            effectiveAt: date(2024, 7, 18),   // 周四
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .macroObservation,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .officialStable, jurisdiction: .chinaMainland
        )
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .fred, identifierScheme: "fred_series", identifierValue: "GDP",
                canonical: .instrument(InstrumentID(rawValue: "inst_gdp")),
                resolutionMethod: .providerAuthoritative, resolvedAt: date(2024, 7, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        let result = try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs_macro_1"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )
        guard case .macroObservation(let macro) = result else {
            XCTFail("expected .macroObservation"); return
        }
        XCTAssertEqual(macro.indicatorID, InstrumentID(rawValue: "inst_gdp"))
        XCTAssertEqual(macro.value, 2.5)
        XCTAssertEqual(macro.unit, .percent)
        XCTAssertEqual(macro.frequency, .quarterly)
        XCTAssertTrue(macro.isSeasonallyAdjusted)
        // PIT：MarketClose policy（宏观暂复用），base=effectiveAt=7-18 → availableAt=7-19
        XCTAssertEqual(macro.temporalEnvelope.availableAt, date(2024, 7, 19))
        XCTAssertEqual(macro.availabilityProvenance.policyID, "market_close")
        XCTAssertEqual(macro.dataQuality.providerReliability, .officialStable)
    }

    // MARK: - REPO-5b：CorporateAction 完整链

    func testMakeObservation_corporateAction_fullChain() throws {
        let exDate = date(2024, 7, 18)
        let payload = CorporateActionPayload(
            kind: .cashDividend, exDate: exDate,
            recordDate: date(2024, 7, 17), payDate: date(2024, 7, 24),
            ratio: 0.50, currency: .cny
        )
        let record = ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: date(2024, 7, 18),    // 除权除息日
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            kind: .corporateAction,
            rawPayload: try JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland
        )
        let result = try factory.makeObservation(
            from: record,
            observationID: ObservationID(rawValue: "obs_ca_1"),
            vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)
        )
        guard case .corporateAction(let action) = result else {
            XCTFail("expected .corporateAction"); return
        }
        XCTAssertEqual(action.listingID, ListingID(rawValue: "list_sh600519"))
        XCTAssertEqual(action.kind, .cashDividend)
        XCTAssertEqual(action.exDate, exDate)
        XCTAssertEqual(action.recordDate, date(2024, 7, 17))
        XCTAssertEqual(action.payDate, date(2024, 7, 24))
        XCTAssertEqual(action.ratio, 0.50)
        XCTAssertEqual(action.currency, .cny)
        // PIT：FundDisclosure policy（公司行动暂复用），base=publishedAt=7-18 → availableAt=7-19
        XCTAssertEqual(action.temporalEnvelope.availableAt, date(2024, 7, 19))
        XCTAssertEqual(action.availabilityProvenance.policyID, "fund_disclosure")
    }

    // MARK: - REPO-5b：5 kind 全覆盖（不漏 case）

    func testMakeObservation_allFiveKindsProducible() throws {
        // 防止后续重构漏掉某个 kind 的 case（switch 穷尽性由编译器保证，此测试
        // 再从端到端确认每种 kind 都能产 CanonicalObservationKind 对应分支）
        let resolver = IdentityResolver.from([
            ProviderIdentifier(providerID: .eastmoney, identifierScheme: "stock_symbol", identifierValue: "600519",
                               canonical: .listing(ListingID(rawValue: "list_sh600519")), resolutionMethod: .exchangeSymbolExact, resolvedAt: date(2024, 7, 1)),
            ProviderIdentifier(providerID: .eastmoney, identifierScheme: "fund_code", identifierValue: "110022",
                               canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")), resolutionMethod: .manualVerified, resolvedAt: date(2024, 7, 1)),
            ProviderIdentifier(providerID: .qieman, identifierScheme: "prodCode", identifierValue: "LONG_WIN",
                               canonical: .fundProduct(FundProductID(rawValue: "fp_longwin")), resolutionMethod: .providerAuthoritative, resolvedAt: date(2024, 7, 1)),
            ProviderIdentifier(providerID: .fred, identifierScheme: "fred_series", identifierValue: "GDP",
                               canonical: .instrument(InstrumentID(rawValue: "inst_gdp")), resolutionMethod: .providerAuthoritative, resolvedAt: date(2024, 7, 1))
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        let kinds: [(ProviderRecordKind, CanonicalObservationKind)] = try [
            (.dailyBar, try factory.makeObservation(from: ProviderRecord(
                providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                effectiveAt: date(2024, 7, 18), publishedAt: date(2024, 7, 18), ingestedAt: date(2024, 7, 19),
                kind: .dailyBar, rawPayload: try JSONEncoder().encode(DailyBarPayload(
                    rawOpen: Price(value: 1, currency: .cny), rawHigh: Price(value: 1, currency: .cny),
                    rawLow: Price(value: 1, currency: .cny), rawClose: Price(value: 1, currency: .cny),
                    volume: 1, adjustmentFactor: 1, fxRate: nil)),
                reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland),
                observationID: ObservationID(rawValue: "o1"),
                vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1))),
            (.navObservation, try factory.makeObservation(from: ProviderRecord(
                providerID: .eastmoney, providerCode: ProviderCode(scheme: "fund_code", value: "110022"),
                effectiveAt: date(2024, 7, 18), publishedAt: date(2024, 7, 18), ingestedAt: date(2024, 7, 19),
                kind: .navObservation, rawPayload: try JSONEncoder().encode(NAVPayload(
                    unitNAV: Price(value: 1, currency: .cny), accumulatedNAV: nil, cumulativeDividendPerShare: nil)),
                reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland),
                observationID: ObservationID(rawValue: "o2"),
                vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1))),
            (.fundHoldingSnapshot, try factory.makeObservation(from: ProviderRecord(
                providerID: .qieman, providerCode: ProviderCode(scheme: "prodCode", value: "LONG_WIN"),
                effectiveAt: date(2024, 6, 30), publishedAt: date(2024, 7, 20), ingestedAt: date(2024, 7, 21),
                kind: .fundHoldingSnapshot, rawPayload: try JSONEncoder().encode(FundHoldingPayload(
                    reportPeriod: .q2, positions: [
                        .init(providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                              weight: Ratio(value: 0.1), shares: nil, marketValue: nil, isDisclosed: true)
                    ], disclosedWeightTotal: Ratio(value: 0.1))),
                reliabilityClass: .undocumentedPublicEndpoint, jurisdiction: .chinaMainland),
                observationID: ObservationID(rawValue: "o3"),
                vintage: Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1))),
            (.macroObservation, try factory.makeObservation(from: ProviderRecord(
                providerID: .fred, providerCode: ProviderCode(scheme: "fred_series", value: "GDP"),
                effectiveAt: date(2024, 7, 18), publishedAt: date(2024, 7, 18), ingestedAt: date(2024, 7, 19),
                kind: .macroObservation, rawPayload: try JSONEncoder().encode(MacroPayload(
                    value: 1, unit: .index, frequency: .monthly, isSeasonallyAdjusted: false, basePeriod: nil)),
                reliabilityClass: .officialStable, jurisdiction: .chinaMainland),
                observationID: ObservationID(rawValue: "o4"),
                vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1))),
            (.corporateAction, try factory.makeObservation(from: ProviderRecord(
                providerID: .eastmoney, providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
                effectiveAt: date(2024, 7, 18), publishedAt: date(2024, 7, 18), ingestedAt: date(2024, 7, 19),
                kind: .corporateAction, rawPayload: try JSONEncoder().encode(CorporateActionPayload(
                    kind: .stockSplit, exDate: date(2024, 7, 18), recordDate: nil, payDate: nil,
                    ratio: 2, currency: nil)),
                reliabilityClass: .communityAggregated, jurisdiction: .chinaMainland),
                observationID: ObservationID(rawValue: "o5"),
                vintage: Vintage(announcementDate: date(2024, 7, 19), publisherVersion: 1)))
        ]
        // 5 kind 各自落到对应的 CanonicalObservationKind 分支
        for (kind, produced) in kinds {
            let matched: Bool
            switch (kind, produced) {
            case (.dailyBar, .dailyBar),
                 (.navObservation, .navObservation),
                 (.fundHoldingSnapshot, .fundHoldingSnapshot),
                 (.macroObservation, .macroObservation),
                 (.corporateAction, .corporateAction):
                matched = true
            default:
                matched = false
            }
            XCTAssertTrue(matched, "kind \(kind) 应产对应 CanonicalObservationKind，得到 \(produced)")
        }
        XCTAssertEqual(kinds.count, 5, "ProviderRecordKind 全部 5 种都已覆盖")
    }
}
