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

    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    static var apiKey: String {
        KeychainHelper.get(account: KeychainHelper.Account.openAIKey) ?? ""
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
        if trimmedKey.isEmpty {
            KeychainHelper.delete(account: KeychainHelper.Account.openAIKey)
        } else {
            KeychainHelper.set(trimmedKey, account: KeychainHelper.Account.openAIKey)
        }
        UserDefaults.standard.set(trimmedKey, forKey: "qieman.trend.openai.key")
    }
}

// MARK: - 真实决策材料供给（WF1 / WF3 共用）

/// 从 App 持仓行构造 V2 决策输入（PortfolioSnapshot + 「维持当前配置」
/// 对照 target + costIntensity criterion + 单 plannerRun）。
struct LivePortfolioDecisionMaterials: PortfolioDecisionMaterialsProviding {
    let rows: [PersonalAssetAggregateRow]
    let now: Date

    private func d(_ value: Decimal) -> Decimal { value }
    private func dec(_ double: Double) -> Decimal { Decimal(string: String(format: "%.6f", double)) ?? Decimal.zero }

    /// 持仓 → V2 positions（subjectKey 与 AttributionSubject.stableKey 同域）。
    private var positions: [PortfolioPosition] {
        let total = rows.reduce(Decimal.zero) {
            $0 + dec($1.effectiveHoldingAmount)
        }
        guard total > 0 else { return [] }
        return rows.compactMap { row -> PortfolioPosition? in
            guard row.effectiveHoldingAmount > 0, let code = row.fundCode,
                  !code.isEmpty else { return nil }
            return PortfolioPosition(
                subjectKey: "fund|\(code)",
                assetClass: row.assetType == .stock ? .equity : .alternative,
                weight: Ratio(value: dec(row.effectiveHoldingAmount) / total)
            )
        }
    }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let snapshotPositions = positions
        guard !snapshotPositions.isEmpty else {
            throw LiveMaterialsError.emptyPortfolio
        }
        let portfolio = PortfolioSnapshot(asOf: now, positions: snapshotPositions)

        // 「维持当前配置」对照 target：资产类聚合权重归一化（用户显式
        // 目标配置入口属后续 UI story——无显式目标时不发明目标，对照
        // 现状只检查漂移；带内不交易）。
        var classTotals: [AssetClass: Decimal] = [:]
        for position in snapshotPositions {
            classTotals[position.assetClass, default: 0] += position.weight.value
        }
        let entries = classTotals
            .map { AllocationTargetEntry(assetClass: $0.key, targetWeight: Ratio(value: $0.value)) }
            .sorted { $0.assetClass.rawValue < $1.assetClass.rawValue }
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: entries, note: "维持当前配置（对照检查漂移）", now: now
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

    func bootstrapIntelligenceV2() {
        guard intelligenceRuntime == nil else { return }
        guard let dataDirectory = dataDirectoryURL else { return }
        do {
            let database = try CanonicalStorePaths.openDatabase(in: dataDirectory)
            let repository = GRDBRepository(
                database: database,
                calendarBackend: HolidayTableTradingCalendar.bundled
            )
            intelligenceRuntime = IntelligenceV2Runtime(
                repository: repository,
                queryService: ArtifactQueryService(repository: repository)
            )
        } catch {
            latestIntelligenceError = "投资智能数据目录初始化失败：\(error.localizedDescription)"
        }
    }

    // MARK: - WF2 市场发现（纯本地，无 LLM 依赖）

    @MainActor
    func runMarketDiscovery() {
        guard let runtime = intelligenceRuntime else {
            latestIntelligenceError = "投资智能运行时未就绪"
            return
        }
        guard !isRunningMarketDiscovery else { return }
        isRunningMarketDiscovery = true
        latestIntelligenceError = nil
        let rows = personalAssetRows
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningMarketDiscovery = false } }
            do {
                // identity 建立（universe 条目 → providerCode→canonical 映射）
                let sync = IdentitySync(repository: runtime.repository)
                _ = try sync.establish(
                    hints: MarketUniverseCatalog.v1.entries.map(\.identityHint)
                )
                let workflow = MarketDiscoveryWorkflow(
                    repository: runtime.repository,
                    snapshotSink: { snapshot in
                        try runtime.repository.database.queue.write { db in
                            try ArtifactRow.write(
                                try ArtifactRow.from(snapshot), into: db)
                        }
                    }
                )
                let outcome = workflow.run(asOf: now, now: now)
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
                let subject = try! CanonicalRef(
                    entityType: "fundShareClass",
                    entityIDRawValue: "portfolio_live"
                )
                let materials = LivePortfolioDecisionMaterials(rows: rows, now: now)
                let providerMaterials = try materials.materials(asOf: now)
                let bounds = providerMaterials.plannerRuns["current"]!.actionDomain
                let input = IntradayWorkflow.Input(
                    subject: subject,
                    portfolio: providerMaterials.plannerRuns["current"]!.portfolio,
                    target: providerMaterials.target,
                    actionDomain: bounds,
                    exchange: .otc   // 组合以场外基金为主——T 日任意时刻可执行
                )
                let signals = try runtime.repository.signals(subject: subject)
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
        let provider = OpenAICompatibleModelProvider(configuration: configuration)
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 1
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { Task { @MainActor in self?.isRunningPortfolioResearch = false } }
            do {
                let subject = try! CanonicalRef(
                    entityType: "fundShareClass", entityIDRawValue: "portfolio_live"
                )
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
                    assetTasks: [],
                    portfolioTask: ResearchTask(
                        subject: subject,
                        objective: "评估组合当前配置的动量、估值与主要风险"
                    )
                )
                let outcome = try await workflow.run(input: input)
                await MainActor.run {
                    if outcome.succeeded {
                        self?.latestResearchArtifactID = outcome.artifact?.id.rawValue
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
