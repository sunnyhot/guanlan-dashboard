import Foundation
import GRDB

// MARK: - AgentJobStore（AGENT-1）
//
// agent_jobs / agent_job_events / agent_checkpoints 三表的领域读面。
// ATTR-4 只落了行 codec（AgentJobRow.from(job:) / toAgentJob(events:)），
// 没有任何生产调用点——本类型把它接成可用的存储 API：
//
// - enqueue：入队（idempotency_key = workflow|fingerprint，UNIQUE 唯一键
//   兜底幂等；重试的 attempt 后缀让每次尝试是一行独立时间线）；
// - record：按事件时间线增量持久化 job 状态（先 enqueue 后 record；
//   已入库事件不重写，崩溃时留下 RUNNING 行正是恢复线索）；
// - checkpoint：长任务阶段间状态落盘 + 崩溃续跑读取；
// - 读面：job(id:) 走 toAgentJob 全量 fail-closed 校验（身份闭环 / 事件
//   时间线 / 冗余列一致——codec 十余轮审查的成果直接复用）。
//
// input_json 约定：{"fingerprint": <fp>, "input": <原始输入 JSON 字符串>}。
// 旧 codec 形态（仅 fingerprint，ATTR-4 测试路径）仍可解码——input 缺失
// 时 inputJSON(id:) 返回 nil，重放型恢复（需原始输入）显式拒收，不猜。

// MARK: - 检查点 / 摘要

/// 一次检查点（runner 在阶段边界落盘的中间状态）。
struct AgentJobCheckpointState: Sendable, Codable, Hashable {
    let seq: Int
    let step: String
    let stateJSON: String
    let createdAt: Date
}

/// 作业摘要（列表读面；AGENT-2 CLI jobs 命令与 App 诊断面消费）。
struct AgentJobSummary: Sendable, Codable, Hashable {
    let id: String
    let workflow: String
    let status: AgentJobStatus
    /// 同一逻辑输入的第几次尝试（fingerprint 后缀解析）
    let attempt: Int
    let baseFingerprint: String
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let errorMessage: String?
    /// 最近活动时间 = max(最后事件, 最后检查点)——恢复判活跃的锚点
    let lastActivityAt: Date
}

// MARK: - Store

struct AgentJobStore: Sendable {
    let database: CanonicalDatabase

    enum StoreError: Error, Equatable, Sendable {
        /// record 遇到未入队的 job（必须先 enqueue）
        case jobNotEnqueued(jobID: String)
        /// 重放型恢复需要原始输入，行内只有指纹（旧形态 / 损坏行）
        case missingInputJSON(jobID: String)
        /// 内存 job 视图落后于库内时间线（另一写者已推进更多事件）——
        /// 陈旧视图回写会把行状态倒拨，拒收（二十轮 P2-6）
        case staleJobView(jobID: String, storedEvents: Int, localEvents: Int)
    }

    enum EnqueueOutcome: Sendable {
        case new(AgentJob)
        case existing(AgentJob)
    }

    // MARK: fingerprint 的 attempt 约定

    /// attempt 后缀约定：`<base>`（第 1 次）→ `<base>#2` → `<base>#3`。
    /// base 是 hex 摘要（不含 `#`），解析无歧义；非数字后缀视为 base 的一部分。
    static func fingerprint(base: String, attempt: Int) -> String {
        attempt <= 1 ? base : "\(base)#\(attempt)"
    }

    static func baseFingerprint(of fingerprint: String) -> String {
        guard let idx = fingerprint.lastIndex(of: "#") else { return fingerprint }
        let suffix = fingerprint[fingerprint.index(after: idx)...]
        return suffix.allSatisfy(\.isNumber) ? String(fingerprint[..<idx]) : fingerprint
    }

    static func attemptNumber(of fingerprint: String) -> Int {
        guard let idx = fingerprint.lastIndex(of: "#") else { return 1 }
        let suffix = fingerprint[fingerprint.index(after: idx)...]
        return suffix.allSatisfy(\.isNumber) ? (Int(suffix) ?? 1) : 1
    }

    // MARK: 写入

    /// 入队（QUEUED 行 + 首事件）。幂等：idempotency_key 已存在 → existing。
    func enqueue(
        workflowKind: String, fingerprint: String, inputJSON: String, now: Date
    ) throws -> EnqueueOutcome {
        let pending = AgentJob(
            workflowKind: workflowKind, inputFingerprint: fingerprint, createdAt: now
        )
        let row = try Self.row(for: pending, inputJSON: inputJSON)
        let events = try AgentJobRow.eventRows(for: pending)
        do {
            try database.queue.write { db in
                try row.insert(db)
                for event in events { try event.insert(db) }
            }
            return .new(pending)
        } catch let error as DatabaseError
        where error.resultCode == .SQLITE_CONSTRAINT
            && (error.message ?? "").contains("idempotency_key") {
            // 唯一键冲突 = 同 (workflow, fingerprint) 已入队（并发提交 / 重放）。
            // 约束分类收窄到 idempotency_key（二十轮 P2-8）：其他约束违例
            // （如事件 PK 撞）不在此列，按原错误上抛。
            let key = row.idempotencyKey ?? "\(workflowKind)|\(fingerprint)"
            guard let existing = try self.job(idempotencyKey: key) else {
                throw error
            }
            return .existing(existing)
        }
    }

