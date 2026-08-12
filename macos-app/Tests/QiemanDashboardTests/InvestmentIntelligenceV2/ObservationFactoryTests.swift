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
}
