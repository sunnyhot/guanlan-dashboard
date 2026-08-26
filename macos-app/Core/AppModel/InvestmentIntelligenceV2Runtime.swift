import Foundation
import GRDB

// MARK: - Investment Intelligence V2 生产运行时（composition root，十六轮审查 P1-1）
//
// App 启动时引导（bootstrap）：打开 canonical.sqlite3 → GRDBRepository →
// ArtifactQueryService。动作面：市场发现（WF2，纯本地）/ 盘中执行决策
// （WF3，纯本地）/ 组合研究（WF1，需 LLM 配置——baseURL/model 走
// UserDefaults，apiKey 走 Keychain，与旧链路同一 account 复用既有凭据）。
//
// 决策材料（真实供给）：从 personalAssetRows 构造 PortfolioSnapshot，
// AllocationTarget = 当前资产类聚合权重（「维持当前配置」的再平衡对照——
// 偏差超容忍带才产动作，用户无显式目标配置时不发明目标，D000 语义）。

// MARK: - V2 LLM Provider 配置（防密钥落盘拆分：非凭据 UserDefaults / 凭据 Keychain）

enum IntelligenceV2ProviderSettings {
    static let baseURLKey = "qieman.v2.llm.baseURL"
    static let modelKey = "qieman.v2.llm.model"
    static let alphaVantageEnabledKey = "qieman.v2.av.enabled"

    /// Keychain 读写注入（默认真实 KeychainHelper；测试替换内存实现——
    /// 单测进程的 Keychain 权限不可靠,十七轮测试稳定性）。
    static var keychainReader: @Sendable (String) -> String? =
        { KeychainHelper.get(account: $0) }
    static var keychainWriter: @Sendable (String, String) -> Void =
        { KeychainHelper.set($1, account: $0) }
    static var keychainDeleter: @Sendable (String) -> Void =
        { _ = KeychainHelper.delete(account: $0) }

    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    static var apiKey: String {
        keychainReader(KeychainHelper.Account.openAIKey) ?? ""
    }

    static var isConfigured: Bool {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedBase.isEmpty && !trimmedModel.isEmpty && !apiKey.isEmpty
    }

    /// V2 Provider 配置（未配置时 nil——WF1 的 LLM 动作在配置前禁用）。
    static func providerConfiguration() -> LLMProviderConfiguration? {
        guard isConfigured else { return nil }
        return LLMProviderConfiguration(
            providerID: "primary",
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
    }

    static func save(baseURL: String, model: String, apiKey: String) {
        let defaults = UserDefaults.standard
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: modelKey)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            // 留空 = 保留 Keychain 既有 Key（改 baseURL 不重输 Key 不停摆,
            // 十七轮 P1-2）;显式清除走 deleteAPIKey()
            return
        }
        keychainWriter(KeychainHelper.Account.openAIKey, trimmedKey)
    }

    /// 显式清除已保存的 API Key（Keychain）。
    static func deleteAPIKey() {
        keychainDeleter(KeychainHelper.Account.openAIKey)
    }
}

// MARK: - 真实决策材料供给（WF1 / WF3 共用）

/// 从 App 持仓行构造 V2 决策输入（PortfolioSnapshot + 「维持当前配置」
/// 对照 target + costIntensity criterion + 单 plannerRun）。
struct LivePortfolioDecisionMaterials: PortfolioDecisionMaterialsProviding {
    let rows: [PersonalAssetAggregateRow]
    let now: Date

    private func dec(_ double: Double) -> Decimal {
        // locale 无关（String(format:) 的 %f 随 locale 出逗号）;金额精度
        // 到分位足够构造权重比例
        Decimal((double * 10_000).rounded() / 10_000)
    }

