import Foundation
import GRDB

// MARK: - Epic 7–10 具体 Artifact 的 GRDB codec（审查 P1-2 修复 + 二轮 P1-5/6）
//
// ArtifactRow 通用形状（id/kind/producedAt/validityPolicy/payload）承接
// 六类领域 Artifact：payload = 领域对象完整 JSON（dependencies 字段
// 自包含于 payload），artifact_dependencies 表行同步写入作为失效传播
// 索引（(kind, reference_id) 反查受影响 artifacts）。
//
// 写入语义（二轮审查 P1-5）：**幂等**——同一语义 ID 重放第二次：
// 已存在且内容（kind/producedAt/validity/payload + 依赖行）完全一致 →
// no-op；内容不一致 → ArtifactWriteError.conflict（不静默覆盖）。
//
// 不触碰任何已发布 migration（AGENTS.md 坑点 18）——本文件只新增 Swift
// codec 代码。
//
// AgentJob 桥（二轮审查 P1-6）：双向 codec——AgentJob/AgentEvent ↔
// agent_jobs / agent_job_events 行；idempotency_key 使用「workflow|指纹」
// 全局键（不同 workflow 同指纹不再撞 UNIQUE）；event detail 经 JSON 编码
// （nil vs 空串语义保留，不再字符串拼接）。

// MARK: - Artifact 领域 kind 常量

extension ArtifactRow {
    static let factorSnapshotKind = "FACTOR_SNAPSHOT"
    static let lookthroughSnapshotKind = "LOOKTHROUGH_SNAPSHOT"
    static let exposureReportKind = "EXPOSURE_REPORT"
    static let riskProfileKind = "RISK_PROFILE"
    static let dailyAttributionKind = "DAILY_ATTRIBUTION"
    static let portfolioDecisionKind = "PORTFOLIO_DECISION"
}

// MARK: - 写入语义

enum ArtifactWriteError: Error, Equatable, Sendable {
    /// 同 ID 已存在但内容不一致（重放语义被破坏——上游确定性出问题）
    case conflict(artifactID: String, field: String)
}

extension ArtifactRow {
    /// 任意具体 Artifact → (row, dependency 行集)。
    /// payload 含领域对象全部字段（dependencies 自包含）；依赖表行按
    /// domain.dependencies 顺序生成（dep_index 稳定）。
    static func from<A: Artifact & Encodable>(
        _ domain: A, kind: String
    ) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        let row = ArtifactRow(
            id: domain.id.rawValue,
            artifactKind: kind,
            producedAt: CanonicalColumnCodec.encodeTimestamp(domain.producedAt),
            validityPolicyJSON: try CanonicalColumnCodec.encodeJSON(domain.validityPolicy),
            payloadJSON: try CanonicalColumnCodec.encodeJSON(domain)
        )
        let deps = domain.dependencies.enumerated().map { index, dep in
            ArtifactDependencyRow(
                artifactID: domain.id.rawValue,
                depIndex: index,
                kind: dep.kind.rawValue,
                referenceID: dep.referenceID,
                version: dep.version
            )
        }
        return (row, deps)
    }

    /// row + 依赖行 → 领域对象（payload 自包含 decode；kind 校验 fail-closed）。
    func toDomain<A: Artifact & Decodable>(
        _ type: A.Type, expectedKind: String
    ) throws -> A {
        guard artifactKind == expectedKind else {
            throw CanonicalColumnCodecError.unknownEnumValue(
                column: "artifact_kind", rawValue: artifactKind
            )
        }
        return try CanonicalColumnCodec.decodeJSON(A.self, from: payloadJSON)
    }

    /// 幂等写入（二轮审查 P1-5）：不存在 → 插入 row + 依赖行；已存在且
    /// 内容完全一致（含依赖行）→ no-op；不一致 → conflict 抛错。
    /// 原子性由调用方事务保证（DatabaseQueue.write 已包事务；GRDB 不支持
    /// 嵌套事务，本方法不自开）。
    static func write(
        _ pair: (row: ArtifactRow, dependencies: [ArtifactDependencyRow]),
        into db: Database
    ) throws {
        if let existing = try ArtifactRow.fetchOne(
            db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [pair.row.id]
        ) {
            try ensureIdentical(existing: existing, incoming: pair, into: db)
            return  // 幂等 no-op
        }
        try pair.row.insert(db)
        for dep in pair.dependencies {
            try dep.insert(db)
        }
    }

    private static func ensureIdentical(
        existing: ArtifactRow,
        incoming: (row: ArtifactRow, dependencies: [ArtifactDependencyRow]),
        into db: Database
    ) throws {
        if existing.artifactKind != incoming.row.artifactKind {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "artifact_kind")
        }
        if existing.producedAt != incoming.row.producedAt {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "produced_at")
        }
        if existing.validityPolicyJSON != incoming.row.validityPolicyJSON {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "validity_policy_json")
        }
        if existing.payloadJSON != incoming.row.payloadJSON {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "payload_json")
        }
        let existingDeps = try ArtifactDependencyRow
            .filter(Column("artifact_id") == existing.id)
            .order(Column("dep_index"))
            .fetchAll(db)
        let incomingDeps = incoming.dependencies.sorted { $0.depIndex < $1.depIndex }
        guard existingDeps.count == incomingDeps.count else {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "dependencies.count")
        }
        for (a, b) in zip(existingDeps, incomingDeps) {
            if a.kind != b.kind || a.referenceID != b.referenceID || a.version != b.version {
                throw ArtifactWriteError.conflict(artifactID: existing.id, field: "dependencies[\(a.depIndex)]")
            }
        }
    }
}

