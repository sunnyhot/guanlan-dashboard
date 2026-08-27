import Foundation

// MARK: - 决策事项评估引擎（审计 A2/A3，V1 ConcentrationRiskEngine 的 V2 重建）
//
// 纯函数引擎：App 侧装配输入（持仓 / 穿透 / 目标偏差），引擎负责
// 四类建案草案生成与既有事项的合并状态机。V2 语义演进（相对 V1）：
// - targetDeviation 从「单标的集中度 vs 画像上限」改为「资产类占比 vs
//   战略目标占比」——V2 有真实用户意图 Target Store，偏离语义更诚实
// - triggerCondition / invalidationCondition 是审计 B2 要求的自然语言
//   条件（人工复核，不自动触发）
// - 输入经值类型注入（不引用 AppModel / SwiftUI，保持 V2 边界）

/// 决策事项引擎（纯函数，Sendable）。
struct DecisionCaseEngine: Sendable {

    let policy: DecisionCasePolicy

    init(policy: DecisionCasePolicy = .default) {
        self.policy = policy
    }

    // MARK: - 输入（App 侧装配的值类型）

    /// 单个持仓行（直接持仓集中度 + 回撤评估的数据基础）。
    struct PositionInput: Sendable, Hashable {
        let name: String
        let code: String?
        /// 组合内占比（百分比，0-100）。
        let weightPct: Double
        /// 持有收益率（百分比；回撤评估用 |profitPct|，nil = 未知）。
        let profitPct: Double?

        init(name: String, code: String? = nil, weightPct: Double, profitPct: Double? = nil) {
            self.name = name
            self.code = code
            self.weightPct = weightPct
            self.profitPct = profitPct
        }
    }

    /// 穿透素材（来自 App 穿透快照的映射）。
    struct LookThroughInput: Sendable, Hashable {
        struct UnderlyingInput: Sendable, Hashable {
            let name: String
            let code: String?
            /// 穿透后组合占比（百分比）。
            let weightPct: Double
            /// 持有该底层的基金数（>1 = 跨基金重叠）。
            let contributorCount: Int

            init(name: String, code: String? = nil, weightPct: Double, contributorCount: Int) {
                self.name = name
                self.code = code
                self.weightPct = weightPct
                self.contributorCount = contributorCount
            }
        }

        struct IndustryInput: Sendable, Hashable {
            let label: String
            let weightPct: Double

            init(label: String, weightPct: Double) {
                self.label = label
                self.weightPct = weightPct
            }
        }

        /// 穿透覆盖率（0-1，来自披露覆盖）。
        let coverage: Double
        /// 穿透后底层标的（weightPct 降序）。
        let topUnderlyings: [UnderlyingInput]
        /// 行业暴露（weightPct 降序）。
        let industries: [IndustryInput]

        init(coverage: Double, topUnderlyings: [UnderlyingInput], industries: [IndustryInput]) {
            self.coverage = coverage
            self.topUnderlyings = topUnderlyings
            self.industries = industries
        }
    }

    /// 资产类目标偏差行。
    struct DeviationInput: Sendable, Hashable {
        let assetClassLabel: String
        /// 当前占比（百分比）。
        let currentPct: Double
        /// 战略目标占比（百分比）。
        let targetPct: Double

        init(assetClassLabel: String, currentPct: Double, targetPct: Double) {
            self.assetClassLabel = assetClassLabel
            self.currentPct = currentPct
            self.targetPct = targetPct
        }

        /// 偏离（百分点，带符号）。
        var deviationPp: Double { currentPct - targetPct }
    }

    /// 评估输入（App 侧装配）。
    struct Input: Sendable, Hashable {
        var positions: [PositionInput] = []
        var lookThrough: LookThroughInput?
        var deviations: [DeviationInput] = []
        var asOf: Date

        init(
            positions: [PositionInput] = [],
            lookThrough: LookThroughInput? = nil,
            deviations: [DeviationInput] = [],
            asOf: Date
        ) {
            self.positions = positions
            self.lookThrough = lookThrough
            self.deviations = deviations
            self.asOf = asOf
        }
    }

    // MARK: - 建案草案生成

