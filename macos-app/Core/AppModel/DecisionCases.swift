import Foundation

// MARK: - AppModel 决策事项集成（审计 A2/A3，2026-08-27）
//
// 数据流：持仓刷新末尾（refreshPortfolioLookThrough 之后）触发
// refreshDecisionCases()——App 侧装配引擎输入（持仓权重 / 穿透素材 /
// 战略目标偏差），DecisionCaseEngine（纯函数）评估 + merge，落
// DecisionCaseStore（user-intent 文件事实源），@Published 驱动 UI。
// 用户动作（关注/解决/关闭/复盘）与行动候选建案（审计 B3）同经本文件。
//
// 通知：新建 watch/prepare/adjustReview 案发本地通知（深链
// NotificationDeepLinkType.intelligence，targetID = case id）。

extension AppModel {

    // MARK: - 装配与刷新

    /// bootstrap 时加载既有事项 + 一次性导入 V1 遗留（幂等）。
    func loadDecisionCasesAndImportLegacy(
        runtime: IntelligenceV2Runtime, dataDirectory: URL
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            // V1 导入（决策事项 + 手写复盘；无源文件时 no-op）
            _ = try? LegacyDecisionCaseImport.run(
                store: runtime.decisionCaseStore, dataDirectory: dataDirectory)
            let cases = (try? runtime.decisionCaseStore.loadAll()) ?? []
            await MainActor.run {
                self?.decisionCases = cases
            }
        }
    }

    /// 评估并合并决策事项（持仓刷新末尾调用；fire-and-forget）。
    func refreshDecisionCases() {
        guard let runtime = intelligenceRuntime else { return }
        guard !isRefreshingDecisionCases else { return }
        isRefreshingDecisionCases = true
        let rows = personalAssetRows
        let lookThroughSnapshot = portfolioLookThroughSnapshot
        let disclosures = lookThroughSnapshot?.disclosures ?? [:]
        let now = Date()
        Task.detached(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.isRefreshingDecisionCases = false } }
            do {
                let input = Self.assembleDecisionCaseInput(
                    rows: rows,
                    lookThroughSnapshot: lookThroughSnapshot,
                    deviations: Self.assembleDeviationInputs(
                        rows: rows, disclosures: disclosures, runtime: runtime, now: now),
                    asOf: now)
                let engine = DecisionCaseEngine()
                let drafts = engine.evaluate(input)
                let existing = try runtime.decisionCaseStore.loadAll()
                let existingKeys = Set(existing.map(\.caseKey))
                let merged = DecisionCaseEngine.merge(
                    existing: existing, incoming: drafts, now: now)
                try runtime.decisionCaseStore.saveAll(merged)
                let newNotable = merged.filter {
                    !existingKeys.contains($0.caseKey)
                        && ($0.decisionState == .watch
                            || $0.decisionState == .prepare
                            || $0.decisionState == .adjustReview)
                }
                await MainActor.run {
                    self?.decisionCases = merged
                    self?.notifyNewDecisionCases(newNotable)
                }
            } catch {
                await AIAgentDiagnosticLog.record(
                    "decision-cases",
                    message: "决策事项刷新失败: \(error)")
            }
        }
    }

    /// 持仓 + 穿透快照 → 引擎输入（纯映射）。
    nonisolated static func assembleDecisionCaseInput(
        rows: [PersonalAssetAggregateRow],
        lookThroughSnapshot: PortfolioLookThroughSnapshot?,
        deviations: [DecisionCaseEngine.DeviationInput],
        asOf: Date
    ) -> DecisionCaseEngine.Input {
        let exposedRows = rows.filter { $0.effectiveHoldingAmount > 0.001 }
        let totalExposure = exposedRows.reduce(0.0) { $0 + $1.effectiveHoldingAmount }
        let positions: [DecisionCaseEngine.PositionInput] = totalExposure > 0
            ? exposedRows.map { row in
                DecisionCaseEngine.PositionInput(
                    name: row.fundName,
                    code: row.fundCode,
                    weightPct: row.effectiveHoldingAmount / totalExposure * 100,
                    profitPct: row.holdingRow?.profitPct)
            }
            : []
        var lookThrough: DecisionCaseEngine.LookThroughInput?
        if let snapshot = lookThroughSnapshot {
            lookThrough = DecisionCaseEngine.LookThroughInput(
                coverage: snapshot.disclosedSecurityCoveragePct / 100,
                topUnderlyings: snapshot.topPositions.prefix(20).map { position in
                    DecisionCaseEngine.LookThroughInput.UnderlyingInput(
                        name: position.name,
                        code: position.code,
                        weightPct: position.portfolioWeightPct,
                        contributorCount: position.contributors.count)
                },
                industries: snapshot.industries.prefix(20).map { industry in
                    DecisionCaseEngine.LookThroughInput.IndustryInput(
                        label: industry.name,
                        weightPct: industry.portfolioWeightPct)
                })
        }
        return DecisionCaseEngine.Input(
            positions: positions,
            lookThrough: lookThrough,
            deviations: deviations,
            asOf: asOf)
    }

    /// 战略目标偏差输入（Target + 分类解析 + 组合快照；被阻断时返回空——
    /// 偏差案只在输入齐备时评估，不猜）。
    nonisolated static func assembleDeviationInputs(
        rows: [PersonalAssetAggregateRow],
        disclosures: [String: FundLookThroughDisclosure],
        runtime: IntelligenceV2Runtime,
        now: Date
    ) -> [DecisionCaseEngine.DeviationInput] {
        guard let target = try? runtime.targetStore.currentTarget(),
              let assignments = try? runtime.assignmentStore.currentAssignments()
        else { return [] }
        let resolved = StrategicAssetClassificationResolver.resolve(
            rows: rows, assignments: assignments, disclosures: disclosures, now: now)
        guard resolved.unresolvedSubjectKeys.isEmpty else { return [] }
        guard let build = try? LivePortfolioSnapshotBuilder.build(
            rows: rows, classification: resolved.classification, asOf: now)
        else { return [] }
        return AssetClass.allCases.compactMap { assetClass in
            guard let currentRatio = build.currentClassWeights[assetClass] else { return nil }
            let targetRatio = target.targetWeight(for: assetClass)?.value ?? .zero
            return DecisionCaseEngine.DeviationInput(
                assetClassLabel: IntelligencePresentationFormatter.assetClassName(assetClass),
                currentPct: (currentRatio as NSDecimalNumber).doubleValue * 100,
                targetPct: (targetRatio as NSDecimalNumber).doubleValue * 100)
        }
    }

    // MARK: - 用户动作

    /// 关注事项（pending → monitoring，设复查时间）。
    func acknowledgeDecisionCase(id: String) {
        mutateDecisionCase(id: id) { existing in
            let now = Date()
            var updated = existing
            updated.userDisposition = .acknowledged
            updated.applyTransition(
                to: .monitoring,
                decisionState: existing.decisionState,
                at: now,
                type: .userAcknowledged,
                reason: "用户确认关注，进入跟踪",
                actor: .user)
            updated.reviewDueAt = DecisionCase.computeReviewDueAt(
                decisionState: existing.decisionState, from: now)
            return updated
        }
    }

    /// 标记已解决（附可选笔记）。
    func resolveDecisionCase(id: String, note: String?) {
        mutateDecisionCase(id: id) { existing in
            let now = Date()
            var updated = existing
            updated.userDisposition = .resolved
            updated.resolvedAt = now
            updated.reviewDueAt = nil
            let reason = note?.isEmpty == false
                ? "用户标记已解决：\(note!)"
                : "用户标记已解决"
            updated.applyTransition(
                to: .closed,
                decisionState: existing.decisionState,
                at: now,
                type: .userResolved,
                reason: reason,
                actor: .user)
            return updated
        }
    }

    /// 关闭事项（墓碑——不再自动复活）。
    func closeDecisionCase(id: String) {
        mutateDecisionCase(id: id) { existing in
            let now = Date()
            var updated = existing
            updated.userDisposition = .closed
            updated.resolvedAt = now
            updated.reviewDueAt = nil
            updated.applyTransition(
                to: .closed,
                decisionState: existing.decisionState,
                at: now,
                type: .userClosed,
                reason: "用户关闭事项（不再跟踪）",
                actor: .user)
            return updated
        }
    }

    /// 重新打开（已关闭但非墓碑的事项）。
    func reopenDecisionCase(id: String) {
        mutateDecisionCase(id: id) { existing in
            guard existing.lifecycle == .closed,
                  existing.userDisposition != .closed
            else { return existing }
            let now = Date()
            var updated = existing
            updated.userDisposition = .pending
            updated.resolvedAt = nil
            updated.applyTransition(
                to: .decisionReady,
                decisionState: existing.decisionState,
                at: now,
                type: .userReopened,
                reason: "用户重新打开事项",
                actor: .user)
            return updated
        }
    }

    /// 记录复盘（六选一 + 经验笔记；流转见 DecisionCaseEngine.applyReview）。
    func recordDecisionReview(
        caseID: String, conclusion: DecisionReviewConclusion, lessons: String
    ) {
        mutateDecisionCase(id: caseID) { existing in
            let now = Date()
            let review = DecisionReview(
                caseID: existing.id,
                reviewedAt: now,
                originalDecisionState: existing.decisionState,
                originalMetricValue: existing.metricValue,
                currentMetricValue: existing.metricValue,
                conclusion: conclusion,
                lessons: lessons)
            return DecisionCaseEngine.applyReview(review, to: existing, now: now)
        }
    }

    /// 行动候选「加入跟踪」建案（审计 B3）。同标的重复加入合并更新。
    @discardableResult
    func addCaseFromActionCandidate(
        subjectName: String,
        subjectCode: String?,
        directionText: String,
        rationale: String,
        trigger: String?,
        invalidation: String?,
        sourceArtifactID: String
    ) -> DecisionCase? {
        guard let runtime = intelligenceRuntime else { return nil }
        let now = Date()
        let draft = DecisionCaseEngine.makeActionMigrationCase(
            subjectName: subjectName,
            subjectCode: subjectCode,
            directionText: directionText,
            rationale: rationale,
            trigger: trigger,
            invalidation: invalidation,
            sourceArtifactID: sourceArtifactID,
            at: now)
        let existing = decisionCases.first { $0.caseKey == draft.caseKey }
        var updated: DecisionCase
        if var existingCase = existing, existingCase.lifecycle != .closed {
            existingCase.detail = draft.detail
            existingCase.title = draft.title
            existingCase.triggerCondition = draft.triggerCondition
            existingCase.invalidationCondition = draft.invalidationCondition
            existingCase.lastEvaluatedAt = now
            existingCase.updatedAt = now
            existingCase.events.append(DecisionCaseEvent(
                at: now,
                type: .reassessed,
                previousLifecycle: existingCase.lifecycle,
                newLifecycle: existingCase.lifecycle,
                previousDecisionState: existingCase.decisionState,
                newDecisionState: existingCase.decisionState,
                reason: "行动候选再次加入，更新研究建议",
                actor: .user))
            updated = existingCase
        } else {
            updated = draft
        }
        do {
            try runtime.decisionCaseStore.save(updated)
            if let index = decisionCases.firstIndex(where: { $0.id == updated.id }) {
                decisionCases[index] = updated
            } else {
                decisionCases.insert(updated, at: 0)
            }
            return updated
        } catch {
            Task {
                await AIAgentDiagnosticLog.record(
                    "decision-cases",
                    message: "行动候选建案失败: \(error)")
            }
            return nil
        }
    }

    // MARK: - 派生（View 消费面）

    /// 开放事项（未关闭）。
    var openDecisionCases: [DecisionCase] {
        decisionCases.filter { $0.lifecycle != .closed }
    }

    /// 待复盘事项（reviewDue 或已到复查时间）。
    var reviewDueDecisionCases: [DecisionCase] {
        decisionCases.filter {
            $0.lifecycle == .reviewDue
                || ($0.lifecycle == .monitoring && $0.isReviewDue(asOf: Date()))
        }
    }

    // MARK: - 私有

    /// 主线程读 → 变换 → 持久化 → 回写（单事项动作的统一管道）。
    private func mutateDecisionCase(
        id: String, _ transform: @escaping (DecisionCase) -> DecisionCase
    ) {
        guard let runtime = intelligenceRuntime,
              let index = decisionCases.firstIndex(where: { $0.id == id })
        else { return }
        let updated = transform(decisionCases[index])
        decisionCases[index] = updated
        Task.detached(priority: .utility) {
            do {
                try runtime.decisionCaseStore.save(updated)
            } catch {
                await AIAgentDiagnosticLog.record(
                    "decision-cases",
                    message: "事项持久化失败 \(id): \(error)")
            }
        }
    }

    /// 新建 watch 及以上状态的事项 → 本地通知（深链打开详情）。
    private func notifyNewDecisionCases(_ cases: [DecisionCase]) {
        guard !cases.isEmpty else { return }
        let top = cases.prefix(3)
        let title = cases.count == 1
            ? "新决策事项：\(top[0].title)"
            : "新增 \(cases.count) 个决策事项"
        let body = top
            .map { "\($0.title)（\($0.decisionState.displayName)）" }
            .joined(separator: "；")
        Task {
            let authorized = await notificationManager.requestAuthorizationIfNeeded()
            guard authorized else { return }
            let payload = NotificationDeepLinkPayload(
                type: .intelligence, targetID: top[0].id)
            try? await notificationManager.send(
                title: title, subtitle: "", body: body, deepLink: payload)
        }
    }
}
