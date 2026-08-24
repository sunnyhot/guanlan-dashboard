import Foundation

// MARK: - ActionDomainBuilder（DEC-4，Epic 10）
//
// per-asset 允许动作域：把 Δw 的搜索空间裁剪到「既有持仓 ± 余量 +
// 显式白名单新标的」。DEC-5 planner 只在域内枚举，域外组合根本不进入
// 搜索——这是搜索空间的结构性缩小，不是事后过滤。
//
// 裁剪规则（保守默认）：
// - 既有持仓：卖出下界 = −当前权重（不能卖超过持有）；增持上界 = buyHeadroom
// - 新标的：默认**不在域内**（再平衡只动既有持仓）；只有显式白名单
//   （eligibleNewSubjects，带资产类声明）才可买入
// - buyHeadroom 由调用方给出（现金缺口口径），nil = 不允许增持

/// 组合的动作域（per-subject 的 Δw 允许区间）。
struct ActionDomain: Sendable, Codable, Hashable {
    /// 既有持仓的 Δw 区间（subjectKey → [lower, upper]，lower ≤ 0 ≤ upper）
    let perSubjectBounds: [String: SubjectBounds]
    /// 白名单新标的（显式资产类声明；域内只有买入方向）
    let eligibleNewSubjects: [String: AssetClass]
    let builderVersion: String

    struct SubjectBounds: Sendable, Codable, Hashable {
        /// 卖出下界（负值，绝对值 = 可卖权重）
        let lower: Ratio
        /// 增持上界
        let upper: Ratio

        func contains(delta: Decimal) -> Bool {
            lower.value <= delta && delta <= upper.value
        }
    }

    /// 动作是否在域内（plan 生成时的门禁；新标的只有买入 ≤ headroom）。
    func contains(action: PortfolioAction) -> Bool {
        if let bounds = perSubjectBounds[action.subjectKey] {
            return bounds.contains(delta: action.deltaWeight.value)
        }
        guard eligibleNewSubjects[action.subjectKey] != nil else { return false }
        return action.deltaWeight.value > 0 && action.deltaWeight.value <= newSubjectBuyUpper.value
    }

    /// 新标的的增持上界（与既有持仓共用 headroom；联合预算由 DEC-6 Gate 管）。
    let newSubjectBuyUpper: Ratio
}

/// 动作域构建器（DEC-4，纯函数）。
struct ActionDomainBuilder: Sendable {
    static let builderVersion = "v1"

    /// 构建参数（versioned）。
    struct Parameters: Sendable, Codable, Hashable {
        /// 白名单新标的（显式资产类；默认空 = 只动既有持仓）
        let eligibleNewSubjects: [String: AssetClass]
        /// 增持上界（现金缺口口径；nil = 不允许任何增持）
        let buyHeadroom: Ratio?

        init(eligibleNewSubjects: [String: AssetClass] = [:], buyHeadroom: Ratio? = nil) {
            self.eligibleNewSubjects = eligibleNewSubjects
            self.buyHeadroom = buyHeadroom
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 从组合当前状态构建动作域。
    func buildActionDomain(portfolio: PortfolioSnapshot) -> ActionDomain {
        let headroom = parameters.buyHeadroom?.value ?? 0
        var bounds: [String: ActionDomain.SubjectBounds] = [:]
        for position in portfolio.positions {
            bounds[position.subjectKey] = ActionDomain.SubjectBounds(
                lower: Ratio(value: -position.weight.value),
                upper: Ratio(value: headroom)
            )
        }
        // 白名单里已存在于组合的标的走既有持仓分支（卖买都可）
        let newSubjects = parameters.eligibleNewSubjects
            .filter { bounds[$0.key] == nil }
        return ActionDomain(
            perSubjectBounds: bounds,
            eligibleNewSubjects: newSubjects,
            builderVersion: Self.builderVersion,
            newSubjectBuyUpper: Ratio(value: headroom)
        )
    }
}
