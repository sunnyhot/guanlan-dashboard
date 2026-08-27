import Foundation

// MARK: - 投资智能 V2 Dashboard 状态（产品重构方案 §5.3）
//
// 把 V2 UI 状态从 AppModel.swift 的零散字段收拢到本文件：
// - 页面数据 = IntelligenceDashboardLoadState（快照整体加载，View 不拼状态）
// - 动作执行 = 三个独立 IntelligenceOperationState（发现 / 盘中 / 研究），
//   不共用一个模糊错误串
// - workflow 成功后统一 refreshIntelligenceDashboard()，不手工更新多个
//   Published 字段造成状态撕裂
// - 原始错误写诊断日志；UI 只显示映射后的 IntelligenceUserFacingError

extension AppModel {

    /// 主页面快照加载状态。
    enum IntelligenceDashboardLoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded(InvestmentIntelligenceDashboardSnapshot)
        case failed(IntelligenceUserFacingError)
    }

    /// 单个 workflow 的执行状态。
    enum IntelligenceOperationState: Equatable, Sendable {
        case idle
        case running(startedAt: Date, stage: Stage)
        case failed(IntelligenceUserFacingError)

        enum Stage: String, Sendable {
            case preparing       // 数据维护 / 材料装配
            case collecting      // 证据收集（研究）
            case synthesizing    // 论点 / 信号合成
            case evaluating      // 评估 / 决策
            case persisting      // 落库
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    // MARK: - 快照装配（MainActor 捕获 → 后台查询 → MainActor 发布）

    /// 刷新主页面快照（bootstrap 完成后自动调用；workflow 成功后统一调用；
    /// 页面重进轻量刷新——只读库不消耗 LLM 配额）。
    @MainActor
    func refreshIntelligenceDashboard() {
        guard let runtime = intelligenceRuntime else { return }
        guard dataDirectoryURL != nil else { return }
        // 已在加载中不重复提交
        if case .loading = intelligenceDashboard { return }
        if case .idle = intelligenceDashboard {
            intelligenceDashboard = .loading
        }
        let rows = personalAssetRows
        let disclosures = portfolioLookThroughSnapshot?.disclosures ?? [:]
        let providerConfigured = IntelligenceV2ProviderSettings.isConfigured
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 用户意图材料（文件事实源 + 分类解析）——DB 外输入在 App 侧装配
                let target = try runtime.targetStore.currentTarget()
                let resolvableIDs = try runtime.targetStore.resolvableTargetIDs()
                let assignments = try runtime.assignmentStore.currentAssignments()
                let resolved = StrategicAssetClassificationResolver.resolve(
                    rows: rows, assignments: assignments,
                    disclosures: disclosures, now: now)

                // 分类 / 估值阻断信息（快照仍生成——readiness 呈现，不整体失败）
                var classWeights: [AssetClass: Decimal]?
                var staleAsOf: Date?
                if resolved.unresolvedSubjectKeys.isEmpty {
                    do {
                        let build = try LivePortfolioSnapshotBuilder.build(
                            rows: rows, classification: resolved.classification, asOf: now)
                        classWeights = build.currentClassWeights
                    } catch let error as LivePortfolioSnapshotBuilder.BuildError {
                        if case let .staleValuation(latest) = error {
                            staleAsOf = latest
                        }
                        classWeights = nil
                    } catch {
                        classWeights = nil
                    }
                }

                let materials = IntelligenceDashboardUserMaterials(
                    currentTarget: target,
                    resolvableTargetIDs: resolvableIDs,
                    currentClassWeights: classWeights,
                    unresolvedSubjects: resolved.unresolvedSubjectKeys,
                    valuationStaleAsOf: staleAsOf,
                    providerConfigured: providerConfigured)
                let snapshot = try runtime.queryService.dashboardSnapshot(
                    userMaterials: materials, now: now)
                await MainActor.run {
                    self?.intelligenceDashboard = .loaded(snapshot)
                }
            } catch {
                await MainActor.run {
                    self?.intelligenceDashboard = .failed(
                        IntelligenceUserFacingError.from(error))
                }
            }
        }
    }

    // MARK: - 状态便捷派生（View 消费面）

    /// 当前快照（nil = 未加载完成）。
    @MainActor
    var intelligenceDashboardSnapshot: InvestmentIntelligenceDashboardSnapshot? {
        if case let .loaded(snapshot) = intelligenceDashboard { return snapshot }
        return nil
    }

    /// 主页面是否可运行盘中决策（readiness 无阻断 + 运行时就绪）。
    @MainActor
    var intelligenceIntradayReady: Bool {
        guard intelligenceRuntime != nil else { return false }
        guard let snapshot = intelligenceDashboardSnapshot else { return false }
        return snapshot.readiness.blocker == nil
    }

    // MARK: - 证据明细加载（审计 A6：UI 逐条证据查看）

    /// 按证据 ID 加载证据摘要（失败回空数组——读面降级，不弹错误）。
    @MainActor
    func loadResearchEvidence(evidenceIDs: [String]) async -> [ResearchEvidenceDigest] {
        guard let runtime = intelligenceRuntime else { return [] }
        return (try? runtime.queryService.researchEvidence(evidenceIDs: evidenceIDs)) ?? []
    }

    // MARK: - 用户意图写入（编辑器入口；D000——Target 永远只从用户动作产生）

    /// 请求跳转到设置中心的指定分区（跨板块深链；Settings View 消费后清空）。
    @MainActor
    func requestSettingsSection(_ section: AppSettingsSection) {
        pendingSettingsSection = section
        selectedSection = .settings
        revealMainWindowIfNeeded()
    }

    /// 保存战略目标（编辑器提交）。五类权重经 Policy 构造 + Store 落盘；
    /// 校验失败返回可展示错误（编辑器 inline 提示，不弹窗）。
    @MainActor
    @discardableResult
    func saveStrategicAllocationTarget(
        weights: [AssetClass: Decimal], changeReason: String?
    ) -> Result<Void, IntelligenceUserFacingError> {
        guard let runtime = intelligenceRuntime else {
            return .failure(IntelligenceUserFacingError(
                title: "运行时未就绪",
                message: "投资智能运行时尚未初始化完成，请稍后重试。",
                recovery: .retry,
                diagnosticCode: "INTL-RUNTIME-NOT-READY"))
        }
        let entries = AssetClass.allCases.map { assetClass in
            AllocationTargetEntry(
                assetClass: assetClass,
                targetWeight: Ratio(value: weights[assetClass] ?? .zero))
        }
        do {
            let now = Date()
            let target = try StrategicAllocationPolicy().applyUserAllocation(
                entries: entries, note: changeReason, now: now)
            let supersedes = try runtime.targetStore.loadCurrentEvent()?
                .target.id.rawValue
            try runtime.targetStore.record(
                target: target, supersedesTargetID: supersedes,
                changeReason: changeReason, now: now)
            refreshIntelligenceDashboard()
            return .success(())
        } catch let error as StrategicAllocationValidator.ValidationError {
            return .failure(IntelligenceUserFacingError(
                title: "目标配置无效",
                message: Self.validationMessage(error),
                recovery: .configureTarget,
                diagnosticCode: "INTL-TARGET-INVALID"))
        } catch {
            return .failure(IntelligenceUserFacingError.runtimeFailure(error))
        }
    }

    /// 保存单个持仓的用户分类（编辑器提交；用户事件不被系统识别覆盖）。
    @MainActor
    @discardableResult
    func saveAssetClassAssignment(
        subjectKey: String, assetClass: AssetClass
    ) -> Result<Void, IntelligenceUserFacingError> {
        guard let runtime = intelligenceRuntime else {
            return .failure(IntelligenceUserFacingError(
                title: "运行时未就绪",
                message: "投资智能运行时尚未初始化完成，请稍后重试。",
                recovery: .retry,
                diagnosticCode: "INTL-RUNTIME-NOT-READY"))
        }
        do {
            let assignment = StrategicAssetClassAssignmentStore.makeAssignment(
                subjectKey: subjectKey, assetClass: assetClass,
                source: .user, recordedAt: Date())
            try runtime.assignmentStore.record(assignment)
            refreshIntelligenceDashboard()
            return .success(())
        } catch {
            return .failure(IntelligenceUserFacingError.runtimeFailure(error))
        }
    }

    private static func validationMessage(
        _ error: StrategicAllocationValidator.ValidationError
    ) -> String {
        switch error {
        case .emptyEntries:
            return "至少需要一类资产配置。"
        case .negativeWeight:
            return "目标占比不能为负数。"
        case .duplicateAssetClass:
            return "同一资产类出现了多次。"
        case .weightsDoNotSumToOne(let sum):
            let percent = (sum * 100).rounded(toScale: 1)
            return "五类占比之和需恰好 100%（当前 \(percent)%）。"
        case .missingAssetClasses(let missing):
            let names = missing.map(IntelligencePresentationFormatter.assetClassName)
                .joined(separator: "、")
            return "缺少资产类：\(names)（权重可以为 0，但不能缺类）。"
        }
    }
}
