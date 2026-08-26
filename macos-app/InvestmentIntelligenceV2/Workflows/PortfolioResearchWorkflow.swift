import Foundation
import GRDB

// MARK: - Portfolio Research Workflow（WF-1，Epic 12 首个工作流）
//
// 替代旧 longTerm 链路的 V2 完整链：Research → AssetThesis →
// PortfolioThesis → Signals → Decision。一次 run 把「研究」与「决策」
// 接成闭环——真实 Research（多轮 Tool Calling）产出 Signal 喂 Decision，
// 而不是 mock（Epic 10 的 M7 用 mock Signal 验证决策确定性，本工作流
// 把 Signal 生产端接上真实链路）。
//
// 阶段与职责边界：
// 1. Research：逐任务跑 ResearchHarness（RES-2），工具结果经 observer
//    收集 → ResearchEvidenceFactory 落 evidence 本体（rollout Epic 11
//    状态块遗留项：RES-6 只落 signals，evidence 落库在本工作流接线）
// 2. Validate → Extract → Persist：RES-5 三层校验 → RES-4 确定性提取 →
//    RES-6 SignalStore 幂等落库
// 3. Thesis：ThesisSynthesizer 合成 asset / portfolio 论点 → ThesisStore
//    （theses 表消费）
// 4. Decision：DecisionMaterialsProviding 供给材料（criterion / factor /
//    band / 逐方案规划输入）→ DecisionReplayer.compute（首产与重放共用
//    同一实现）→ assemble → **DecisionValidator（落库前强制门禁，AGENTS.md
//    关键约定 11）**→ artifactSink 落库
//
// 失败语义：任一阶段失败 → job failed + errorDetail（不崩进程、不落
// 半截状态——各 Store 写入本身幂等，重跑整个 workflow 是安全的）。
// 取消：研究段的 CancellationError 按结构化并发语义 rethrow（job 标
// cancelled）。

// MARK: - 决策段材料供给

/// 决策段材料（材料供给协议的产出形态）。
struct PortfolioDecisionMaterials: Sendable {
    /// criterion 定义 + factor 实例 + band（Replayer 材料形状）。
    let replayerMaterials: DecisionReplayer.ReplayMaterials
    /// 逐方案规划输入（key 域即 plan 域；assemble 会校验恰好覆盖）。
    let plannerRuns: [String: DecisionReplayer.PlannerRun]
    /// 参照 Target（必须与每个 plannerRun.target 一致——validator 逐 run
    /// 严格相等，workflow 组装前预检，fail-closed）。
    let target: AllocationTarget?
    /// 决策上下文摘要（DATA002：当时的可知口径）。
    let knowledgeContextSummary: String

    init(
        replayerMaterials: DecisionReplayer.ReplayMaterials,
        plannerRuns: [String: DecisionReplayer.PlannerRun],
        target: AllocationTarget?,
        knowledgeContextSummary: String
    ) {
        self.replayerMaterials = replayerMaterials
        self.plannerRuns = plannerRuns
        self.target = target
        self.knowledgeContextSummary = knowledgeContextSummary
    }
}

/// 决策材料供给（App / CLI 接线时真实现读 GRDB Repository；测试 mock）。
/// signals 不进 cardinal 数学（D002）——供给方按 asOf 取组合快照与因子，
/// 研究信号只作 artifact 引用层的 narrative 溯源。
protocol PortfolioDecisionMaterialsProviding: Sendable {
    func materials(asOf: Date) throws -> PortfolioDecisionMaterials
}

// MARK: - Workflow 本体

struct PortfolioResearchWorkflow: Sendable {
    static let workflowKind = "portfolioResearch"

    /// 依赖集合（构造方注入；全部协议化，测试可全 mock）。
    struct Dependencies: Sendable {
        let harness: ResearchHarness
        let extractor: SignalExtractor
        let validation: ResearchValidationPipeline
        let signalStore: any SignalStore
        let thesisStore: any ThesisStore
        let evidenceStore: any ResearchEvidenceStore
        let decisionMaterials: any PortfolioDecisionMaterialsProviding
        /// artifact 落库回调（App/CLI 接 GRDB Repository.writeArtifact；
        /// 落库前 workflow 已过 DecisionValidator）。
        let artifactSink: @Sendable (PortfolioDecisionArtifact) throws -> Void