    /// 持仓 → V2 positions（subjectKey 与 AttributionSubject.stableKey 同域）。
    /// 权重归一（十七轮 P0-1 根治）：残差 (1 − Σothers) 归入最大仓——
    /// Decimal 除法对非终尽小数（1/3 等）的权和 ≠ 1,下游 target 校验
    /// 精确比对 1,不归一必然被拒。
    private var positions: [PortfolioPosition] {
        let amounts = rows.compactMap { row -> (code: String, amount: Decimal, assetClass: AssetClass)? in
            guard row.effectiveHoldingAmount > 0, let code = row.fundCode,
                  !code.isEmpty else { return nil }
            // 资产类映射（十七轮 P2 已知限制）：股票 → equity；基金内部
            // 细分（债/货/黄金）需穿透数据，当前统一 alternative——精确
            // 分类属后续 FundLookThrough 接线
            return (
                code, dec(row.effectiveHoldingAmount),
                row.assetType == .stock ? .equity : .alternative
            )
        }
        let total = amounts.map(\.amount).reduce(Decimal.zero, +)
        guard total > 0 else { return [] }
        var normalized = amounts.map {
            (code: $0.code, assetClass: $0.assetClass, weight: $0.amount / total)
        }
        // 残差归最大仓（和恒精确 = 1）
        let largestIndex = normalized.indices.max(by: {
            normalized[$0].weight == normalized[$1].weight
                ? normalized[$0].code < normalized[$1].code
                : normalized[$0].weight < normalized[$1].weight
        })
        if let largestIndex {
            let othersSum = normalized.enumerated()
                .filter { $0.offset != largestIndex }
                .reduce(Decimal.zero) { $0 + $1.element.weight }
            normalized[largestIndex].weight = Decimal(1) - othersSum
        }
        return normalized.map {
            PortfolioPosition(
                subjectKey: "fund|\($0.code)",
                assetClass: $0.assetClass,
                weight: Ratio(value: $0.weight)
            )
        }
    }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let snapshotPositions = positions
        guard !snapshotPositions.isEmpty else {
            throw LiveMaterialsError.emptyPortfolio
        }
        let portfolio = PortfolioSnapshot(asOf: asOf, positions: snapshotPositions)

        // 「维持当前配置」对照 target：资产类聚合权重归一化（用户显式
        // 目标配置入口属后续 UI story——无显式目标时不发明目标，对照
        // 现状只检查漂移；带内不交易）。
        // 归一化（十七轮 P0-1）：Decimal 除法对非终尽小数（如 1/3）的
        // 权重和 ≠ 1，StrategicAllocationValidator 精确校验会拒——把
        // 残差 (1 − Σothers) 归入权重最大的类，entries 权重和恒精确 = 1。
        var classTotals: [AssetClass: Decimal] = [:]
        for position in snapshotPositions {
            classTotals[position.assetClass, default: 0] += position.weight.value
        }
        guard let largestClass = classTotals.max(by: {
            $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value < $1.value
        })?.key else {
            throw LiveMaterialsError.emptyPortfolio
        }
        let othersSum = classTotals
            .filter { $0.key != largestClass }
            .values.reduce(Decimal.zero, +)
        classTotals[largestClass] = Decimal(1) - othersSum
        let entries = classTotals
            .map { AllocationTargetEntry(assetClass: $0.key, targetWeight: Ratio(value: $0.value)) }
            .sorted { $0.assetClass.rawValue < $1.assetClass.rawValue }
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: entries, note: "维持当前配置（对照检查漂移）", now: asOf
        )

        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio, higherIsBetter: false
        )
        let bounds = Dictionary(
            uniqueKeysWithValues: snapshotPositions.map {
                ($0.subjectKey, ActionDomain.SubjectBounds(
                    lower: Ratio(value: Decimal(string: "-1")!), upper: Ratio(value: Decimal(string: "1")!)))
            }
        )
        let actionDomain = ActionDomain(
            perSubjectBounds: bounds,
            eligibleNewSubjects: [:],
            builderVersion: "live-v1",
            newSubjectBuyUpper: Ratio(value: Decimal(string: "1")!)
        )
        let plannerRun = DecisionReplayer.PlannerRun(
            portfolio: portfolio, target: target, remediationTargets: [],
            userDirectives: [], actionDomain: actionDomain,
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
        return PortfolioDecisionMaterials(
            replayerMaterials: DecisionReplayer.ReplayMaterials(
                criterionDefinitions: [definition.fingerprint: definition],
                factorSnapshots: [:], observations: [:],
                band: IndifferenceBand(
                    policyID: "live-band", version: "v1",
                    defaultBand: Decimal(string: "0.01")!,
                    rationale: "生产默认带——turnover 差 1% 内视为无差异"
                )
            ),
            plannerRuns: ["current": plannerRun],
            target: target,
            knowledgeContextSummary: "economicKnowledge(自 \(now))· live materials"
        )
    }

    enum LiveMaterialsError: Error, Equatable, Sendable {
        case emptyPortfolio
    }
}

// MARK: - 旧 AI 数据迁移（WF-5「清空重来并明确告知」，十六轮审查 P1-6）