// MARK: - 六类便捷入口

extension ArtifactRow {
    static func from(_ domain: FactorSnapshot) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: factorSnapshotKind)
    }
    static func from(_ domain: LookthroughSnapshot) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: lookthroughSnapshotKind)
    }
    static func from(_ domain: ExposureReport) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: exposureReportKind)
    }
    static func from(_ domain: PortfolioRiskProfile) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: riskProfileKind)
    }
    static func from(_ domain: DailyAttribution) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: dailyAttributionKind)
    }
    static func from(_ domain: PortfolioDecisionArtifact) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: portfolioDecisionKind)
    }

    func toFactorSnapshot() throws -> FactorSnapshot {
        try toDomain(FactorSnapshot.self, expectedKind: Self.factorSnapshotKind)
    }
    func toLookthroughSnapshot() throws -> LookthroughSnapshot {
        try toDomain(LookthroughSnapshot.self, expectedKind: Self.lookthroughSnapshotKind)
    }
    func toExposureReport() throws -> ExposureReport {
        try toDomain(ExposureReport.self, expectedKind: Self.exposureReportKind)
    }
    func toRiskProfile() throws -> PortfolioRiskProfile {
        try toDomain(PortfolioRiskProfile.self, expectedKind: Self.riskProfileKind)
    }
    func toDailyAttribution() throws -> DailyAttribution {
        try toDomain(DailyAttribution.self, expectedKind: Self.dailyAttributionKind)
    }
    func toPortfolioDecision() throws -> PortfolioDecisionArtifact {
        try toDomain(PortfolioDecisionArtifact.self, expectedKind: Self.portfolioDecisionKind)
    }
}

// MARK: - AgentJob ↔ agent_jobs 行桥（双向）

extension AgentJobRow {
    enum JobCodecError: Error, Equatable, Sendable {
        /// 事件行首条不是 QUEUED（时间线不完整）
        case malformedEventTimeline(firstKind: String)
        /// 事件 kind 未知
        case unknownEventKind(String)
        /// 重建后的 job 终态与行 status 不一致
        case statusMismatch(rebuilt: String, row: String)
        /// 事件 seq 不连续
        case nonContiguousSeq([Int])
        /// input_json 缺 fingerprint
        case malformedInputJSON(String)
    }

    /// 事件 payload（JSON 编码，nil vs 空串语义保留——二轮审查 P1-6）。
    struct EventPayload: Codable, Hashable {
        let detail: String?
    }

    /// AgentJobState（小写 rawValue）→ agent_jobs.status 列（大写）。
    static func statusColumn(for state: AgentJobState) -> String {
        switch state {
        case .queued: return AgentJobStatus.queued.rawValue
        case .running: return AgentJobStatus.running.rawValue
        case .completed: return AgentJobStatus.completed.rawValue
        case .failed: return AgentJobStatus.failed.rawValue
        case .cancelled: return AgentJobStatus.cancelled.rawValue
        }
    }

