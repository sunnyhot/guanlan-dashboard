import Foundation

// 集中度决策阈值表。
//
// 所有阈值集中在此,便于测试和调整。
// 复核方案要求:「阈值不得散落在 View 中,统一放在 Policy」。
// 改阈值前先看 ConcentrationRiskEngineTests,确认对应测试同步更新。

struct PortfolioDecisionPolicy: Sendable {
    /// 直接持仓集中度 watch 阈值(百分比)。
    /// top1 占比 ≥ 此值 → watch。
    let concentrationWatchThreshold: Double

    /// 直接持仓集中度 review 阈值(百分比)。
    /// top1 占比 ≥ 此值 → adjustReview(需 Profile 允许)。
    let concentrationReviewThreshold: Double

    /// prepare 区间宽度(百分比)。
    /// top1 占比在 [review - prepareProximity, review) 内 → prepare。
    let prepareProximity: Double

    /// 穿透集中度 watch 阈值(百分比)。
    let lookThroughWatchThreshold: Double

    /// 穿透集中度 review 阈值(百分比)。
    let lookThroughReviewThreshold: Double

    /// 穿透重叠 watch 阈值(百分比)。
    let overlapWatchThreshold: Double

    /// 穿透重叠 review 阈值(百分比)。
    let overlapReviewThreshold: Double

    /// 穿透覆盖率最低要求(百分比)。
    /// 低于此值时,穿透相关评估降级为 insufficientEvidence。
    let minLookThroughCoverage: Double

    /// 默认阈值。
    static let `default` = PortfolioDecisionPolicy(
        concentrationWatchThreshold: 30,
        concentrationReviewThreshold: 50,
        prepareProximity: 5,
        lookThroughWatchThreshold: 20,
        lookThroughReviewThreshold: 35,
        overlapWatchThreshold: 15,
        overlapReviewThreshold: 25,
        minLookThroughCoverage: 70
    )
}

// MARK: - 阈值判定辅助

extension PortfolioDecisionPolicy {
    /// 根据指标值和 watch/review 阈值推导初步状态(不考虑 Profile 约束)。
    /// - Parameters:
    ///   - value: 指标值(如 top1 占比 55.3)
    ///   - watch: watch 阈值
    ///   - review: review 阈值
    ///   - hasData: 数据是否充足
    /// - Returns: 初步状态(ConcentrationRiskEngine 会再用 Profile 约束修正)
    func preliminaryState(
        value: Double,
        watch: Double,
        review: Double,
        hasData: Bool
    ) -> PortfolioDecisionState {
        guard hasData else { return .insufficientEvidence }
        if value >= review {
            return .adjustReview
        }
        if value >= review - prepareProximity {
            return .prepare
        }
        if value >= watch {
            return .watch
        }
        return .stable
    }
}
