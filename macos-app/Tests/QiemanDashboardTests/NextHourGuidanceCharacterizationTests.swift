import Foundation
import XCTest
@testable import QiemanDashboard

// NextHourGuidance 行为冻结测试。
//
// 补充现有 NextHourGuidanceTests 未覆盖的契约(见 docs/ai-pipeline-baseline.md 第 3 节):
//   - NextHourGuidanceAction.confidence 钳制(0...100)
//   - NextHourGuidanceActionKind 旧值兼容解码 + evidencePolicyLevel 映射
//   - NextHourGuidanceReport 解码默认值(缺字段兜底)
//   - NextHourGuidanceSchedule 剩余窗口边界(10:14/10:15、11:14/11:15、15:00 收盘后)
//   - TrendClaimEvidencePolicy.validateExecution 的关键门槛(资金动作的证据门)
//
// 注:互斥 guard 嵌入 AppModel extension,无法独立测试,不在本文件覆盖。
// 注:调度窗口的 14:49/14:50 切换已由现有 testClosingSlotIsOnlyScopeIncludingOffExchangeFunds 覆盖。
final class NextHourGuidanceCharacterizationTests: XCTestCase {

    // MARK: - 测试:NextHourGuidanceAction.confidence 钳制

    func testActionConfidenceClampedToZeroToHundred() throws {
        // 负值 → 0
        let negative = NextHourGuidanceAction(
            targetName: "标的A", action: .hold,
            instruction: "持有观察", rationale: "理由",
            trigger: "触发", invalidation: "失效",
            confidence: -5
        )
        XCTAssertEqual(negative.confidence, 0, "confidence 负值必须钳制为 0")

        // 超过 100 → 100
        let overflow = NextHourGuidanceAction(
            targetName: "标的B", action: .buy,
            instruction: "买入", rationale: "理由",
            trigger: "触发", invalidation: "失效",
            confidence: 150
        )
        XCTAssertEqual(overflow.confidence, 100, "confidence 超过 100 必须钳制为 100")

        // 正常值不变
        let normal = NextHourGuidanceAction(
            targetName: "标的C", action: .sell,
            instruction: "卖出", rationale: "理由",
            trigger: "触发", invalidation: "失效",
            confidence: 65
        )
        XCTAssertEqual(normal.confidence, 65)
    }

    // MARK: - 测试:NextHourGuidanceActionKind 旧值兼容解码 + policyLevel

    func testActionKindDecodesLegacyValuesAndMapsPolicyLevel() throws {
        // 旧版 kind 字符串仍可解码(向后兼容)
        let legacyKinds: [(String, NextHourGuidanceActionKind)] = [
            ("buy", .buy), ("sell", .sell), ("hold", .hold),
            ("watch", .watch), ("wait", .wait),
            ("avoid_chasing", .avoidChasing),
            ("buy_small", .buySmall), ("reduce_small", .reduceSmall)
        ]
        for (raw, expected) in legacyKinds {
            let json = "{\"action\":\"\(raw)\"}"
            let decoded = try JSONDecoder().decode(LegacyActionWrapper.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.action, expected, "旧值 \(raw) 应可解码")
        }

        // evidencePolicyLevel:执行级(buy/sell/buySmall/reduceSmall)vs 信息级(其余)
        XCTAssertEqual(NextHourGuidanceActionKind.buy.evidencePolicyLevel, .execution)
        XCTAssertEqual(NextHourGuidanceActionKind.sell.evidencePolicyLevel, .execution)
        XCTAssertEqual(NextHourGuidanceActionKind.buySmall.evidencePolicyLevel, .execution)
        XCTAssertEqual(NextHourGuidanceActionKind.reduceSmall.evidencePolicyLevel, .execution)
        XCTAssertEqual(NextHourGuidanceActionKind.hold.evidencePolicyLevel, .informational)
        XCTAssertEqual(NextHourGuidanceActionKind.watch.evidencePolicyLevel, .informational)
    }

    private struct LegacyActionWrapper: Codable {
        let action: NextHourGuidanceActionKind
    }

    // MARK: - 测试:NextHourGuidanceSchedule 剩余窗口边界

    func testScheduleBoundariesTenFourteenAndElevenFourteen() {
        let schedule = NextHourGuidanceSchedule.default

        // 真实行为(冻结):10:14:59 属于 09:15 窗口(09:15 窗口的 end 是 10:14)
        // 这说明 09:15 窗口覆盖 09:15-10:14,10:15 才是新窗口起点
        let slot10_14 = schedule.dueSlot(at: "2026-07-27 10:14:59", lastAttemptedSlotKey: nil)
        XCTAssertNotNil(slot10_14, "10:14:59 应命中某个盘中窗口")
        XCTAssertEqual(slot10_14?.scope, .marketTrading)

        // 10:15:00 进入 10:15 窗口
        let slot10_15 = schedule.dueSlot(at: "2026-07-27 10:15:00", lastAttemptedSlotKey: nil)
        XCTAssertEqual(slot10_15?.timeString, "10:15")

        // 11:15:00 进入 11:15 窗口(11:14:59 仍属 10:15)
        let slot11_15 = schedule.dueSlot(at: "2026-07-27 11:15:00", lastAttemptedSlotKey: nil)
        XCTAssertEqual(slot11_15?.timeString, "11:15")
    }

