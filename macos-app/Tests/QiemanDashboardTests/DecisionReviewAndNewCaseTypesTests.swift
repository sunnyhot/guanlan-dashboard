import Foundation
import XCTest
@testable import QiemanDashboard

// Slice 7 测试:复盘机制 + 新 Case 类型(回撤扩大、目标配置偏离)。
@MainActor
final class DecisionReviewAndNewCaseTypesTests: XCTestCase {

    private let timestamp = "2026-08-05 10:00:00"

    // MARK: - 复盘时间

    func testNextReviewAtForWatchState() {
        // Schema V2:reviewDueAt 是显式存储的,不再从 updatedAt 计算
        let cs = DecisionCase(
            caseKey: "test|watch", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .monitoring, decisionState: .watch,
            metricValue: 40, metricLabel: "40%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: timestamp, updatedAt: timestamp,
            reviewDueAt: "2026-08-12 10:00:00"
        )
        XCTAssertEqual(cs.nextReviewAt, "2026-08-12 10:00:00")
    }

    func testNextReviewAtForPrepareState() {
        let cs = DecisionCase(
            caseKey: "test|prepare", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .monitoring, decisionState: .prepare,
            metricValue: 47, metricLabel: "47%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: timestamp, updatedAt: timestamp,
            reviewDueAt: "2026-08-08 10:00:00"
        )
        XCTAssertEqual(cs.nextReviewAt, "2026-08-08 10:00:00")
    }