    /// 四路评估（集中度四维 / 回撤 / 目标偏离），产出建案草案。
    /// 排序：metricValue 降序，insufficientEvidence 垫底（V1 语义）。
    func evaluate(_ input: Input) -> [DecisionCase] {
        var drafts: [DecisionCase] = []
        drafts.append(contentsOf: concentrationDrafts(input))
        drafts.append(contentsOf: drawdownDrafts(input))
        drafts.append(contentsOf: deviationDrafts(input))
        return drafts.sorted { lhs, rhs in
            if lhs.decisionState == .insufficientEvidence && rhs.decisionState != .insufficientEvidence {
                return false
            }
            if rhs.decisionState == .insufficientEvidence && lhs.decisionState != .insufficientEvidence {
                return true
            }
            if lhs.metricValue != rhs.metricValue {
                return lhs.metricValue > rhs.metricValue
            }
            return lhs.caseKey < rhs.caseKey
        }
    }

    // MARK: 集中度四维

    private func concentrationDrafts(_ input: Input) -> [DecisionCase] {
        var drafts: [DecisionCase] = []
        let p = policy

        // 1. 直接持仓 top1 + HHI
        let sortedPositions = input.positions.sorted {
            if $0.weightPct != $1.weightPct { return $0.weightPct > $1.weightPct }
            return $0.name < $1.name
        }
        if let top = sortedPositions.first, top.weightPct > 0 {
            let hhi = input.positions.reduce(0.0) { $0 + $1.weightPct * $1.weightPct }
            let state = p.preliminaryState(
                value: top.weightPct,
                watch: p.concentrationWatchThreshold,
                review: p.concentrationReviewThreshold,
                hasData: !input.positions.isEmpty)
            if state != .stable {
                drafts.append(makeCase(
                    kind: .concentrationRisk, dimension: .directHolding,
                    subjectName: top.name, subjectCode: top.code,
                    metricValue: top.weightPct,
                    metricDescription: "第一大持仓占比",
                    title: "单一持仓集中：\(top.name)",
                    detail: "第一大持仓「\(top.name)」占组合 \(format(top.weightPct))%，"
                        + "持仓 HHI \(String(format: "%.0f", hhi))。"
                        + state.guidanceText + "。",
                    trigger: "占比继续升至 \(format(p.concentrationReviewThreshold))% 以上时加重关注",
                    invalidation: "占比回落至 \(format(p.concentrationWatchThreshold))% 以下",
                    state: state, at: input.asOf))
            }
        }

        guard let lookThrough = input.lookThrough, !lookThrough.topUnderlyings.isEmpty else {
            return drafts
        }
        // 覆盖不足：穿透相关评估整体降级为一条 insufficientEvidence 占位案
        guard lookThrough.coverage >= p.minLookThroughCoverage else {
            drafts.append(makeInsufficientCase(
                coverage: lookThrough.coverage, at: input.asOf))
            return drafts
        }

        // 2. 穿透后单标的集中度
        if let topUnderlying = lookThrough.topUnderlyings.first {
            let state = p.preliminaryState(
                value: topUnderlying.weightPct,
                watch: p.lookThroughWatchThreshold,
                review: p.lookThroughReviewThreshold,
                hasData: true)
            if state != .stable {
                drafts.append(makeCase(
                    kind: .concentrationRisk, dimension: .lookThrough,
                    subjectName: topUnderlying.name, subjectCode: topUnderlying.code,
                    metricValue: topUnderlying.weightPct,
                    metricDescription: "穿透后第一大标的占比",
                    title: "穿透集中：\(topUnderlying.name)",
                    detail: "穿透后「\(topUnderlying.name)」合计占组合 \(format(topUnderlying.weightPct))%。"
                        + state.guidanceText + "。",
                    trigger: "穿透占比继续升至 \(format(p.lookThroughReviewThreshold))% 以上时加重关注",
                    invalidation: "穿透占比回落至 \(format(p.lookThroughWatchThreshold))% 以下",
                    state: state, at: input.asOf))
            }
        }

        // 3. 穿透重叠（多只基金持有同一底层）
        if let overlap = lookThrough.topUnderlyings.first(where: { $0.contributorCount > 1 }) {
            let state = p.preliminaryState(
                value: overlap.weightPct,
                watch: p.overlapWatchThreshold,
                review: p.overlapReviewThreshold,
                hasData: true)
            if state != .stable {
                drafts.append(makeCase(
                    kind: .concentrationRisk, dimension: .lookThroughOverlap,
                    subjectName: overlap.name, subjectCode: overlap.code,
                    metricValue: overlap.weightPct,
                    metricDescription: "跨基金重叠占比",
                    title: "持仓重叠：\(overlap.name)",
                    detail: "\(overlap.contributorCount) 只基金同时持有「\(overlap.name)」，"
                        + "穿透后合计占组合 \(format(overlap.weightPct))%。"
                        + state.guidanceText + "。",
                    trigger: "重叠占比继续升至 \(format(p.overlapReviewThreshold))% 以上时加重关注",
                    invalidation: "重叠占比回落至 \(format(p.overlapWatchThreshold))% 以下",
                    state: state, at: input.asOf))
            }
        }

        // 4. 行业集中度
        if let topSector = lookThrough.industries.first {
            let state = p.preliminaryState(
                value: topSector.weightPct,
                watch: p.sectorWatchThreshold,
                review: p.sectorReviewThreshold,
                hasData: true)
            if state != .stable {
                drafts.append(makeCase(
                    kind: .concentrationRisk, dimension: .sector,
                    subjectName: topSector.label, subjectCode: nil,
                    metricValue: topSector.weightPct,
                    metricDescription: "第一大行业占比",
                    title: "行业集中：\(topSector.label)",
                    detail: "穿透后「\(topSector.label)」行业占组合 \(format(topSector.weightPct))%。"
                        + state.guidanceText + "。",
                    trigger: "行业占比继续升至 \(format(p.sectorReviewThreshold))% 以上时加重关注",
                    invalidation: "行业占比回落至 \(format(p.sectorWatchThreshold))% 以下",
                    state: state, at: input.asOf))
            }
        }

        return drafts
    }

