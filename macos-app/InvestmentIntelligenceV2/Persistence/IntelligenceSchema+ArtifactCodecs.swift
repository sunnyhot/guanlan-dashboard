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

    /// 幂等写入（二轮 P1-5 + 三轮 P1-2）：不存在 → 插入 row + 依赖行；
    /// 已存在且**语义内容**一致（kind / validity / payload 语义字段 /
    /// 依赖行）→ no-op（保留首次 producedAt——ID 不含它，稍后重算同语义
    /// 不应触发冲突）；语义不一致 → conflict 抛错。
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
            return  // 幂等 no-op（existing 的 producedAt 即首次产出时间）
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
        if existing.validityPolicyJSON != incoming.row.validityPolicyJSON {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "validity_policy_json")
        }
        // 三轮 P1-2:payload 比较剥离 producedAt 字段——ID 的语义域不含产出
        // 时间,同语义稍后重算(producedAt 不同)必须幂等通过
        if Self.semanticPayloadFingerprint(existing.payloadJSON)
            != Self.semanticPayloadFingerprint(incoming.row.payloadJSON) {
            throw ArtifactWriteError.conflict(artifactID: existing.id, field: "payload_json(semantic)")
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

// MARK: - 语义 payload 指纹（三轮 P1-2）

extension ArtifactRow {
    /// payload JSON → 剥离 producedAt 后的语义指纹（JSONSerialization
    /// 确定性重序列化；解析失败回退原文——保持 fail-closed 的比较语义）。
    fileprivate static func semanticPayloadFingerprint(_ payloadJSON: String) -> String {
        guard let data = payloadJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return "raw|\(payloadJSON)"
        }
        var semantic = object
        semantic.removeValue(forKey: "producedAt")
        if let sorted = (try? JSONSerialization.data(
            withJSONObject: semantic, options: [.sortedKeys]
        )) {
            return String(decoding: sorted, as: UTF8.self)
        }
        return "raw|\(payloadJSON)"
    }
}

// MARK: - fail-closed 读回入口（五轮 P1-4 + 六轮 P1 收紧）

enum ArtifactReadError: Error, Equatable, Sendable {
    case notFound(id: String)
    case kindMismatch(expected: String, actual: String)
    /// payload 的 id 与行 id 不一致（行被篡改或错行）
    case identityMismatch(field: String)
    /// 依赖行与 payload 内 dependencies 分歧（split-brain——失效索引
    /// 与业务读回使用两套事实）
    case dependencyDivergence(artifactID: String)
}

extension ArtifactRow {
    /// fail-closed 读回：行 + 依赖表行 + payload 三方一致才返回领域对象。
    /// **唯一公开的读回入口**（六轮 P1：payload-only 便捷解码已隐藏——
    /// 依赖表被篡改后，任何绕过依赖行校验的解码路径都不存在）。
    /// 校验：① kind；② payload 解出的 domain.id == 行 id；③ validity
    /// JSON == 行列；④ producedAt 列与 payload 时间的毫秒编码**逐字相等**
    /// （重编码比较，不再容差 2ms——同毫秒内不可区分是列精度上限，
    /// 跨毫秒漂移一律拒）；⑤ 依赖行（按 dep_index 排序且从 0 连续）
    /// 与 domain.dependencies 逐字段（kind/referenceID/version）相等
    /// ——结构化比较，不做分隔符拼接；依赖表缺失 / 多余 / 错行 / 断号
    /// 都抛 dependencyDivergence。
    static func fetchDomain<A: Artifact & Decodable>(
        _ type: A.Type,
        id: String,
        expectedKind: String,
        from db: Database
    ) throws -> A {
        guard let row = try ArtifactRow.fetchOne(
            db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [id]
        ) else {
            throw ArtifactReadError.notFound(id: id)
        }
        guard row.artifactKind == expectedKind else {
            throw ArtifactReadError.kindMismatch(expected: expectedKind, actual: row.artifactKind)
        }
        let domain = try row.toDomain(A.self, expectedKind: expectedKind)
        guard domain.id.rawValue == row.id else {
            throw ArtifactReadError.identityMismatch(field: "payload.id ≠ row.id")
        }
        guard row.validityPolicyJSON == (try CanonicalColumnCodec.encodeJSON(domain.validityPolicy)) else {
            throw ArtifactReadError.identityMismatch(field: "validity_policy_json 与 payload 分歧")
        }
        // producedAt：域时间重新毫秒编码后与列**逐字相等**（编码确定性，
        // 同一时刻必同串；列只到毫秒精度，同毫秒内为精度上限）
        guard row.producedAt == CanonicalColumnCodec.encodeTimestamp(domain.producedAt) else {
            throw ArtifactReadError.identityMismatch(field: "produced_at 与 payload 分歧")
        }
        // 依赖行：dep_index 从 0 连续 + 与 domain.dependencies 逐字段相等
        let depRows = try ArtifactDependencyRow
            .filter(Column("artifact_id") == row.id)
            .order(Column("dep_index"))
            .fetchAll(db)
        guard depRows.count == domain.dependencies.count,
              zip(depRows, domain.dependencies).enumerated()
                .allSatisfy({ index, pair in pair.0.depIndex == index })
        else {
            throw ArtifactReadError.dependencyDivergence(artifactID: row.id)
        }
        for (depRow, dep) in zip(depRows, domain.dependencies) {
            guard depRow.kind == dep.kind.rawValue,
                  depRow.referenceID == dep.referenceID,
                  depRow.version == dep.version
            else {
                throw ArtifactReadError.dependencyDivergence(artifactID: row.id)
            }
        }
        return domain
    }
}