    func testComputeReviewDueAt() {
        // 测静态计算方法(进入 monitoring 时调用)
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .watch, from: "2026-08-05 10:00:00"),
            "2026-08-12 10:00:00"
        )
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .prepare, from: "2026-08-05 10:00:00"),
            "2026-08-08 10:00:00"
        )
        XCTAssertEqual(
            DecisionCase.computeReviewDueAt(decisionState: .adjustReview, from: "2026-08-05 10:00:00"),
            "2026-08-06 10:00:00"
        )
        XCTAssertNil(DecisionCase.computeReviewDueAt(decisionState: .stable, from: "2026-08-05 10:00:00"))
    }

    func testIsReviewDue() {
        let cs = DecisionCase(
            caseKey: "test|due", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .monitoring, decisionState: .watch,
            metricValue: 40, metricLabel: "40%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: "2026-07-20 10:00:00", updatedAt: "2026-07-20 10:00:00",
            reviewDueAt: "2026-07-27 10:00:00"
        )
        // updatedAt 7/20 + 7 天 = 7/27,8/5 已过期
        XCTAssertTrue(cs.isReviewDue(asOf: "2026-08-05 10:00:00"))
        XCTAssertFalse(cs.isReviewDue(asOf: "2026-07-25 10:00:00"))
    }

    func testStableStateHasNoReview() {
        let cs = DecisionCase(
            caseKey: "test|stable", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .decisionReady, decisionState: .stable,
            metricValue: 10, metricLabel: "10%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: timestamp, updatedAt: timestamp
        )
        XCTAssertNil(cs.nextReviewAt)
    }

    // MARK: - 复盘执行

    func testPerformReviewClosesContradictedCase() {
        let model = AppModel()
        model.dataDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-test-\(UUID().uuidString)", isDirectory: true)

        var cs = DecisionCase(
            caseKey: "test|review", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .monitoring, decisionState: .watch,
            metricValue: 40, metricLabel: "40%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: timestamp, updatedAt: timestamp
        )
        cs.applyTransition(to: .monitoring, decisionState: .watch, at: timestamp,
                           type: .userAcknowledged, reason: "关注", actor: .user)
        model.decisionCases = [cs]

        model.performReview(for: cs.id, conclusion: .contradicted, lessons: "判断不成立")

        XCTAssertEqual(model.decisionCases[0].lifecycle, .closed)
        XCTAssertEqual(model.decisionCases[0].userDisposition, .resolved)
    }

    func testPerformReviewKeepsSupportedCase() {
        let model = AppModel()
        model.dataDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-test-\(UUID().uuidString)", isDirectory: true)

        let cs = DecisionCase(
            caseKey: "test|supported", kind: .concentrationRisk, dimension: .directHolding,
            subjectName: "A", subjectCode: "001",
            lifecycle: .monitoring, decisionState: .watch,
            metricValue: 40, metricLabel: "40%", metricDescription: "test",
            title: "T", detail: "D",
            createdAt: timestamp, updatedAt: timestamp
        )
        model.decisionCases = [cs]

        model.performReview(for: cs.id, conclusion: .supported)

        // supported → 不关闭,保持 monitoring/reviewDue
        XCTAssertNotEqual(model.decisionCases[0].lifecycle, .closed)
        XCTAssertEqual(model.decisionCases[0].userDisposition, .pending)
    }

    // MARK: - 回撤扩大

    func testDrawdownCaseGeneratedWhenProfitPctDeep() {
        let rows = [
            makeRow(name: "大跌基金", code: "001", profitPct: -20),  // 回撤 20% > watch(15)
            makeRow(name: "正常基金", code: "002", profitPct: 5)
        ]
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let drawdownCase = cases.first { $0.kind == .drawdownExpansion }
        XCTAssertNotNil(drawdownCase, "回撤超阈值应生成 Case")
        XCTAssertEqual(drawdownCase?.subjectName, "大跌基金")
    }

    func testDrawdownNotGeneratedWhenWithinThreshold() {
        let rows = [
            makeRow(name: "微跌", code: "001", profitPct: -5),  // -5% < watch(15)
            makeRow(name: "B", code: "002", profitPct: 3)
        ]
        // 用 5 个标的确保不被集中度引擎触发
        let allRows = rows + [
            makeRow(name: "C", code: "003", profitPct: 2),
            makeRow(name: "D", code: "004", profitPct: 1),
            makeRow(name: "E", code: "005", profitPct: 0)
        ]
        let cases = ConcentrationRiskEngine.evaluate(rows: allRows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let drawdownCase = cases.first { $0.kind == .drawdownExpansion }
        XCTAssertNil(drawdownCase, "回撤在阈值内不应生成 Case")
    }

    // MARK: - 目标配置偏离

    func testTargetDeviationGeneratedWhenOverLimit() {
        // 默认 Profile 上限 30%,top1 占比 45%,偏离 15pp > deviationWatch(5)
        let rows = [
            makeRow(name: "超配", code: "001", marketValue: 45000, profitPct: 0),
            makeRow(name: "B", code: "002", marketValue: 55000, profitPct: 0)
        ]
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let deviationCase = cases.first { $0.kind == .targetDeviation }
        XCTAssertNotNil(deviationCase, "超配偏离应生成 Case")
        XCTAssertTrue(deviationCase?.title.contains("超配") ?? false)
    }

    func testTargetDeviationNotGeneratedWhenWithinLimit() {
        // 默认 Profile 上限 30%,用进取上限 50%,top1 占比 35%,偏离 -15pp(未超)
        let profile = UserDecisionProfile(riskTolerance: .aggressive, concentrationLimit: 50, isCustomized: true)
        let rows = [
            makeRow(name: "A", code: "001", marketValue: 35000, profitPct: 0),
            makeRow(name: "B", code: "002", marketValue: 35000, profitPct: 0),
            makeRow(name: "C", code: "003", marketValue: 30000, profitPct: 0)
        ]
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: profile, timestamp: timestamp)
        let deviationCase = cases.first { $0.kind == .targetDeviation }
        XCTAssertNil(deviationCase, "未超配不应生成偏离 Case")
    }

    // MARK: - 辅助

    private func makeRow(name: String, code: String, marketValue: Double = 25000, profitPct: Double? = nil) -> PersonalAssetAggregateRow {
        let holding = UserPortfolioHolding(fundCode: code, assetType: .fund, units: 10000, costPrice: 1, displayName: name)
        let valuationRow = UserPortfolioValuationRow(
            holding: holding, fundName: name,
            currentPrice: nil, priceTime: "2026-08-05 15:00", priceSource: nil,
            officialNav: nil, officialNavDate: nil,
            estimatePrice: nil, estimatePriceTime: nil,
            marketValue: marketValue, costValue: nil,
            profitAmount: nil, profitPct: profitPct, estimateChangePct: nil
        )
        return PersonalAssetAggregateRow(
            key: code, assetType: .fund, fundName: name, fundCode: code,
            holdingRow: valuationRow, rawHolding: holding, archivedHolding: nil,
            pendingTrades: [], plans: []
        )
    }
}
