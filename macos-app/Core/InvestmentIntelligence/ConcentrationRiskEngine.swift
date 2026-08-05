import Foundation

// 集中度风险评估引擎(纯函数,无副作用,可测试)。
//
// 输入:personalAssetRows + portfolioLookThroughSnapshot(可选) + UserDecisionProfile
// 输出:[DecisionCase]
//
// 设计(见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 1 设计):
// - 直接持仓集中度:基于 rows,算 top1 占比 + HHI。无需穿透。
// - 穿透集中度:基于 snapshot.topPositions,算穿透后 top1 占比。
// - 穿透重叠:基于 snapshot.topPositions.contributors,算最大重叠暴露。
// - 穿透数据缺失(覆盖率 < 阈值)→ 穿透维度降级 insufficientEvidence。
// - Profile 未自定义或不允许再平衡 → 强行动状态(adjustReview/exitReview)降级为 watch。
// - exitReview 在 Slice 1 不主动触发(需 LLM 反向证据,留 Slice 3)。

enum ConcentrationRiskEngine {

    // MARK: - 主入口

    /// 评估集中度风险,生成 DecisionCase 列表。
    /// 返回的 Case 按 metricValue 降序(最严重的在前)。
    static func evaluate(
        rows: [PersonalAssetAggregateRow],
        lookThroughSnapshot snapshot: PortfolioLookThroughSnapshot?,
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy = .default,
        timestamp: String
    ) -> [DecisionCase] {
        var cases: [DecisionCase] = []

        // 1. 直接持仓集中度
        if let directCase = evaluateDirectHolding(rows: rows, profile: profile, policy: policy, timestamp: timestamp) {
            cases.append(directCase)
        }

        // 2. 穿透集中度 + 重叠(需要 snapshot)
        let lookThroughCases = evaluateLookThrough(snapshot: snapshot, profile: profile, policy: policy, timestamp: timestamp)
        cases.append(contentsOf: lookThroughCases)

        // 3. 回撤扩大(Slice 7):基于 profitPct
        if let drawdownCase = evaluateDrawdown(rows: rows, profile: profile, policy: policy, timestamp: timestamp) {
            cases.append(drawdownCase)
        }

        // 4. 目标配置偏离(Slice 7):实际集中度 vs Profile 上限
        if let deviationCase = evaluateTargetDeviation(rows: rows, profile: profile, policy: policy, timestamp: timestamp) {
            cases.append(deviationCase)
        }

        // 按 metricValue 降序(最严重在前);insufficientEvidence 的排最后
        return cases.sorted { lhs, rhs in
            if lhs.decisionState == .insufficientEvidence && rhs.decisionState != .insufficientEvidence {
                return false
            }
            if rhs.decisionState == .insufficientEvidence && lhs.decisionState != .insufficientEvidence {
                return true
            }
            return lhs.metricValue > rhs.metricValue
        }
    }

    // MARK: - 直接持仓集中度

    private static func evaluateDirectHolding(
        rows: [PersonalAssetAggregateRow],
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy,
        timestamp: String
    ) -> DecisionCase? {
        let metrics = computeDirectMetrics(rows: rows)
        guard let m = metrics else { return nil }

        // 用 Profile 的有效上限作为 review 阈值(而非全局 policy),
        // 这样 adjustReview 的触发与用户风险偏好挂钩。
        let reviewThreshold = min(policy.concentrationReviewThreshold, profile.effectiveConcentrationLimit)
        let watchThreshold = policy.concentrationWatchThreshold

        let preliminary = policy.preliminaryState(
            value: m.topShare,
            watch: watchThreshold,
            review: reviewThreshold,
            hasData: true  // 直接持仓数据总是充足(rows 常驻)
        )
        let finalState = constrainState(preliminary, profile: profile)

        // 只在 watch 及以上才生成 Case(stable 不生成)
        guard finalState != .stable else { return nil }

        return makeCase(
            dimension: .directHolding,
            subjectName: m.topName,
            subjectCode: m.topCode,
            metricValue: m.topShare,
            metricDescription: "第一大标的占比",
            watchThreshold: watchThreshold,
            reviewThreshold: reviewThreshold,
            state: finalState,
            profile: profile,
            policy: policy,
            timestamp: timestamp,
            hhi: m.hhi,
            holdingCount: m.holdingCount
        )
    }

