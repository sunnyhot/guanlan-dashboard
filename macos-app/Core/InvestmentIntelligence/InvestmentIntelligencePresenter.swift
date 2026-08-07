import Foundation

// 投资智能 Presenter(M4)。
//
// 把领域模型转换为 UI 展示模型,View 不做业务计算。
// 只使用本地结构化事实,不调用 LLM。
// 禁止生成无依据的"72 分"等评分。

enum InvestmentIntelligencePresenter {

    /// 生成仪表盘摘要(无 Case 时也展示有价值的组合状态)。
    static func makeSummary(
        cases: [DecisionCase],
        rows: [PersonalAssetAggregateRow],
        lookThroughSnapshot: PortfolioLookThroughSnapshot?,
        evaluatedAt: String
    ) -> InvestmentIntelligenceDashboardSummary {
        let activeCases = cases.filter { $0.userDisposition != .closed && $0.lifecycle != .closed }
        let reviewDueCases = activeCases.filter { $0.lifecycle == .reviewDue }
        let mostSevere = mostSevereState(activeCases)

        let overallState: InvestmentIntelligenceOverallState
        let headline: String
        let detail: String

        if activeCases.isEmpty {
            // 没有风险事项不等于数据充分：缺持仓或穿透覆盖不足时必须明确降级。
            let hasAdequateData = !rows.isEmpty
                && (lookThroughSnapshot?.disclosedSecurityCoveragePct ?? 0) >= 70
            overallState = hasAdequateData ? .stable : .insufficientData
            headline = overallState == .stable ? "当前组合状态稳定" : "组合数据不完整"
            detail = makeNoCaseDetail(rows: rows, snapshot: lookThroughSnapshot, evaluatedAt: evaluatedAt)
        } else {
            switch mostSevere {
            case .adjustReview, .exitReview:
                overallState = .actionReviewNeeded
                headline = "\(activeCases.count) 项决策事项需要复核"
            case .prepare, .watch:
                overallState = .attentionNeeded
                headline = "\(activeCases.count) 项决策事项需要关注"
            case .insufficientEvidence:
                overallState = .insufficientData
                headline = "部分决策事项数据不足"
            case .stable, nil:
                overallState = .stable
                headline = "组合状态稳定"
            }
            detail = makeActiveDetail(cases: activeCases, mostSevere: mostSevere)
        }

        let primaryCase = mostSevereCase(activeCases)

        return InvestmentIntelligenceDashboardSummary(
            overallState: overallState,
            headline: headline,
            detail: detail,
            activeCaseCount: activeCases.count,
            reviewDueCount: reviewDueCases.count,
            primaryCaseID: primaryCase?.id,
            topDirectHoldingText: topDirectHoldingText(rows: rows),
            topSectorText: topSectorText(snapshot: lookThroughSnapshot),
            lookThroughCoverageText: lookThroughCoverageText(snapshot: lookThroughSnapshot),
            evaluatedAtText: evaluatedAt
        )
    }

    // MARK: - 无 Case 详情

    private static func makeNoCaseDetail(
        rows: [PersonalAssetAggregateRow],
        snapshot: PortfolioLookThroughSnapshot?,
        evaluatedAt: String
    ) -> String {
        var parts: [String] = []
        if let top = topDirectHoldingText(rows: rows) {
            parts.append("第一大持仓:\(top)")
        }
        if let sector = topSectorText(snapshot: snapshot) {
            parts.append("第一大行业:\(sector)")
        }
        if let coverage = lookThroughCoverageText(snapshot: snapshot) {
            parts.append("穿透覆盖率:\(coverage)")
        } else {
            parts.append("基金穿透数据尚未就绪")
        }
        if !evaluatedAt.isEmpty {
            parts.append("最近评估:\(evaluatedAt)")
        }
        parts.append("组合变化后会自动重新评估")
        return parts.joined(separator: "\n")
    }

    // MARK: - 有 Case 详情

    private static func makeActiveDetail(cases: [DecisionCase], mostSevere: PortfolioDecisionState?) -> String {
        let primary = mostSevereCase(cases)
        if let primary {
            return "最需要留意：\(primary.title)（\(primary.metricLabel)）"
        }
        return ""
    }

    // MARK: - 组合状态文案

    private static func topDirectHoldingText(rows: [PersonalAssetAggregateRow]) -> String? {
        let metrics = ConcentrationRiskEngine.computeDirectMetrics(rows: rows)
        guard let m = metrics else { return nil }
        return "\(m.topName) \(String(format: "%.1f%%", m.topShare))"
    }

    private static func topSectorText(snapshot: PortfolioLookThroughSnapshot?) -> String? {
        guard let snapshot, let top = snapshot.industries.first else { return nil }
        return "\(top.name) \(String(format: "%.1f%%", top.portfolioWeightPct))"
    }

    private static func lookThroughCoverageText(snapshot: PortfolioLookThroughSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let coverage = snapshot.disclosedSecurityCoveragePct
        if coverage < 70 { return "\(Int(coverage))%（披露不全）" }
        return "\(Int(coverage))%"
    }

    // MARK: - 排序

    private static func mostSevereState(_ cases: [DecisionCase]) -> PortfolioDecisionState? {
        let order: [PortfolioDecisionState] = [.exitReview, .adjustReview, .prepare, .watch, .insufficientEvidence, .stable]
        for state in order {
            if cases.contains(where: { $0.decisionState == state }) { return state }
        }
        return nil
    }

    private static func mostSevereCase(_ cases: [DecisionCase]) -> DecisionCase? {
        guard let state = mostSevereState(cases) else { return nil }
        return cases.first { $0.decisionState == state }
    }
}
