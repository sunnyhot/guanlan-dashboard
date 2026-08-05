import Foundation

// 决策指标解析器(Schema V2)。
//
// 解决缺陷:旧代码对所有非 directHolding 维度统一读 topPositions.first,
// 忽略 Case 自己的 subjectCode/subjectName。
// 本 Resolver 按 Case 的标的精确查找真实指标。
//
// ConcentrationRiskEngine 和 DecisionReviewEngine 共用此 Resolver。

// MARK: - 解析结果

enum DecisionMetricResolution: Hashable {
    case available(DecisionCaseMetricSnapshot)
    case unavailable(reason: String)

    var value: Double? {
        if case .available(let snapshot) = self { return snapshot.value }
        return nil
    }
}

// MARK: - Resolver

struct DecisionMetricResolver {

    func resolve(
        decisionCase cs: DecisionCase,
        rows: [PersonalAssetAggregateRow],
        lookThroughSnapshot snapshot: PortfolioLookThroughSnapshot?,
        profile: UserDecisionProfile,
        timestamp: String
    ) -> DecisionMetricResolution {
        switch cs.kind {
        case .concentrationRisk:
            return resolveConcentrationRisk(dimension: cs.dimension, cs: cs, rows: rows, snapshot: snapshot, timestamp: timestamp)
        case .drawdownExpansion:
            return resolveDrawdown(cs: cs, rows: rows, timestamp: timestamp)
        case .targetDeviation:
            return resolveTargetDeviation(cs: cs, rows: rows, profile: profile, timestamp: timestamp)
        }
    }

    // MARK: - 集中度风险

    private func resolveConcentrationRisk(
        dimension: ConcentrationDimension,
        cs: DecisionCase,
        rows: [PersonalAssetAggregateRow],
        snapshot: PortfolioLookThroughSnapshot?,
        timestamp: String
    ) -> DecisionMetricResolution {
        switch dimension {
        case .directHolding:
            // 按 subjectCode 精确查找该标的的占比
            return resolveDirectHolding(cs: cs, rows: rows, timestamp: timestamp)

        case .lookThrough:
            // 在 snapshot.topPositions 按 subjectCode 查找该底层证券的穿透占比
            return resolveLookThroughSecurity(cs: cs, snapshot: snapshot, timestamp: timestamp)

        case .lookThroughOverlap:
            // 查找该标的的重叠暴露(contributors 数量)
            return resolveLookThroughOverlap(cs: cs, snapshot: snapshot, timestamp: timestamp)

        case .sector:
            // 在 snapshot.industries 按 subjectName 查找该行业的占比
            return resolveSector(cs: cs, snapshot: snapshot, timestamp: timestamp)
        }
    }

    // MARK: - 直接持仓

