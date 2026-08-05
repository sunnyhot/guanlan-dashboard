import Foundation
import XCTest
@testable import QiemanDashboard

// ConcentrationRiskEngine 计算引擎测试。
//
// 验证:top1/HHI/穿透重叠的指标计算,以及各决策状态的触发条件。
// 见 Slice 1 设计(docs/ai-pipeline-baseline.md 第 9 节)。
final class ConcentrationRiskEngineTests: XCTestCase {

    private let timestamp = "2026-08-05 10:00:00"
    private let policy = PortfolioDecisionPolicy.default

    // MARK: - 直接持仓集中度

    func testStableWhenConcentrationBelowWatchThreshold() {
        // 5 个均等标的,各 20%。
        // 注意:默认 Profile 保守上限 30% → reviewThreshold = min(50,30) = 30,
        // prepare 区间 = [30-5, 30) = [25, 30)。20% < 25% → 确保是 stable。
        let rows = makeRows([
            ("001", "基金A", 20000), ("002", "基金B", 20000),
            ("003", "基金C", 20000), ("004", "基金D", 20000),
            ("005", "基金E", 20000)
        ])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        // 直接持仓 stable 不生成 Case;但无穿透数据 → 生成 1 个 insufficientEvidence 占位 Case
        let directCases = cases.filter { $0.dimension == .directHolding }
        XCTAssertTrue(directCases.isEmpty, "直接持仓在阈值内时不应生成 Case(stable 不生成)")
        // 穿透数据缺失会有占位 Case(这是预期行为)
        let insufficient = cases.filter { $0.decisionState == .insufficientEvidence }
        XCTAssertFalse(insufficient.isEmpty, "无穿透数据应有 insufficientEvidence 占位 Case")
    }

