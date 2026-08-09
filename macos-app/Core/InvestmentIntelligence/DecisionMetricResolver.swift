import Foundation

// 决策指标解析器。
// 按 Case 的 subjectCode 精确查找真实指标(不是 topPositions.first)。
// 数据不足返回 nil(不是 0)。

struct DecisionMetricResolution: Hashable {
    let value: Double?
    let coverage: Double?
    let reason: String?
    var isAvailable: Bool { value != nil }
}

struct DecisionMetricResolver {

    func resolve(
        decisionCase cs: DecisionCase,
        rows: [PersonalAssetAggregateRow],
        lookThroughSnapshot snapshot: PortfolioLookThroughSnapshot?,
        profile: UserDecisionProfile
    ) -> DecisionMetricResolution {
        switch cs.kind {
        case .concentrationRisk:
            return resolveConcentration(dimension: cs.dimension, cs: cs, rows: rows, snapshot: snapshot)
        case .drawdownExpansion:
            return resolveDrawdown(cs: cs, rows: rows)
        case .targetDeviation:
            return resolveTargetDeviation(cs: cs, rows: rows, profile: profile)
        }
    }

    // MARK: - 集中度

    private func resolveConcentration(
        dimension: ConcentrationDimension,
        cs: DecisionCase,
        rows: [PersonalAssetAggregateRow],
        snapshot: PortfolioLookThroughSnapshot?
    ) -> DecisionMetricResolution {
        switch dimension {
        case .directHolding:
            return resolveDirectHolding(cs: cs, rows: rows)
        case .lookThrough, .lookThroughOverlap:
            return resolveLookThrough(cs: cs, snapshot: snapshot)
        case .sector:
            return resolveSector(cs: cs, snapshot: snapshot)
        }
    }

    private func resolveDirectHolding(cs: DecisionCase, rows: [PersonalAssetAggregateRow]) -> DecisionMetricResolution {
        let holdingRows = rows.filter { $0.effectiveHoldingAmount > 0 }
        guard !holdingRows.isEmpty else { return .init(value: nil, coverage: nil, reason: "无有效持仓") }
        let total = holdingRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        guard total > 0 else { return .init(value: nil, coverage: nil, reason: "总暴露为零") }

        let target = findRow(in: holdingRows, subjectCode: cs.subjectCode, subjectName: cs.subjectName)
        guard let target else { return .init(value: nil, coverage: nil, reason: "标的已不在持仓中") }

        return .init(value: target.effectiveHoldingAmount / total * 100, coverage: nil, reason: nil)
    }

    private func resolveLookThrough(cs: DecisionCase, snapshot: PortfolioLookThroughSnapshot?) -> DecisionMetricResolution {
        guard let snapshot else { return .init(value: nil, coverage: nil, reason: "无穿透数据") }
        let position = snapshot.topPositions.first { matchesSubject($0.code, $0.name, cs.subjectCode, cs.subjectName) }
        guard let position else { return .init(value: nil, coverage: snapshot.disclosedSecurityCoveragePct, reason: "穿透数据中未找到该标的") }
        return .init(value: position.portfolioWeightPct, coverage: snapshot.disclosedSecurityCoveragePct, reason: nil)
    }

    private func resolveSector(cs: DecisionCase, snapshot: PortfolioLookThroughSnapshot?) -> DecisionMetricResolution {
        guard let snapshot else { return .init(value: nil, coverage: nil, reason: "无穿透数据") }
        let industry = snapshot.industries.first { $0.name.lowercased() == cs.subjectName.lowercased() }
        guard let industry else { return .init(value: nil, coverage: snapshot.disclosedSecurityCoveragePct, reason: "行业数据中未找到") }
        return .init(value: industry.portfolioWeightPct, coverage: snapshot.disclosedSecurityCoveragePct, reason: nil)
    }

    // MARK: - 回撤

    private func resolveDrawdown(cs: DecisionCase, rows: [PersonalAssetAggregateRow]) -> DecisionMetricResolution {
        let holdingRows = rows.filter { $0.hasHolding }
        let target = findRow(in: holdingRows, subjectCode: cs.subjectCode, subjectName: cs.subjectName)
        guard let target else { return .init(value: nil, coverage: nil, reason: "标的已不在持仓中") }
        guard let profitPct = target.profitPct else { return .init(value: nil, coverage: nil, reason: "无收益数据") }
        // 只有负收益才是回撤(正收益不是回撤)
        guard profitPct < 0 else { return .init(value: 0, coverage: nil, reason: nil) }
        return .init(value: abs(profitPct), coverage: nil, reason: nil)
    }

    // MARK: - 目标偏离

    private func resolveTargetDeviation(cs: DecisionCase, rows: [PersonalAssetAggregateRow], profile: UserDecisionProfile) -> DecisionMetricResolution {
        guard profile.isCustomized else { return .init(value: nil, coverage: nil, reason: "未配置目标") }
        let holdingRows = rows.filter { $0.effectiveHoldingAmount > 0 }
        guard !holdingRows.isEmpty else { return .init(value: nil, coverage: nil, reason: "无有效持仓") }
        let total = holdingRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        guard total > 0 else { return .init(value: nil, coverage: nil, reason: "总暴露为零") }

        let target = findRow(in: holdingRows, subjectCode: cs.subjectCode, subjectName: cs.subjectName)
        guard let target else { return .init(value: nil, coverage: nil, reason: "标的已不在持仓中") }

        let share = target.effectiveHoldingAmount / total * 100
        return .init(value: share - profile.effectiveConcentrationLimit, coverage: nil, reason: nil)
    }

    // MARK: - 辅助

    private func findRow(in rows: [PersonalAssetAggregateRow], subjectCode: String?, subjectName: String) -> PersonalAssetAggregateRow? {
        rows.first { row in
            if let code = subjectCode, let rowCode = row.fundCode {
                return rowCode.lowercased() == code.lowercased()
            }
            return row.fundName.lowercased() == subjectName.lowercased()
        }
    }

    private func matchesSubject(_ code: String, _ name: String, _ subjectCode: String?, _ subjectName: String) -> Bool {
        if let sc = subjectCode {
            return code.lowercased() == sc.lowercased()
        }
        return name.lowercased() == subjectName.lowercased()
    }
}
