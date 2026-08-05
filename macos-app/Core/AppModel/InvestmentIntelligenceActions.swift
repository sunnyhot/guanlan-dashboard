import Foundation

// 投资智能系统的 AppModel 动作层。
//
// 全部 gate 在 InvestmentIntelligence.enabled(默认 false):
// - enabled=false 时,所有动作直接 return,不读不写不计算。
// - enabled=true 时,才加载/刷新/操作 DecisionCase。
//
// 见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 1 设计。

extension AppModel {

    // MARK: - 状态加载

    /// 加载 DecisionCase 和 UserDecisionProfile(Slice 1 gate)。
    /// 在 loadEnhancementState 里调用。enabled=false 时跳过。
    func loadInvestmentIntelligenceState() {
        guard InvestmentIntelligence.enabled else { return }

        if let profileURL = userDecisionProfileFileURL {
            do {
                userDecisionProfile = try UserDecisionProfileStore().load(from: profileURL)
            } catch {
                errorMessage = "用户决策画像加载失败：\(error.localizedDescription)"
            }
        }

        if let casesURL = decisionCasesFileURL {
            do {
                decisionCases = try DecisionCaseStore().load(from: casesURL)
            } catch {
                errorMessage = "决策事项加载失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 刷新(集中度评估)

    /// 刷新集中度风险评估,生成/更新 DecisionCase。
    /// 在 PortfolioRefresh 末尾调用。enabled=false 时跳过。
    func refreshConcentrationDecisionCases() async {
        guard InvestmentIntelligence.enabled else { return }
        guard !isRefreshingDecisionCases else { return }
        guard !personalAssetRows.isEmpty else { return }

        isRefreshingDecisionCases = true
        defer { isRefreshingDecisionCases = false }

        // 如果穿透快照缺失或过旧,尝试刷新(复用趋势分析的管线)。
        // 注意:fetchDisclosures 是异步的,有缓存。失败时静默降级(snapshot=nil → insufficientEvidence)。
        if portfolioLookThroughSnapshot == nil {
            await refreshLookThroughForConcentration()
        }

        let timestamp = Self.timestampString()
        let newCases = ConcentrationRiskEngine.evaluate(
            rows: personalAssetRows,
            lookThroughSnapshot: portfolioLookThroughSnapshot,
            profile: userDecisionProfile,
            timestamp: timestamp
        )

        // 合并:保留用户已处置(acknowledged/resolved/closed)的旧 Case,
        // 用新评估的 Case 替换/新增 pending 的。
        decisionCases = mergeDecisionCases(existing: decisionCases, incoming: newCases, timestamp: timestamp)
        persistDecisionCases()
    }

    /// 独立刷新穿透快照(供集中度评估用,不依赖趋势分析流程)。
    private func refreshLookThroughForConcentration() async {
        let fundCodes = personalAssetRows
            .filter { $0.assetType == .fund }
            .compactMap { $0.fundCode }
            .filter { !$0.isEmpty }
        guard !fundCodes.isEmpty else { return }

        do {
            let batch = await fundLookThroughClient.fetchDisclosures(fundCodes: fundCodes)
            portfolioLookThroughSnapshot = PortfolioLookThroughCalculator.make(
                rows: personalAssetRows,
                disclosures: batch.disclosures,
                generatedAt: Self.timestampString()
            )
            portfolioLookThroughSourceWarnings = batch.warnings
        } catch {
            // 静默失败:穿透缺失时引擎会降级 insufficientEvidence
            portfolioLookThroughSourceWarnings = ["集中度穿透刷新失败：\(error.localizedDescription)"]
        }
    }

    // MARK: - 合并逻辑

    /// 合并旧 Case(保留用户处置)和新 Case(新评估)。
    private func mergeDecisionCases(
        existing: [DecisionCase],
        incoming: [DecisionCase],
        timestamp: String
    ) -> [DecisionCase] {
        let existingByKey = Dictionary(existing.map { ($0.caseKey, $0) }, uniquingKeysWith: { _, last in last })

        var merged: [DecisionCase] = []
        var consumedKeys = Set<String>()

        // 1. 处理新评估的 Case
        for newCase in incoming {
            consumedKeys.insert(newCase.caseKey)
            if let oldCase = existingByKey[newCase.caseKey] {
                // 已存在:保留用户处置状态,更新指标和决策状态
                var updated = newCase
                updated.id = oldCase.id  // 保持 ID 稳定
                updated.createdAt = oldCase.createdAt
                updated.events = oldCase.events  // 保留历史事件
                updated.userDisposition = oldCase.userDisposition

                // 如果决策状态有变化,记录一次 reassessed 事件
                if oldCase.decisionState != newCase.decisionState {
                    updated.applyTransition(
                        to: newCase.lifecycle,
                        decisionState: newCase.decisionState,
                        at: timestamp,
                        type: .reassessed,
                        reason: "指标更新:\(oldCase.metricLabel) → \(newCase.metricLabel)",
                        actor: .system
                    )
                } else {
                    // 仅更新指标数值,不改状态
                    updated.updatedAt = timestamp
                }

                // 用户已关闭的 Case 不重新激活
                if oldCase.userDisposition == .closed {
                    updated.lifecycle = .closed
                }

                merged.append(updated)
            } else {
                // 新 Case
                merged.append(newCase)
            }
        }

        // 2. 保留不再出现但用户仍关注的旧 Case(标记为 stale,不删除)
        for oldCase in existing where !consumedKeys.contains(oldCase.caseKey) {
            if oldCase.userDisposition == .acknowledged || oldCase.userDisposition == .pending {
                var stale = oldCase
                stale.applyTransition(
                    to: oldCase.lifecycle,
                    decisionState: .stable,
                    at: timestamp,
                    type: .reassessed,
                    reason: "指标已回到阈值内",
                    actor: .system
                )
                merged.append(stale)
            }
            // resolved/closed 的旧 Case 不保留(已处理)
        }

        return merged
    }

    // MARK: - 用户操作

    /// 用户确认关注某个 Case(进入 monitoring)。
    func acknowledgeDecisionCase(_ id: UUID) {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        decisionCases[index].applyTransition(
            to: .monitoring,
            decisionState: decisionCases[index].decisionState,
            at: Self.timestampString(),
            type: .userAcknowledged,
            reason: "用户确认关注",
            actor: .user
        )
        decisionCases[index].userDisposition = .acknowledged
        persistDecisionCases()
    }

    /// 用户标记 Case 已解决。
    func resolveDecisionCase(_ id: UUID, note: String = "") {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        decisionCases[index].applyTransition(
            to: .closed,
            decisionState: .stable,
            at: Self.timestampString(),
            type: .userResolved,
            reason: note.isEmpty ? "用户标记已解决" : note,
            actor: .user
        )
        decisionCases[index].userDisposition = .resolved
        persistDecisionCases()
    }

    /// 用户关闭 Case(不再关注)。
    func closeDecisionCase(_ id: UUID) {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        decisionCases[index].applyTransition(
            to: .closed,
            decisionState: decisionCases[index].decisionState,
            at: Self.timestampString(),
            type: .userClosed,
            reason: "用户关闭",
            actor: .user
        )
        decisionCases[index].userDisposition = .closed
        persistDecisionCases()
    }

    // MARK: - Profile 更新

    /// 更新用户决策画像。
    func updateUserDecisionProfile(_ profile: UserDecisionProfile) {
        userDecisionProfile = profile
        if let url = userDecisionProfileFileURL {
            do {
                try UserDecisionProfileStore().save(profile, to: url)
            } catch {
                errorMessage = "用户决策画像保存失败：\(error.localizedDescription)"
            }
        }
        // Profile 变化后立即重新评估(阈值可能改变)
        Task { await refreshConcentrationDecisionCases() }
    }

    // MARK: - 持久化

    func persistDecisionCases() {
        guard let url = decisionCasesFileURL else { return }
        do {
            try DecisionCaseStore().save(decisionCases, to: url)
        } catch {
            errorMessage = "决策事项保存失败：\(error.localizedDescription)"
        }
    }
}