enum LegacyAIDataMigration {
    struct Outcome: Sendable, Equatable {
        /// 已移入备份目录的旧文件名
        let archivedFiles: [String]
        /// 用户通知文案（nil = 无需迁移）
        let notice: String?
    }

    static let markerFileName = "legacy-ai-migration.json"
    static let backupDirectoryName = "legacy-ai-backup"
    static let legacyFileNames = [
        "trend-analysis-report.json",
        "trend-analysis-settings.json",
        "trend-tracking-items.json",
        "next-hour-guidance.json",
        "market-close-review.json",
        "decision-cases.json",
        "decision-case-journal.json",
        "trend-agent.log",
    ]

    /// 一次性迁移：旧 AI 数据文件存在且无标记 → 移入备份目录（不删除，
    /// 可审计可找回）→ 写标记 → 返回告知文案。重复调用幂等。
    static func migrateIfNeeded(in dataDirectory: URL) -> Outcome {
        let fm = FileManager.default
        let markerURL = dataDirectory.appendingPathComponent(markerFileName)
        guard !fm.fileExists(atPath: markerURL.path) else {
            return Outcome(archivedFiles: [], notice: nil)
        }
        // 标记先行写入（即使本轮没有旧文件也落标记——版本升级只告知一次）
        let payload: [String: String] = [
            "migratedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) {
            try? data.write(to: markerURL, options: .atomic)
        }

        let present = legacyFileNames.filter {
            fm.fileExists(atPath: dataDirectory.appendingPathComponent($0).path)
        }
        guard !present.isEmpty else {
            return Outcome(archivedFiles: [], notice: nil)
        }
        let backupDir = dataDirectory.appendingPathComponent(
            backupDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var moved: [String] = []
        for name in present {
            let src = dataDirectory.appendingPathComponent(name)
            let dst = backupDir.appendingPathComponent(name)
            do {
                try fm.moveItem(at: src, to: dst)
                moved.append(name)
            } catch {
                // 移动失败保留原文件（不再消费,无副作用）——不阻断启动
                continue
            }
        }
        guard !moved.isEmpty else {
            return Outcome(archivedFiles: [], notice: nil)
        }
        let notice = """
        旧版「AI 趋势研判」功能已下线。检测到 \(moved.count) 个旧数据文件，\
        已移入数据目录的 \(backupDirectoryName)/ 备份保留（App 不再读取）。\
        新一代投资智能（研究 / 发现 / 盘中决策）请使用「投资智能」板块。
        """
        return Outcome(archivedFiles: moved, notice: notice)
    }
}

// MARK: - AppModel 集成

extension AppModel {

    /// V2 运行时句柄（start() 引导；打开失败时 nil + 错误提示，不阻断 App）。
    struct IntelligenceV2Runtime: Sendable {
        let repository: GRDBRepository
        let queryService: ArtifactQueryService
    }