    // MARK: 回撤扩大

    private func drawdownDrafts(_ input: Input) -> [DecisionCase] {
        let p = policy
        // 收益率最负的标的（|profitPct| 口径）
        guard let worst = input.positions
            .compactMap({ position -> (PositionInput, Double)? in
                guard let profitPct = position.profitPct else { return nil }
                return (position, profitPct)
            })
            .min(by: { $0.1 < $1.1 }),
            worst.1 < 0
        else { return [] }
        let drawdown = abs(worst.1)
        let state = p.preliminaryState(
            value: drawdown,
            watch: p.drawdownWatchThreshold,
            review: p.drawdownReviewThreshold,
            hasData: true)
        guard state != .stable else { return [] }
        let position = worst.0
        return [makeCase(
            kind: .drawdownExpansion, dimension: .directHolding,
            subjectName: position.name, subjectCode: position.code,
            metricValue: drawdown,
            metricDescription: "持有收益率回撤幅度",
            title: "回撤扩大：\(position.name)",
            detail: "「\(position.name)」持有收益率 \(format(worst.1))%，回撤幅度超过 "
                + "\(format(p.drawdownWatchThreshold))% 观察线。" + state.guidanceText + "。",
            trigger: "回撤加深至 \(format(p.drawdownReviewThreshold))% 以上时加重关注",
            invalidation: "收益回升，回撤收窄至 \(format(p.drawdownWatchThreshold))% 以内",
            state: state, at: input.asOf)]
    }

    // MARK: 目标偏离（V2 语义：资产类占比 vs 战略目标）