// MARK: - 六类 typed fetch（DB-backed，唯一公开读回形态）

extension ArtifactRow {
    static func fetchFactorSnapshot(id: String, from db: Database) throws -> FactorSnapshot {
        try fetchDomain(FactorSnapshot.self, id: id, expectedKind: factorSnapshotKind, from: db)
    }
    static func fetchLookthroughSnapshot(id: String, from db: Database) throws -> LookthroughSnapshot {
        try fetchDomain(LookthroughSnapshot.self, id: id, expectedKind: lookthroughSnapshotKind, from: db)
    }
    static func fetchExposureReport(id: String, from db: Database) throws -> ExposureReport {
        try fetchDomain(ExposureReport.self, id: id, expectedKind: exposureReportKind, from: db)
    }
    static func fetchRiskProfile(id: String, from db: Database) throws -> PortfolioRiskProfile {
        try fetchDomain(PortfolioRiskProfile.self, id: id, expectedKind: riskProfileKind, from: db)
    }
    static func fetchDailyAttribution(id: String, from db: Database) throws -> DailyAttribution {
        try fetchDomain(DailyAttribution.self, id: id, expectedKind: dailyAttributionKind, from: db)
    }
    static func fetchPortfolioDecision(id: String, from db: Database) throws -> PortfolioDecisionArtifact {
        try fetchDomain(PortfolioDecisionArtifact.self, id: id, expectedKind: portfolioDecisionKind, from: db)
    }
}

// MARK: - 六类写入入口

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

    /// payload-only 解码（六轮 P1：**私有**——不读依赖表即返回领域对象，
    /// 会绕过 fetchDomain 的三方一致校验；外部读回一律走 typed fetch）。
    private func toDomain<A: Artifact & Decodable>(
        _ type: A.Type, expectedKind: String
    ) throws -> A {
        guard artifactKind == expectedKind else {
            throw CanonicalColumnCodecError.unknownEnumValue(
                column: "artifact_kind", rawValue: artifactKind
            )
        }
        return try CanonicalColumnCodec.decodeJSON(A.self, from: payloadJSON)
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
        /// 身份闭环失败（三轮 P2-8）：派生 ID / 幂等键 / 事件归属 / 首事件时间
        case identityMismatch(field: String)
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
        // 三轮 P2-8:身份闭环——事件必须归属本 job、首事件时间 == 行 createdAt
        for event in ordered where event.jobID != id {
            throw JobCodecError.identityMismatch(field: "event.jobID \(event.jobID) ≠ 行 id \(id)")
        }
        if let firstEvent = ordered.first,
           firstEvent.occurredAt != CanonicalColumnCodec.encodeTimestamp(createdAtDate) {
            throw JobCodecError.identityMismatch(field: "首事件 occurredAt ≠ 行 created_at")
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
        // 三轮 P2-8:派生 ID 与幂等键闭环(混入他作业的事件 / 篡改身份列在此拒收)
        guard job.id == id else {
            throw JobCodecError.identityMismatch(field: "派生 job.id \(job.id) ≠ 行 id \(id)")
        }
        guard idempotencyKey == "\(workflow)|\(fingerprint)" else {
            throw JobCodecError.identityMismatch(field: "idempotency_key 与 workflow|fingerprint 不一致")
        }
        // 行 started/completed/errorMessage 冗余列与事件时间线**完整相等**
        // (四轮 P2-6:Optional 两侧都必须一致——删掉列值保留事件、或反之,
        // 都不再静默通过;FAILED 的 errorMessage 与事件 detail 核对)
        let expectedStarted = ordered
            .first(where: { $0.kind == AgentEvent.Kind.started.rawValue })?.occurredAt
        guard startedAt == expectedStarted else {
            throw JobCodecError.identityMismatch(field: "started_at 列(\(startedAt ?? "nil"))与 STARTED 事件时间(\(expectedStarted ?? "nil"))不一致")
        }
        let expectedCompleted = ordered
            .last(where: { [AgentEvent.Kind.completed, .failed, .cancelled]
                .map(\.rawValue).contains($0.kind) })?.occurredAt
        guard completedAt == expectedCompleted else {
            throw JobCodecError.identityMismatch(field: "completed_at 列(\(completedAt ?? "nil"))与终态事件时间(\(expectedCompleted ?? "nil"))不一致")
        }
        let expectedError = ordered
            .first(where: { $0.kind == AgentEvent.Kind.failed.rawValue })
            .flatMap { try? CanonicalColumnCodec.decodeJSON(EventPayload.self, from: $0.payloadJSON) }?.detail
        guard errorMessage == expectedError else {
            throw JobCodecError.identityMismatch(field: "error_message 列与 FAILED 事件 detail 不一致")
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