    /// 按事件时间线增量持久化 job 当前状态（行必须已 enqueue）。
    /// 已入库事件数之后的部分才追加——重复 record 幂等；库内时间线比
    /// 内存视图更长时拒收（staleJobView：陈旧视图回写会把行状态倒拨，
    /// 二十轮 P2-6——单写者假设被并发写者打破时的显式失败，不静默）。
    func record(job: AgentJob) throws {
        let fresh = try AgentJobRow.from(job: job)
        try database.queue.write { db in
            guard try AgentJobRow.fetchOne(
                db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [job.id]
            ) != nil else {
                throw StoreError.jobNotEnqueued(jobID: job.id)
            }
            let existingCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM agent_job_events WHERE job_id = ?",
                arguments: [job.id]
            ) ?? 0
            guard existingCount <= job.events.count else {
                throw StoreError.staleJobView(
                    jobID: job.id, storedEvents: existingCount, localEvents: job.events.count
                )
            }
            try db.execute(
                sql: """
                UPDATE agent_jobs
                SET status = ?, started_at = ?, completed_at = ?, error_message = ?
                WHERE id = ?
                """,
                arguments: [fresh.status, fresh.startedAt, fresh.completedAt, fresh.errorMessage, job.id]
            )
            for eventRow in try AgentJobRow.eventRows(for: job).dropFirst(existingCount) {
                try eventRow.insert(db)
            }
        }
    }

    /// 落一个检查点（seq 由现有数量决定，同 job 内单调递增）。
    func saveCheckpoint(
        jobID: String, step: String, stateJSON: String, now: Date
    ) throws {
        let payload = try CanonicalColumnCodec.encodeJSON(
            CheckpointPayload(step: step, state: stateJSON)
        )
        try database.queue.write { db in
            let seq = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM agent_checkpoints WHERE job_id = ?",
                arguments: [jobID]
            ) ?? 0
            try AgentCheckpointRow(
                jobID: jobID,
                seq: seq,
                createdAt: CanonicalColumnCodec.encodeTimestamp(now),
                stateJSON: payload
            ).insert(db)
        }
    }

    // MARK: 读取

    /// 按 id 读回（toAgentJob 全量 fail-closed 校验：身份闭环 / 时间线 /
    /// 冗余列一致；损坏行抛错不静默）。
    func job(id: String) throws -> AgentJob? {
        try readJob(sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [id])
    }

    /// 幂等键读回。
    func job(idempotencyKey: String) throws -> AgentJob? {
        try readJob(
            sql: "SELECT * FROM agent_jobs WHERE idempotency_key = ?",
            arguments: [idempotencyKey]
        )
    }

    /// 行内原始输入 JSON（缺失 → nil：只有指纹的旧形态行）。
    func inputJSON(id: String) throws -> String? {
        try database.queue.read { db in
            guard let row = try AgentJobRow.fetchOne(
                db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [id]
            ) else { return nil }
            guard let dict = try? CanonicalColumnCodec.decodeJSON(
                [String: String].self, from: row.inputJSON
            ) else { return nil }
            return dict["input"]
        }
    }

    /// 同一逻辑输入（base fingerprint）已尝试的最大次数（0 = 从未）。
    func latestAttempt(workflowKind: String, baseFingerprint: String) throws -> Int {
        try database.queue.read { db in
            let rows = try AgentJobRow.fetchAll(
                db, sql: "SELECT * FROM agent_jobs WHERE workflow = ?",
                arguments: [workflowKind]
            )
            return rows
                .compactMap { try? CanonicalColumnCodec.decodeJSON([String: String].self, from: $0.inputJSON)["fingerprint"] }
                .filter { Self.baseFingerprint(of: $0) == baseFingerprint }
                .map { Self.attemptNumber(of: $0) }
                .max() ?? 0
        }
    }

    /// 非终端作业（queued / running）——恢复扫描的候选集。
    func nonTerminalJobs() throws -> [AgentJob] {
        try database.queue.read { db in
            let rows = try AgentJobRow.fetchAll(
                db, sql: "SELECT * FROM agent_jobs WHERE status IN ('QUEUED', 'RUNNING')"
            )
            return try rows.map { row in
                let events = try AgentJobEventRow.fetchAll(
                    db, sql: "SELECT * FROM agent_job_events WHERE job_id = ? ORDER BY seq",
                    arguments: [row.id]
                )
                return try row.toAgentJob(events: events)
            }
        }
    }

    /// 检查点（seq 升序）。
    func checkpoints(jobID: String) throws -> [AgentJobCheckpointState] {
        try database.queue.read { db in
            let rows = try AgentCheckpointRow.fetchAll(
                db, sql: "SELECT * FROM agent_checkpoints WHERE job_id = ? ORDER BY seq",
                arguments: [jobID]
            )
            return try rows.map { row in
                let payload = try CanonicalColumnCodec.decodeJSON(
                    CheckpointPayload.self, from: row.stateJSON
                )
                return AgentJobCheckpointState(
                    seq: row.seq,
                    step: payload.step,
                    stateJSON: payload.state,
                    createdAt: try CanonicalColumnCodec.decodeTimestamp(row.createdAt)
                )
            }
        }
    }

    /// 最近活动时间 = max(最后事件, 最后检查点)——活跃度判定的唯一锚点。
    func lastActivity(jobID: String) throws -> Date {
        try database.queue.read { db in
            let lastEvent = try String.fetchOne(
                db, sql: "SELECT MAX(occurred_at) FROM agent_job_events WHERE job_id = ?",
                arguments: [jobID]
            )
            let lastCheckpoint = try String.fetchOne(
                db, sql: "SELECT MAX(created_at) FROM agent_checkpoints WHERE job_id = ?",
                arguments: [jobID]
            )
            let candidates = [lastEvent, lastCheckpoint]
                .compactMap { $0 }
                .compactMap { try? CanonicalColumnCodec.decodeTimestamp($0) }
            return candidates.max() ?? .distantPast
        }
    }

    /// 列表读面（createdAt 降序）。
    func summaries(limit: Int) throws -> [AgentJobSummary] {
        try database.queue.read { db in
            let rows = try AgentJobRow.fetchAll(
                db, sql: "SELECT * FROM agent_jobs ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            )
            return try rows.map { row in
                let lastEvent = try String.fetchOne(
                    db, sql: "SELECT MAX(occurred_at) FROM agent_job_events WHERE job_id = ?",
                    arguments: [row.id]
                )
                let lastCheckpoint = try String.fetchOne(
                    db, sql: "SELECT MAX(created_at) FROM agent_checkpoints WHERE job_id = ?",
                    arguments: [row.id]
                )
                let candidates = [lastEvent, lastCheckpoint]
                    .compactMap { $0 }
                    .compactMap { try? CanonicalColumnCodec.decodeTimestamp($0) }
                // fingerprint 从幂等键 workflow|fingerprint 提取（codec 同式）
                let fingerprint = row.idempotencyKey.flatMap { key -> String? in
                    guard let pipe = key.firstIndex(of: "|") else { return nil }
                    return String(key[key.index(after: pipe)...])
                } ?? ""
                return AgentJobSummary(
                    id: row.id,
                    workflow: row.workflow,
                    status: try row.decodedStatus(),
                    attempt: Self.attemptNumber(of: fingerprint),
                    baseFingerprint: Self.baseFingerprint(of: fingerprint),
                    createdAt: try CanonicalColumnCodec.decodeTimestamp(row.createdAt),
                    startedAt: try row.startedAt.map { try CanonicalColumnCodec.decodeTimestamp($0) },
                    completedAt: try row.completedAt.map { try CanonicalColumnCodec.decodeTimestamp($0) },
                    errorMessage: row.errorMessage,
                    lastActivityAt: try (candidates.max()
                        ?? CanonicalColumnCodec.decodeTimestamp(row.createdAt))
                )
            }
        }
    }

    // MARK: 私有

    private struct CheckpointPayload: Codable {
        let step: String
        let state: String
    }

    private func readJob(sql: String, arguments: StatementArguments) throws -> AgentJob? {
        try database.queue.read { db in
            guard let row = try AgentJobRow.fetchOne(db, sql: sql, arguments: arguments) else {
                return nil
            }
            let events = try AgentJobEventRow.fetchAll(
                db, sql: "SELECT * FROM agent_job_events WHERE job_id = ? ORDER BY seq",
                arguments: [row.id]
            )
            return try row.toAgentJob(events: events)
        }
    }

    /// 行构造（inputJSON 全量形态：指纹 + 原始输入）。
    private static func row(for job: AgentJob, inputJSON: String) throws -> AgentJobRow {
        let inputDict = try CanonicalColumnCodec.encodeJSON(
            ["fingerprint": job.inputFingerprint, "input": inputJSON]
        )
        return AgentJobRow(
            id: job.id,
            workflow: job.workflowKind,
            idempotencyKey: "\(job.workflowKind)|\(job.inputFingerprint)",
            status: AgentJobRow.statusColumn(for: job.state),
            inputJSON: inputDict,
            createdAt: CanonicalColumnCodec.encodeTimestamp(job.createdAt),
            startedAt: nil,
            completedAt: nil,
            errorMessage: nil
        )
    }
}