    // MARK: - 穿透集中度 + 重叠

    private static func evaluateLookThrough(
        snapshot: PortfolioLookThroughSnapshot?,
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy,
        timestamp: String
    ) -> [DecisionCase] {
        var cases: [DecisionCase] = []

        // 穿透覆盖率检查
        let coverage = snapshot?.disclosedSecurityCoveragePct ?? 0
        let hasData = snapshot != nil && coverage >= policy.minLookThroughCoverage

        // 穿透集中度(第一大底层证券)
        if let snapshot = snapshot, let topPosition = snapshot.topPositions.first {
            let reviewThreshold = min(policy.lookThroughReviewThreshold, profile.effectiveConcentrationLimit)
            let watchThreshold = policy.lookThroughWatchThreshold
            let preliminary = policy.preliminaryState(
                value: topPosition.portfolioWeightPct,
                watch: watchThreshold,
                review: reviewThreshold,
                hasData: hasData
            )
            let finalState = constrainState(preliminary, profile: profile)

            if finalState != .stable {
                cases.append(makeCase(
                    dimension: .lookThrough,
                    subjectName: topPosition.name,
                    subjectCode: topPosition.code,
                    metricValue: topPosition.portfolioWeightPct,
                    metricDescription: "穿透后第一大底层证券占比",
                    watchThreshold: watchThreshold,
                    reviewThreshold: reviewThreshold,
                    state: finalState,
                    profile: profile,
                    policy: policy,
                    timestamp: timestamp,
                    coverage: coverage
                ))
            }
        } else if !hasData {
            // 无穿透数据 → 生成 insufficientEvidence 占位 Case(只在用户开了投资智能时才有意义)
            cases.append(makeInsufficientCase(
                dimension: .lookThrough,
                subjectName: "穿透数据",
                metricDescription: "穿透后底层证券集中度",
                coverage: coverage,
                policy: policy,
                timestamp: timestamp
            ))
        }

        // 穿透重叠(被多个来源持有的同一底层)
        if let overlap = computeOverlapMetrics(snapshot: snapshot, policy: policy) {
            let reviewThreshold = min(policy.overlapReviewThreshold, profile.effectiveOverlapLimit)
            let watchThreshold = policy.overlapWatchThreshold
            let preliminary = policy.preliminaryState(
                value: overlap.maxOverlapShare,
                watch: watchThreshold,
                review: reviewThreshold,
                hasData: overlap.isAvailable
            )
            let finalState = constrainState(preliminary, profile: profile)

            if finalState != .stable {
                cases.append(makeCase(
                    dimension: .lookThroughOverlap,
                    subjectName: overlap.topName,
                    subjectCode: overlap.topCode,
                    metricValue: overlap.maxOverlapShare,
                    metricDescription: "穿透重叠暴露(\(overlap.contributorCount) 个来源)",
                    watchThreshold: watchThreshold,
                    reviewThreshold: reviewThreshold,
                    state: finalState,
                    profile: profile,
                    policy: policy,
                    timestamp: timestamp,
                    coverage: coverage
                ))
            }
        }

        // 穿透行业集中度(Slice 2):单一行业占比过高
        if let snapshot = snapshot, let topIndustry = snapshot.industries.first, hasData {
            let reviewThreshold = min(policy.sectorReviewThreshold, profile.effectiveConcentrationLimit)
            let watchThreshold = policy.sectorWatchThreshold
            let preliminary = policy.preliminaryState(
                value: topIndustry.portfolioWeightPct,
                watch: watchThreshold,
                review: reviewThreshold,
                hasData: hasData
            )
            let finalState = constrainState(preliminary, profile: profile)

            if finalState != .stable {
                cases.append(makeCase(
                    dimension: .sector,
                    subjectName: topIndustry.name,
                    subjectCode: topIndustry.name,  // 行业用 name 作 code
                    metricValue: topIndustry.portfolioWeightPct,
                    metricDescription: "第一大行业暴露",
                    watchThreshold: watchThreshold,
                    reviewThreshold: reviewThreshold,
                    state: finalState,
                    profile: profile,
                    policy: policy,
                    timestamp: timestamp,
                    coverage: coverage
                ))
            }
        }

        return cases
    }