    func testWatchWhenTopShareExceedsWatchThreshold() {
        // top1 = 40%(超过 watch 30,未到 review 50)
        let rows = makeRows([("001", "基金A", 40000), ("002", "基金B", 30000), ("003", "基金C", 30000)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let directCase = cases.first { $0.dimension == .directHolding }
        XCTAssertNotNil(directCase)
        XCTAssertEqual(directCase?.decisionState, .watch)
        XCTAssertEqual(directCase?.subjectName, "基金A")
        XCTAssertEqual(directCase?.metricValue ?? 0, 40, accuracy: 0.5)
    }

    func testPrepareWhenApproachingReviewThreshold() {
        // top1 = 46%(在 prepare 区间 [45,50))
        // 默认 Profile 保守上限 30 → reviewThreshold = min(50, 30) = 30
        // 46 > 30 → adjustReview,但 Profile 不允许强行动 → 降级 watch
        // 要测 prepare,需要 Profile 上限让 reviewThreshold = 50
        let profile = UserDecisionProfile(riskTolerance: .aggressive, concentrationLimit: 50, allowsActiveRebalancing: true, isCustomized: true)
        let rows = makeRows([("001", "基金A", 46000), ("002", "基金B", 27000), ("003", "基金C", 27000)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: profile, timestamp: timestamp)
        let directCase = cases.first { $0.dimension == .directHolding }
        // 46 在 [50-5, 50) = [45,50) → prepare
        XCTAssertEqual(directCase?.decisionState, .prepare)
    }

    func testAdjustReviewWhenExceedsReviewAndProfileAllows() {
        // top1 = 55%,Profile 允许强行动,上限 50
        let profile = UserDecisionProfile(riskTolerance: .aggressive, concentrationLimit: 50, allowsActiveRebalancing: true, isCustomized: true)
        let rows = makeRows([("001", "基金A", 55000), ("002", "基金B", 22500), ("003", "基金C", 22500)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: profile, timestamp: timestamp)
        let directCase = cases.first { $0.dimension == .directHolding }
        XCTAssertEqual(directCase?.decisionState, .adjustReview)
    }

    func testAdjustReviewDowngradesToWatchWhenProfileDisallows() {
        // top1 = 55%,但 Profile 默认(不允许强行动)→ adjustReview 降级 watch
        let rows = makeRows([("001", "基金A", 55000), ("002", "基金B", 22500), ("003", "基金C", 22500)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let directCase = cases.first { $0.dimension == .directHolding }
        // 默认 Profile 上限 30 → reviewThreshold = min(50,30) = 30,55 > 30 → adjustReview → 降级 watch
        XCTAssertEqual(directCase?.decisionState, .watch, "Profile 不允许强行动时 adjustReview 必须降级 watch")
    }

    // MARK: - HHI

    func testHHIComputation() {
        // 4 个均等 25%:HHI = 4 * 25^2 = 2500
        let rows = makeRows([("001", "A", 25000), ("002", "B", 25000), ("003", "C", 25000), ("004", "D", 25000)])
        let metrics = ConcentrationRiskEngine.computeDirectMetrics(rows: rows)
        XCTAssertEqual(metrics?.hhi ?? 0, 2500, accuracy: 1)

        // 1 个 100%:HHI = 10000
        let single = makeRows([("001", "A", 100000)])
        let singleMetrics = ConcentrationRiskEngine.computeDirectMetrics(rows: single)
        XCTAssertEqual(singleMetrics?.hhi ?? 0, 10000, accuracy: 1)
    }

    // MARK: - 穿透覆盖不足降级

    func testLookThroughInsufficientWhenCoverageBelowMinimum() {
        // 穿透覆盖率 50% < 70% → insufficientEvidence
        let snapshot = makeSnapshot(topPositions: [], coveragePct: 50)
        let rows = makeRows([("001", "A", 25000), ("002", "B", 25000)])  // 直接持仓 stable
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: .default, timestamp: timestamp)
        let lookThroughCase = cases.first { $0.dimension == .lookThrough }
        XCTAssertEqual(lookThroughCase?.decisionState, .insufficientEvidence)
    }

    func testLookThroughNilGeneratesInsufficientCase() {
        // 无穿透数据 + 直接持仓 stable → 只有 insufficient 占位 Case
        let rows = makeRows([("001", "A", 25000), ("002", "B", 25000), ("003", "C", 25000), ("004", "D", 25000)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: nil, profile: .default, timestamp: timestamp)
        let insufficient = cases.first { $0.decisionState == .insufficientEvidence }
        XCTAssertNotNil(insufficient, "无穿透数据时应生成 insufficientEvidence 占位 Case")
        XCTAssertEqual(insufficient?.dimension, .lookThrough)
    }

    // MARK: - 穿透集中度

    func testLookThroughWatchWhenTopPositionExceedsWatch() {
        // 穿透后 top1 = 22%(超过 watch 20),覆盖率 80%(达标)
        let snapshot = makeSnapshot(
            topPositions: [makePosition(code: "600519", name: "贵州茅台", weight: 22)],
            coveragePct: 80
        )
        let rows = makeRows([("001", "A", 25000), ("002", "B", 25000), ("003", "C", 25000), ("004", "D", 25000)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: .default, timestamp: timestamp)
        let lookThroughCase = cases.first { $0.dimension == .lookThrough }
        XCTAssertNotNil(lookThroughCase)
        XCTAssertEqual(lookThroughCase?.decisionState, .watch)
        XCTAssertEqual(lookThroughCase?.subjectName, "贵州茅台")
    }

    // MARK: - 穿透重叠

    func testOverlapDetectedWhenMultipleContributors() {
        // 某底层被 3 个来源持有,合计占比 18%(超过 overlap watch 15)
        let contributors = [
            makeContributor(fundName: "基金A", weight: 8),
            makeContributor(fundName: "基金B", weight: 6),
            makeContributor(fundName: "基金C", weight: 4)
        ]
        let snapshot = makeSnapshot(
            topPositions: [makePosition(code: "600519", name: "贵州茅台", weight: 18, contributors: contributors)],
            coveragePct: 80
        )
        let rows = makeRows([("001", "A", 25000), ("002", "B", 25000), ("003", "C", 25000), ("004", "D", 25000)])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: .default, timestamp: timestamp)
        let overlapCase = cases.first { $0.dimension == .lookThroughOverlap }
        XCTAssertNotNil(overlapCase)
        XCTAssertEqual(overlapCase?.decisionState, .watch)
        XCTAssertEqual(overlapCase?.subjectName, "贵州茅台")
    }

    // MARK: - 穿透行业集中度(Slice 2)

    func testSectorWatchWhenTopIndustryExceedsWatch() {
        // 第一大行业 28%(超过 watch 25,未到 review)。
        // 用自定义 Profile 让 concentrationLimit=50,使 reviewThreshold=min(40,50)=40,
        // 28 在 [25, 40-5=35) → watch(不受 prepare 压制)。
        let profile = UserDecisionProfile(riskTolerance: .aggressive, concentrationLimit: 50, allowsActiveRebalancing: false, isCustomized: true)
        let industries = [
            PortfolioLookThroughIndustry(name: "白酒", portfolioWeightPct: 28),
            PortfolioLookThroughIndustry(name: "银行", portfolioWeightPct: 12)
        ]
        let snapshot = makeSnapshot(topPositions: [], coveragePct: 80, industries: industries)
        let rows = makeRows([
            ("001", "A", 20000), ("002", "B", 20000),
            ("003", "C", 20000), ("004", "D", 20000), ("005", "E", 20000)
        ])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: profile, timestamp: timestamp)
        let sectorCase = cases.first { $0.dimension == .sector }
        XCTAssertNotNil(sectorCase, "行业超阈值应生成 Case")
        XCTAssertEqual(sectorCase?.decisionState, .watch)
        XCTAssertEqual(sectorCase?.subjectName, "白酒")
        XCTAssertEqual(sectorCase?.metricValue ?? 0, 28, accuracy: 0.5)
    }

    func testSectorAdjustReviewWhenExceedsReviewAndProfileAllows() {
        // 第一大行业 42%(超过 review 40),Profile 允许强行动
        let profile = UserDecisionProfile(riskTolerance: .aggressive, concentrationLimit: 50, allowsActiveRebalancing: true, isCustomized: true)
        let industries = [
            PortfolioLookThroughIndustry(name: "医药", portfolioWeightPct: 42)
        ]
        let snapshot = makeSnapshot(topPositions: [], coveragePct: 80, industries: industries)
        let rows = makeRows([
            ("001", "A", 20000), ("002", "B", 20000),
            ("003", "C", 20000), ("004", "D", 20000), ("005", "E", 20000)
        ])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: profile, timestamp: timestamp)
        let sectorCase = cases.first { $0.dimension == .sector }
        XCTAssertEqual(sectorCase?.decisionState, .adjustReview)
    }

    func testSectorNotGeneratedWhenCoverageInsufficient() {
        // 行业 30% 但覆盖率只有 50%(低于 70)→ 不生成行业 Case(insufficient 由穿透占位处理)
        let industries = [PortfolioLookThroughIndustry(name: "白酒", portfolioWeightPct: 30)]
        let snapshot = makeSnapshot(topPositions: [], coveragePct: 50, industries: industries)
        let rows = makeRows([
            ("001", "A", 20000), ("002", "B", 20000),
            ("003", "C", 20000), ("004", "D", 20000), ("005", "E", 20000)
        ])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: .default, timestamp: timestamp)
        let sectorCase = cases.first { $0.dimension == .sector }
        XCTAssertNil(sectorCase, "覆盖率不足时不应生成行业 Case(由穿透 insufficientEvidence 占位)")
    }

    func testSectorStableDoesNotGenerateCase() {
        // 第一大行业 18%(低于 watch 25)→ 不生成 Case
        let industries = [
            PortfolioLookThroughIndustry(name: "银行", portfolioWeightPct: 18),
            PortfolioLookThroughIndustry(name: "白酒", portfolioWeightPct: 15)
        ]
        let snapshot = makeSnapshot(topPositions: [], coveragePct: 80, industries: industries)
        let rows = makeRows([
            ("001", "A", 20000), ("002", "B", 20000),
            ("003", "C", 20000), ("004", "D", 20000), ("005", "E", 20000)
        ])
        let cases = ConcentrationRiskEngine.evaluate(rows: rows, lookThroughSnapshot: snapshot, profile: .default, timestamp: timestamp)
        let sectorCase = cases.first { $0.dimension == .sector }
        XCTAssertNil(sectorCase, "行业在阈值内时不应生成 Case")
    }

    // MARK: - constrainState

    func testConstrainStateDowngradesStrongActionWhenProfileDisallows() {
        let profile = UserDecisionProfile.default  // 不允许强行动
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.adjustReview, profile: profile), .watch)
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.exitReview, profile: profile), .watch)
        // 非强行动不受影响
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.watch, profile: profile), .watch)
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.stable, profile: profile), .stable)
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.prepare, profile: profile), .prepare)
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.insufficientEvidence, profile: profile), .insufficientEvidence)
    }

    func testConstrainStateKeepsStrongActionWhenProfileAllows() {
        let profile = UserDecisionProfile(allowsActiveRebalancing: true, isCustomized: true)
        XCTAssertEqual(ConcentrationRiskEngine.constrainState(.adjustReview, profile: profile), .adjustReview)
    }

    // MARK: - 辅助(参考 PortfolioDiagnosticsTests 的 row helper)

    private func makeRows(_ holdings: [(String, String, Double)]) -> [PersonalAssetAggregateRow] {
        holdings.map { code, name, marketValue in
            makeRow(name: name, code: code, marketValue: marketValue)
        }
    }

    private func makeRow(
        name: String, code: String, marketValue: Double
    ) -> PersonalAssetAggregateRow {
        let holding = UserPortfolioHolding(fundCode: code, assetType: .fund, units: 10000, costPrice: 1, displayName: name)
        let valuationRow = UserPortfolioValuationRow(
            holding: holding, fundName: name,
            currentPrice: nil, priceTime: "2026-08-05 15:00", priceSource: nil,
            officialNav: nil, officialNavDate: nil,
            estimatePrice: nil, estimatePriceTime: nil,
            marketValue: marketValue, costValue: nil,
            profitAmount: nil, profitPct: nil, estimateChangePct: nil
        )
        return PersonalAssetAggregateRow(
            key: code, assetType: .fund, fundName: name, fundCode: code,
            holdingRow: valuationRow, rawHolding: holding, archivedHolding: nil,
            pendingTrades: [], plans: []
        )
    }

    private func makeSnapshot(
        topPositions: [PortfolioLookThroughPosition],
        coveragePct: Double,
        industries: [PortfolioLookThroughIndustry] = []
    ) -> PortfolioLookThroughSnapshot {
        PortfolioLookThroughSnapshot(
            expectedFundCount: 2, coveredFundCount: 2,
            fundDataCoveragePct: coveragePct,
            disclosedSecurityCoveragePct: coveragePct,
            unknownPortfolioWeightPct: 100 - coveragePct,
            topPositions: topPositions,
            industries: industries, assetClasses: [],
            funds: [], disclosures: [:], warnings: []
        )
    }

    private func makePosition(code: String, name: String, weight: Double, contributors: [PortfolioLookThroughContributor]? = nil) -> PortfolioLookThroughPosition {
        PortfolioLookThroughPosition(
            code: code, name: name, kind: .stock,
            portfolioWeightPct: weight,
            contributors: contributors ?? [makeContributor(fundName: "基金A", weight: weight)]
        )
    }

    private func makeContributor(fundName: String, weight: Double) -> PortfolioLookThroughContributor {
        PortfolioLookThroughContributor(
            fundCode: nil, fundName: fundName,
            fundPortfolioWeightPct: weight, underlyingWeightPct: 100,
            portfolioWeightPct: weight, disclosureDate: "2026-06-30",
            isDirectHolding: false
        )
    }
}
