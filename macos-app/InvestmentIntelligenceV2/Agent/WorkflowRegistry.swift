import Foundation

// MARK: - WorkflowRegistry / JobRecovery（AGENT-1）
//
// ATTR-4 留下的形态：workflow 自己 new 一个内存 AgentJob 跑完即弃，job
// 不落库、无恢复。本文件补齐 Agent 运行时的两块：
//
// - WorkflowRegistry：kind → runner 的调度面。submit 是幂等入口——
//   同输入 completed → alreadyCompleted（不重跑）；queued/running →
//   inProgress；failed/cancelled → 新 attempt（fingerprint 后缀 +1，
//   重试是一等公民，每次尝试独立成行、完整审计）。
// - JobRecovery：进程崩溃后的恢复面。非终端作业两态处理：
//   queued（还没起跑）→ 直接续跑（同一行续时间线）；
//   running 且已陈旧（超过 staleAfter 无事件 / 检查点活动）→ 标记
//   abandoned-failed + 以同输入开新 attempt，新 attempt 收到崩溃行
//   已落盘的 checkpoints（续跑而非从头重来的唯一通道）。
//
// 活跃判定是「最后活动时间」启发（无心跳列——迁移只追加，schema 已冻结
// 的列不动）：单写者现实（App 尚不经 registry 落 job，行来源即 CLI 本身）
// 下足够；并发双进程同跑同一 job 的场景由调用方用足够的 staleAfter 排除。
//
// 检查点语义：runner 在阶段边界 saveCheckpoint(step, stateJSON)；崩溃后
// 新 attempt 的 context.resumeCheckpoints 按原顺序携带全部检查点，跳过
// 已完成阶段（含产物幂等写入）由 runner 自理——registry 不解释 state。

// MARK: - 运行协议

/// 一次运行的上下文（registry → runner）。
struct AgentRunContext: Sendable {
    let jobID: String
    let workflowKind: String
    let now: Date
    /// 崩溃续跑：前一 attempt 已持久化的检查点（seq 升序；空 = 全新运行）
    let resumeCheckpoints: [AgentJobCheckpointState]
    /// 检查点持久化（runner 在长任务阶段间调用；写入失败抛错上抛）
    let saveCheckpoint: @Sendable (_ step: String, _ stateJSON: String) throws -> Void
}

/// 一次运行的结果（人可读摘要 + 产出 artifact 引用）。
struct AgentRunResult: Sendable, Hashable {
    let summary: String
    let artifactIDs: [String]

    init(summary: String, artifactIDs: [String] = []) {
        self.summary = summary
        self.artifactIDs = artifactIDs
    }
}

/// workflow runner：registry 只认 kind + 输入 JSON（输入的编解码归 runner，
/// registry 不解释业务输入——泛型输入会把调度面拖回具体 workflow）。
protocol AgentWorkflowRunner: Sendable {
    var kind: String { get }
    func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult
}

// MARK: - Registry

/// 提交结果。
enum AgentSubmissionOutcome: Sendable {
    /// 本进程执行了一轮（成功 / 失败都在 job.state；result nil = 失败）
    case ran(job: AgentJob, result: AgentRunResult?)
    /// 同输入已 completed（幂等命中，不重跑）
    case alreadyCompleted(job: AgentJob)
    /// 同输入正在排队 / 执行（另一提交方持有）
    case inProgress(job: AgentJob)
    /// kind 未注册
    case unknownWorkflow(kind: String)
}

/// 续跑结果。
enum AgentResumeOutcome: Sendable {
    /// 续跑完成（queued 直跑路径；result nil = 失败）
    case ran(job: AgentJob, result: AgentRunResult?)
    /// running 且已陈旧：abandoned 行标 failed，新 attempt 已执行
    case reattempted(abandoned: AgentJob, job: AgentJob, result: AgentRunResult?)
    /// 终态 job 不可续跑（重跑请重新 submit）
    case alreadyTerminal(job: AgentJob)
    /// 仍在活跃窗口内（另一进程可能持有；lastActivity 为最后活动时间）
    case stillActive(job: AgentJob, lastActivity: Date)
    case notFound(jobID: String)
    case unknownWorkflow(kind: String)
}

struct WorkflowRegistry: Sendable {
    let store: AgentJobStore
    private let runners: [String: any AgentWorkflowRunner]
    private let clock: @Sendable () -> Date

    /// 重试上限：同一次 submit 内 fingerprint 后缀推进的护栏（防御行被
    /// 外部写入异常形态导致的死循环；正常路径最多推进几次即遇到 new）。
    private static let maxAttemptAdvance = 1000

    init(
        store: AgentJobStore,
        runners: [any AgentWorkflowRunner],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.runners = Dictionary(
            uniqueKeysWithValues: runners.map { ($0.kind, $0) }
        )
        self.clock = clock
    }

    /// 已注册的 workflow 种类（排序稳定，诊断 / help 用）。
    var kinds: [String] { runners.keys.sorted() }

