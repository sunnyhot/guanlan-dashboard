import XCTest
@testable import QiemanDashboard

// MARK: - 市场阶段

final class MarketPhaseTests: XCTestCase {
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    func testPhaseDetectionAcrossTradingDay() {
        // 2026-08-28 周五
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 08:30:00")), .premarket)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 09:25:00")), .premarket, "集合竞价按盘前处理")
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 09:30:00")), .intraday)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 11:29:59")), .intraday)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 11:30:00")), .lunchBreak)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 12:59:59")), .lunchBreak)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 13:00:00")), .intraday)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 14:56:59")), .intraday)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 14:57:00")), .closingAuction)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 15:00:00")), .postmarket)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-28 22:00:00")), .postmarket)
    }

    func testWeekendAndHolidayAreNonTrading() {
        // 2026-08-29 周六 / 2026-08-30 周日
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-29 10:00:00")), .nonTrading)
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-30 10:00:00")), .nonTrading)
        // 内置节假日：2026 春节（2/16 起 8 天）
        XCTAssertEqual(MarketPhase.phase(at: date("2026-02-17 10:00:00")), .nonTrading)
        // 2026 国庆
        XCTAssertEqual(MarketPhase.phase(at: date("2026-10-01 10:00:00")), .nonTrading)
        // 节假日表之外的普通周三
        XCTAssertEqual(MarketPhase.phase(at: date("2026-08-26 10:00:00")), .intraday)
    }

    func testImmediateTradePermissionMatrix() {
        XCTAssertTrue(MarketPhase.intraday.allowsImmediateTradeActions)
        XCTAssertTrue(MarketPhase.postmarket.allowsImmediateTradeActions)
        XCTAssertFalse(MarketPhase.premarket.allowsImmediateTradeActions)
        XCTAssertFalse(MarketPhase.nonTrading.allowsImmediateTradeActions)
        XCTAssertFalse(MarketPhase.unknown.allowsImmediateTradeActions)
    }

    func testBehaviorConstraintsNonEmpty() {
        for phase in MarketPhase.allCases {
            XCTAssertFalse(phase.behaviorConstraints.isEmpty, "\(phase.rawValue) 应有行为禁令")
        }
    }

    func testNextTradingDaySkipsWeekend() {
        // 周五 → 下周一
        let friday = date("2026-08-28 16:00:00")
        let next = MarketPhase.nextTradingDay(after: friday)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from: next), "2026-08-31")
    }
}

// MARK: - 数据质量置信度封顶

final class DataQualityConfidencePolicyTests: XCTestCase {
    func testCeilingRules() {
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: [.ok, .ok]), .high)
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: [.ok, .stale]), .medium)
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: [.missing]), .medium)
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: [.stale, .partial]), .low, "两个以上 degraded → low")
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: [.failed]), .low, "任一 failed → low")
        XCTAssertEqual(DataQualityConfidencePolicy.confidenceCeiling(coreStatuses: []), .high)
    }

    func testConfidenceCappingOnlyGoesDown() {
        XCTAssertEqual(DecisionConfidenceLevel.high.capped(at: .medium), .medium)
        XCTAssertEqual(DecisionConfidenceLevel.low.capped(at: .high), .low, "封顶不抬升")
        XCTAssertEqual(DecisionConfidenceLevel.medium.capped(at: .medium), .medium)
    }
}

// MARK: - 位置区间

final class PricePositionZoneTests: XCTestCase {
    func testZoneToleranceBands() {
        // support 10 / resistance 11
        XCTAssertEqual(PricePositionZone.zone(price: 9.8, support: 10, resistance: 11), .brokeSupport, "< 0.985×10 = 9.85")
        XCTAssertEqual(PricePositionZone.zone(price: 9.9, support: 10, resistance: 11), .nearSupport, "≤ 1.03×10")
        XCTAssertEqual(PricePositionZone.zone(price: 11.15, support: 10, resistance: 11), .breakout, "> 1.01×11")
        XCTAssertEqual(PricePositionZone.zone(price: 10.7, support: 10, resistance: 11), .nearResistance, "≥ 0.97×11")
        XCTAssertEqual(PricePositionZone.zone(price: 10.4, support: 10, resistance: 11), .midRange)
        XCTAssertEqual(PricePositionZone.zone(price: nil, support: 10, resistance: 11), .unknown)
        XCTAssertEqual(PricePositionZone.zone(price: 10.4, support: nil, resistance: nil), .unknown, "无支撑压力数据")
    }
}

