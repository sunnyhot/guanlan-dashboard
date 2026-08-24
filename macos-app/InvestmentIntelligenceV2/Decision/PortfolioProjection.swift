import Foundation

// MARK: - PortfolioSnapshot / ProjectedPortfolio（DEC-3，Epic 10）
//
// 决策子系统的组合状态视图与「apply plan 后」的模拟。
// ProjectedPortfolio 是**忠实投影**：动作的权重增减原样应用，不修正、
// 不归一、不 clamp 负值——非法形态（负权重 / 超额配置）由 DEC-6 的
// portfolio-level Constraint Gate 在 ProjectedPortfolio 上拒绝，
// 模拟层不越权修补。

/// 组合内单个持仓（决策视角的最小视图）。
struct PortfolioPosition: Sendable, Codable, Hashable {
    /// 持仓主体键（与 AttributionSubject.stableKey 同域：fund|xxx / listing|xxx）
    let subjectKey: String
    /// 该持仓的资产大类（Target 对照与资产类聚合用）
    let assetClass: AssetClass
    /// 组合内权重（0-1；Σ ≤ 1，现金缺口显式保留在 PortfolioSnapshot）
    let weight: Ratio

    init(subjectKey: String, assetClass: AssetClass, weight: Ratio) {
        self.subjectKey = subjectKey
        self.assetClass = assetClass
        self.weight = weight
    }
}

/// 组合当前状态（决策输入视图）。
struct PortfolioSnapshot: Sendable, Codable, Hashable {
    let asOf: Date
    let positions: [PortfolioPosition]

    init(asOf: Date, positions: [PortfolioPosition]) {
        self.asOf = asOf
        self.positions = positions.sorted {
            if $0.subjectKey != $1.subjectKey { return $0.subjectKey < $1.subjectKey }
            return $0.assetClass.rawValue < $1.assetClass.rawValue
        }
    }

    /// 资产大类聚合权重。
    func assetClassWeights() -> [AssetClass: Ratio] {
        var result: [AssetClass: Decimal] = [:]
        for position in positions {
            result[position.assetClass, default: 0] += position.weight.value
        }
        return result.mapValues { Ratio(value: $0) }
    }

    /// 现金缺口（1 − Σ权重；显式保留，不隐式配 cash）。
    var cashGap: Ratio {
        let sum = positions.reduce(Decimal.zero) { $0 + $1.weight.value }
        return Ratio(value: max(Decimal.one - sum, 0))
    }
}

/// 单个组合动作（权重增量；正 = 增持，负 = 减持）。
struct PortfolioAction: Sendable, Codable, Hashable {
    let subjectKey: String
    let deltaWeight: Ratio

    init(subjectKey: String, deltaWeight: Ratio) {
        self.subjectKey = subjectKey
        self.deltaWeight = deltaWeight
    }
}

/// apply 动作后的模拟组合（DEC-3）。
struct ProjectedPortfolio: Sendable, Codable, Hashable {
    let base: PortfolioSnapshot
    /// 应用到 base 的动作（原样记录，审计用）
    let appliedActions: [PortfolioAction]
    /// 投影后持仓（同标的合并）
    let positions: [PortfolioPosition]
    /// 动作引入了新标的但缺资产类声明的主体（fail-closed：不猜分类、
    /// 不静默丢弃——显式暴露给下游拒绝或补声明）
    let unresolvedNewSubjects: [String]

    /// 忠实投影：每标的权重 = base + Σ deltas；不归一、不 clamp——
    /// 非法形态留给 Constraint Gate（DEC-6）判定。
    ///
    /// 新标的（base 无此 subjectKey）必须在 `assetClassForNewSubjects`
    /// 中显式声明资产类，否则进入 unresolvedNewSubjects（不进 positions）。
    static func project(
        base: PortfolioSnapshot,
        applying actions: [PortfolioAction],
        assetClassForNewSubjects: [String: AssetClass] = [:]
    ) -> ProjectedPortfolio {
        var deltas: [String: Decimal] = [:]
        for action in actions {
            deltas[action.subjectKey, default: 0] += action.deltaWeight.value
        }
        var resultMap: [String: PortfolioPosition] = [:]
        for position in base.positions {
            let delta = deltas.removeValue(forKey: position.subjectKey) ?? 0
            resultMap[position.subjectKey] = PortfolioPosition(
                subjectKey: position.subjectKey,
                assetClass: position.assetClass,
                weight: Ratio(value: position.weight.value + delta)
            )
        }
        var unresolved: [String] = []
        for (subjectKey, delta) in deltas.sorted(by: { $0.key < $1.key }) {
            guard let assetClass = assetClassForNewSubjects[subjectKey] else {
                unresolved.append(subjectKey)
                continue
            }
            resultMap[subjectKey] = PortfolioPosition(
                subjectKey: subjectKey,
                assetClass: assetClass,
                weight: Ratio(value: delta)
            )
        }
        let positions = resultMap.values.sorted {
            if $0.subjectKey != $1.subjectKey { return $0.subjectKey < $1.subjectKey }
            return $0.assetClass.rawValue < $1.assetClass.rawValue
        }
        return ProjectedPortfolio(
            base: base,
            appliedActions: actions,
            positions: positions,
            unresolvedNewSubjects: unresolved
        )
    }

    /// 投影后资产类聚合。
    func assetClassWeights() -> [AssetClass: Ratio] {
        var result: [AssetClass: Decimal] = [:]
        for position in positions {
            result[position.assetClass, default: 0] += position.weight.value
        }
        return result.mapValues { Ratio(value: $0) }
    }
}

private extension Decimal {
    static let one = Decimal(1)
}