    // MARK: 提交

    /// 幂等提交：输入 JSON 的确定性摘要即逻辑身份。同输入 completed 幂等
    /// 命中；failed/cancelled 自动开新 attempt 执行。
    func submit(kind: String, inputJSON: String) async throws -> AgentSubmissionOutcome {
        guard let runner = runners[kind] else {
            return .unknownWorkflow(kind: kind)
        }
        let base = AgentJob.digest(inputJSON)
        var attempt = try store.latestAttempt(workflowKind: kind, baseFingerprint: base)
        var advanced = 0
        while advanced < Self.maxAttemptAdvance {
            let fingerprint = AgentJobStore.fingerprint(base: base, attempt: attempt)
            switch try store.enqueue(
                workflowKind: kind, fingerprint: fingerprint, inputJSON: inputJSON, now: clock()
            ) {
            case .new(let job):
                let executed = try await execute(
                    job: job, runner: runner, inputJSON: inputJSON, resumeCheckpoints: []
                )
                return .ran(job: executed.job, result: executed.result)
            case .existing(let job):
                switch job.state {
                case .completed:
                    return .alreadyCompleted(job: job)
                case .queued, .running:
                    return .inProgress(job: job)
                case .failed, .cancelled:
                    attempt += 1
                    advanced += 1
                    continue
                }
            }
        }
        throw AgentRegistryError.attemptExhausted(kind: kind, base: base)
    }

    // MARK: 续跑

    /// 指定 job 续跑（恢复入口，JobRecovery 与 CLI resume 共用）。
    ///
    /// - queued：从未起跑（崩溃在 enqueue 后 / start 前）→ 同一行直接执行；
    /// - running：活跃窗口外视为崩溃残留 → abandoned 标 failed + 新 attempt
    ///   续跑（携带崩溃行检查点）；
    /// - 活跃窗口由 staleAfter 控制（最后事件 / 检查点时间距今）。
    func resume(jobID: String, staleAfter: TimeInterval) async throws -> AgentResumeOutcome {
        guard let job = try store.job(id: jobID) else {
            return .notFound(jobID: jobID)
        }
        guard let runner = runners[job.workflowKind] else {
            return .unknownWorkflow(kind: job.workflowKind)
        }
        if job.state.isTerminal {
            return .alreadyTerminal(job: job)
        }
        if job.state == .queued {
            let executed = try await execute(
                job: job, runner: runner, inputJSON: try requiredInput(for: job),
                resumeCheckpoints: []
            )
            return .ran(job: executed.job, result: executed.result)
        }
        // running：活跃判定
        let lastActivity = try store.lastActivity(jobID: job.id)
        if clock().timeIntervalSince(lastActivity) < staleAfter {
            return .stillActive(job: job, lastActivity: lastActivity)
        }
        var abandoned = job
        try abandoned.transition(
            to: .failed, at: clock(),
            detail: "abandoned: 进程中断（最后活动 \(lastActivity)），由恢复入口标记"
        )
        try store.record(job: abandoned)
        let input = try requiredInput(for: job)
        let checkpoints = try store.checkpoints(jobID: job.id)
        let base = AgentJobStore.baseFingerprint(of: job.inputFingerprint)
        // 崩溃行本身已占一个 attempt（含更高的历史尝试）——新 attempt = max+1
        let attempt = try store.latestAttempt(
            workflowKind: job.workflowKind, baseFingerprint: base
        ) + 1
        let fingerprint = AgentJobStore.fingerprint(base: base, attempt: attempt)
        switch try store.enqueue(
            workflowKind: job.workflowKind,
            fingerprint: fingerprint,
            inputJSON: input,
            now: clock()
        ) {
        case .new(let newJob):
            let executed = try await execute(
                job: newJob, runner: runner, inputJSON: input, resumeCheckpoints: checkpoints
            )
            return .reattempted(
                abandoned: abandoned, job: executed.job, result: executed.result
            )
        case .existing(let existing):
            // 并发竞态：另一恢复方已建新 attempt——如实上报未执行
            return .reattempted(abandoned: abandoned, job: existing, result: nil)
        }
    }

    // MARK: 执行

