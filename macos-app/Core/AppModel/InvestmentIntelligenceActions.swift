import Foundation

// 投资智能系统的 AppModel 动作层。
//
// 全部 gate 在 InvestmentIntelligence.enabled(默认 false):
// - enabled=false 时,所有动作直接 return,不读不写不计算。
// - enabled=true 时,才加载/刷新/操作 DecisionCase。
//
// 见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 1 设计。

extension AppModel {

    // MARK: - 派生数据(M4:View 不做业务计算)

    /// 活跃的 DecisionCase(未关闭)。
    var activeDecisionCases: [DecisionCase] {
        decisionCases.filter { $0.userDisposition != .closed && $0.lifecycle != .closed }
    }

    /// 历史 Case(已关闭)。
    var historicalDecisionCases: [DecisionCase] {
        decisionCases.filter { $0.userDisposition == .closed || $0.lifecycle == .closed }
    }

    /// 投资智能仪表盘摘要(Presenter 输出,View 直接消费)。
    var investmentIntelligenceSummary: InvestmentIntelligenceDashboardSummary {
        InvestmentIntelligencePresenter.makeSummary(
            cases: decisionCases,
            rows: personalAssetRows,
            lookThroughSnapshot: portfolioLookThroughSnapshot,
            evaluatedAt: decisionCases.map(\.lastEvaluatedAt).max() ?? ""
        )
    }

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

        // 兼容 GLM 中间版本的目录式 Repository。旧目录只读保留，迁到当前唯一 Store/Journal。
        if let baseDirectory = investmentIntelligenceDirectoryURL,
           let journalDirectory = decisionCaseJournalDirectoryURL {
            do {
                let migration = LegacyDecisionCaseMigration(baseDirectory: baseDirectory)
                if migration.needsMigration {
                    let legacyCases = try migration.migrate(
                        into: DecisionCaseJournalStore(baseDirectory: journalDirectory)
                    )
                    for legacyCase in legacyCases {
                        if let index = decisionCases.firstIndex(where: {
                            $0.id == legacyCase.id || $0.caseKey == legacyCase.caseKey
                        }) {
                            // 用户处置和更完整的事件历史优先保留；当前指标仍由随后刷新更新。
                            if decisionCases[index].userDisposition == .pending,
                               legacyCase.userDisposition != .pending {
                                decisionCases[index] = legacyCase
                            } else {
                                let knownEventIDs = Set(decisionCases[index].events.map(\.id))
                                let missingEvents = legacyCase.events.filter { !knownEventIDs.contains($0.id) }
                                decisionCases[index].events.append(contentsOf: missingEvents)
                                decisionCases[index].events.sort { $0.at < $1.at }
                                decisionCases[index].createdAt = min(
                                    decisionCases[index].createdAt,
                                    legacyCase.createdAt
                                )
                                decisionCases[index].latestResearchRunID =
                                    decisionCases[index].latestResearchRunID ?? legacyCase.latestResearchRunID
                                decisionCases[index].latestReviewID =
                                    decisionCases[index].latestReviewID ?? legacyCase.latestReviewID
                            }
                        } else {
                            decisionCases.append(legacyCase)
                        }
                    }
                    persistDecisionCases()
                }
            } catch {
                errorMessage = "旧决策记录迁移失败：\(error.localizedDescription)"
            }
        }

        // 加载可恢复的研究运行与复盘记录。
        if let journalDir = decisionCaseJournalDirectoryURL {
            let store = DecisionCaseJournalStore(baseDirectory: journalDir)
            var reports: [UUID: DecisionCaseResearchReport] = [:]
            var runs: [UUID: DecisionCaseResearchRunRecord] = [:]
            var errors: [UUID: String] = [:]
            var reviews: [UUID: [DecisionReview]] = [:]
            for cs in decisionCases {
                do {
                    if var run = try store.loadLatestResearchRun(caseID: cs.id) {
                        if run.status == .running {
                            run = DecisionCaseResearchRunRecord(
                                id: run.id,
                                caseID: run.caseID,
                                startedAt: run.startedAt,
                                finishedAt: Self.timestampString(),
                                trigger: run.trigger,
                                status: .interrupted,
                                report: run.report,
                                errorMessage: "应用退出前研究尚未完成"
                            )
                            try store.saveResearchRun(run)
                        }
                        runs[cs.id] = run
                        if let report = run.report { reports[cs.id] = report }
                        if let message = run.errorMessage, !message.isEmpty { errors[cs.id] = message }
                    } else if let legacyReport = store.loadLegacyLatestResearch(caseID: cs.id) {
                        reports[cs.id] = legacyReport
                    }
                    reviews[cs.id] = try store.loadReviews(caseID: cs.id)
                } catch {
                    errorMessage = "决策历史加载失败：\(error.localizedDescription)"
                }
            }
            lastDecisionCaseResearchReports = reports
            latestDecisionCaseResearchRuns = runs
            decisionCaseResearchErrors = errors
            decisionCaseReviews = reviews
        }