        init(
            harness: ResearchHarness,
            extractor: SignalExtractor = SignalExtractor(),
            validation: ResearchValidationPipeline = ResearchValidationPipeline(),
            signalStore: any SignalStore,
            thesisStore: any ThesisStore,
            evidenceStore: any ResearchEvidenceStore,
            decisionMaterials: any PortfolioDecisionMaterialsProviding,
            artifactSink: @Sendable @escaping (PortfolioDecisionArtifact) throws -> Void
        ) {
            self.harness = harness
            self.extractor = extractor
            self.validation = validation
            self.signalStore = signalStore
            self.thesisStore = thesisStore
            self.evidenceStore = evidenceStore
            self.decisionMaterials = decisionMaterials
            self.artifactSink = artifactSink
        }
    }

    /// 一次运行输入。
    struct Input: Sendable, Hashable {
        /// 组合主体（portfolio thesis 归属 / 决策对象的 Canonical 引用）。
        let portfolioSubject: CanonicalRef
        /// 资产级研究任务（0..n 个；产物 = asset theses + signals）。
        let assetTasks: [ResearchTask]
        /// 组合级研究任务（产物并入 portfolio thesis）。
        let portfolioTask: ResearchTask?

        init(
            portfolioSubject: CanonicalRef,
            assetTasks: [ResearchTask],
            portfolioTask: ResearchTask? = nil
        ) {
            self.portfolioSubject = portfolioSubject
            self.assetTasks = assetTasks
            self.portfolioTask = portfolioTask
        }

        /// 输入指纹（全部任务指纹的确定性聚合；AgentJob 幂等键）。
        var inputFingerprint: String {
            let taskTokens = (assetTasks + [portfolioTask].compactMap { $0 })
                .map { $0.inputFingerprint }
                .sorted()
            return StableDigest.digest(
                "\(portfolioSubject.stableKey)|\(taskTokens.joined(separator: ","))"
            )
        }
    }

    struct RunOutcome: Sendable {
        let job: AgentJob
        let signals: [InvestmentSignal]
        let theses: [ResearchThesis]
        let artifact: PortfolioDecisionArtifact?
        let errorDetail: String?

        var succeeded: Bool { job.state == .completed }
    }

    let dependencies: Dependencies
    private let clock: @Sendable () -> Date

    init(
        dependencies: Dependencies,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dependencies = dependencies
        self.clock = clock
    }

    /// 运行事件（进度可观察；App 层订阅展示）。
    enum RunEvent: Sendable, Hashable {
        case researchStarted(taskCount: Int)
        case researchTaskCompleted(objective: String, claimCount: Int)
        case evidencePersisted(count: Int)
        case signalsExtracted(count: Int)
        case thesesWritten(count: Int)
        case decisionAssembled(artifactID: String, status: String)
        case failed(detail: String)
    }