    /// ATTR-4 AgentJob → 行。
    /// idempotency_key 使用「workflow|指纹」全局键（不同 workflow 的同
    /// 指纹不再撞 UNIQUE——二轮审查 P1-6）；input_json 存指纹 JSON。
    static func from(job: AgentJob) throws -> AgentJobRow {
        AgentJobRow(
            id: job.id,
            workflow: job.workflowKind,
            idempotencyKey: "\(job.workflowKind)|\(job.inputFingerprint)",
            status: statusColumn(for: job.state),
            inputJSON: try CanonicalColumnCodec.encodeJSON(["fingerprint": job.inputFingerprint]),
            createdAt: CanonicalColumnCodec.encodeTimestamp(job.createdAt),
            startedAt: Self.encodedTime(job.events, kind: .started),
            completedAt: Self.encodedTime(job.events, kinds: [.completed, .failed, .cancelled]),
            errorMessage: job.events.first(where: { $0.kind == .failed })?.detail
        )
    }

    /// 事件行（seq 按时间线顺序；payload 经 JSON 编码器——引号/反斜杠/
    /// 换行安全转义，nil 不降格为空串）。
    static func eventRows(for job: AgentJob) throws -> [AgentJobEventRow] {
        try job.events.enumerated().map { index, event in
            AgentJobEventRow(
                jobID: job.id,
                seq: index,
                occurredAt: CanonicalColumnCodec.encodeTimestamp(event.timestamp),
                kind: event.kind.rawValue,
                payloadJSON: try CanonicalColumnCodec.encodeJSON(EventPayload(detail: event.detail))
            )
        }
    }

    /// 反向 codec（二轮审查 P1-6）：job 行 + 事件行 → AgentJob 领域对象。
    /// 从 (workflow, fingerprint, createdAt) 重建（id 自动派生一致），
    /// 按事件时间线重放状态迁移；重建终态必须与行 status 一致，否则抛错。
    func toAgentJob(events: [AgentJobEventRow]) throws -> AgentJob {
        let seqs = events.map(\.seq)
        guard seqs == Array(0..<events.count) else {
            throw JobCodecError.nonContiguousSeq(seqs)
        }
        let ordered = events.sorted { $0.seq < $1.seq }
        guard let first = ordered.first, first.kind == AgentEvent.Kind.queued.rawValue else {
            throw JobCodecError.malformedEventTimeline(firstKind: ordered.first?.kind ?? "∅")
        }
        guard let decoded = try? CanonicalColumnCodec
            .decodeJSON([String: String].self, from: inputJSON),
            let fingerprint = decoded["fingerprint"]
        else {
            throw JobCodecError.malformedInputJSON(inputJSON)
        }

        let createdAtDate: Date
        do {
            createdAtDate = try CanonicalColumnCodec.decodeTimestamp(createdAt)
        } catch {
            throw CanonicalColumnCodecError.malformedTimestamp(createdAt)
        }
        var job = AgentJob(
            workflowKind: workflow,
            inputFingerprint: fingerprint,
            createdAt: createdAtDate
        )
        // 跳过首条 QUEUED（init 已含），按时间线重放迁移
        for event in ordered.dropFirst() {
            guard let kind = AgentEvent.Kind(rawValue: event.kind) else {
                throw JobCodecError.unknownEventKind(event.kind)
            }
            let detail = try CanonicalColumnCodec
                .decodeJSON(EventPayload.self, from: event.payloadJSON).detail
            let next: AgentJobState
            switch kind {
            case .queued: continue
            case .started: next = .running
            case .completed: next = .completed
            case .failed: next = .failed
            case .cancelled: next = .cancelled
            }
            try job.transition(
                to: next,
                at: CanonicalColumnCodec.decodeTimestamp(event.occurredAt),
                detail: detail
            )
        }
        let rebuiltStatus = Self.statusColumn(for: job.state)
        guard rebuiltStatus == status else {
            throw JobCodecError.statusMismatch(rebuilt: rebuiltStatus, row: status)
        }
        return job
    }

    private static func encodedTime(_ events: [AgentEvent], kind: AgentEvent.Kind) -> String? {
        guard let event = events.first(where: { $0.kind == kind }) else { return nil }
        return CanonicalColumnCodec.encodeTimestamp(event.timestamp)
    }

    private static func encodedTime(_ events: [AgentEvent], kinds: Set<AgentEvent.Kind>) -> String? {
        guard let event = events.last(where: { kinds.contains($0.kind) }) else { return nil }
        return CanonicalColumnCodec.encodeTimestamp(event.timestamp)
    }
}