    /// 引导 V2 运行时（十八轮 P2：开库含迁移，移出主线程——原先 start()
    /// 内同步执行会卡启动）。
    func bootstrapIntelligenceV2() {
        guard intelligenceRuntime == nil, !isBootstrappingIntelligence else { return }
        guard let dataDirectory = dataDirectoryURL else { return }
        isBootstrappingIntelligence = true
        // 诊断日志挂载（十七轮 P2：record 默认 no-op,生产需显式挂文件
        #if canImport(AppKit) || canImport(UIKit)
        Task.detached(priority: .utility) {
            let logsDirectory = dataDirectory.appendingPathComponent(
                "ai-analysis-logs", isDirectory: true)
            if let recorder = try? await AIAgentDiagnosticRecorder(
                directoryURL: logsDirectory,
                metadata: AIAgentDiagnosticRunMetadata(
                    runID: UUID(), agentKind: "app-runtime", scope: "bootstrap",
                    trigger: "launch", providerName: "-", baseURL: "-", model: "-",
                    privacyMode: "sanitized",
                    startedAt: Self.timestampString()
                )
            ) {
                AIAgentDiagnosticLog.setDefaultRecorder(recorder)
            }
        }
        #endif
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let database = try CanonicalStorePaths.openDatabase(in: dataDirectory)
                let repository = GRDBRepository(
                    database: database,
                    calendarBackend: HolidayTableTradingCalendar.bundled
                )
                let runtime = IntelligenceV2Runtime(
                    repository: repository,
                    queryService: ArtifactQueryService(repository: repository)
                )
                await MainActor.run { [weak self] in
                    self?.intelligenceRuntime = runtime
                    self?.isBootstrappingIntelligence = false
                    self?.restoreLatestIntelligenceArtifacts(runtime: runtime)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isBootstrappingIntelligence = false
                    self?.latestIntelligenceError =
                        "投资智能数据目录初始化失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 重启恢复（十八轮 P2-5）：UI 消费的是 AppModel 内存态，重启后库里有
    /// artifact 但板块空白——启动时经 ArtifactQueryService 统一读面把最新
    /// 产物灌回 published 状态。只补空位，不覆盖本会话新产出。
    @MainActor
    func restoreLatestIntelligenceArtifacts(runtime: IntelligenceV2Runtime) {
        if latestDiscoveryReport == nil,
           let report = try? runtime.queryService.latestMarketDiscoveryReports(limit: 1).first {
            latestDiscoveryReport = report
        }
        if latestIntradayReport == nil,
           let report = try? runtime.queryService.latestIntradayReports(
               limit: 1, includeInvalid: true
           ).first {
            latestIntradayReport = report
        }
        if latestResearchArtifactID == nil {
            let summary = (try? runtime.queryService.latestPortfolioDecisions(limit: 1))?.first
            latestResearchArtifactID = summary?.artifactID
            latestPortfolioDecisionSummary = summary
        }
    }

    // MARK: - WF2 市场发现（纯本地因子；数据供给经维护引擎先行）

    @MainActor
    func runMarketDiscovery() {
        guard let runtime = intelligenceRuntime else {
            latestIntelligenceError = "投资智能运行时未就绪"
            return
        }
        guard !isRunningMarketDiscovery else { return }
        isRunningMarketDiscovery = true
        latestIntelligenceError = nil
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningMarketDiscovery = false } }
            do {
                // 数据维护先行（十八轮 P1-1；十九轮 P3-1 起经串行门与 6h
                // 循环互斥）：identity 建立 → universe 回填（首轮冷库多批次
                // 推进）→ 收盘增量 + remote spool 提交。维护失败不阻断扫描
                // ——降级为 coverage gap（DATA006 local 兜底），摘要记入诊断面
                await self?.runSerializedMarketDataMaintenance(backfillRounds: 3)

                // identity 建立兜底（幂等；维护引擎已建过，引擎整体失败时
                // 保证 discovery 自身的 factor 读取与后续提交可用）
                try MarketDataMaintenanceEngine.establishUniverseIdentity(
                    repository: runtime.repository
                )

                // 因子快照批量缓冲（原逐条目一个写事务 → 整轮单事务，
                // 十八轮 P2；含 coverage-gap 条目——失效传播不留盲区）
                let snapshotBuffer = FactorSnapshotBuffer()
                let workflow = MarketDiscoveryWorkflow(
                    repository: runtime.repository,
                    snapshotSink: { snapshot in
                        snapshotBuffer.append(snapshot)
                    }
                )
                let outcome = workflow.run(asOf: now, now: now)
                let snapshots = snapshotBuffer.drain()
                if !snapshots.isEmpty {
                    try await runtime.repository.database.queue.write { db in
                        for snapshot in snapshots {
                            try ArtifactRow.write(try ArtifactRow.from(snapshot), into: db)
                        }
                    }
                }
                guard let report = outcome.report else {
                    throw NSError(domain: "intelligence", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                            outcome.errorDetail ?? "发现运行失败"])
                }
                try runtime.repository.writeMarketDiscoveryReport(report)
                await MainActor.run { self?.latestDiscoveryReport = report }
            } catch {
                await MainActor.run {
                    self?.latestIntelligenceError = "市场发现失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - WF3 盘中执行决策（纯本地，无 LLM 依赖）

    @MainActor
    func runIntradayDecision() {
        guard let runtime = intelligenceRuntime else {
            latestIntelligenceError = "投资智能运行时未就绪"
            return
        }
        guard !isRunningIntradayDecision else { return }
        isRunningIntradayDecision = true
        latestIntelligenceError = nil
        let rows = personalAssetRows
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningIntradayDecision = false } }
            do {
                let subject = CanonicalRef.fundShareClass(FundShareClassID(rawValue: "portfolio_live"))
                let materials = LivePortfolioDecisionMaterials(rows: rows, now: now)
                let providerMaterials = try materials.materials(asOf: now)
                guard let plannerRun = providerMaterials.plannerRuns["current"] else {
                    throw NSError(domain: "intelligence", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "决策材料缺规划输入"])
                }
                let input = IntradayWorkflow.Input(
                    subject: subject,
                    portfolio: plannerRun.portfolio,
                    target: providerMaterials.target,
                    actionDomain: plannerRun.actionDomain,
                    exchange: .otc,   // 组合以场外基金为主——T 日任意时刻可执行
                    tradingJurisdiction: .chinaMainland   // 申赎日历按 A 股（十七轮 P0-2）
                )
                let workflow = IntradayWorkflow(
                    signalStore: runtime.repository,
                    calendar: HolidayTableTradingCalendar.bundled
                )
                let outcome = workflow.run(input: input, asOf: now, now: now)
                guard let report = outcome.report else {
                    throw NSError(domain: "intelligence", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                            outcome.errorDetail ?? "盘中决策失败"])
                }
                try await runtime.repository.database.queue.write { db in
                    try ArtifactRow.write(
                        try ArtifactRow.from(report), into: db)
                }
                await MainActor.run { self?.latestIntradayReport = report }
            } catch {
                await MainActor.run {
                    self?.latestIntelligenceError = "盘中决策失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - WF1 组合研究（需 LLM 配置）

    @MainActor
    var intelligenceV2ProviderConfigured: Bool {
        IntelligenceV2ProviderSettings.isConfigured
    }

    @MainActor
    func runPortfolioResearch() {
        guard let runtime = intelligenceRuntime else {
            latestIntelligenceError = "投资智能运行时未就绪"
            return
        }
        guard let configuration = IntelligenceV2ProviderSettings.providerConfiguration()
        else {
            latestIntelligenceError = "尚未配置 AI 模型（投资智能板块内填写 baseURL / 模型 / API Key）"
            return
        }
        guard !isRunningPortfolioResearch else { return }
        isRunningPortfolioResearch = true
        latestIntelligenceError = nil
        let rows = personalAssetRows
        let now = Date()
        // 选择性研究接线（十八轮 P2-4）：市场发现 top-K 候选 → assetTasks，
        // LLM / Tavily 只花在本地因子筛出的标的上（AGENTS.md 的 Epic 12
        // 语义——「本地因子先筛 + 选择性研究」的研究侧闭环）。limit 4 是
        // 单次点击的 LLM 预算上限；top-K 8 全量留给批处理场景
        let discoveryAssetTasks = latestDiscoveryReport?.researchTasks(limit: 4) ?? []
        let provider = OpenAICompatibleModelProvider(configuration: configuration)
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 1
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningPortfolioResearch = false } }
            do {
                let subject = CanonicalRef.fundShareClass(FundShareClassID(rawValue: "portfolio_live"))
                let harness = ResearchHarness(
                    gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
                    tools: ResearchToolRegistry().tools,
                    sources: ResearchSourcesConfiguration(
                        tavilyAPIKey:
                            KeychainHelper.get(account: KeychainHelper.Account.tavilyKey) ?? "",
                        alphaVantageEnabled: true,
                        alphaVantageAPIKey:
                            KeychainHelper.get(account: KeychainHelper.Account.alphaVantageKey) ?? ""
                    ),
                    dataAccess: RepositoryResearchDataAccess(
                        nav: runtime.repository, market: runtime.repository
                    )
                )
                let workflow = PortfolioResearchWorkflow(
                    dependencies: PortfolioResearchWorkflow.Dependencies(
                        harness: harness,
                        signalStore: runtime.repository,
                        thesisStore: runtime.repository,
                        evidenceStore: runtime.repository,
                        decisionMaterials: LivePortfolioDecisionMaterials(rows: rows, now: now),
                        artifactSink: { artifact in
                            try runtime.repository.writeArtifact(artifact)
                        }
                    )
                )
                let input = PortfolioResearchWorkflow.Input(
                    portfolioSubject: subject,
                    assetTasks: discoveryAssetTasks,
                    portfolioTask: ResearchTask(
                        subject: subject,
                        objective: "评估组合当前配置的动量、估值与主要风险"
                    )
                )
                let outcome = try await workflow.run(input: input)
                await MainActor.run {
                    if outcome.succeeded {
                        self?.latestResearchArtifactID = outcome.artifact?.id.rawValue
                        // 概要统一读面刷新（十八轮 P2-5：View body 不查库）
                        let summary = (try? runtime.queryService.latestPortfolioDecisions(limit: 1))?.first
                        self?.latestPortfolioDecisionSummary = summary
                    } else {
                        self?.latestIntelligenceError =
                            "组合研究失败：\(outcome.errorDetail ?? "unknown")"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.latestIntelligenceError = "组合研究失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