    /// 执行一个已入队的 job：running → runner → 终态，全程逐步落库
    /// （崩溃时留下 RUNNING 行 + 已有事件，正是恢复线索）。
    /// 返回执行后的 job（成功 / 失败都在 state）与结果（失败为 nil）。
    private func execute(
        job: AgentJob,
        runner: any AgentWorkflowRunner,
        inputJSON: String,
        resumeCheckpoints: [AgentJobCheckpointState]
    ) async throws -> (job: AgentJob, result: AgentRunResult?) {
        var job = job
        try job.transition(to: .running, at: clock(), detail: nil)
        try store.record(job: job)
        let context = AgentRunContext(
            jobID: job.id,
            workflowKind: job.workflowKind,
            now: clock(),
            resumeCheckpoints: resumeCheckpoints,
            saveCheckpoint: { [store, jobID = job.id, clock] step, stateJSON in
                try store.saveCheckpoint(
                    jobID: jobID, step: step, stateJSON: stateJSON, now: clock()
                )
            }
        )
        do {
            let result = try await runner.run(inputJSON: inputJSON, context: context)
            let detail = result.artifactIDs.isEmpty
                ? result.summary
                : "\(result.summary)｜artifacts: \(result.artifactIDs.joined(separator: ","))"
            // 终态段（二十轮 P2-7）：runner 已成功、终态落库失败时不得被
            // 通用 catch 吞成「completed + result nil / 行停 RUNNING」——
            // 包成 terminalRecordFailed 上抛（调用方报错退出；行由恢复面
            // 按 abandoned 幂等处置，产物写入本身幂等）
            do {
                try job.transition(to: .completed, at: clock(), detail: detail)
                try store.record(job: job)
            } catch {
                throw AgentRegistryError.terminalRecordFailed(
                    jobID: job.id, detail: String(describing: error)
                )
            }
            return (job: job, result: result)
        } catch is CancellationError {
            try? job.transition(to: .cancelled, at: clock(), detail: nil)
            try? store.record(job: job)
            throw CancellationError()
        } catch let error as AgentRegistryError {
            throw error   // 终态落库失败不降格为「运行失败」语义
        } catch {
            try? job.transition(to: .failed, at: clock(), detail: String(describing: error))
            try? store.record(job: job)
            return (job: job, result: nil)
        }
    }

    /// 续跑需要原始输入——行内只有指纹（旧形态 / 损坏）时显式拒收。
    private func requiredInput(for job: AgentJob) throws -> String {
        guard let input = try store.inputJSON(id: job.id), !input.isEmpty else {
            throw AgentJobStore.StoreError.missingInputJSON(jobID: job.id)
        }
        return input
    }
}

enum AgentRegistryError: Error, Equatable, Sendable {
    /// fingerprint 后缀推进超护栏（行被外部写坏 / 并发循环冲突）
    case attemptExhausted(kind: String, base: String)
    /// runner 已成功但终态落库失败（行可能停 RUNNING——由恢复面处置）
    case terminalRecordFailed(jobID: String, detail: String)
}

// MARK: - JobRecovery

/// 恢复扫描：启动 / 运维入口对全部非终端作业逐个处置。
struct JobRecovery: Sendable {
    let registry: WorkflowRegistry

    enum Outcome: Sendable, Hashable {
        /// queued 直跑完成
        case continuedQueued(jobID: String)
        /// running 陈旧 → abandoned 标 failed + 新 attempt 完成
        case reattempted(abandonedJobID: String, newJobID: String)
        /// 活跃窗口内（不处置）
        case skippedActive(jobID: String)
        /// 扫描快照后已被他方终结（竞态，无操作）
        case alreadyTerminal(jobID: String)
        /// workflow 未注册（runner 已下线；作业保持原状待人工处置）
        case unknownWorkflow(jobID: String, kind: String)
        /// 恢复动作本身失败（记录详情，不中断其余作业的处置）
        case failed(jobID: String, detail: String)
    }

    /// 单作业恢复的默认陈旧阈值：两小时无任何事件 / 检查点活动。
    /// CLI / App 可按场景收紧（如启动恢复传 0——本进程刚起，任何
    /// RUNNING 都不是本进程持有的）。
    static let defaultStaleAfter: TimeInterval = 2 * 60 * 60

    /// 扫描并处置全部非终端作业（逐作业 best-effort：单作业失败不阻断
    /// 其余作业，失败如实入返回值）。**扫描本身失败上抛**（二十轮 P2-10：
    /// 吞成空列表会让调用方把「读不出」当「无事可做」）。
    func recover(staleAfter: TimeInterval = JobRecovery.defaultStaleAfter) async throws -> [Outcome] {
        let jobs = try registry.store.nonTerminalJobs()
        var outcomes: [Outcome] = []
        for job in jobs {
            do {
                switch try await registry.resume(jobID: job.id, staleAfter: staleAfter) {
                case .ran(let ranJob, _):
                    outcomes.append(.continuedQueued(jobID: ranJob.id))
                case .reattempted(let abandoned, let newJob, _):
                    outcomes.append(.reattempted(
                        abandonedJobID: abandoned.id, newJobID: newJob.id
                    ))
                case .stillActive:
                    outcomes.append(.skippedActive(jobID: job.id))
                case .alreadyTerminal:
                    outcomes.append(.alreadyTerminal(jobID: job.id))
                case .notFound:
                    outcomes.append(.alreadyTerminal(jobID: job.id))
                case .unknownWorkflow:
                    outcomes.append(.unknownWorkflow(jobID: job.id, kind: job.workflowKind))
                }
            } catch {
                outcomes.append(.failed(
                    jobID: job.id, detail: String(describing: error)
                ))
            }
        }
        return outcomes
    }
}
