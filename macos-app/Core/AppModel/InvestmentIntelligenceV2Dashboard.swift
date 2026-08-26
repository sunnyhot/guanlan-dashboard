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
}