    // MARK: - 原始指标计算

    /// 从 rows 算直接持仓集中度指标。
    static func computeDirectMetrics(rows: [PersonalAssetAggregateRow]) -> DirectConcentrationMetrics? {
        let holdingRows = rows.filter { $0.effectiveHoldingAmount > 0 }
        guard !holdingRows.isEmpty else { return nil }

        let total = holdingRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        guard total > 0 else { return nil }

        // 按 effectiveHoldingAmount 降序
        let sorted = holdingRows.sorted { $0.effectiveHoldingAmount > $1.effectiveHoldingAmount }
        let top = sorted[0]
        let topShare = top.effectiveHoldingAmount / total * 100

        // HHI = Σ(share_i)^2,share 用百分比
        let hhi = sorted.reduce(0.0) { partial, row in
            let share = row.effectiveHoldingAmount / total * 100
            return partial + share * share
        }

        return DirectConcentrationMetrics(
            topShare: topShare,
            topName: top.fundName,
            topCode: top.fundCode,
            hhi: hhi,
            holdingCount: sorted.count
        )
    }

    /// 从 snapshot 算穿透重叠指标。
    /// 重叠 = 同一底层证券被多个 contributor 持有(基金间接 + 直接持仓)。
    static func computeOverlapMetrics(
        snapshot: PortfolioLookThroughSnapshot?,
        policy: PortfolioDecisionPolicy
    ) -> LookThroughOverlapMetrics? {
        guard let snapshot = snapshot,
              snapshot.disclosedSecurityCoveragePct >= policy.minLookThroughCoverage,
              let topPosition = snapshot.topPositions.first(where: { $0.contributors.count > 1 })
        else {
            return nil
        }

        return LookThroughOverlapMetrics(
            maxOverlapShare: topPosition.portfolioWeightPct,
            topName: topPosition.name,
            topCode: topPosition.code,
            contributorCount: topPosition.contributors.count,
            isAvailable: true
        )
    }

    // MARK: - 回撤扩大(Slice 7)