    private func deviationDrafts(_ input: Input) -> [DecisionCase] {
        let p = policy
        return input.deviations
            .filter { abs($0.deviationPp) >= p.deviationWatchThreshold }
            .map { deviation in
                let magnitude = abs(deviation.deviationPp)
                let state = p.preliminaryState(
                    value: magnitude,
                    watch: p.deviationWatchThreshold,
                    review: p.deviationReviewThreshold,
                    hasData: true)
                let direction = deviation.deviationPp > 0 ? "超配" : "低配"
                return makeCase(
                    kind: .targetDeviation, dimension: .directHolding,
                    subjectName: deviation.assetClassLabel, subjectCode: nil,
                    metricValue: magnitude,
                    metricDescription: "资产类偏离幅度（百分点）",
                    title: "目标偏离：\(deviation.assetClassLabel)",
                    detail: "\(deviation.assetClassLabel)当前 \(format(deviation.currentPct))%、"
                        + "目标 \(format(deviation.targetPct))%，\(direction) \(format(magnitude)) 个百分点。"
                        + state.guidanceText + "。",
                    trigger: "偏离扩大至 \(format(p.deviationReviewThreshold)) 个百分点以上时加重关注",
                    invalidation: "偏离收敛至 \(format(p.deviationWatchThreshold)) 个百分点以内",
                    state: state, at: input.asOf)
            }
    }

    // MARK: 草案构造

    private func makeCase(
        kind: DecisionCaseKind,
        dimension: ConcentrationDimension,
        subjectName: String,
        subjectCode: String?,
        metricValue: Double,
        metricDescription: String,
        title: String,
        detail: String,
        trigger: String,
        invalidation: String,
        state: PortfolioDecisionState,
        at date: Date
    ) -> DecisionCase {
        var draft = DecisionCase(
            caseKey: DecisionCase.makeCaseKey(
                kind: kind, dimension: dimension,
                subjectCode: subjectCode, subjectName: subjectName),
            kind: kind,
            dimension: dimension,
            subjectName: subjectName,
            subjectCode: subjectCode,
            lifecycle: .decisionReady,
            decisionState: state,
            metricValue: metricValue,
            metricLabel: "\(format(metricValue))\(kind == .targetDeviation ? "pp" : "%")",
            metricDescription: metricDescription,
            title: title,
            detail: detail,
            triggerCondition: trigger,
            invalidationCondition: invalidation,
            createdAt: date)
        draft.applyTransition(
            to: .decisionReady,
            decisionState: state,
            at: date,
            type: .created,
            reason: "组合风险评估自动生成",
            actor: .system)
        return draft
    }

    /// 穿透覆盖不足的占位案（insufficientEvidence）。
    private func makeInsufficientCase(coverage: Double, at date: Date) -> DecisionCase {
        var draft = DecisionCase(
            caseKey: DecisionCase.makeCaseKey(
                kind: .concentrationRisk, dimension: .lookThrough,
                subjectCode: nil, subjectName: "披露覆盖不足"),
            kind: .concentrationRisk,
            dimension: .lookThrough,
            subjectName: "披露覆盖不足",
            subjectCode: nil,
            lifecycle: .decisionReady,
            decisionState: .insufficientEvidence,
            metricValue: coverage * 100,
            metricLabel: "\(format(coverage * 100))%",
            metricDescription: "穿透披露覆盖率",
            title: "穿透数据不足",
            detail: "持仓披露覆盖率 \(format(coverage * 100))%，低于 "
                + "\(format(policy.minLookThroughCoverage * 100))% 下限，穿透集中度与重叠暂无法评估。",
            createdAt: date)
        draft.applyTransition(
            to: .decisionReady,
            decisionState: .insufficientEvidence,
            at: date,
            type: .created,
            reason: "穿透披露覆盖不足",
            actor: .system)
        return draft
    }

    // MARK: - 行动候选建案（审计 B3）

    /// 行动候选「加入跟踪」建案：kind .actionMigration，直接进入
    /// monitoring + acknowledged（用户主动动作），detail 标注人工复核。
    /// caseKey 复用 kind|dimension|subjectKey —— 同标的重复加入去重合并。
    static func makeActionMigrationCase(
        subjectName: String,
        subjectCode: String?,
        directionText: String,
        rationale: String,
        trigger: String?,
        invalidation: String?,
        sourceArtifactID: String,
        at date: Date
    ) -> DecisionCase {
        var draft = DecisionCase(
            caseKey: DecisionCase.makeCaseKey(
                kind: .actionMigration, dimension: .directHolding,
                subjectCode: subjectCode, subjectName: subjectName),
            kind: .actionMigration,
            dimension: .directHolding,
            subjectName: subjectName,
            subjectCode: subjectCode,
            lifecycle: .monitoring,
            decisionState: .watch,
            metricValue: 0,
            metricLabel: "",
            metricDescription: "研究行动候选",
            title: "行动跟踪：\(subjectName) \(directionText)",
            detail: rationale + "\n\n来源研究报告 \(sourceArtifactID)。"
                + "触发/失效条件为研究建议（人工复核，不自动触发）。",
            triggerCondition: trigger,
            invalidationCondition: invalidation,
            createdAt: date,
            userDisposition: .acknowledged)
        draft.reviewDueAt = DecisionCase.computeReviewDueAt(decisionState: .watch, from: date)
        draft.applyTransition(
            to: .monitoring,
            decisionState: .watch,
            at: date,
            type: .created,
            reason: "用户从研究报告加入行动跟踪",
            actor: .user)
        return draft
    }

