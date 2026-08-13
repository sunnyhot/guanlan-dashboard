import XCTest
@testable import QiemanDashboard

/// 天天基金真实解析链端到端测试（审查 P0 修复）。
///
/// 从 fixture（基于现有 QiemanPlatformFundQuoteFallbackTests inline mock 的真实
/// wire 格式派生——**不是 live network 录制**，审查 P1-4 修正表述）→
/// EastmoneyProviderAdapter 解析 → ProviderRecord → ObservationFactory 转换 →
/// CanonicalObservation → InMemoryRepository → PIT 查询。
///
/// 这验证了天天基金这一条 Provider 链路的真实解析（不是 stub filter）。
/// 但 **M2 仍未通过**：且慢 Provider 仍是 stub，live network 集成测试留 Epic 4。
/// 这些测试是 M2 的部分证据（天天基金链路），不是完整 M2 gate。
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

    // MARK: - Data_ACWorthTrend missing vs malformed（审查 P2）

    func testPingzhongdata_missingACWorthTrend_isLegitimateGap() throws {
        // Data_ACWorthTrend 变量不存在 → 合法缺口，accumulatedNAV 留 nil，不抛错
        let parser = EastmoneyResponseParser()
        let body = #"var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}];"#
        let history = try parser.parsePingzhongdata(body, fundCode: "110022")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(history.entries[0].accumulatedNAV, "缺 Data_ACWorthTrend 时 accumulatedNAV 应为 nil（合法缺口）")
    }

    func testPingzhongdata_malformedACWorthTrend_throws() {
        // Data_ACWorthTrend 变量存在但格式坏 → schema 漂移，抛 accumulatedTrendDecodeFailed，
        // 不静默降级为 nil（审查 P2）
        let parser = EastmoneyResponseParser()
        let body = #"var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}]; var Data_ACWorthTrend = [{bad}];"#
        XCTAssertThrowsError(try parser.parsePingzhongdata(body, fundCode: "110022")) { err in
            if case .accumulatedTrendDecodeFailed = err as? EastmoneyParseError {
                // ok
            } else {
                XCTFail("expected accumulatedTrendDecodeFailed, got \(err)")
            }
        }
    }

    // MARK: - Data_ACWorthTrend 声明存在但值非数组（审查 P2）

    func testPingzhongdata_acWorthTrendNull_throws() {
        // `var Data_ACWorthTrend = null;` 声明存在但值非数组 → schema 漂移，抛错，
        // 不当成合法缺失（审查 P2：先判断变量声明存在性）
        let parser = EastmoneyResponseParser()
        let body = #"var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}]; var Data_ACWorthTrend = null;"#
        XCTAssertThrowsError(try parser.parsePingzhongdata(body, fundCode: "110022")) { err in
            if case .accumulatedTrendDecodeFailed = err as? EastmoneyParseError {
                // ok
            } else {
                XCTFail("expected accumulatedTrendDecodeFailed for null ACWorthTrend, got \(err)")
            }
        }
    }

    func testPingzhongdata_acWorthTrendUnclosedArray_throws() {
        // 数组未闭合 `var Data_ACWorthTrend = [{"x":1,` → schema 漂移，抛错
        let parser = EastmoneyResponseParser()
        let body = #"var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}]; var Data_ACWorthTrend = [{"x":1,"#
        XCTAssertThrowsError(try parser.parsePingzhongdata(body, fundCode: "110022")) { err in
            if case .accumulatedTrendDecodeFailed = err as? EastmoneyParseError {
                // ok
            } else {
                XCTFail("expected accumulatedTrendDecodeFailed for unclosed array, got \(err)")
            }
        }
    }

    // 注：原 testPingzhongdata_acWorthTrendAbsent_isLegitimateGap 与
    // testPingzhongdata_missingACWorthTrend_isLegitimateGap 完全重复（都验证变量未声明
    // 时 accumulatedNAV 留 nil），合并为上面的 missing 版本（审查 P3）。

    // MARK: - Provider 诊断出口（审查 P2：LSJZ droppedMalformedCount 离开解析层）

    func testFetchWithDiagnostics_surfacesLSJZDroppedCount() async throws {
        // 个别 LSJZ 行格式异常 → diagnostics 应透传 droppedMalformedCount，
        // 不在 Adapter 构造 merged 时丢失（审查 P2）
        let pingBody = #"var fS_name = "T"; var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}];"#
        // LSJZ 有 2 条，其中 1 条格式异常
        let lsjzBody = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"2024-07-18","DWJZ":"3.5"},{"FSRQ":"bad","DWJZ":"x"}]}}
        """
        let fetcher = StaticResponseFetcher([
            .pingzhongdata(fundCode: "110022"): pingBody,
            .lsjz(fundCode: "110022"): lsjzBody
        ])
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(fetcher: fetcher) { d723 }

        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["lsjz"], 1,
                       "诊断应透传 LSJZ 的 droppedMalformedCount")
        XCTAssertEqual(result.diagnostics.totalDropped, 1)
        // records 仍返回（合法的那 1 条）
        XCTAssertGreaterThanOrEqual(result.records.count, 1)
    }

    func testFetchWithDiagnostics_cleanFixture_noDrops() async throws {
        // 正常 fixture 无丢弃，诊断应为空
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(
            fetcher: StaticResponseFetcher([
                .pingzhongdata(fundCode: "110022"): try String(contentsOf: Bundle.module.url(
                    forResource: "v2-eastmoney-pingzhongdata-110022", withExtension: "json.txt", subdirectory: "Fixtures"
                )!, encoding: .utf8),
                .lsjz(fundCode: "110022"): try String(contentsOf: Bundle.module.url(
                    forResource: "v2-eastmoney-lsjz-110022", withExtension: "json", subdirectory: "Fixtures"
                )!, encoding: .utf8)
            ])
        ) { d723 }
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.totalDropped, 0)
    }

    // MARK: - 字段级合并（审查 P1：LSJZ 的 LJJZ 填补 ping 缺失的 accumulatedNAV）

    func testMerge_pingMissingAccumulated_lsjzFillsIt() async throws {
        // 构造 pingzhongdata 无 Data_ACWorthTrend（accumulatedNAV 全 nil），
        // LSJZ 有 LJJZ。字段级合并应让合并结果的 accumulatedNAV 来自 LSJZ。
        let pingBody = """
        var fS_name = "测试";
        var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}];
        """
        let lsjzBody = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"2024-07-18","DWJZ":"3.5000","JZZZL":"1.20","LJJZ":"4.20"}]}}
        """
        let fetcher = StaticResponseFetcher([
            .pingzhongdata(fundCode: "110022"): pingBody,
            .lsjz(fundCode: "110022"): lsjzBody
        ])
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(fetcher: fetcher) { d723 }
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        // 合并后 1 条（同日），不应因 ping 缺 AC 而丢 LSJZ 的 LJJZ
        XCTAssertEqual(records.count, 1)
        let payload = try JSONDecoder().decode(NAVPayload.self, from: records[0].rawPayload)
        XCTAssertEqual(payload.accumulatedNAV?.value, Decimal(string: "4.20"),
                       "ping 缺 accumulatedNAV 时，LSJZ 的 LJJZ 应通过字段级合并填补")
    }

    func testMerge_lsjzOfficialPriorityForUnitNAV() async throws {
        // 同日 pingzhongdata 与 LSJZ 都有 unitNAV，LSJZ（近期官方）应优先
        let pingBody = """
        var fS_name = "测试";
        var Data_netWorthTrend = [{"x":1721308800000,"y":3.5,"equityReturn":0.01}];
        var Data_ACWorthTrend = [{"x":1721308800000,"y":4.2}];
        """
        let lsjzBody = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"2024-07-18","DWJZ":"3.55","JZZZL":"1.43","LJJZ":"4.25"}]}}
        """
        let fetcher = StaticResponseFetcher([
            .pingzhongdata(fundCode: "110022"): pingBody,
            .lsjz(fundCode: "110022"): lsjzBody
        ])
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(fetcher: fetcher) { d723 }
        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(records.count, 1)
        let payload = try JSONDecoder().decode(NAVPayload.self, from: records[0].rawPayload)
        // LSJZ 优先：unitNAV=3.55（LSJZ），accumulatedNAV=4.25（LSJZ）
        XCTAssertEqual(payload.unitNAV.value, Decimal(string: "3.55"))
        XCTAssertEqual(payload.accumulatedNAV?.value, Decimal(string: "4.25"))
    }

    func testParseLSJZ_countsDroppedMalformedEntries() throws {
        // 个别行格式异常应被丢弃但计入 droppedMalformedCount，而非静默
        let parser = EastmoneyResponseParser()
        let body = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"2024-07-18","DWJZ":"3.5"},{"FSRQ":"bad-date","DWJZ":"x"}]}}
        """
        let history = try parser.parseLSJZ(body, fundCode: "110022")
        XCTAssertEqual(history.entries.count, 1, "1 条合法 + 1 条格式异常")
        XCTAssertEqual(history.droppedMalformedCount, 1, "格式异常的行应被计入")
    }

    func testParseLSJZ_allMalformedThrows() {
        // 所有行都异常 → 整体 schema 失败，抛错
        let parser = EastmoneyResponseParser()
        let body = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"bad","DWJZ":"x"},{"FSRQ":"also-bad","DWJZ":"y"}]}}
        """
        XCTAssertThrowsError(try parser.parseLSJZ(body, fundCode: "110022")) { err in
            if case .invalidLSJZ = err as? EastmoneyParseError {
                // ok
            } else {
                XCTFail("expected invalidLSJZ, got \(err)")
            }
        }
    }

    // MARK: - 非有限数（NaN/Infinity）不崩溃（审查 P1）

    func testParseLSJZ_nonFiniteNumbersDroppedNotCrash() throws {
        // Double("NaN") / Double("Infinity") 会成功，但 Decimal(nonFinite) 会 trap。
        // 这些异常值必须进入 dropped 计数，绝不进入 entry（否则 toProviderRecords 崩溃）。
        let parser = EastmoneyResponseParser()
        let body = """
        {"ErrCode":0,"Data":{"LSJZList":[
            {"FSRQ":"2024-07-18","DWJZ":"3.5","JZZZL":"1.2","LJJZ":"4.2"},
            {"FSRQ":"2024-07-19","DWJZ":"NaN"},
            {"FSRQ":"2024-07-22","DWJZ":"Infinity","LJJZ":"Infinity"},
            {"FSRQ":"2024-07-23","DWJZ":"3.55","JZZZL":"NaN","LJJZ":"Infinity"}
        ]}}
        """
        let history = try parser.parseLSJZ(body, fundCode: "110022")
        // 2 条 NaN/Infinity 的 DWJZ 被丢弃（7-19、7-22）
        XCTAssertEqual(history.entries.count, 2, "DWJZ 为 NaN/Infinity 的行应被丢弃")
        XCTAssertEqual(history.droppedMalformedCount, 2, "两条非有限 NAV 计入 dropped")
        // 合法 entry 的 unitNAV 必须有限（绝不能让 NaN 漏到 Decimal 转换）
        XCTAssertTrue(history.entries.allSatisfy { $0.unitNAV.isFinite && $0.unitNAV > 0 })
        // 7-23 行 DWJZ 合法但 LJJZ=Infinity/JZZZL=NaN：这两个 Optional 字段应被滤为 nil，
        // 不进入 entry（否则后续 Decimal(accumulatedNAV) 仍会 trap）
        let lateEntry = history.entries.first { $0.unitNAV == 3.55 }
        XCTAssertNotNil(lateEntry)
        XCTAssertNil(lateEntry?.accumulatedNAV, "Infinity 的 LJJZ 应滤为 nil 而非保留非有限值")
        XCTAssertNil(lateEntry?.changePct, "NaN 的 JZZZL 应滤为 nil 而非保留非有限值")
    }

    func testAdapter_nonFiniteValues_toProviderRecordsDoesNotCrash() async throws {
        // 端到端：NaN/Infinity 经 Adapter → toProviderRecords（Decimal 转换）不得崩溃，
        // 且诊断出口应反映丢弃（审查 P1 + P2）。
        let pingBody = #"var fS_name = "T"; var Data_netWorthTrend = [{"x":1721308800000,"y":3.5}];"#
        let lsjzBody = """
        {"ErrCode":0,"Data":{"LSJZList":[{"FSRQ":"2024-07-19","DWJZ":"NaN"},{"FSRQ":"2024-07-18","DWJZ":"3.5"}]}}
        """
        let fetcher = StaticResponseFetcher([
            .pingzhongdata(fundCode: "110022"): pingBody,
            .lsjz(fundCode: "110022"): lsjzBody
        ])
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(fetcher: fetcher) { d723 }
        // 若 NaN 漏到 Decimal 转换，此调用会 trap 而非返回
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.droppedMalformedBySource["lsjz"], 1,
                       "NaN 的 LSJZ 行应计入诊断")
        // 每条存活的 record 其 payload 都能安全解码（Decimal 已避开非有限数）。
        // 若 NaN 漏进 Decimal 转换，上文 fetchWithDiagnostics 就已 trap，不会执行到这里。
        for record in result.records {
            let payload = try JSONDecoder().decode(NAVPayload.self, from: record.rawPayload)
            XCTAssertGreaterThan(payload.unitNAV.value, 0, "存活净值必须为正有限值")
        }
    }

    // MARK: - 诊断覆盖度：unsupported vs complete（审查 P2）

    func testDiagnostics_stubAdapter_reportsUnsupported() async throws {
        // 走默认 fetchWithDiagnostics 的桩 Adapter：completeness 必须是 .unsupported，
        // totalDropped == 0 不代表「确认零丢弃」（审查 P2）。
        // 用内联极简 stub（不覆盖 fetchWithDiagnostics），验证协议默认实现返回 .unsupported。
        struct StubAdapter: ProviderAdapter {
            let providerID: DataProviderID = .stooq
            let reliabilityClass: ProviderReliabilityClass = .documentFreeAPI
            let stubRecords: [ProviderRecord]
            func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
                stubRecords.filter { $0.providerCode == code && $0.effectiveAt >= from && $0.effectiveAt <= to }
            }
        }
        let stub = StubAdapter(stubRecords: [
            ProviderRecord(
                providerID: .stooq, providerCode: ProviderCode(scheme: "stock_symbol", value: "X"),
                effectiveAt: date(2024, 7, 1), publishedAt: date(2024, 7, 1), ingestedAt: date(2024, 7, 1),
                kind: .dailyBar, rawPayload: Data(), reliabilityClass: .documentFreeAPI,
                jurisdiction: .unitedStates
            )
        ])
        let result = try await stub.fetchWithDiagnostics(
            code: ProviderCode(scheme: "stock_symbol", value: "X"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.completeness, .unsupported,
                       "默认实现未覆盖诊断，应标 .unsupported")
        XCTAssertEqual(result.diagnostics.totalDropped, 0)
    }

    func testDiagnostics_eastmoneyAdapter_reportsComplete() async throws {
        // 真实 Adapter 实现了诊断出口：completeness 为 .complete，
        // totalDropped == 0 即确认零丢弃
        let d723 = date(2024, 7, 23)
        let adapter = EastmoneyProviderAdapter(
            fetcher: StaticResponseFetcher([
                .pingzhongdata(fundCode: "110022"): try String(contentsOf: Bundle.module.url(
                    forResource: "v2-eastmoney-pingzhongdata-110022", withExtension: "json.txt", subdirectory: "Fixtures"
                )!, encoding: .utf8),
                .lsjz(fundCode: "110022"): try String(contentsOf: Bundle.module.url(
                    forResource: "v2-eastmoney-lsjz-110022", withExtension: "json", subdirectory: "Fixtures"
                )!, encoding: .utf8)
            ])
        ) { d723 }
        let result = try await adapter.fetchWithDiagnostics(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(result.diagnostics.completeness, .complete,
                       "Eastmoney 覆盖诊断，应标 .complete")
        XCTAssertEqual(result.diagnostics.totalDropped, 0, "clean fixture 确认零丢弃")
    }
}