// MARK: - 结构稳定器

final class DecisionStructureGuardrailTests: XCTestCase {
    private func input(
        score: Int = 70,
        action: CanonicalAction = .buy,
        price: Double? = 10.8,
        support: Double? = 10.0,
        resistance: Double? = 11.0,
        flow: CapitalFlowSignal = .neutral
    ) -> DecisionStructureGuardrail.Input {
        DecisionStructureGuardrail.Input(
            score: score, action: action, confidence: .high,
            price: price, support: support, resistance: resistance,
            capitalFlow: flow
        )
    }

    func testBuyNearResistanceWithoutInflowDowngrades() {
        // 10.8 ≥ 0.97×11=10.67 → 贴近压力；资金 neutral ≠ inflow → 降级
        let decision = DecisionStructureGuardrail.apply(input(flow: .neutral))
        XCTAssertEqual(decision.action, .watch)
        XCTAssertEqual(decision.score, 59, "降级后钳制观望带上限")
        XCTAssertEqual(decision.calibration.rawScore, 70, "raw 保留审计")
        XCTAssertTrue(decision.calibration.guardrailReasons.contains { $0.contains("压力位") })
        XCTAssertEqual(decision.calibration.structureSnapshot, decision.calibration.structureSnapshot)
        XCTAssertTrue(decision.calibration.structureSnapshot.contains("位置:贴近压力"))
    }

    func testBuyNearResistanceWithInflowSurvives() {
        let decision = DecisionStructureGuardrail.apply(input(flow: .inflow))
        XCTAssertEqual(decision.action, .buy)
        XCTAssertEqual(decision.score, 70)
        XCTAssertTrue(decision.calibration.guardrailReasons.isEmpty)
    }

    func testBuyMidRangeNeutralDowngrades() {
        let decision = DecisionStructureGuardrail.apply(input(price: 10.5, flow: .neutral))
        XCTAssertEqual(decision.action, .watch)
        XCTAssertTrue(decision.guardrailNotes.contains { $0.contains("区间中部") })
    }

    func testBuyWithoutCapitalFlowDowngrades() {
        // 10.4 处于区间中部，避开压力位规则，让「资金不可用」成为唯一触发条件
        let decision = DecisionStructureGuardrail.apply(input(price: 10.4, flow: .unavailable))
        XCTAssertEqual(decision.action, .watch)
        XCTAssertTrue(decision.guardrailNotes.contains { $0.contains("缺少资金面确认") })
    }

    func testBuyOutflowWithoutBreakoutDowngradesButBreakoutSurvives() {
        let decision = DecisionStructureGuardrail.apply(input(flow: .outflow))
        XCTAssertEqual(decision.action, .watch)
        // 有效突破（>1.01×11=11.11）且资金流出：突破优先，保留买入
        let breakout = DecisionStructureGuardrail.apply(input(price: 11.2, flow: .outflow))
        XCTAssertEqual(breakout.action, .buy)
    }

    func testSellNearSupportWithoutOutflowDowngradesToWatch() {
        // 贴近支撑 + 无流出 + 无重大风险 → 洗盘观察
        let decision = DecisionStructureGuardrail.apply(input(score: 15, action: .sell, price: 10.1, flow: .neutral))
        XCTAssertEqual(decision.action, .watch)
        XCTAssertEqual(decision.score, 45, "15 钳制到观望带下限")
        XCTAssertTrue(decision.guardrailNotes.contains { $0.contains("洗盘") })
    }