    // MARK: - 合并状态机（评估结果并入既有事项）

    /// 语义（V1 对齐 + 显式化）：
    /// - 用户显式关闭（disposition .closed）的事项是墓碑，永不复活
    /// - 已关闭（自动关闭 / 复盘关闭）+ 风险再现 → 重新开启（保留 id/createdAt/events）
    /// - 开放事项命中草案 → 刷新指标（显著变化才记事件）；acknowledged 保持
    ///   monitoring 并按最新状态续期 reviewDueAt；pending 保持 decisionReady
    /// - 不再命中草案：pending 自动关闭；acknowledged 保留监控（交复盘解决），
    ///   状态降 stable 并记录「回到阈值内」
    static func merge(
        existing: [DecisionCase], incoming: [DecisionCase], now: Date
    ) -> [DecisionCase] {
        var draftsByKey: [String: DecisionCase] = [:]
        for draft in incoming {
            draftsByKey[draft.caseKey] = draft
        }
        // 同标的的行动候选建案与既有行动案合并（content 更新，不重复建）
        var result: [DecisionCase] = []
        var consumedDraftKeys = Set<String>()

        for var existingCase in existing {
            guard existingCase.userDisposition != .closed else {
                // 用户显式关闭：墓碑，不再触碰
                result.append(existingCase)
                consumedDraftKeys.insert(existingCase.caseKey)
                continue
            }

            if let draft = draftsByKey[existingCase.caseKey] {
                consumedDraftKeys.insert(existingCase.caseKey)
                if existingCase.lifecycle == .closed {
                    // 自动关闭 / 复盘关闭后风险再现 → 重新开启
                    existingCase.applyTransition(
                        to: existingCase.userDisposition == .acknowledged ? .monitoring : .decisionReady,
                        decisionState: draft.decisionState,
                        at: now,
                        type: .reassessed,
                        reason: "风险指标再次超标，重新开启",
                        actor: .system)
                    existingCase.resolvedAt = nil
                    existingCase.reviewDueAt = existingCase.userDisposition == .acknowledged
                        ? DecisionCase.computeReviewDueAt(decisionState: draft.decisionState, from: now)
                        : nil
                } else {
                    mergeDraftIntoCase(&existingCase, draft: draft, now: now)
                }
                result.append(existingCase)
                continue
            }

            // 不再命中草案：风险消退
            if existingCase.lifecycle != .closed {
                if existingCase.userDisposition == .pending {
                    existingCase.applyTransition(
                        to: .closed,
                        decisionState: .stable,
                        at: now,
                        type: .reassessed,
                        reason: "风险指标已回到阈值内，自动关闭",
                        actor: .system)
                    existingCase.resolvedAt = now
                } else {
                    // acknowledged：保留监控，状态降 stable，等待用户复盘了结
                    let stateChanged = existingCase.decisionState != .stable
                    existingCase.decisionState = .stable
                    existingCase.lastEvaluatedAt = now
                    if stateChanged {
                        existingCase.applyTransition(
                            to: existingCase.lifecycle,
                            decisionState: .stable,
                            at: now,
                            type: .reassessed,
                            reason: "风险指标已回到阈值内",
                            actor: .system)
                    }
                }
            }
            result.append(existingCase)
        }

        // 新草案追加
        let newCases = incoming.filter { !consumedDraftKeys.contains($0.caseKey) }
        result.append(contentsOf: newCases)

        // monitoring 到期 → reviewDue（merge 后统一标记——先标记会被草案
        // 合并的重置逻辑盖回 monitoring；不改 updatedAt，V1 语义）
        for index in result.indices {
            guard result[index].lifecycle == .monitoring,
                  result[index].isReviewDue(asOf: now)
            else { continue }
            let decisionCase = result[index]
            result[index].lifecycle = .reviewDue
            result[index].events.append(DecisionCaseEvent(
                at: now,
                type: .reassessed,
                previousLifecycle: .monitoring,
                newLifecycle: .reviewDue,
                previousDecisionState: decisionCase.decisionState,
                newDecisionState: decisionCase.decisionState,
                reason: "到达复查时间",
                actor: .system))
        }

        return result.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.caseKey < $1.caseKey
        }
    }

    /// 草案指标并入开放事项：显著变化才记事件（避免每次刷新刷屏）。
    private static func mergeDraftIntoCase(
        _ existingCase: inout DecisionCase, draft: DecisionCase, now: Date
    ) {
        let metricChanged = abs(existingCase.metricValue - draft.metricValue) > 0.05
        let stateChanged = existingCase.decisionState != draft.decisionState
        existingCase.metricValue = draft.metricValue
        existingCase.metricLabel = draft.metricLabel
        existingCase.title = draft.title
        existingCase.detail = draft.detail
        existingCase.triggerCondition = draft.triggerCondition
        existingCase.invalidationCondition = draft.invalidationCondition
        existingCase.lastEvaluatedAt = now
        existingCase.updatedAt = now
        if metricChanged || stateChanged {
            existingCase.applyTransition(
                to: existingCase.lifecycle,
                decisionState: draft.decisionState,
                at: now,
                type: .reassessed,
                reason: "指标刷新：\(draft.metricLabel)",
                actor: .system)
            // 指标显著变化 = 有新信息 → acknowledged 案的复查时钟重置；
            // 指标不变不续期（否则频繁刷新会让复查永远不到期）
            if existingCase.userDisposition == .acknowledged,
               existingCase.lifecycle == .monitoring || existingCase.lifecycle == .reviewDue {
                existingCase.lifecycle = .monitoring
                existingCase.reviewDueAt = DecisionCase.computeReviewDueAt(
                    decisionState: draft.decisionState, from: now)
            }
        } else {
            existingCase.decisionState = draft.decisionState
        }
    }

    // MARK: - 复盘落地（六选一 + 经验笔记）

    /// 复盘结论 → 生命周期流转（V1 语义）：
    /// - supported / partiallySupported / unresolved → 回 monitoring 续期
    /// - contradicted / invalidatedBeforeEvaluation → 关闭（resolved）
    /// - insufficientData → 回 monitoring，复查缩短 3 天
    static func applyReview(
        _ review: DecisionReview, to caseInput: DecisionCase, now: Date
    ) -> DecisionCase {
        var updated = caseInput
        updated.reviews.append(review)
        switch review.conclusion {
        case .supported, .partiallySupported, .unresolved:
            updated.applyTransition(
                to: .monitoring,
                decisionState: updated.decisionState,
                at: now,
                type: .reviewRecorded,
                reason: "复盘结论：\(review.conclusion.displayName)——继续跟踪",
                actor: .user)
            updated.reviewDueAt = DecisionCase.computeReviewDueAt(
                decisionState: updated.decisionState, from: now)
        case .contradicted, .invalidatedBeforeEvaluation:
            updated.applyTransition(
                to: .closed,
                decisionState: updated.decisionState,
                at: now,
                type: .reviewRecorded,
                reason: "复盘结论：\(review.conclusion.displayName)——关闭事项",
                actor: .user)
            updated.userDisposition = .resolved
            updated.resolvedAt = now
            updated.reviewDueAt = nil
        case .insufficientData:
            updated.applyTransition(
                to: .monitoring,
                decisionState: updated.decisionState,
                at: now,
                type: .reviewRecorded,
                reason: "复盘结论：数据不足——3 天后复查",
                actor: .user)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            updated.reviewDueAt = calendar.date(byAdding: .day, value: 3, to: now)
        }
        return updated
    }

    // MARK: - 格式化

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