    private func resolveDirectHolding(cs: DecisionCase, rows: [PersonalAssetAggregateRow], timestamp: String) -> DecisionMetricResolution {
        let holdingRows = rows.filter { $0.effectiveHoldingAmount > 0 }
        guard !holdingRows.isEmpty else {
            return .unavailable(reason: "无有效持仓")
        }
        let total = holdingRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        guard total > 0 else { return .unavailable(reason: "总暴露为零") }

        // 按 subjectCode 精确查找(优先 code,兜底 name)
        let target = holdingRows.first { row in
            if let code = cs.subjectCode, let rowCode = row.fundCode {
                return rowCode.lowercased() == code.lowercased()
            }
            return row.fundName.lowercased() == cs.subjectName.lowercased()
        }

        guard let target else {
            return .unavailable(reason: "未找到标的 \(cs.subjectName)(可能已不在持仓中)")
        }

        let share = target.effectiveHoldingAmount / total * 100
        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .directHoldingWeight, value: share, unit: .percent,
            dataAsOf: timestamp
        ))
    }

    // MARK: - 穿透证券

    private func resolveLookThroughSecurity(cs: DecisionCase, snapshot: PortfolioLookThroughSnapshot?, timestamp: String) -> DecisionMetricResolution {
        guard let snapshot, snapshot.disclosedSecurityCoveragePct >= 0 else {
            return .unavailable(reason: "无穿透数据")
        }

        // 按 subjectCode 在 topPositions 查找
        let position = snapshot.topPositions.first { pos in
            if let code = cs.subjectCode {
                return pos.code.lowercased() == code.lowercased()
            }
            return pos.name.lowercased() == cs.subjectName.lowercased()
        }

        guard let position else {
            return .unavailable(reason: "穿透数据中未找到 \(cs.subjectName)")
        }

        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .lookThroughSecurityWeight, value: position.portfolioWeightPct, unit: .percent,
            dataAsOf: timestamp, coverage: snapshot.disclosedSecurityCoveragePct
        ))
    }

    // MARK: - 穿透重叠

    private func resolveLookThroughOverlap(cs: DecisionCase, snapshot: PortfolioLookThroughSnapshot?, timestamp: String) -> DecisionMetricResolution {
        guard let snapshot else {
            return .unavailable(reason: "无穿透数据")
        }

        // 找该标的的重叠暴露
        let position = snapshot.topPositions.first { pos in
            if let code = cs.subjectCode {
                return pos.code.lowercased() == code.lowercased()
            }
            return pos.name.lowercased() == cs.subjectName.lowercased()
        }

        guard let position else {
            return .unavailable(reason: "穿透数据中未找到 \(cs.subjectName)")
        }

        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .lookThroughOverlapWeight, value: position.portfolioWeightPct, unit: .percent,
            dataAsOf: timestamp, coverage: snapshot.disclosedSecurityCoveragePct,
            evidenceIDs: []
        ))
    }

    // MARK: - 行业

    private func resolveSector(cs: DecisionCase, snapshot: PortfolioLookThroughSnapshot?, timestamp: String) -> DecisionMetricResolution {
        guard let snapshot else {
            return .unavailable(reason: "无穿透数据")
        }

        // 在 industries 按 subjectName(name 作为行业名)查找
        let industry = snapshot.industries.first { $0.name.lowercased() == cs.subjectName.lowercased() }

        guard let industry else {
            return .unavailable(reason: "穿透行业数据中未找到 \(cs.subjectName)")
        }

        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .sectorWeight, value: industry.portfolioWeightPct, unit: .percent,
            dataAsOf: timestamp, coverage: snapshot.disclosedSecurityCoveragePct
        ))
    }

    // MARK: - 回撤

    private func resolveDrawdown(cs: DecisionCase, rows: [PersonalAssetAggregateRow], timestamp: String) -> DecisionMetricResolution {
        let holdingRows = rows.filter { $0.hasHolding }

        // 按 subjectCode 查找该标的
        let target = holdingRows.first { row in
            if let code = cs.subjectCode, let rowCode = row.fundCode {
                return rowCode.lowercased() == code.lowercased()
            }
            return row.fundName.lowercased() == cs.subjectName.lowercased()
        }

        guard let target else {
            return .unavailable(reason: "未找到标的 \(cs.subjectName)")
        }

        guard let profitPct = target.profitPct else {
            return .unavailable(reason: "无收益数据")
        }

        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .drawdown, value: abs(profitPct), unit: .percent,
            dataAsOf: timestamp
        ))
    }

    // MARK: - 目标配置偏离

    private func resolveTargetDeviation(cs: DecisionCase, rows: [PersonalAssetAggregateRow], profile: UserDecisionProfile, timestamp: String) -> DecisionMetricResolution {
        guard profile.isCustomized else {
            return .unavailable(reason: "用户未配置目标")
        }

        let holdingRows = rows.filter { $0.effectiveHoldingAmount > 0 }
        guard !holdingRows.isEmpty else { return .unavailable(reason: "无有效持仓") }
        let total = holdingRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        guard total > 0 else { return .unavailable(reason: "总暴露为零") }

        // 按 subjectCode 查找该标的
        let target = holdingRows.first { row in
            if let code = cs.subjectCode, let rowCode = row.fundCode {
                return rowCode.lowercased() == code.lowercased()
            }
            return row.fundName.lowercased() == cs.subjectName.lowercased()
        }

        guard let target else {
            return .unavailable(reason: "未找到标的 \(cs.subjectName)")
        }

        let share = target.effectiveHoldingAmount / total * 100
        let deviation = share - profile.effectiveConcentrationLimit

        return .available(DecisionCaseMetricSnapshot(
            caseID: cs.id, recordedAt: timestamp,
            metric: .targetDeviation, value: deviation, unit: .percentagePoint,
            dataAsOf: timestamp
        ))
    }
}
