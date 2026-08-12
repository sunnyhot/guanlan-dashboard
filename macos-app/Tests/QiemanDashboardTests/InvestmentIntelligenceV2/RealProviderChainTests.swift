import XCTest
@testable import QiemanDashboard

/// 真实 Provider 链路端到端测试（审查 P0 修复）。
///
/// 这是 M2 的「真实数据」验证：从预录真实响应（天天基金 wire 格式）→
/// EastmoneyProviderAdapter 解析 → ProviderRecord → ObservationFactory 转换 →
/// CanonicalObservation → InMemoryRepository → PIT 查询。
///
/// 审查 P0 要求：M2 测试至少要使用录制自真实响应的 fixture，验证 Adapter
/// 解析链路。本测试满足该要求——不再是 stub filter，而是真实解析 + 完整转换。
final class RealProviderChainTests: XCTestCase {

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

    // MARK: - 真实 Provider 链路：fixture → Adapter → ProviderRecord

    /// 加载预录真实响应，跑完整 Adapter 解析。
    private func fetchEastmoneyRecords(fundCode: String, ingestedAt: Date) async throws -> [ProviderRecord] {
        let bundle = Bundle.module
        let pingzhongBody = try String(contentsOf: bundle.url(
            forResource: "v2-eastmoney-pingzhongdata-\(fundCode)", withExtension: "json.txt", subdirectory: "Fixtures"
        )!, encoding: .utf8)
        let lsjzBody = try String(contentsOf: bundle.url(
            forResource: "v2-eastmoney-lsjz-\(fundCode)", withExtension: "json", subdirectory: "Fixtures"
        )!, encoding: .utf8)
        let fetcher = StaticResponseFetcher([
            .pingzhongdata(fundCode: fundCode): pingzhongBody,
            .lsjz(fundCode: fundCode): lsjzBody
        ])
        let adapter = EastmoneyProviderAdapter(fetcher: fetcher) { ingestedAt }
        return try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: fundCode),
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    func testRealChain_eastmoneyProducesProviderRecordsWithRealPayload() async throws {
        // 真实响应 → ProviderRecord，rawPayload 含真实 NAV 字段
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))
        XCTAssertGreaterThanOrEqual(records.count, 3, "至少 3 条 NAV")

        // 每条 rawPayload 解出来是真实 NAVPayload
        for record in records {
            XCTAssertEqual(record.providerID, .eastmoney)
            XCTAssertEqual(record.kind, .navObservation)
            XCTAssertEqual(record.reliabilityClass, .communityAggregated)
            let payload = try JSONDecoder().decode(NAVPayload.self, from: record.rawPayload)
            XCTAssertGreaterThan(payload.unitNAV.value, 0, "单位净值应 > 0")
            XCTAssertEqual(payload.unitNAV.currency, .cny)
        }

        // 验证 fixture 里的具体值：pingzhongdata 第一条 y=3.5, equityReturn=0.012
        // tsMs=1719820800000 → 2024-07-01 08:00:00 CN（日界处理）
        let firstPayload = try JSONDecoder().decode(NAVPayload.self, from: records[0].rawPayload)
        XCTAssertEqual(firstPayload.unitNAV.value, Decimal(string: "3.5"))
    }

    // MARK: - 真实链路 → ObservationFactory → CanonicalObservation

    func testRealChain_providerRecordToCanonicalObservation() async throws {
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))

        // IdentityResolver 预登记 fund_code 110022 → sc_110022_A
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "fund_code", identifierValue: "110022",
                canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")),
                resolutionMethod: .manualVerified, resolvedAt: date(2024, 7, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )

        // 每条 ProviderRecord → CanonicalObservation
        var navObservations: [NAVObservation] = []
        for (idx, record) in records.enumerated() {
            let result = try factory.makeObservation(
                from: record,
                observationID: ObservationID(rawValue: "obs_\(idx)"),
                vintage: Vintage(announcementDate: record.effectiveAt, publisherVersion: 1)
            )
            if case .navObservation(let nav) = result {
                navObservations.append(nav)
            } else {
                XCTFail("expected navObservation")
            }
        }
        XCTAssertEqual(navObservations.count, records.count)

        // 验证 identity 解析：所有 NAV 都指向 sc_110022_A
        XCTAssertTrue(navObservations.allSatisfy { $0.shareClassID == FundShareClassID(rawValue: "sc_110022_A") })
        // 验证 PIT：availableAt 来自 FundNAV policy（effectiveAt 次交易日）
        // 验证 provenance 来自真实 policy
        XCTAssertTrue(navObservations.allSatisfy { $0.availabilityProvenance.policyID == "fund_nav" })
    }

    // MARK: - 真实链路 → Repository → PIT 查询（M2 场景 4 真实版）

    func testRealChain_providerDelayPITDifference() async throws {
        // Provider 故障：响应数据客观 availableAt 是 navDate 次交易日，
        // 但本机 8-01 才抓到（ingestedAt=8-01）
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 8, 1))

        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .eastmoney, identifierScheme: "fund_code", identifierValue: "110022",
                canonical: .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")),
                resolutionMethod: .manualVerified, resolvedAt: date(2024, 7, 1)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        for (idx, record) in records.enumerated() {
            let result = try factory.makeObservation(
                from: record,
                observationID: ObservationID(rawValue: "obs_\(idx)"),
                vintage: Vintage(announcementDate: record.effectiveAt, publisherVersion: 1)
            )
            if case .navObservation(let nav) = result {
                repo.upsert(nav)
            }
        }

        // 验证 ingestedAt=8-01，但 availableAt 是各 navDate 的次交易日（早于 8-01）
        let allNAV = repo.navObservations(
            shareClassID: FundShareClassID(rawValue: "sc_110022_A"),
            context: .economicKnowledge(asOf: date(2024, 12, 1))
        )
        XCTAssertFalse(allNAV.isEmpty)
        // 所有观测的 ingestedAt 都是 8-01
        XCTAssertTrue(allNAV.allSatisfy { $0.temporalEnvelope.ingestedAt == date(2024, 8, 1) })
        // 所有观测的 availableAt < 8-01（次交易日远早于 Provider 故障抓取时间）
        XCTAssertTrue(allNAV.allSatisfy { $0.temporalEnvelope.availableAt < date(2024, 8, 1) })

        // economicKnowledge(asOf: 7-23) 应能看到这些 NAV（客观可知）
        let atEconomic723 = repo.navObservations(
            shareClassID: FundShareClassID(rawValue: "sc_110022_A"),
            context: .economicKnowledge(asOf: date(2024, 7, 23))
        )
        XCTAssertFalse(atEconomic723.isEmpty, "economicKnowledge 应看到客观可知的 NAV")

        // operationalKnowledge(asOf: 7-23) 应看不到（本机还没抓到）
        let atOperational723 = repo.navObservations(
            shareClassID: FundShareClassID(rawValue: "sc_110022_A"),
            context: .operationalKnowledge(asOf: date(2024, 7, 23))
        )
        XCTAssertTrue(atOperational723.isEmpty, "operationalKnowledge(asOf:7-23) 应看不到，本机 8-01 才抓到")

        // operationalKnowledge(asOf: 8-01) 应看到
        let atOperational801 = repo.navObservations(
            shareClassID: FundShareClassID(rawValue: "sc_110022_A"),
            context: .operationalKnowledge(asOf: date(2024, 8, 1))
        )
        XCTAssertFalse(atOperational801.isEmpty, "operationalKnowledge(asOf:8-01) 应看到")
    }

    // MARK: - 真实链路：rawPayload 解析正确性（验证非 stub）

    func testRealChain_rawPayloadContainsRealParsedValues() async throws {
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))

        // pingzhongdata 与 LSJZ fixture 现在用同一组交易日（7-18/7-19/7-22），
        // 去重后应正好 3 条（不再因日期未归一化而变成 6 条，审查 P1）
        XCTAssertEqual(records.count, 3, "pingzhongdata + LSJZ 同一交易日应去重为 3 条")

        // 至少有一条 unitNAV = 3.5（pingzhongdata fixture 第一条 y=3.5）
        let payloads = try records.map { try JSONDecoder().decode(NAVPayload.self, from: $0.rawPayload) }
        let hasNav3_5 = payloads.contains { $0.unitNAV.value == Decimal(string: "3.5") }
        XCTAssertTrue(hasNav3_5, "应解析出 fixture 里 y=3.5 的真实净值")

        // 至少有一条 unitNAV = 3.55（pingzhongdata fixture 第三条 + lsjz 第三条）
        let hasNav3_55 = payloads.contains { $0.unitNAV.value == Decimal(string: "3.55") }
        XCTAssertTrue(hasNav3_55, "应解析出 fixture 里 y=3.55 的真实净值")
    }

    // MARK: - 真实累计净值解析（审查 P1：不伪造缺失字段）

    func testRealChain_accumulatedNAVParsedFromACWorthTrend() async throws {
        // fixture 的 Data_ACWorthTrend + LSJZ 的 LJJZ 都提供累计净值，
        // 应解析出真实值，而不是用单位净值占位
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))
        let payloads = try records.map { try JSONDecoder().decode(NAVPayload.self, from: $0.rawPayload) }

        // 每条都应有真实累计净值（4.2/4.19/4.25）
        XCTAssertTrue(payloads.allSatisfy { $0.accumulatedNAV != nil }, "累计净值应解析自真实源，不是 nil")
        let hasAc4_2 = payloads.contains { $0.accumulatedNAV?.value == Decimal(string: "4.2") }
        XCTAssertTrue(hasAc4_2, "应解析出 fixture 里累计净值 4.2")
        // 累计净值 ≠ 单位净值（证明不是伪造占位）
        XCTAssertTrue(payloads.allSatisfy { $0.accumulatedNAV!.value != $0.unitNAV.value },
                      "累计净值应不同于单位净值（证明解析了真实值，非伪造）")
    }

    func testRealChain_dividendIsNil_notFaked() async throws {
        // 审查 P1：天天基金不直接披露分红，cumulativeDividendPerShare 必须是 nil，
        // 不能伪造为 0（否则污染总回报计算）
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))
        let payloads = try records.map { try JSONDecoder().decode(NAVPayload.self, from: $0.rawPayload) }
        XCTAssertTrue(payloads.allSatisfy { $0.cumulativeDividendPerShare == nil },
                      "分红字段必须为 nil（天天基金不披露），不能伪造为 0")
    }

    func testRealChain_effectiveAtNormalizedToShanghaiTradingDay() async throws {
        // 审查 P1：pingzhongdata 的 tsMs 是盘中 UTC 时刻，effectiveAt 应归一化到
        // Asia/Shanghai 交易日界，否则 exactSnapshot 匹配不到
        let records = try await fetchEastmoneyRecords(fundCode: "110022", ingestedAt: date(2024, 7, 23))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for record in records {
            // effectiveAt 应是上海 00:00（交易日界）
            let comps = cal.dateComponents([.hour, .minute, .second], from: record.effectiveAt)
            XCTAssertEqual(comps.hour, 0, "effectiveAt 应归一化到上海 00:00")
            XCTAssertEqual(comps.minute, 0)
        }
    }

    // MARK: - schema 漂移抛错（审查 P1：不静默吞）

    func testPingzhongdata_schemaDriftThrows() {
        // Data_netWorthTrend 存在但 JSON 字段错（缺 y）应抛 netWorthTrendDecodeFailed，
        // 而非静默解释为「零条数据」
        let parser = EastmoneyResponseParser()
        let badBody = #"var Data_netWorthTrend = [{"x":1719820800000}];"#
        XCTAssertThrowsError(try parser.parsePingzhongdata(badBody, fundCode: "110022")) { err in
            if case .netWorthTrendDecodeFailed = err as? EastmoneyParseError {
                // ok
            } else {
                XCTFail("expected netWorthTrendDecodeFailed, got \(err)")
            }
        }
    }
}