    private static func evaluateDrawdown(
        rows: [PersonalAssetAggregateRow],
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy,
        timestamp: String
    ) -> DecisionCase? {
        // 找最大回撤(profitPct 最负的标的)
        let holdingRows = rows.filter { $0.hasHolding }
        guard let worst = holdingRows.min(by: { ($0.profitPct ?? 0) < ($1.profitPct ?? 0) }) else { return nil }
        guard let drawdown = worst.profitPct, drawdown < -policy.drawdownWatchThreshold else { return nil }

        let preliminary = policy.preliminaryState(
            value: abs(drawdown),
            watch: policy.drawdownWatchThreshold,
            review: policy.drawdownReviewThreshold,
            hasData: true
        )
        let finalState = constrainState(preliminary, profile: profile)
        guard finalState != .stable else { return nil }

        // 直接构造(不用 makeCase,因为它硬编码 concentrationRisk kind)
        let caseKey = DecisionCase.makeCaseKey(
            kind: .drawdownExpansion, dimension: .directHolding,
            subjectCode: worst.fundCode, subjectName: worst.fundName
        )
        var cs = DecisionCase(
            caseKey: caseKey,
            kind: .drawdownExpansion,
            dimension: .directHolding,
            subjectName: worst.fundName,
            subjectCode: worst.fundCode,
            lifecycle: .decisionReady,
            decisionState: finalState,
            metricValue: abs(drawdown),
            metricLabel: String(format: "%.1f%%", abs(drawdown)),
            metricDescription: "最大回撤",
            title: "\(worst.fundName) · 回撤 \(String(format: "%.1f", abs(drawdown)))%",
            detail: "该标的回撤 \(String(format: "%.1f", abs(drawdown)))%,超过观察阈值 \(Int(policy.drawdownWatchThreshold))%。",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        cs.applyTransition(to: .decisionReady, decisionState: finalState, at: timestamp,
                           type: .created, reason: "回撤扩大检测", actor: .system)
        return cs
    }

    // MARK: - 目标配置偏离(Slice 7)

    private static func evaluateTargetDeviation(
        rows: [PersonalAssetAggregateRow],
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy,
        timestamp: String
    ) -> DecisionCase? {
        // 实际 top1 占比 vs Profile 上限的偏离
        guard let metrics = computeDirectMetrics(rows: rows) else { return nil }
        let limit = profile.effectiveConcentrationLimit
        let deviation = metrics.topShare - limit
        guard deviation > policy.deviationWatchThreshold else { return nil }  // 偏离 > 阈值才生成

        // 偏离本身就是超标,直接用 constrainState
        let preliminary: PortfolioDecisionState = deviation > policy.deviationReviewThreshold ? .adjustReview : .watch
        let finalState = constrainState(preliminary, profile: profile)
        guard finalState != .stable else { return nil }

        let caseKey = DecisionCase.makeCaseKey(
            kind: .targetDeviation, dimension: .directHolding,
            subjectCode: metrics.topCode, subjectName: metrics.topName
        )
        var cs = DecisionCase(
            caseKey: caseKey,
            kind: .targetDeviation,
            dimension: .directHolding,
            subjectName: metrics.topName,
            subjectCode: metrics.topCode,
            lifecycle: .decisionReady,
            decisionState: finalState,
            metricValue: deviation,
            metricLabel: String(format: "+%.1fpp", deviation),
            metricDescription: "超出上限 \(Int(limit))%",
            title: "\(metrics.topName) · 超配 \(String(format: "%.1f", deviation))pp",
            detail: "第一大标的占比 \(String(format: "%.1f", metrics.topShare))%,超出你的上限 \(Int(limit))% 共 \(String(format: "%.1f", deviation)) 个百分点。",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        cs.applyTransition(to: .decisionReady, decisionState: finalState, at: timestamp,
                           type: .created, reason: "目标配置偏离检测", actor: .system)
        return cs
    }

    // MARK: - Profile 约束

    /// 用 Profile 约束状态:未自定义或不允许再平衡时,强行动降级为 watch。
    /// exitReview 在 Slice 1 永远不主动产生(由 constrainState 兜底降级)。
    static func constrainState(
        _ preliminary: PortfolioDecisionState,
        profile: UserDecisionProfile
    ) -> PortfolioDecisionState {
        switch preliminary {
        case .adjustReview, .exitReview:
            // Profile 不允许强行动 → 降级为 watch
            return profile.allowsStrongAction ? preliminary : .watch
        case .stable, .watch, .prepare, .insufficientEvidence:
            return preliminary
        }
    }

    // MARK: - Case 构造辅助

    private static func makeCase(
        dimension: ConcentrationDimension,
        subjectName: String,
        subjectCode: String?,
        metricValue: Double,
        metricDescription: String,
        watchThreshold: Double,
        reviewThreshold: Double,
        state: PortfolioDecisionState,
        profile: UserDecisionProfile,
        policy: PortfolioDecisionPolicy,
        timestamp: String,
        hhi: Double? = nil,
        holdingCount: Int? = nil,
        coverage: Double? = nil
    ) -> DecisionCase {
        let caseKey = DecisionCase.makeCaseKey(
            kind: .concentrationRisk,
            dimension: dimension,
            subjectCode: subjectCode,
            subjectName: subjectName
        )
        let metricLabel = String(format: "%.1f%%", metricValue)
        let title = makeTitle(dimension: dimension, state: state, subjectName: subjectName)
        let detail = makeDetail(
            dimension: dimension, state: state, subjectName: subjectName,
            metricValue: metricValue, metricLabel: metricLabel, metricDescription: metricDescription,
            watchThreshold: watchThreshold, reviewThreshold: reviewThreshold,
            hhi: hhi, holdingCount: holdingCount, coverage: coverage, profile: profile
        )
        let lifecycle: DecisionCaseLifecycle = state == .stable ? .closed : .decisionReady

        var cs = DecisionCase(
            caseKey: caseKey,
            kind: .concentrationRisk,
            dimension: dimension,
            subjectName: subjectName,
            subjectCode: subjectCode,
            lifecycle: lifecycle,
            decisionState: state,
            metricValue: metricValue,
            metricLabel: metricLabel,
            metricDescription: metricDescription,
            title: title,
            detail: detail,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        // 初始事件
        cs.applyTransition(
            to: lifecycle,
            decisionState: state,
            at: timestamp,
            type: .created,
            reason: "集中度评估自动生成",
            actor: .system
        )
        return cs
    }

    private static func makeInsufficientCase(
        dimension: ConcentrationDimension,
        subjectName: String,
        metricDescription: String,
        coverage: Double,
        policy: PortfolioDecisionPolicy,
        timestamp: String
    ) -> DecisionCase {
        let caseKey = DecisionCase.makeCaseKey(
            kind: .concentrationRisk,
            dimension: dimension,
            subjectCode: "insufficient",
            subjectName: subjectName
        )
        let metricLabel = String(format: "覆盖 %.0f%%", coverage)
        let title = "\(metricDescription)数据不足"
        let detail = "穿透覆盖率 \(Int(coverage))%,低于 \(Int(policy.minLookThroughCoverage))% 的最低要求。请等待基金披露更新后重新评估。"

        var cs = DecisionCase(
            caseKey: caseKey,
            kind: .concentrationRisk,
            dimension: dimension,
            subjectName: subjectName,
            subjectCode: nil,
            lifecycle: .decisionReady,
            decisionState: .insufficientEvidence,
            metricValue: coverage,
            metricLabel: metricLabel,
            metricDescription: metricDescription,
            title: title,
            detail: detail,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        cs.applyTransition(
            to: .decisionReady,
            decisionState: .insufficientEvidence,
            at: timestamp,
            type: .created,
            reason: "穿透数据不足",
            actor: .system
        )
        return cs
    }

    private static func makeTitle(
        dimension: ConcentrationDimension,
        state: PortfolioDecisionState,
        subjectName: String
    ) -> String {
        let dimensionText: String
        switch dimension {
        case .directHolding: dimensionText = "持仓集中度"
        case .lookThrough: dimensionText = "穿透集中度"
        case .lookThroughOverlap: dimensionText = "穿透重叠"
        case .sector: dimensionText = "行业集中度"
        }
        switch state {
        case .adjustReview: return "\(subjectName) · \(dimensionText)超限,建议复核"
        case .prepare: return "\(subjectName) · \(dimensionText)接近上限"
        case .watch: return "\(subjectName) · \(dimensionText)偏高"
        case .insufficientEvidence: return "\(dimensionText)数据不足"
        case .stable, .exitReview: return "\(subjectName) · \(dimensionText)"
        }
    }

    private static func makeDetail(
        dimension: ConcentrationDimension,
        state: PortfolioDecisionState,
        subjectName: String,
        metricValue: Double,
        metricLabel: String,
        metricDescription: String,
        watchThreshold: Double,
        reviewThreshold: Double,
        hhi: Double?,
        holdingCount: Int?,
        coverage: Double?,
        profile: UserDecisionProfile
    ) -> String {
        var parts: [String] = []
        parts.append("\(metricDescription) \(metricLabel)。")

        if let hhi = hhi {
            parts.append("HHI 指数 \(Int(hhi))。")
        }
        if let count = holdingCount {
            parts.append("共 \(count) 个标的。")
        }
        if let coverage = coverage {
            parts.append("穿透覆盖率 \(Int(coverage))%。")
        }

        switch state {
        case .adjustReview:
            parts.append("已超过你的集中度上限 \(Int(reviewThreshold))%,建议评估是否调整。")
            if !profile.allowsActiveRebalancing {
                parts.append("(当前 Profile 未开启主动再平衡,仅供观察。)")
            }
        case .prepare:
            let remaining = max(0, reviewThreshold - Double(metricValue))
            parts.append("接近上限 \(Int(reviewThreshold))%(剩余约 \(Int(remaining))pp),建议提前关注。")
        case .watch:
            parts.append("超过观察阈值 \(Int(watchThreshold))%,暂不需要行动。")
        case .insufficientEvidence:
            parts.append("数据不足,暂无法给出判断。")
        case .stable, .exitReview:
            parts.append("在阈值范围内。")
        }

        return parts.joined(separator: " ")
    }
}
