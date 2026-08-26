import XCTest
@testable import QiemanDashboard

/// AGENT-1 单元测试：AgentJobStore（持久化读面）/ WorkflowRegistry（调度
/// + 幂等）/ JobRecovery（崩溃恢复 + 检查点续跑）。
final class AgentRuntimeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: 测试工具

    /// 可编程 runner：记录调用（输入 / 续跑检查点），按脚本返回或抛错。
    private final class ScriptedRunner: AgentWorkflowRunner, @unchecked Sendable {
        let kind: String
        private let lock = NSLock()
        private var _calls: [(input: String, resumeSteps: [String])] = []
        /// 第 n 次调用（0 起）的行为；越界沿用最后一个
        private var behaviors: [@Sendable (AgentRunContext) throws -> AgentRunResult]

        init(
            kind: String,
            behaviors: [@Sendable (AgentRunContext) throws -> AgentRunResult] = []
        ) {
            self.kind = kind
            self.behaviors = behaviors.isEmpty
                ? [{ _ in AgentRunResult(summary: "ok") }]
                : behaviors
        }

        var calls: [(input: String, resumeSteps: [String])] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult {
            lock.lock()
            _calls.append((input: inputJSON, resumeSteps: context.resumeCheckpoints.map(\.step)))
            let behavior = behaviors[min(_calls.count - 1, behaviors.count - 1)]
            lock.unlock()
            return try behavior(context)
        }
    }

    private struct ThrowingError: Error, Equatable {}

    private func makeStore() throws -> AgentJobStore {
        AgentJobStore(database: try CanonicalDatabase())
    }

    /// 固定时钟的 registry（测试确定性：时间由测试推进 `now` 掌控）。
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRegistry(
        _ runners: [any AgentWorkflowRunner],
        store: AgentJobStore
    ) -> WorkflowRegistry {
        now = t0
        return WorkflowRegistry(store: store, runners: runners, clock: { [self] in now })
    }

    // MARK: fingerprint 约定

    func testFingerprintAttemptSuffix() {
        XCTAssertEqual(AgentJobStore.fingerprint(base: "abc", attempt: 1), "abc")
        XCTAssertEqual(AgentJobStore.fingerprint(base: "abc", attempt: 3), "abc#3")
        XCTAssertEqual(AgentJobStore.baseFingerprint(of: "abc#3"), "abc")
        XCTAssertEqual(AgentJobStore.attemptNumber(of: "abc#3"), 3)
        // 非数字后缀视为 base 一部分（防御解析歧义）
        XCTAssertEqual(AgentJobStore.baseFingerprint(of: "abc#x"), "abc#x")
        XCTAssertEqual(AgentJobStore.attemptNumber(of: "abc#x"), 1)
        // 纯 base（无后缀）
        XCTAssertEqual(AgentJobStore.baseFingerprint(of: "abc"), "abc")
        XCTAssertEqual(AgentJobStore.attemptNumber(of: "abc"), 1)
    }

    // MARK: Store

    func testEnqueueIdempotentByFingerprint() throws {
        let store = try makeStore()
        let a = try store.enqueue(
            workflowKind: "w", fingerprint: "fp1", inputJSON: "{\"x\":1}", now: t0
        )
        guard case .new(let job) = a else { return XCTFail("首次应入队新行") }
        XCTAssertEqual(job.state, .queued)

        let b = try store.enqueue(
            workflowKind: "w", fingerprint: "fp1", inputJSON: "{\"x\":1}", now: t0
        )
        guard case .existing(let existing) = b else { return XCTFail("同指纹应命中已有行") }
        XCTAssertEqual(existing.id, job.id)

        // 不同 fingerprint 各自成行
        let c = try store.enqueue(
            workflowKind: "w", fingerprint: "fp2", inputJSON: "{}", now: t0
        )
        guard case .new(let job2) = c else { return XCTFail("新指纹应入队新行") }
        XCTAssertNotEqual(job2.id, job.id)

        // 读回走 toAgentJob 全量校验
        let fetched = try store.job(id: job.id)
        XCTAssertEqual(fetched?.id, job.id)
        XCTAssertEqual(fetched?.state, .queued)
        XCTAssertEqual(try store.inputJSON(id: job.id), "{\"x\":1}")
    }

    func testRecordAppendsEventsIncrementally() throws {
        let store = try makeStore()
        guard case .new(var job) = try store.enqueue(
            workflowKind: "w", fingerprint: "fp", inputJSON: "{}", now: t0
        ) else { return XCTFail() }
        try job.transition(to: .running, at: t0)
        try store.record(job: job)
        // 重复 record 幂等（已入库事件不重写）
        try store.record(job: job)
        try job.transition(to: .completed, at: t0.addingTimeInterval(5), detail: "done")
        try store.record(job: job)

        let fetched = try store.job(id: job.id)
        XCTAssertEqual(fetched?.state, .completed)
        XCTAssertEqual(fetched?.events.map(\.kind), [.queued, .started, .completed])
        XCTAssertEqual(fetched?.events.last?.detail, "done")

        let summaries = try store.summaries(limit: 10)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.status, .completed)
        XCTAssertEqual(summaries.first?.attempt, 1)
        XCTAssertEqual(summaries.first?.baseFingerprint, "fp")
        XCTAssertEqual(summaries.first?.workflow, "w")

        // 未入队的 job record 拒收
        let stranger = AgentJob(workflowKind: "w", inputFingerprint: "zzz", createdAt: t0)
        XCTAssertThrowsError(try store.record(job: stranger)) { error in
            guard case AgentJobStore.StoreError.jobNotEnqueued = error else {
                return XCTFail("应拒收未入队 job：\(error)")
            }
        }
    }

    func testCheckpointsAndLastActivity() throws {
        let store = try makeStore()
        guard case .new(var job) = try store.enqueue(
            workflowKind: "w", fingerprint: "fp", inputJSON: "{}", now: t0
        ) else { return XCTFail() }
        try job.transition(to: .running, at: t0)
        try store.record(job: job)

        try store.saveCheckpoint(
            jobID: job.id, step: "phase1", stateJSON: "{\"done\":true}",
            now: t0.addingTimeInterval(10)
        )
        try store.saveCheckpoint(
            jobID: job.id, step: "phase2", stateJSON: "{\"n\":2}",
            now: t0.addingTimeInterval(20)
        )
        let checkpoints = try store.checkpoints(jobID: job.id)
        XCTAssertEqual(checkpoints.map(\.step), ["phase1", "phase2"])
        XCTAssertEqual(checkpoints.first?.seq, 0)
        XCTAssertEqual(checkpoints.last?.stateJSON, "{\"n\":2}")

        // lastActivity = max(事件, 检查点)
        let last = try store.lastActivity(jobID: job.id)
        XCTAssertEqual(last.timeIntervalSince1970, t0.addingTimeInterval(20).timeIntervalSince1970)
    }

    // MARK: Registry 提交与幂等

    func testSubmitRunsAndIsIdempotentOnCompletion() async throws {
        let store = try makeStore()
        let runner = ScriptedRunner(kind: "w")
        let registry = makeRegistry([runner], store: store)

        let outcome = try await registry.submit(kind: "w", inputJSON: "{\"a\":1}")
        guard case .ran(let job, let result) = outcome else {
            return XCTFail("应执行：\(outcome)")
        }
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(result?.summary, "ok")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.input, "{\"a\":1}")
        XCTAssertEqual(runner.calls.first?.resumeSteps, [])

        // 同输入再提交 → alreadyCompleted，不重跑
        let second = try await registry.submit(kind: "w", inputJSON: "{\"a\":1}")
        guard case .alreadyCompleted(let cached) = second else {
            return XCTFail("completed 应幂等命中：\(second)")
        }
        XCTAssertEqual(cached.id, job.id)
        XCTAssertEqual(runner.calls.count, 1)

        // 未注册 kind
        let unknown = try await registry.submit(kind: "nope", inputJSON: "{}")
        guard case .unknownWorkflow = unknown else { return XCTFail("应 unknownWorkflow") }
        XCTAssertEqual(registry.kinds, ["w"])
    }

    func testSubmitFailureThenReattempt() async throws {
        let store = try makeStore()
        let runner = ScriptedRunner(kind: "w", behaviors: [
            { _ in throw ThrowingError() },
            { _ in AgentRunResult(summary: "second attempt ok") },
        ])
        let registry = makeRegistry([runner], store: store)

        let first = try await registry.submit(kind: "w", inputJSON: "{\"a\":1}")
        guard case .ran(let failedJob, let nilResult) = first else {
            return XCTFail("首轮应执行（失败形态）：\(first)")
        }
        XCTAssertEqual(failedJob.state, .failed)
        XCTAssertNil(nilResult)
        let failedRow = try store.job(id: failedJob.id)
        XCTAssertEqual(failedRow?.state, .failed)

        // 同输入再提交：failed → 新 attempt（fingerprint#2）
        let second = try await registry.submit(kind: "w", inputJSON: "{\"a\":1}")
        guard case .ran(let retryJob, let result) = second else {
            return XCTFail("failed 后应自动重试：\(second)")
        }
        XCTAssertEqual(retryJob.state, .completed)
        XCTAssertEqual(result?.summary, "second attempt ok")
        XCTAssertNotEqual(retryJob.id, failedJob.id)

        let summaries = try store.summaries(limit: 10)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(
            try store.latestAttempt(
                workflowKind: "w", baseFingerprint: AgentJob.digest("{\"a\":1}")
            ),
            2
        )
        // 第三次提交：attempt#2 已 completed → 幂等命中
        let third = try await registry.submit(kind: "w", inputJSON: "{\"a\":1}")
        guard case .alreadyCompleted = third else { return XCTFail("应命中 attempt#2：\(third)") }
        XCTAssertEqual(runner.calls.count, 2)
    }

    // MARK: 恢复

    /// 模拟崩溃：入队 + 起跑 + 检查点落盘后不再推进（行停 RUNNING）。
    @discardableResult
    private func simulateCrashedRunningJob(
        store: AgentJobStore, input: String, checkpointSteps: [String],
        lastActivity: Date? = nil
    ) throws -> AgentJob {
        let base = AgentJob.digest(input)
        guard case .new(var job) = try store.enqueue(
            workflowKind: "w", fingerprint: base, inputJSON: input, now: t0
        ) else { throw ThrowingError() }
        try job.transition(to: .running, at: t0)
        try store.record(job: job)
        var stamp = t0
        for (index, step) in checkpointSteps.enumerated() {
            stamp = t0.addingTimeInterval(Double(index + 1))
            try store.saveCheckpoint(
                jobID: job.id, step: step, stateJSON: "{\"i\":\(index)}", now: stamp
            )
        }
        if let lastActivity {
            try store.saveCheckpoint(
                jobID: job.id, step: "heartbeat", stateJSON: "{}", now: lastActivity
            )
        }
        return job
    }

    func testResumeStaleRunningReattemptsWithCheckpoints() async throws {
        let store = try makeStore()
        let crashed = try simulateCrashedRunningJob(
            store: store, input: "{\"a\":1}", checkpointSteps: ["research", "thesis"]
        )
        var seenSteps: [String] = []
        let runner = ScriptedRunner(kind: "w", behaviors: [
            { context in
                seenSteps = context.resumeCheckpoints.map(\.step)
                return AgentRunResult(summary: "resumed")
            },
        ])
        let registry = makeRegistry([runner], store: store)

        // 陈旧阈值 0：立即判定崩溃残留
        now = t0.addingTimeInterval(3600)
        let outcome = try await registry.resume(jobID: crashed.id, staleAfter: 0)
        guard case .reattempted(let abandoned, let newJob, let result) = outcome else {
            return XCTFail("陈旧 running 应重试：\(outcome)")
        }
        XCTAssertEqual(abandoned.id, crashed.id)
        XCTAssertEqual(abandoned.state, .failed)
        XCTAssertEqual(newJob.state, .completed)
        XCTAssertEqual(result?.summary, "resumed")
        XCTAssertEqual(seenSteps, ["research", "thesis"])
        // 新 attempt 行与崩溃行并存（完整审计）
        XCTAssertEqual(try store.summaries(limit: 10).count, 2)
    }

    func testResumeActiveRunningRejected() async throws {
        let store = try makeStore()
        let active = try simulateCrashedRunningJob(store: store, input: "{}", checkpointSteps: [])
        let runner = ScriptedRunner(kind: "w")
        let registry = makeRegistry([runner], store: store)

        now = t0.addingTimeInterval(60)
        let outcome = try await registry.resume(jobID: active.id, staleAfter: 3600)
        guard case .stillActive(_, let lastActivity) = outcome else {
            return XCTFail("活跃窗口内应拒收：\(outcome)")
        }
        XCTAssertEqual(lastActivity, t0)
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testResumeQueuedRunsSameRow() async throws {
        let store = try makeStore()
        guard case .new(let queued) = try store.enqueue(
            workflowKind: "w", fingerprint: AgentJob.digest("{}"), inputJSON: "{}", now: t0
        ) else { return XCTFail() }
        let runner = ScriptedRunner(kind: "w")
        let registry = makeRegistry([runner], store: store)

        now = t0.addingTimeInterval(1)
        let outcome = try await registry.resume(jobID: queued.id, staleAfter: 0)
        guard case .ran(let job, _) = outcome else {
            return XCTFail("queued 应直跑：\(outcome)")
        }
        XCTAssertEqual(job.id, queued.id)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(try store.summaries(limit: 10).count, 1)
    }

    func testResumeTerminalAndMissing() async throws {
        let store = try makeStore()
        let runner = ScriptedRunner(kind: "w")
        let registry = makeRegistry([runner], store: store)

        let missing = try await registry.resume(jobID: "job_none", staleAfter: 0)
        guard case .notFound = missing else { return XCTFail("应 notFound：\(missing)") }

        // 终态拒收
        guard case .new(var job) = try store.enqueue(
            workflowKind: "w", fingerprint: AgentJob.digest("{}"), inputJSON: "{}", now: t0
        ) else { return XCTFail() }
        try job.transition(to: .running, at: t0)
        try job.transition(to: .cancelled, at: t0)
        try store.record(job: job)
        let terminal = try await registry.resume(jobID: job.id, staleAfter: 0)
        guard case .alreadyTerminal = terminal else { return XCTFail("终态应拒收：\(terminal)") }
    }

    func testRecoverySweepMixedStates() async throws {
        let store = try makeStore()
        // 作业 1：陈旧 running（崩溃残留，最后活动 t0）→ reattempted
        let stale = try simulateCrashedRunningJob(
            store: store, input: "{\"s\":1}", checkpointSteps: []
        )
        // 作业 2：活跃 running（最近 10s 有检查点活动）→ skippedActive
        let active = try simulateCrashedRunningJob(
            store: store, input: "{\"s\":2}", checkpointSteps: [],
            lastActivity: t0.addingTimeInterval(3590)
        )
        // 作业 3：queued（崩溃在起跑前）→ 直跑
        guard case .new(let queued) = try store.enqueue(
            workflowKind: "w", fingerprint: AgentJob.digest("{\"s\":3}"),
            inputJSON: "{\"s\":3}", now: t0
        ) else { return XCTFail() }

        let runner = ScriptedRunner(kind: "w")
        let registry = makeRegistry([runner], store: store)
        let recovery = JobRecovery(registry: registry)

        now = t0.addingTimeInterval(3600)
        let outcomes = await recovery.recover(staleAfter: 1800)
        XCTAssertEqual(outcomes.count, 3)

        func outcomeJobID(_ o: JobRecovery.Outcome) -> String {
            switch o {
            case .continuedQueued(let id): return id
            case .reattempted(let abandoned, _): return abandoned
            case .skippedActive(let id): return id
            case .alreadyTerminal(let id): return id
            case .unknownWorkflow(let id, _): return id
            case .failed(let id, _): return id
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { (outcomeJobID($0), $0) })

        guard case .reattempted = byID[stale.id] else {
            return XCTFail("陈旧 running 应 reattempted：\(String(describing: byID[stale.id]))")
        }
        guard case .skippedActive = byID[active.id] else {
            return XCTFail("活跃 running 应 skipped：\(String(describing: byID[active.id]))")
        }
        guard case .continuedQueued(let id) = byID[queued.id] else {
            return XCTFail("queued 应直跑：\(String(describing: byID[queued.id]))")
        }
        _ = id
        // 直跑完成后行变 completed
        XCTAssertEqual(try store.job(id: queued.id)?.state, .completed)
    }
}