    func testScheduleClosingWindowIncludesFifteenHundred() {
        let schedule = NextHourGuidanceSchedule.default
        // 真实行为(冻结):15:00:00 仍命中 14:50 收盘窗口(end=15:00 含边界)
        let slot = schedule.dueSlot(at: "2026-07-27 15:00:00", lastAttemptedSlotKey: nil)
        XCTAssertEqual(slot?.timeString, "14:50", "15:00:00 仍属 14:50 收盘窗口")
        XCTAssertEqual(slot?.scope, .closingWindow)
    }

    func testScheduleRejectsMalformedTimestamp() {
        let schedule = NextHourGuidanceSchedule.default
        // 真实行为:timestampParts 要求 count >= 16
        // 短于阈值或无法解析的时间戳返回 nil
        XCTAssertNil(schedule.dueSlot(at: "bad", lastAttemptedSlotKey: nil), "无效时间戳应返回 nil")
        XCTAssertNil(schedule.dueSlot(at: "2026-07-27", lastAttemptedSlotKey: nil), "仅日期应返回 nil")
    }

    // MARK: - 测试:NextHourGuidanceReport 解码默认值

    func testReportDecodesWithDefaultsForMissingFields() throws {
        // 最小 report JSON,缺 id/runID/actions/riskChecks 等
        let minimalJSON = """
        {
          "slotKey": "2026-07-27 14:50",
          "validUntil": "2026-07-27 15:00",
          "scope": "closing_window",
          "posture": "balanced",
          "headline": "测试",
          "summary": "摘要",
          "confidence": 60,
          "generatedAt": "2026-07-27 14:50:00"
        }
        """
        let report = try JSONDecoder().decode(NextHourGuidanceReport.self, from: Data(minimalJSON.utf8))

        // 缺失字段应被默认值兜底,而非解码失败
        XCTAssertNotNil(report.id, "缺 id 应生成新 UUID")
        XCTAssertTrue(report.actions.isEmpty, "缺 actions 应默认空数组")
        // 关键不变量:解码成功即证明向后兼容设计生效
        XCTAssertEqual(report.scope, .closingWindow)
    }

    // MARK: - 测试:TrendClaimEvidencePolicy.validateExecution 关键门槛

    func testValidateExecutionRejectsBuyWithoutSizingTerm() {
        // buy action 的 instruction 必须含仓位词(%,成,小仓,分批,份额)
        let policy = TrendClaimEvidencePolicy()
        let assessment = makeFreshExecutionAssessment()
        let errors = policy.validateExecution(
            actionKind: .buy,
            targetName: "标的X",
            targetCode: nil,
            instruction: "买入",  // 缺仓位词
            trigger: "触发",
            invalidation: "失效",
            quoteAssessment: assessment,
            marketDataIsFresh: true,
            evidenceIDs: [],
            evidenceByID: [:],
            relatedEntityCodes: [],
            relatedEntityNames: [],
            relatedSectorKeys: [],
            requiresFundDisclosure: false,
            fundDisclosureEvidencePrefix: "fund:look-through:"
        )
        XCTAssertTrue(errors.contains { $0.contains("仓位") || $0.contains("分批") || $0.contains("份额") },
                      "buy 缺仓位词应被拒")
    }

    func testValidateExecutionForcesHoldWhenMarketDataNotFresh() {
        let policy = TrendClaimEvidencePolicy()
        let assessment = TrendQuoteAssessment(
            quoteType: .lastTrade, freshnessStatus: .unknown,
            asOf: nil, receivedAt: "2026-07-27 14:50:00",
            ageSeconds: 3600, marketSession: .closed
        )
        let errors = policy.validateExecution(
            actionKind: .buy,
            targetName: "标的Y",
            targetCode: nil,
            instruction: "买入 1 成",
            trigger: "触发",
            invalidation: "失效",
            quoteAssessment: assessment,
            marketDataIsFresh: false,  // 行情不新鲜
            evidenceIDs: [],
            evidenceByID: [:],
            relatedEntityCodes: [],
            relatedEntityNames: [],
            relatedSectorKeys: [],
            requiresFundDisclosure: false,
            fundDisclosureEvidencePrefix: "fund:look-through:"
        )
        XCTAssertTrue(errors.contains { $0.contains("hold") || $0.contains("持有") || $0.contains("行情") || $0.contains("新鲜") },
                      "行情不新鲜时只能给 hold,买/卖应被拒")
    }

    private func makeFreshExecutionAssessment() -> TrendQuoteAssessment {
        TrendQuoteAssessment(
            quoteType: .lastTrade, freshnessStatus: .fresh,
            asOf: "2026-07-27 14:50:00", receivedAt: "2026-07-27 14:50:00",
            ageSeconds: 10, marketSession: .trading
        )
    }
}
