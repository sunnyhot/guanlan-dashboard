import Foundation
import GRDB

// MARK: - Epic 7–10 具体 Artifact 的 GRDB codec（审查 P1-2 修复）
//
// ArtifactRow 通用形状（id/kind/producedAt/validityPolicy/payload）承接
// 五类领域 Artifact：payload = 领域对象完整 JSON（dependencies 字段
// 自包含于 payload），artifact_dependencies 表行同步写入作为失效传播
// 索引（(kind, reference_id) 反查受影响 artifacts）。
//
// 不触碰任何已发布 migration（AGENTS.md 坑点 18：迁移只追加不改写）——
// 本文件只新增 Swift codec 代码。
//
// AgentJob 桥：ATTR-4 的 AgentJob/AgentEvent 映射到既有 agent_jobs /
// agent_job_events 表（status 值域一致：QUEUED/RUNNING/COMPLETED/
// FAILED/CANCELLED）。

// MARK: - Artifact 领域 kind 常量

extension ArtifactRow {
    static let factorSnapshotKind = "FACTOR_SNAPSHOT"
    static let exposureReportKind = "EXPOSURE_REPORT"
    static let riskProfileKind = "RISK_PROFILE"
    static let dailyAttributionKind = "DAILY_ATTRIBUTION"
    static let portfolioDecisionKind = "PORTFOLIO_DECISION"
}

// MARK: - 通用 codec（事务性写入 row + dependencies）

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

    /// 写入 row + 全部依赖行。**原子性由调用方的事务保证**（GRDB 的
    /// DatabaseQueue.write / db.inTransaction 均已包事务；GRDB 不支持
    /// 嵌套事务，本方法不自开）。
    static func write(
        _ pair: (row: ArtifactRow, dependencies: [ArtifactDependencyRow]),
        into db: Database
    ) throws {
        try pair.row.insert(db)
        for dep in pair.dependencies {
            try dep.insert(db)
        }
    }
}

// MARK: - 五类便捷入口

extension ArtifactRow {
    static func from(_ domain: FactorSnapshot) throws -> (row: ArtifactRow, dependencies: [ArtifactDependencyRow]) {
        try from(domain, kind: factorSnapshotKind)
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

// MARK: - AgentJob ↔ agent_jobs 行桥

extension AgentJobRow {
    /// AgentJobState（小写 rawValue）→ agent_jobs.status 列（大写）。
    private static func statusColumn(for state: AgentJobState) -> String {
        switch state {
        case .queued: return AgentJobStatus.queued.rawValue
        case .running: return AgentJobStatus.running.rawValue
        case .completed: return AgentJobStatus.completed.rawValue
        case .failed: return AgentJobStatus.failed.rawValue
        case .cancelled: return AgentJobStatus.cancelled.rawValue
        }
    }

    /// ATTR-4 AgentJob → 行（状态列大写映射 AgentJobStatus 值域）。
    /// input_json 存 fingerprint 的 JSON（工作流输入快照由调用方另存
    /// agent_checkpoints / 业务表——job 行本身只记身份与生命周期）。
    static func from(job: AgentJob) throws -> AgentJobRow {
        AgentJobRow(
            id: job.id,
            workflow: job.workflowKind,
            idempotencyKey: job.inputFingerprint,
            status: statusColumn(for: job.state),
            inputJSON: try CanonicalColumnCodec.encodeJSON(["fingerprint": job.inputFingerprint]),
            createdAt: CanonicalColumnCodec.encodeTimestamp(job.createdAt),
            startedAt: Self.encodedTime(job.events, kind: .started),
            completedAt: Self.encodedTime(job.events, kinds: [.completed, .failed, .cancelled]),
            errorMessage: job.events.first(where: { $0.kind == .failed })?.detail
        )
    }

    private static func encodedTime(_ events: [AgentEvent], kind: AgentEvent.Kind) -> String? {
        guard let event = events.first(where: { $0.kind == kind }) else { return nil }
        return CanonicalColumnCodec.encodeTimestamp(event.timestamp)
    }

    private static func encodedTime(_ events: [AgentEvent], kinds: Set<AgentEvent.Kind>) -> String? {
        guard let event = events.last(where: { kinds.contains($0.kind) }) else { return nil }
        return CanonicalColumnCodec.encodeTimestamp(event.timestamp)
    }

    /// 事件行（seq 按时间线顺序）。
    static func eventRows(for job: AgentJob) -> [AgentJobEventRow] {
        job.events.enumerated().map { index, event in
            AgentJobEventRow(
                jobID: job.id,
                seq: index,
                occurredAt: CanonicalColumnCodec.encodeTimestamp(event.timestamp),
                kind: event.kind.rawValue,
                payloadJSON: "\"\(event.detail ?? "")\""
            )
        }
    }
}
