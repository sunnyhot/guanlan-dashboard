import Foundation

// MARK: - 决策事项阈值表（审计 A2/A3，2026-08-27）
//
// V1 PortfolioDecisionPolicy 的 V2 重建：阈值沿用 V1 默认值（用户拍板
// A4 暂缓——本期无用户画像，恒用默认表）。所有阈值集中在此，改阈值前
// 先同步 DecisionCaseEngineTests。

/// 决策事项评估阈值（全部为百分比口径；纯值类型）。
struct DecisionCasePolicy: Sendable, Equatable {
    // MARK: 直接持仓集中度
    /// top1 占比 ≥ 此值 → watch。
    let concentrationWatchThreshold: Double
    /// top1 占比 ≥ 此值 → adjustReview。
    let concentrationReviewThreshold: Double
    /// top1 占比在 [review − prepareProximity, review) 内 → prepare。
    let prepareProximity: Double

    // MARK: 穿透集中度（单标的 / 重叠 / 行业）
    let lookThroughWatchThreshold: Double
    let lookThroughReviewThreshold: Double
    let overlapWatchThreshold: Double
    let overlapReviewThreshold: Double
    let sectorWatchThreshold: Double
    let sectorReviewThreshold: Double
    /// 穿透覆盖率下限（0-1）。低于此值 → 穿透相关评估降级 insufficientEvidence。
    let minLookThroughCoverage: Double

    // MARK: 回撤扩大（|profitPct| 口径）
    let drawdownWatchThreshold: Double
    let drawdownReviewThreshold: Double

    // MARK: 目标偏离（百分点口径）
    /// V2 语义：资产类当前占比 − 战略目标占比 ≥ 此值 → watch。
    let deviationWatchThreshold: Double
    let deviationReviewThreshold: Double

    /// 默认阈值（V1 PortfolioDecisionPolicy.default 原值）。
    static let `default` = DecisionCasePolicy(
        concentrationWatchThreshold: 30,
        concentrationReviewThreshold: 50,
        prepareProximity: 5,
        lookThroughWatchThreshold: 20,
        lookThroughReviewThreshold: 35,
        overlapWatchThreshold: 15,
        overlapReviewThreshold: 25,
        sectorWatchThreshold: 25,
        sectorReviewThreshold: 40,
        minLookThroughCoverage: 0.70,
        drawdownWatchThreshold: 15,
        drawdownReviewThreshold: 25,
        deviationWatchThreshold: 5,
        deviationReviewThreshold: 15)

    init(
        concentrationWatchThreshold: Double,
        concentrationReviewThreshold: Double,
        prepareProximity: Double,
        lookThroughWatchThreshold: Double,
        lookThroughReviewThreshold: Double,
        overlapWatchThreshold: Double,
        overlapReviewThreshold: Double,
        sectorWatchThreshold: Double,
        sectorReviewThreshold: Double,
        minLookThroughCoverage: Double,
        drawdownWatchThreshold: Double,
        drawdownReviewThreshold: Double,
        deviationWatchThreshold: Double,
        deviationReviewThreshold: Double
    ) {
        self.concentrationWatchThreshold = concentrationWatchThreshold
        self.concentrationReviewThreshold = concentrationReviewThreshold
        self.prepareProximity = prepareProximity
        self.lookThroughWatchThreshold = lookThroughWatchThreshold
        self.lookThroughReviewThreshold = lookThroughReviewThreshold
        self.overlapWatchThreshold = overlapWatchThreshold
        self.overlapReviewThreshold = overlapReviewThreshold
        self.sectorWatchThreshold = sectorWatchThreshold
        self.sectorReviewThreshold = sectorReviewThreshold
        self.minLookThroughCoverage = minLookThroughCoverage
        self.drawdownWatchThreshold = drawdownWatchThreshold
        self.drawdownReviewThreshold = drawdownReviewThreshold
        self.deviationWatchThreshold = deviationWatchThreshold
        self.deviationReviewThreshold = deviationReviewThreshold
    }

    /// 指标值 + watch/review 阈值 → 初步状态（数据不足 → insufficientEvidence；
    /// ≥review → adjustReview；≥review−prepareProximity → prepare；≥watch → watch）。
    func preliminaryState(
        value: Double, watch: Double, review: Double, hasData: Bool
    ) -> PortfolioDecisionState {
        guard hasData else { return .insufficientEvidence }
        if value >= review { return .adjustReview }
        if value >= review - prepareProximity { return .prepare }
        if value >= watch { return .watch }
        return .stable
    }
}
