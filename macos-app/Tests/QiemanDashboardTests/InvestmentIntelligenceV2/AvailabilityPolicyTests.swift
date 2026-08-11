import XCTest
@testable import QiemanDashboard

/// DOM-7 单元测试：AvailabilityPolicy 协议 + V1 保守规则集。
///
/// 重点验证 ADR-DATA005 §Decision 1（三类 V1 规则）+ §Decision 3（保守优先）+
/// 审查 P1 修复：rule 数据化、法域动态推导、Codable 验证 id/version。
final class AvailabilityPolicyTests: XCTestCase {

    // MARK: - 桩 TradingCalendar（REPO-2 会做真实实现）
    //
    // 简化假设：每周一~五是交易日（不考虑节假日，真实节假日由 SYNC-1 处理）。
    // tradingDay(after:offset:) 返回从 base 起第 N 个交易日（不含 base 当日）。
    private struct WeekdayOnlyCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return weekday >= 2 && weekday <= 6   // Monday(2)..Friday(6)
        }

        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date
            var remaining = max(offset, 0)
            var safety = 0
            while remaining > 0 && safety < 14 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    remaining -= 1
                }
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

    private let calendar = WeekdayOnlyCalendar()

    // MARK: - Policy 结构（每条 policy 含 id/version/rule/provenance，可审计）

    func testFundNAVPolicy_structure() {
        let p = AvailabilityPolicyV1.FundNAV()
        XCTAssertEqual(p.policyID, "fund_nav")
        XCTAssertEqual(p.version, "v1")
        XCTAssertEqual(p.applicableKind, .fundNAV)
        XCTAssertEqual(p.provenance, .manual)
        // rule 数据化（审查 P1 修复：规则不再藏在方法体）
        XCTAssertEqual(p.rule.base, .effectiveAt)
        XCTAssertEqual(p.rule.offset.tradingDays, 1)
        XCTAssertEqual(p.rule.jurisdictionSource, .fixed(.chinaMainland))
    }

    func testMarketClosePolicy_structure() {
        let p = AvailabilityPolicyV1.MarketClose()
        XCTAssertEqual(p.policyID, "market_close")
        XCTAssertEqual(p.version, "v1")
        XCTAssertEqual(p.applicableKind, .marketClose)
        // 法域从 listing 推导（审查 P1 修复：不硬编码 chinaMainland）
        XCTAssertEqual(p.rule.base, .effectiveAt)
        XCTAssertEqual(p.rule.offset.tradingDays, 1)
        XCTAssertEqual(p.rule.jurisdictionSource, .fromListing)
    }

    func testFundDisclosurePolicy_structure() {
        let p = AvailabilityPolicyV1.FundDisclosure()
        XCTAssertEqual(p.policyID, "fund_disclosure")
        XCTAssertEqual(p.version, "v1")
        XCTAssertEqual(p.applicableKind, .fundDisclosure)
        XCTAssertEqual(p.rule.base, .publishedAt)   // 公告日为基准
        XCTAssertEqual(p.rule.offset.tradingDays, 1)
        XCTAssertEqual(p.rule.jurisdictionSource, .fromListing)
    }

    func testV1All_threePolicies() {
        XCTAssertEqual(AvailabilityPolicyV1.all.count, 3)
        let kinds = AvailabilityPolicyV1.all.map(\.applicableKind)
        XCTAssertEqual(Set(kinds), Set(AvailabilityPolicyKind.allCases))
    }

    // MARK: - V1 保守规则：availableAt = nextTradingDay(base) 00:00

    func testFundNAV_availableAtNextTradingDay() {
        // navDate 2024-07-18（周四），base=effectiveAt，offset+1 → 7-19（周五）
        let navDate = makeDate(2024, 7, 18)
        let p = AvailabilityPolicyV1.FundNAV()
        let availableAt = p.availableAt(
            effectiveAt: navDate,
            publishedAt: navDate,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 19))
    }

    func testFundNAV_availableAtSkipsWeekend() {
        // navDate 2024-07-19（周五）→ 次交易日跳周末 = 7-22（周一）
        let navDate = makeDate(2024, 7, 19)
        let p = AvailabilityPolicyV1.FundNAV()
        let availableAt = p.availableAt(
            effectiveAt: navDate,
            publishedAt: navDate,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 22))
    }

    func testMarketClose_availableAtNextTradingDay() {
        let tradingDay = makeDate(2024, 7, 18)
        let p = AvailabilityPolicyV1.MarketClose()
        let availableAt = p.availableAt(
            effectiveAt: tradingDay,
            publishedAt: tradingDay,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 19))
    }

    func testFundDisclosure_availableAtNextTradingDayAfterAnnouncement() {
        // 报告期 effectiveAt 2024-06-30，公告 publishedAt 2024-07-20（周六）
        // base = publishedAt，客观可知 = 公告日的次交易日 = 7-22（周一）
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)  // 周六
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 22))
    }

    // MARK: - 法域动态推导（审查 P1 修复：跨市场生效）

    func testMarketClose_respectsListingJurisdiction_US() {
        // 同一个 tradingDay，A股（CN）和美股（US）在桩日历下都是下一工作日。
        // 关键是 MarketClose 不再把结果硬编码为 chinaMainland，
        // 而是接受调用方传入的 jurisdiction（这里验证 API 接受 US 法域）。
        let tradingDay = makeDate(2024, 7, 18)
        let p = AvailabilityPolicyV1.MarketClose()
        let usAvailable = p.availableAt(
            effectiveAt: tradingDay,
            publishedAt: tradingDay,
            jurisdiction: .unitedStates,
            calendar: calendar
        )
        // 桩日历对 US 与 CN 行为一致（都是下一工作日），真实日历会在节假日不同
        XCTAssertEqual(usAvailable, makeDate(2024, 7, 19))
    }

    func testMarketClose_jurisdictionSourceFromListing_usesProvidedJurisdiction() {
        // jurisdictionSource = .fromListing：调用方传什么 jurisdiction 就用什么。
        // 这是修复的核心——不再无视传入的 jurisdiction。
        let p = AvailabilityPolicyV1.MarketClose()
        XCTAssertEqual(p.rule.jurisdictionSource, .fromListing)
        // 即使传 HK，policy 也尊重它（而非硬编 CN）
        let hk = p.availableAt(
            effectiveAt: makeDate(2024, 7, 18),
            publishedAt: makeDate(2024, 7, 18),
            jurisdiction: .hongKong,
            calendar: calendar
        )
        XCTAssertNotNil(hk)
    }

    func testFundNAV_fixedJurisdiction_ignoresProvidedJurisdiction() {
        // FundNAV 用 .fixed(.chinaMainland)，即使调用方传 US 仍按 CN 算。
        // 公募基金净值公布日历按 CN 监管，跨市场不适用。
        let p = AvailabilityPolicyV1.FundNAV()
        XCTAssertEqual(p.rule.jurisdictionSource, .fixed(.chinaMainland))
        let withUS = p.availableAt(
            effectiveAt: makeDate(2024, 7, 18),
            publishedAt: makeDate(2024, 7, 18),
            jurisdiction: .unitedStates,
            calendar: calendar
        )
        // fixed(.chinaMainland) 覆盖传入的 US；结果仍按 CN 日历
        XCTAssertEqual(withUS, makeDate(2024, 7, 19))
    }

    // MARK: - M2 场景 3：基金 Q2 持仓 7-22 才可知，7-10 查不到（防 lookahead）

    func testM2Scenario3_Q2HoldingNotVisibleAt710() {
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )!
        let mode = DataQueryMode.economicKnowledge(asOf: makeDate(2024, 7, 10))
        let env = TemporalEnvelope(
            effectiveAt: effective,
            publishedAt: announced,
            availableAt: availableAt,
            ingestedAt: makeDate(2024, 8, 1)
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testM2Scenario4_availableAtIsObjectiveNotIngestedAt() {
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )!
        let ingestedAt = makeDate(2024, 8, 1)
        XCTAssertNotEqual(availableAt, ingestedAt)
        let mode = DataQueryMode.economicKnowledge(asOf: makeDate(2024, 7, 22))
        let env = TemporalEnvelope(
            effectiveAt: effective,
            publishedAt: announced,
            availableAt: availableAt,
            ingestedAt: ingestedAt
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    // MARK: - 保守优先：publishedAt 早期不影响 availableAt（不乐观假设）

    func testConservative_publishedAtEarlyDoesNotAdvanceAvailableAt() {
        // MarketClose 的 base = effectiveAt（不是 publishedAt），
        // 即使 Provider 在 publishedAt 7-20 凌晨就给了，availableAt 仍按 effectiveAt 次交易日算
        let effective = makeDate(2024, 7, 19)  // 周五
        let published = makeDate(2024, 7, 20)  // 周六，Provider 实际给了
        let p = AvailabilityPolicyV1.MarketClose()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: published,
            jurisdiction: .chinaMainland,
            calendar: calendar
        )!
        // base=effectiveAt(7-19 周五)，offset+1 → 7-22 周一
        XCTAssertEqual(availableAt, makeDate(2024, 7, 22))
    }

    // MARK: - policy(for:) 工厂

    func testPolicyFactory_byKind() {
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .fundNAV) is AvailabilityPolicyV1.FundNAV)
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .marketClose) is AvailabilityPolicyV1.MarketClose)
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .fundDisclosure) is AvailabilityPolicyV1.FundDisclosure)
    }

    // MARK: - Codable：V1 policy 序列化 + 解码验证 id/version（审查 P1 修复）

    func testFundNAVPolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.FundNAV()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)
        XCTAssertEqual(p, decoded)
        XCTAssertEqual(decoded.policyID, "fund_nav")
        XCTAssertEqual(decoded.version, "v1")
    }

    func testMarketClosePolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.MarketClose()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.MarketClose.self, from: data)
        XCTAssertEqual(p, decoded)
        XCTAssertEqual(decoded.rule.jurisdictionSource, .fromListing)
    }

    func testFundDisclosurePolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.FundDisclosure()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.FundDisclosure.self, from: data)
        XCTAssertEqual(p, decoded)
        XCTAssertEqual(decoded.rule.base, .publishedAt)
    }

    func testAvailabilityRule_codableRoundTrip() throws {
        // rule 数据化后可独立序列化（用于 GRDB-6 持久化 policy 历史）
        let rule = AvailabilityRule(
            base: .publishedAt,
            offset: .init(tradingDays: 2),
            jurisdictionSource: .fixed(.hongKong)
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(AvailabilityRule.self, from: data)
        XCTAssertEqual(rule, decoded)
        XCTAssertEqual(decoded.offset.tradingDays, 2)
    }

    // MARK: - Codable 防静默解码（审查 P1 修复核心）

    private func mutatedJSON<T: Encodable>(_ value: T, mutate: (inout [String: Any]) -> Void) throws -> Data {
        let data = try JSONEncoder().encode(value)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        mutate(&dict)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    func testCodable_rejectsMismatchedPolicyID() throws {
        // 从正确的 FundNAV 编码，再把 policyID 改成错的，解时应抛 identityMismatch
        // 而非静默解成 fund_nav v1
        let data = try mutatedJSON(AvailabilityPolicyV1.FundNAV()) { dict in
            dict["policyID"] = "wrong_id"
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)) { err in
            guard case .identityMismatch(let pid, _) = err as? AvailabilityPolicyDecodeError else {
                XCTFail("expected identityMismatch, got \(err)"); return
            }
            XCTAssertEqual(pid, "wrong_id")
        }
    }

    func testCodable_rejectsMismatchedVersion() throws {
        // 从正确的 FundNAV 编码，再把 version 改成 v2，解时应抛 identityMismatch
        let data = try mutatedJSON(AvailabilityPolicyV1.FundNAV()) { dict in
            dict["version"] = "v2"
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)) { err in
            guard case .identityMismatch(_, let ver) = err as? AvailabilityPolicyDecodeError else {
                XCTFail("expected identityMismatch, got \(err)"); return
            }
            XCTAssertEqual(ver, "v2")
        }
    }

    func testCodable_rejectsMismatchedRule() throws {
        // rule.base 改成 PUBLISHED_AT（FundNAV 应是 EFFECTIVE_AT），解时应抛 identityMismatch
        let data = try mutatedJSON(AvailabilityPolicyV1.FundNAV()) { dict in
            var rule = dict["rule"] as! [String: Any]
            rule["base"] = "PUBLISHED_AT"
            dict["rule"] = rule
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)) { err in
            XCTAssertNotNil(err as? AvailabilityPolicyDecodeError, "got \(err)")
        }
    }

    func testCodable_acceptsExactV1RoundTrip() throws {
        // 正确的 V1 JSON 应正常解码（与 testFundNAVPolicy_codableRoundTrip 互补）
        let p = AvailabilityPolicyV1.FundNAV()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    // MARK: - 辅助

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }
}