    func run(
        input: Input,
        eventHandler: (@Sendable (RunEvent) async -> Void)? = nil
    ) async throws -> RunOutcome {
        let events = eventHandler ?? { _ in }
        let now = clock()
        var job = AgentJob(
            workflowKind: Self.workflowKind,
            inputFingerprint: input.inputFingerprint,
            createdAt: now
        )
        try job.transition(to: .running, at: now, detail: nil)

        func fail(_ detail: String) async -> RunOutcome {
            try? job.transition(to: .failed, at: clock(), detail: detail)
            await events(.failed(detail: detail))
            return RunOutcome(
                job: job, signals: [], theses: [], artifact: nil, errorDetail: detail
            )
        }

        do {
            // ---- 阶段 1：Research（工具结果收集 + evidence 落库）----

            await events(.researchStarted(taskCount: input.assetTasks.count + (input.portfolioTask == nil ? 0 : 1)))
            // observer 线程安全收集（Harness 在本 run 的并发上下文回调）
            let collector = ResearchToolResultCollector()
            let harness = dependencies.harness.withToolResultObserver {
                collector.record(toolName: $0, result: $1, at: clock())
            }

            var allNotes: [ResearchNotes] = []
            for task in input.assetTasks + [input.portfolioTask].compactMap({ $0 }) {
                collector.anchor(subject: task.subject)
                let outcome = try await harness.run(task: task)
                guard let notes = outcome.notes else {
                    return await fail(
                        "研究任务失败（\(task.subject.entityIDRawValue)）：\(outcome.errorDetail ?? "unknown")"
                    )
                }
                allNotes.append(notes)
                await events(.researchTaskCompleted(
                    objective: task.objective, claimCount: notes.claims.count
                ))
            }

            // evidence 本体构造并**暂存**（十六轮审查 P1-5：Decision 失败时
            // 不留半截状态——全部产物在 Decision 校验通过后统一提交；
            // 校验管道的 knownEvidence / evidenceDates 由「store 已有 +
            // 本次暂存」合并供给，语义与落库后一致）
            var stagedEvidence: [EvidenceObservation] = []
            for record in collector.records {
                for evidenceID in record.result.evidenceIDs {
                    let observation = try ResearchEvidenceFactory().observation(
                        evidenceID: evidenceID,
                        toolName: record.toolName,
                        content: record.result.contentJSON,
                        subject: record.taskSubject,
                        sourceDate: record.result.evidenceSourceDates[
                            evidenceID.rawValue],
                        at: record.timestamp
                    )
                    stagedEvidence.append(observation)
                }
            }
            await events(.evidencePersisted(count: stagedEvidence.count))

            // ---- 阶段 2：Validate → Extract → Persist signals ----

            var knownEvidence = try dependencies.evidenceStore.knownEvidenceIDs()
            for observation in stagedEvidence {
                knownEvidence.insert(observation.evidenceID.rawValue)
            }
            var evidenceDates = try dependencies.evidenceStore.evidenceDates()
            for observation in stagedEvidence {
                let available = observation.temporalEnvelope.availableAt
                if (evidenceDates[observation.evidenceID.rawValue] ?? .distantPast) < available {
                    evidenceDates[observation.evidenceID.rawValue] = available
                }
            }
            for notes in allNotes {
                let verdict = dependencies.validation.validate(
                    notes, now: clock(),
                    knownEvidence: knownEvidence, evidenceDates: evidenceDates
                )
                guard verdict.isValid else {
                    let detail = verdict.errors
                        .map { "\($0.validator.rawValue)/\($0.code):\($0.detail)" }
                        .joined(separator: "; ")
                    return await fail("研究笔记未通过校验管道：\(detail)")
                }
            }

            var signals: [InvestmentSignal] = []
            for notes in allNotes {
                signals.append(contentsOf: dependencies.extractor.extract(
                    from: notes, now: clock()
                ))
            }
            await events(.signalsExtracted(count: signals.count))

            // ---- 阶段 3：Thesis 合成落库 ----

            let synthesizer = ThesisSynthesizer()
            var theses: [ResearchThesis] = []
            var assetTheses: [ResearchThesis] = []
            var portfolioNotes: ResearchNotes?
            for notes in allNotes {
                // 组合主体的任务不产 asset thesis——其叙述与 claims 直接
                // 并入 portfolio thesis（资产级论点只属于资产级主体）
                guard notes.task.subject != input.portfolioSubject else {
                    portfolioNotes = notes
                    continue
                }
                let scopedSignals = signals.filter {
                    $0.subjectCanonical == notes.task.subject
                }
                let thesis = synthesizer.assetThesis(
                    from: notes, signals: scopedSignals, now: clock()
                )
                theses.append(thesis)
                assetTheses.append(thesis)
            }
            let portfolioThesis = synthesizer.portfolioThesis(
                subject: input.portfolioSubject,
                assetTheses: assetTheses,
                portfolioNotes: portfolioNotes,
                signals: signals,
                now: clock()
            )
            theses.append(portfolioThesis)
            await events(.thesesWritten(count: theses.count))

            // ---- 阶段 4：Decision（材料 → 首产（= 重放实现）→ 校验 → 落库）----

            let materials = try dependencies.decisionMaterials.materials(asOf: clock())
            // 组装前预检：plannerRuns 非空 + target 一致（与 validator 同语义，
            // 提前 fail-closed 给出可读错误）
            guard !materials.plannerRuns.isEmpty else {
                return await fail("决策材料缺规划输入（plannerRuns 为空）")
            }
            for (key, run) in materials.plannerRuns
            where run.target?.id != materials.target?.id {
                return await fail(
                    "规划输入 plannerRuns[\(key)].target 与材料 target 不一致"
                )
            }
            let replayerOutcome = try DecisionReplayer().compute(
                materials: materials.replayerMaterials,
                plannerInputs: materials.plannerRuns,
                frozenNowByPlan: [:]
            )
            let artifact = PortfolioDecisionArtifact.assemble(
                signalIDs: signals.map(\.id),
                criterionDefinitions: Array(materials.replayerMaterials.criterionDefinitions.values),
                factorSnapshotIDs: materials.replayerMaterials.factorSnapshots.keys
                    .map { ArtifactID(rawValue: $0) },
                target: materials.target,
                band: materials.replayerMaterials.band,
                knowledgeContextSummary: materials.knowledgeContextSummary,
                decision: replayerOutcome.decision,
                comparison: replayerOutcome.comparison,
                plans: replayerOutcome.plans,
                plannerRuns: materials.plannerRuns,
                producedAt: clock()
            )
            // 落库前强制门禁（AGENTS.md 关键约定 11）：resolvers 实查可解析
            // 域——signal 查「本次暂存 ∪ store 已有」（暂存信号尚未落库，
            // 域语义与 flush 后一致），其余查材料本身
            let materialFingerprints = Set(materials.replayerMaterials.criterionDefinitions.keys)
            let materialSnapshots = Set(materials.replayerMaterials.factorSnapshots.keys)
            let bandVersion = "\(materials.replayerMaterials.band.policyID)@\(materials.replayerMaterials.band.version)"
            let stagedSignalIDs = Set(signals.map(\.id))
            let existingSignalStore = dependencies.signalStore
            try DecisionValidator().validate(
                artifact: artifact,
                resolvers: .init(
                    signal: { id in
                        stagedSignalIDs.contains(id)
                            || (try? existingSignalStore.signal(id: id)) != nil
                    },
                    factorSnapshot: { materialSnapshots.contains($0.rawValue) },
                    criterion: { materialFingerprints.contains($0) },
                    indifferenceBand: { $0 == bandVersion }
                )
            )

            // ---- 统一提交（十六轮审查 P1-5）----
            // Decision 校验通过前零落库：材料缺失 / validator 拒绝 / 组装
            // 失败都不留 evidence / signals / theses 半截状态。顺序：
            // evidence → signals → theses → artifact——artifact 最后落库，
            // 下游（Intraday / QueryService）以「存在 decision artifact」为
            // 本次 run 完成的可见标志。flush 中途 IO 失败仍可能留部分写入
            // （错误级、各 store 幂等可重跑收敛），与「决策失败留产物」的
            // 语义性缺陷不同。
            for observation in stagedEvidence {
                try dependencies.evidenceStore.write(observation)
            }
            for signal in signals {
                try dependencies.signalStore.write(signal)
            }
            for thesis in theses {
                try dependencies.thesisStore.write(thesis)
            }
            try dependencies.artifactSink(artifact)
            await events(.decisionAssembled(
                artifactID: artifact.id.rawValue,
                status: artifact.decision.status.rawValue
            ))

            try job.transition(to: .completed, at: clock(), detail: artifact.id.rawValue)
            return RunOutcome(
                job: job, signals: signals, theses: theses,
                artifact: artifact, errorDetail: nil
            )
        } catch is CancellationError {
            try? job.transition(to: .cancelled, at: clock(), detail: nil)
            throw CancellationError()
        } catch {
            return await fail(String(describing: error))
        }
    }
}

