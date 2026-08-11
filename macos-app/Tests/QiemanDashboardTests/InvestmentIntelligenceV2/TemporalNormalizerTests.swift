import XCTest
@testable import QiemanDashboard

/// REPO-5 单元测试：TemporalNormalizer 的 PIT 标注。
///
/// 重点验证 ADR-DATA005（availableAt 由 policy 推导）+ ADR-DATA002 §4
/// （ingestedAt 与 availableAt 不建立全序）。
final class TemporalNormalizerTests: XCTestCase {

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

    private let normalizer = TemporalNormalizer(calendar: WeekdayCalendar())

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    // MARK: - FundNAV：T 日净值 T+1 日可知

    func testNormalizeFundNAV_basicNextTradingDay() {
        let result = normalizer.normalizeFundNAV(
            effectiveAt: date(2024, 7, 18),   // 周四 navDate
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.envelope.availableAt, date(2024, 7, 19))   // 次交易日
        XCTAssertEqual(result?.envelope.ingestedAt, date(2024, 7, 19))
        XCTAssertEqual(result?.provenance.policyID, "fund_nav")
        XCTAssertEqual(result?.provenance.policyVersion, "v1")
    }

    func testNormalizeFundNAV_skipsWeekend() {
        let result = normalizer.normalizeFundNAV(
            effectiveAt: date(2024, 7, 19),   // 周五
            publishedAt: date(2024, 7, 19),
            ingestedAt: date(2024, 7, 22)
        )
        XCTAssertEqual(result?.envelope.availableAt, date(2024, 7, 22))   // 周一
    }

    // MARK: - M2 场景 4：Provider 故障 ingestedAt ≠ availableAt（核心）

    func testM2Scenario4_providerDelay_availableAtStaysObjective() {
        // 基金 Q2 持仓 effectiveAt=6-30，公告 publishedAt=7-20（周六）
        // Provider 故障延迟到 8-01 才抓到（ingestedAt=8-01）
        // availableAt 仍记客观可知 = nextTradingDay(7-20) = 7-22（周一）
        let result = normalizer.normalizeFundDisclosure(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),   // 周六
            ingestedAt: date(2024, 8, 1),     // Provider 故障延迟
            jurisdiction: .chinaMainland
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.envelope.availableAt, date(2024, 7, 22))   // 客观可知，不受 ingestedAt 影响
        XCTAssertEqual(result?.envelope.ingestedAt, date(2024, 8, 1))
        XCTAssertNotEqual(result?.envelope.availableAt, result?.envelope.ingestedAt)
        // TemporalEnvelope.validate() 不校验 availableAt <= ingestedAt（两者无全序）
        XCTAssertNil(result?.envelope.validate())
    }

    func testM2Scenario4_economicKnowledgeAt722SeesIt_operationalDoesNot() {
        // 同一 normalized envelope，两种 query mode 在 7-22 时点结果不同
        let result = normalizer.normalizeFundDisclosure(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 8, 1),
            jurisdiction: .chinaMainland
        )!
        let env = result.envelope
        // economicKnowledge(asOf: 7-22)：availableAt 7-22 <= 7-22 → 可见
        XCTAssertTrue(DataQueryMode.economicKnowledge(asOf: date(2024, 7, 22)).includes(envelope: env))
        // operationalKnowledge(asOf: 7-22)：ingestedAt 8-01 > 7-22 → 不可见
        XCTAssertFalse(DataQueryMode.operationalKnowledge(asOf: date(2024, 7, 22)).includes(envelope: env))
        // operationalKnowledge(asOf: 8-01)：两条件都满足 → 可见
        XCTAssertTrue(DataQueryMode.operationalKnowledge(asOf: date(2024, 8, 1)).includes(envelope: env))
    }

    // MARK: - M2 场景 3：Q2 持仓 7-22 才可知，7-10 查不到

    func testM2Scenario3_fundQ2NotVisibleAt710() {
        let result = normalizer.normalizeFundDisclosure(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 7, 22),
            jurisdiction: .chinaMainland
        )!
        // economicKnowledge(asOf: 7-10) 应查不到
        XCTAssertFalse(DataQueryMode.economicKnowledge(asOf: date(2024, 7, 10)).includes(envelope: result.envelope))
    }

    // MARK: - availableAt 不受 publishedAt 早期影响（保守）

    func testAvailableAtUsesPolicyNotProviderOptimism() {
        // MarketClose base=effectiveAt。即使 Provider 在 publishedAt 7-20 凌晨就给了，
        // availableAt 仍按 effectiveAt 次交易日算（不乐观假设盘后立刻可知）
        let result = normalizer.normalizeMarketClose(
            effectiveAt: date(2024, 7, 19),    // 周五收盘
            publishedAt: date(2024, 7, 20),    // 周六 Provider 给了（乐观）
            ingestedAt: date(2024, 7, 20),
            jurisdiction: .chinaMainland
        )
        // base=effectiveAt(7-19 周五) → nextTradingDay = 7-22 周一
        XCTAssertEqual(result?.envelope.availableAt, date(2024, 7, 22))
    }

    // MARK: - 法域动态推导

    func testNormalizeMarketClose_respectsUSJurisdiction() {
        // 美股收盘，传 US 法域（MarketClose jurisdictionSource=.fromListing 尊重传入值）
        let result = normalizer.normalizeMarketClose(
            effectiveAt: date(2024, 7, 18),   // 周四
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19),
            jurisdiction: .unitedStates
        )
        // 桩日历对 US 与 CN 行为一致（都是次工作日），真实日历会在节假日不同。
        // 关键是 policy 接受了 US 法域（不硬编码 CN）
        XCTAssertEqual(result?.envelope.availableAt, date(2024, 7, 19))
    }

    // MARK: - 不变量违反时返回 nil（Pipeline 拒收）

    func testNormalize_returnsNilWhenEffectiveAfterPublished() {
        // effectiveAt 晚于 publishedAt（事件还没发生就「公布」了）→ 非法
        let result = normalizer.normalizeFundNAV(
            effectiveAt: date(2024, 7, 25),    // 晚于 publishedAt
            publishedAt: date(2024, 7, 20),
            ingestedAt: date(2024, 7, 26)
        )
        XCTAssertNil(result)   // validate() 失败 → Pipeline 拒收
    }

    // MARK: - Provenance 完整

    func testProvenance_carriesPolicyIDAndVersion() {
        let result = normalizer.normalizeFundNAV(
            effectiveAt: date(2024, 7, 18),
            publishedAt: date(2024, 7, 18),
            ingestedAt: date(2024, 7, 19)
        )!
        XCTAssertEqual(result.provenance.policyID, "fund_nav")
        XCTAssertEqual(result.provenance.policyVersion, "v1")
        // derivedAt 是「现在」（推导时刻），与 availableAt 无关
        XCTAssertNotNil(result.provenance.derivedAt)
    }
}