    func testSellNearSupportWithMajorRiskSurvives() {
        let decision = DecisionStructureGuardrail.apply(
            DecisionStructureGuardrail.Input(
                score: 15, action: .sell, confidence: .high,
                price: 10.1, support: 10.0, resistance: 11.0,
                capitalFlow: .neutral, hasMajorRisk: true
            )
        )
        XCTAssertEqual(decision.action, .sell, "重大风险在身不拦截卖出")
    }

    func testSellWithInflowDowngradesButBrokeSupportSurvives() {
        let decision = DecisionStructureGuardrail.apply(input(score: 15, action: .sell, price: 10.4, flow: .inflow))
        XCTAssertEqual(decision.action, .watch)
        let broke = DecisionStructureGuardrail.apply(input(score: 15, action: .sell, price: 9.8, flow: .inflow))
        XCTAssertEqual(broke.action, .sell, "已破位不拦截")
    }

    func testIncoherentScoreActionAlignedFirst() {
        // 分数 70（看多带）但声明的行动是 sell：先对齐成 sell → 再看是否触发卖出侧护栏
        let decision = DecisionStructureGuardrail.apply(input(score: 70, action: .sell, price: 10.4, flow: .outflow))
        XCTAssertTrue(decision.calibration.guardrailReasons.contains { $0.contains("不自洽") })
    }

    func testAddActionNotDowngradedByCapitalFlowUnavailable() {
        // 加仓是既有持仓的动作，仅在贴近压力等结构条件触发（对齐后仍为 add → 不降级）
        let decision = DecisionStructureGuardrail.apply(input(score: 65, action: .add, price: 10.4, flow: .unavailable))
        XCTAssertEqual(decision.action, .add, "资金不可用只拦新买入，不拦加仓（保守口径仍受结构位约束）")
    }
}

// MARK: - 护栏管线

final class DecisionGuardrailPipelineTests: XCTestCase {
    func testPremarketImmediateActionForcedToWatch() {
        let decision = DecisionGuardrailPipeline.apply(
            DecisionGuardrailPipeline.Input(
                score: 85, action: .buy, confidence: .high,
                price: 10.4, support: 10.0, resistance: 11.0,
                capitalFlow: .inflow, phase: .premarket
            )
        )
        XCTAssertEqual(decision.action, .watch)
        XCTAssertEqual(decision.confidence, .low)
        XCTAssertTrue(decision.guardrailNotes.contains { $0.contains("阶段护栏") })
        XCTAssertTrue(decision.calibration.adjustedScore <= 59)
    }

    func testIntradayCoherentBuySurvivesWithCleanData() {
        let decision = DecisionGuardrailPipeline.apply(
            DecisionGuardrailPipeline.Input(
                score: 75, action: .buy, confidence: .high,
                price: 10.2, support: 10.0, resistance: 11.0,
                capitalFlow: .inflow, phase: .intraday,
                coreDataStatuses: [.ok, .ok, .ok]
            )
        )
        XCTAssertEqual(decision.action, .buy)
        XCTAssertEqual(decision.confidence, .high)
        XCTAssertEqual(decision.score, 75)
    }

    func testDegradedDataCapsConfidence() {
        let decision = DecisionGuardrailPipeline.apply(
            DecisionGuardrailPipeline.Input(
                score: 75, action: .buy, confidence: .high,
                price: 10.2, support: 10.0, resistance: 11.0,
                capitalFlow: .inflow, phase: .intraday,
                coreDataStatuses: [.ok, .stale, .ok]
            )
        )
        XCTAssertEqual(decision.action, .buy, "结构没触发，不降级行动")
        XCTAssertEqual(decision.confidence, .medium, "一个 degraded 封顶 medium")
        XCTAssertTrue(decision.guardrailNotes.contains { $0.contains("数据质量护栏") })
    }

    func testTransitionOrdering() {
        XCTAssertTrue(DecisionActionTransition.isMoreConservative(from: .buy, to: .hold))
        XCTAssertTrue(DecisionActionTransition.isMoreConservative(from: .buy, to: .sell))
        XCTAssertFalse(DecisionActionTransition.isMoreConservative(from: .sell, to: .hold))
        XCTAssertFalse(DecisionActionTransition.isMoreConservative(from: .hold, to: .buy))
    }
}
