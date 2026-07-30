import Foundation
import XCTest
@testable import QiemanDashboard

final class PortfolioValuationAlertTests: XCTestCase {

    private func makeRule(
        metric: PortfolioValuationAlertMetric = .holdingProfitPct,
        side: PortfolioValuationAlertSide = .sell,
        direction: PortfolioValuationAlertDirection = .above,
        threshold: Double,
        isEnabled: Bool = true
    ) -> PortfolioValuationAlertRule {
        PortfolioValuationAlertRule(
            metric: metric, side: side, direction: direction,
            threshold: threshold, isEnabled: isEnabled
        )
    }

    private func context(
        holdingProfitPct: Double? = nil,
        estimateChangePct: Double? = nil,
        estimatePrice: Double? = nil
    ) -> PortfolioValuationAlertContext {
        PortfolioValuationAlertContext(
            holdingProfitPct: holdingProfitPct,
            estimateChangePct: estimateChangePct,
            estimatePrice: estimatePrice
        )
    }

    // MARK: - 基础触发

    func testFireAbovePositiveThreshold() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 20.5), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    func testFireBelowNegativeThreshold() {
        let rule = makeRule(side: .buy, direction: .below, threshold: -10)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: -10.3), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    // MARK: - 去重（滞回）

    func testHoldWhenBreachedStillInRange() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 21), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .hold)
    }

    func testFireAgainAfterReturningAndReCrossing() {
        let rule = makeRule(direction: .above, threshold: 20)
        // 第一次达标 → fire
        var lastBreached = false
        let first = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 21), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(first, .fire)
        lastBreached = true
        // 回落离开 → clear
        let 回落 = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 18), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(回落, .clear)
        lastBreached = false
        // 再次穿越 → fire
        let again = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 22), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(again, .fire)
    }

    func testClearWhenBreachedLeavesRange() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 15), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .clear)
    }

    // MARK: - 浮点容差

    func testFireBoundaryEpsilon() {
        let rule = makeRule(direction: .above, threshold: 20)
        // 20.0 - 1e-10 仍 >= 20 - 1e-9
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 20.0 - 1e-10), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    // MARK: - 数据缺失：保持 breached 状态（不解除）

    func testHoldWhenObservedValueNilAndBreached() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: nil), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .hold)
    }

    func testIdleWhenObservedValueNilAndNotBreached() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: nil), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .idle)
    }

    // MARK: - 规则禁用

    func testIdleWhenRuleDisabled() {
        let rule = makeRule(direction: .above, threshold: 20, isEnabled: false)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 25), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .idle)
    }

    // MARK: - 文案

    func testDescribeHoldingProfitPctSell() {
        let rule = makeRule(metric: .holdingProfitPct, side: .sell, direction: .above, threshold: 20)
        let body = PortfolioValuationAlertEvaluator.describe(
            rule: rule, fundName: "易方达蓝筹", fundCode: "005827", observedValue: 20.5)
        XCTAssertTrue(body.contains("易方达蓝筹"), "body 应含基金名：\(body)")
        XCTAssertTrue(body.contains("持有收益率"), "body 应含维度名：\(body)")
        XCTAssertTrue(body.contains("卖出"), "body 应含卖出方向：\(body)")
    }

    func testDescribeEstimatePrice() {
        let rule = makeRule(metric: .estimatePrice, side: .sell, direction: .above, threshold: 1.5)
        let body = PortfolioValuationAlertEvaluator.describe(
            rule: rule, fundName: "易方达蓝筹", fundCode: "005827", observedValue: 1.512)
        XCTAssertTrue(body.contains("估算净值"), "body 应含估算净值：\(body)")
        XCTAssertTrue(body.contains("1.5"), "body 应含目标阈值：\(body)")
    }
}