        // Slice 6:从旧 TrendTracking 迁移(一次性,用 legacy: 前缀去重)
        migrateLegacyTrackingIfNeeded()
    }

    /// 从旧 trend-tracking-items.json 增量迁移到 DecisionCase。
    /// per-item 去重:按每个 tracking item 的 caseKey 判断是否已迁移(不用全局 contains)。
    /// 新增的 tracking item 仍能增量迁移。
    /// 旧文件保留不删除(sunset 三阶段:N 版双读)。
    private func migrateLegacyTrackingIfNeeded() {
        guard let trackingURL = trendTrackingItemsFileURL else { return }
        guard FileManager.default.fileExists(atPath: trackingURL.path) else { return }

        do {
            let trackingItems = try TrendTrackingStore().load(from: trackingURL)
            guard !trackingItems.isEmpty else { return }

            // 已有的 caseKey 集合(per-item 去重)
            let existingKeys = Set(decisionCases.map(\.caseKey))
            var newCases: [DecisionCase] = []

            for item in trackingItems {
                if item.status == .ended { continue }  // ended 不迁移

                // 构造迁移后的 caseKey(与 TrendTrackingMigration 一致)
                let subjectID = item.assetCode?.lowercased() ?? item.assetName.lowercased()
                let caseKey = "legacy:\(item.action.rawValue)|\(subjectID)"

                if existingKeys.contains(caseKey) { continue }  // 已迁移跳过

                let migrated = TrendTrackingMigration.migrate(item)
                newCases.append(migrated)
            }

            guard !newCases.isEmpty else { return }
            decisionCases.append(contentsOf: newCases)
            persistDecisionCases()
        } catch {
            errorMessage = "旧跟踪清单迁移失败:\(error.localizedDescription)"
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

        // Slice 7:检查到期复查的 Case
        markReviewDueCases()

        // Slice 3:自动触发专项研究(对 watch/prepare Case,后台启动)
        await autoTriggerDecisionCaseResearchIfNeeded()
    }

    /// 独立刷新穿透快照(供集中度评估和研究用,不依赖趋势分析流程)。
    func refreshLookThroughForConcentration() async {
        let fundCodes = personalAssetRows
            .filter { $0.assetType == .fund }
            .compactMap { $0.fundCode }
            .filter { !$0.isEmpty }
        guard !fundCodes.isEmpty else { return }

        let batch = await fundLookThroughClient.fetchDisclosures(fundCodes: fundCodes)
        portfolioLookThroughSnapshot = PortfolioLookThroughCalculator.make(
            rows: personalAssetRows,
            disclosures: batch.disclosures,
            generatedAt: Self.timestampString()
        )
        portfolioLookThroughSourceWarnings = batch.warnings
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
                // 用户明确关闭的事项不自动复活；其余事项保留完整工作流与 Journal 引用。
                if oldCase.userDisposition == .closed {
                    merged.append(oldCase)
                    continue
                }

                if oldCase.userDisposition == .resolved || oldCase.lifecycle == .closed {
                    var reopened = newCase
                    reopened.id = oldCase.id
                    reopened.createdAt = oldCase.createdAt
                    reopened.events = oldCase.events
                    reopened.userDisposition = .pending
                    reopened.resolvedAt = nil
                    reopened.latestResearchRunID = oldCase.latestResearchRunID
                    reopened.latestReviewID = oldCase.latestReviewID
                    reopened.applyTransition(
                        to: .decisionReady,
                        decisionState: newCase.decisionState,
                        at: timestamp,
                        type: .userReopened,
                        reason: "风险指标再次进入关注区间",
                        actor: .system
                    )
                    merged.append(reopened)
                    continue
                }

                var updated = oldCase
                updated.metricValue = newCase.metricValue
                updated.metricLabel = newCase.metricLabel
                updated.metricDescription = newCase.metricDescription
                updated.title = newCase.title
                updated.detail = newCase.detail
                updated.lastEvaluatedAt = newCase.lastEvaluatedAt

                let preservedLifecycle: DecisionCaseLifecycle = oldCase.userDisposition == .acknowledged
                    ? (oldCase.lifecycle == .reviewDue ? .reviewDue : .monitoring)
                    : .decisionReady
                if oldCase.decisionState != newCase.decisionState {
                    updated.applyTransition(
                        to: preservedLifecycle,
                        decisionState: newCase.decisionState,
                        at: timestamp,
                        type: .reassessed,
                        reason: "指标更新：\(oldCase.metricLabel) → \(newCase.metricLabel)",
                        actor: .system
                    )
                    if updated.userDisposition == .acknowledged {
                        updated.reviewDueAt = DecisionCase.computeReviewDueAt(
                            decisionState: newCase.decisionState,
                            from: timestamp
                        )
                    }
                } else {
                    updated.lifecycle = preservedLifecycle
                    updated.updatedAt = timestamp
                }
                merged.append(updated)
            } else {
                // 新 Case
                merged.append(newCase)
            }
        }

        // 2. 保留不再出现的旧 Case(不删除,保留历史)。
        // resolved/closed 的 Case 也保留(进历史,不丢弃)——修复缺陷:旧代码只保留 acknowledged/pending。
        for oldCase in existing where !consumedKeys.contains(oldCase.caseKey) {
            if oldCase.userDisposition == .closed || oldCase.lifecycle == .closed {
                // 已关闭的 Case 原样保留(不更新状态,只是不丢弃)
                merged.append(oldCase)
            } else if oldCase.userDisposition == .resolved {
                merged.append(oldCase)
            } else {
                // 风险已回到阈值内，系统关闭事项并保留完整历史。
                var stale = oldCase
                stale.applyTransition(
                    to: .closed,
                    decisionState: .stable,
                    at: timestamp,
                    type: .reassessed,
                    reason: "风险指标已回到阈值内，事项自动结束",
                    actor: .system
                )
                stale.userDisposition = .resolved
                stale.resolvedAt = timestamp
                stale.reviewDueAt = nil
                merged.append(stale)
            }
        }

        return merged
    }

    // MARK: - 用户操作

    /// 用户确认关注某个 Case（进入 monitoring，并设置明确复查时间）。
    func acknowledgeDecisionCase(_ id: UUID) {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        let now = Self.timestampString()
        let state = decisionCases[index].decisionState
        decisionCases[index].applyTransition(
            to: .monitoring,
            decisionState: state,
            at: now,
            type: .userAcknowledged,
            reason: "用户确认关注",
            actor: .user
        )
        decisionCases[index].userDisposition = .acknowledged
        // 设显式复查时间(Schema V2:不用 updatedAt 算)
        decisionCases[index].reviewDueAt = DecisionCase.computeReviewDueAt(
            decisionState: state, from: now
        )
        persistDecisionCases()
    }

    /// 用户标记 Case 已解决。
    func resolveDecisionCase(_ id: UUID, note: String = "") {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        let now = Self.timestampString()
        decisionCases[index].applyTransition(
            to: .closed,
            decisionState: .stable,
            at: now,
            type: .userResolved,
            reason: note.isEmpty ? "用户标记已解决" : note,
            actor: .user
        )
        decisionCases[index].userDisposition = .resolved
        decisionCases[index].resolvedAt = now
        decisionCases[index].reviewDueAt = nil
        persistDecisionCases()
    }

    /// 用户关闭 Case(不再关注)。
    func closeDecisionCase(_ id: UUID) {
        guard let index = decisionCases.firstIndex(where: { $0.id == id }) else { return }
        let now = Self.timestampString()
        decisionCases[index].applyTransition(
            to: .closed,
            decisionState: decisionCases[index].decisionState,
            at: now,
            type: .userClosed,
            reason: "用户关闭",
            actor: .user
        )
        decisionCases[index].userDisposition = .closed
        decisionCases[index].resolvedAt = now
        decisionCases[index].reviewDueAt = nil
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