// MARK: - 工具结果收集（线程安全）

/// ResearchHarness observer 的收集端：记录 (toolName, result, task 主体,
/// 时间)。task 主体经 Harness 调用上下文传入（observer 闭包只拿到工具
/// 名与结果——主体由 workflow 在构造 observer 时按当前任务锚定）。
private final class ResearchToolResultCollector: @unchecked Sendable {
    struct Record: Sendable {
        let toolName: String
        let result: ResearchToolResult
        let taskSubject: CanonicalRef
        let timestamp: Date
    }

    private let lock = NSLock()
    private var subject: CanonicalRef?
    var records: [Record] = []

    /// workflow 在发起每个研究任务前锚定主体（observer 回调读到的是
    /// 最近锚定的主体——run 循环内串行，无竞态窗口）。
    func anchor(subject: CanonicalRef) {
        lock.lock()
        defer { lock.unlock() }
        self.subject = subject
    }

    func record(toolName: String, result: ResearchToolResult, at timestamp: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let subject else { return }
        records.append(
            Record(toolName: toolName, result: result, taskSubject: subject, timestamp: timestamp)
        )
    }
}

extension ResearchHarness {
    /// 挂 observer 的副本（值类型复制，原 harness 不变）。
    fileprivate func withToolResultObserver(
        _ observer: @escaping @Sendable (String, ResearchToolResult) -> Void
    ) -> ResearchHarness {
        var copy = self
        copy.toolResultObserver = observer
        return copy
    }
}

// MARK: - GRDB artifact 落库便捷入口（App / CLI 接线用）

extension GRDBRepository {
    /// 决策 artifact 幂等落库（同 ID 同语义 no-op，异语义 conflict——
    /// ArtifactRow.write 语义，事务包裹）。
    func writeArtifact(_ artifact: PortfolioDecisionArtifact) throws {
        try database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(artifact), into: db)
        }
    }

    /// 按 ID 读回决策 artifact（不存在 → nil；存在但损坏 → 抛错 fail-closed）。
    func portfolioDecision(id: String) throws -> PortfolioDecisionArtifact? {
        try database.queue.read { db in
            do {
                return try ArtifactRow.fetchPortfolioDecision(id: id, from: db)
            } catch ArtifactReadError.notFound {
                return nil
            }
        }
    }
}
