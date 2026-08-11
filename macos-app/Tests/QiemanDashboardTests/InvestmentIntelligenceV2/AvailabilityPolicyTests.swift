import XCTest
@testable import QiemanDashboard

/// DOM-7 单元测试：AvailabilityPolicy 协议 + V1 保守规则集。
///
/// 重点验证 ADR-DATA005 §Decision 1（三类 V1 规则）+ §Decision 3（保守优先）。
final class AvailabilityPolicyTests: XCTestCase {

    // MARK: - 桩 TradingCalendar（REPO-2 会做真实实现）
    //
    // 简化假设：每周一~五是交易日（不考虑节假日，真实节假日由 SYNC-1 处理）。
    // 次交易日 = 次日（若次日是周末则顺延到周一）。
    private struct WeekdayOnlyCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
            // Sunday=1, Saturday=7
            return weekday >= 2 && weekday <= 6
        }

        func nextTradingDay(after date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date
            for _ in 0..<4 {  // 最多跳 4 天（跨周末）
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    return current
                }
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
    }

    func testMarketClosePolicy_structure() {
        let p = AvailabilityPolicyV1.MarketClose()
        XCTAssertEqual(p.policyID, "market_close")
        XCTAssertEqual(p.version, "v1")
        XCTAssertEqual(p.applicableKind, .marketClose)
    }

    func testFundDisclosurePolicy_structure() {
        let p = AvailabilityPolicyV1.FundDisclosure()
        XCTAssertEqual(p.policyID, "fund_disclosure")
        XCTAssertEqual(p.version, "v1")
        XCTAssertEqual(p.applicableKind, .fundDisclosure)
    }

    func testV1All_threePolicies() {
        XCTAssertEqual(AvailabilityPolicyV1.all.count, 3)
        let kinds = AvailabilityPolicyV1.all.map(\.applicableKind)
        XCTAssertEqual(Set(kinds), Set(AvailabilityPolicyKind.allCases))
    }

    // MARK: - V1 保守规则：availableAt = 次交易日 00:00

    func testFundNAV_availableAtNextTradingDay() {
        // navDate 2024-07-18（周四），次交易日 2024-07-19（周五）
        let navDate = makeDate(2024, 7, 18)
        let p = AvailabilityPolicyV1.FundNAV()
        let availableAt = p.availableAt(
            effectiveAt: navDate,
            publishedAt: navDate,
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 19))
    }

    func testFundNAV_availableAtSkipsWeekend() {
        // navDate 2024-07-19（周五），次交易日跳周末 = 2024-07-22（周一）
        let navDate = makeDate(2024, 7, 19)
        let p = AvailabilityPolicyV1.FundNAV()
        let availableAt = p.availableAt(
            effectiveAt: navDate,
            publishedAt: navDate,
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
            calendar: calendar
        )
        XCTAssertEqual(availableAt, makeDate(2024, 7, 19))
    }

    func testFundDisclosure_availableAtNextTradingDayAfterAnnouncement() {
        // 报告期 effectiveAt 2024-06-30，公告 publishedAt 2024-07-20（周六）
        // 客观可知 = 公告日次交易日（7-22 周一）
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)  // 周六
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            calendar: calendar
        )
        // 公告日 7-20（周六）的次交易日是 7-22（周一）
        XCTAssertEqual(availableAt, makeDate(2024, 7, 22))
    }

    // MARK: - M2 场景 3：基金 Q2 持仓 7-20 公告，7-10 查不到（防 lookahead）

    func testM2Scenario3_Q2HoldingNotVisibleAt710() {
        // 报告期 6-30，公告 7-20（周六），可知 = 7-22（周一）
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            calendar: calendar
        )!
        // economicKnowledge(asOf: 7-10) 应该查不到（availableAt 7-22 > 7-10）
        let mode = DataQueryMode.economicKnowledge(asOf: makeDate(2024, 7, 10))
        let env = TemporalEnvelope(
            effectiveAt: effective,
            publishedAt: announced,
            availableAt: availableAt,
            ingestedAt: makeDate(2024, 8, 1)
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    // MARK: - M2 场景 4：Provider 故障 ingestedAt ≠ availableAt

    func testM2Scenario4_availableAtIsObjectiveNotIngestedAt() {
        // Provider 故障延迟到 8-01 抓到，但 availableAt 仍记客观可知的 7-22
        let effective = makeDate(2024, 6, 30)
        let announced = makeDate(2024, 7, 20)
        let p = AvailabilityPolicyV1.FundDisclosure()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: announced,
            calendar: calendar
        )!
        let ingestedAt = makeDate(2024, 8, 1)

        // availableAt ≠ ingestedAt
        XCTAssertNotEqual(availableAt, ingestedAt)
        // 7-22 决策用 economicKnowledge(asOf: 7-22) 仍能看到
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
        // 即使 Provider 在 publishedAt 7-20 凌晨就给了（乐观情况），
        // 保守规则仍记客观可知为次交易日 7-22（V1 简化版统一次日）
        let effective = makeDate(2024, 7, 19)  // 周五
        let published = makeDate(2024, 7, 20)  // 周六，实际 Provider 给了
        let p = AvailabilityPolicyV1.MarketClose()
        let availableAt = p.availableAt(
            effectiveAt: effective,
            publishedAt: published,
            calendar: calendar
        )!
        // 不乐观假设周六就可知，仍记周一 7-22
        XCTAssertEqual(availableAt, makeDate(2024, 7, 22))
    }

    // MARK: - policy(for:) 工厂

    func testPolicyFactory_byKind() {
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .fundNAV) is AvailabilityPolicyV1.FundNAV)
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .marketClose) is AvailabilityPolicyV1.MarketClose)
        XCTAssertTrue(AvailabilityPolicyV1.policy(for: .fundDisclosure) is AvailabilityPolicyV1.FundDisclosure)
    }

    // MARK: - Codable（V1 policy 序列化用于 GRDB-6 持久化）

    func testFundNAVPolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.FundNAV()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.FundNAV.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    func testMarketClosePolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.MarketClose()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.MarketClose.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    func testFundDisclosurePolicy_codableRoundTrip() throws {
        let p = AvailabilityPolicyV1.FundDisclosure()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AvailabilityPolicyV1.FundDisclosure.self, from: data)
        XCTAssertEqual(p, decoded)
    }

    // MARK: - 辅助

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }
}
