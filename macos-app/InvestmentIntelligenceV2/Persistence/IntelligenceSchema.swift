import Foundation
import GRDB

// MARK: - IntelligenceSchema（GRDB-6，Intelligence / Decision / Agent 域）
//
// 10 张表：evidence / evidence_facts / signals / theses / artifacts /
// artifact_dependencies / decisions / agent_jobs / agent_job_events /
// agent_checkpoints。
//
// 分两类：
// 1. **有领域类型的表**（codec 完整）：evidence（EvidenceObservation）、
//    evidence_facts（EvidenceFact）、signals（InvestmentSignal）、
//    artifacts + artifact_dependencies（Artifact 协议，当前以
//    PlaceholderArtifact 为 codec 载体，Epic 7-10 各具体 Artifact 补 codec）。
// 2. **通用形状表**（领域类型在 Epic 10/11/13 落）：theses / decisions /
//    agent_jobs / agent_job_events / agent_checkpoints——按 rollout 的
//    行为契约（WF-1 论点图、DEC-9 replay 引用、AGENT-1 checkpoint 恢复、
//    ATTR-4 Job 生命周期）定列，payload 先 JSON；对应 story 落地领域类型时
//    在 row codec 上补 toDomain，schema 列不改（只追加 migration）。
//
// 关键语义：
// - **EvidenceID 是逻辑身份**（V3.1 §53）：evidence 表同时存 ObservationID
//   （行主键）与 EvidenceID（UNIQUE）；下游引用（evidence_facts / signals 的
//   derivedFrom）一律用 EvidenceID——DailyBar 的 ObservationID 无法冒充。
// - **Signal ≠ Evidence 分开存储**（V3.1 §38）：signals 独立表，
//   derivedFrom 以 EvidenceID 数组携带溯源；不建跨表 FK（JSON 数组做不到
//   行级 FK，完整性由 RES-5 Validation + RES-8 Evidence Matcher 保证——
//   「LLM 无法生成不存在的 evidence ID」是 M8 验收项）。
// - **artifact_dependencies 规范化**（不进 JSON）：失效传播查询
//   「dependency 变化 → 受影响 artifacts」需要按 (kind, reference_id) 索引，
//   这是 untilDependencyChanges 策略的存储基础。
// - **agent_jobs.idempotency_key UNIQUE（可空）**：AGENT-1 的 idempotency
//   语义库级兜底；NULL 不参与唯一（一个 workflow 可有无 key 的手工运行）。

/// Intelligence / Decision / Agent 域 schema（migration v6_intelligence 建表体）。
enum IntelligenceSchema {

    /// 建全部 Intelligence 域表 + 索引（migration v6_intelligence 调用；只追加）。
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE evidence (
                id                      TEXT PRIMARY KEY NOT NULL,
                evidence_id             TEXT NOT NULL UNIQUE,
                \(ObservationEnvelopeColumns.ddlColumns),
                content                 TEXT NOT NULL,
                source                  TEXT NOT NULL,
                subject_entity_type     TEXT NOT NULL,
                subject_entity_id       TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX evidence_subject_idx ON evidence(subject_entity_type, subject_entity_id)
            """)

        try db.execute(sql: """
            CREATE TABLE evidence_facts (
                id                      TEXT PRIMARY KEY NOT NULL,
                evidence_id             TEXT NOT NULL REFERENCES evidence(evidence_id),
                statement               TEXT NOT NULL,
                extraction_method       TEXT NOT NULL,
                verification_status     TEXT NOT NULL,
                subject_entity_type     TEXT NOT NULL,
                subject_entity_id       TEXT NOT NULL,
                numeric_value           TEXT,
                numeric_unit            TEXT
            )
            """)
        try db.execute(sql: """
            CREATE INDEX evidence_facts_evidence_idx ON evidence_facts(evidence_id)
            """)
        try db.execute(sql: """
            CREATE INDEX evidence_facts_subject_idx
                ON evidence_facts(subject_entity_type, subject_entity_id)
            """)

        try db.execute(sql: """
            CREATE TABLE signals (
                id                          TEXT PRIMARY KEY NOT NULL,
                subject_entity_type         TEXT NOT NULL,
                subject_entity_id           TEXT NOT NULL,
                dimension                   TEXT NOT NULL,
                direction                   TEXT NOT NULL,
                strength                    TEXT NOT NULL,
                derived_from_evidence_ids   TEXT NOT NULL,
                effective_at                TEXT NOT NULL,
                producer_kind               TEXT NOT NULL,
                producer_model_identifier   TEXT,
                rationale                   TEXT
            )
            """)
        try db.execute(sql: """
            CREATE INDEX signals_subject_idx ON signals(subject_entity_type, subject_entity_id)
            """)
        try db.execute(sql: """
            CREATE INDEX signals_effective_at_idx ON signals(effective_at)
            """)

        try db.execute(sql: """
            CREATE TABLE theses (
                id                        TEXT PRIMARY KEY NOT NULL,
                kind                      TEXT NOT NULL,
                subject_entity_type       TEXT NOT NULL,
                subject_entity_id         TEXT NOT NULL,
                statement                 TEXT NOT NULL,
                supporting_evidence_ids   TEXT NOT NULL,
                linked_signal_ids         TEXT NOT NULL,
                created_at                TEXT NOT NULL,
                revised_at                TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE artifacts (
                id                      TEXT PRIMARY KEY NOT NULL,
                artifact_kind           TEXT NOT NULL,
                produced_at             TEXT NOT NULL,
                validity_policy_json    TEXT NOT NULL,
                payload_json            TEXT NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE artifact_dependencies (
                artifact_id             TEXT NOT NULL REFERENCES artifacts(id),
                dep_index               INTEGER NOT NULL,
                kind                    TEXT NOT NULL,
                reference_id            TEXT NOT NULL,
                version                 TEXT,
                PRIMARY KEY (artifact_id, dep_index)
            )
            """)
        // 失效传播：dependency (kind, reference_id) 变化 → 找受影响 artifacts
        try db.execute(sql: """
            CREATE INDEX artifact_dependencies_reference_idx
                ON artifact_dependencies(kind, reference_id)
            """)

        try db.execute(sql: """
            CREATE TABLE decisions (
                id                        TEXT PRIMARY KEY NOT NULL,
                decision_kind             TEXT NOT NULL,
                produced_at               TEXT NOT NULL,
                action_plan_json          TEXT NOT NULL,
                referenced_signal_ids     TEXT NOT NULL,
                validity_policy_json      TEXT NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE agent_jobs (
                id                  TEXT PRIMARY KEY NOT NULL,
                workflow            TEXT NOT NULL,
                idempotency_key     TEXT UNIQUE,
                status              TEXT NOT NULL,
                input_json          TEXT NOT NULL,
                created_at          TEXT NOT NULL,
                started_at          TEXT,
                completed_at        TEXT,
                error_message       TEXT
            )
            """)
        try db.execute(sql: """
            CREATE INDEX agent_jobs_status_idx ON agent_jobs(status)
            """)

        try db.execute(sql: """
            CREATE TABLE agent_job_events (
                job_id          TEXT NOT NULL REFERENCES agent_jobs(id),
                seq             INTEGER NOT NULL,
                occurred_at     TEXT NOT NULL,
                kind            TEXT NOT NULL,
                payload_json    TEXT NOT NULL,
                PRIMARY KEY (job_id, seq)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE agent_checkpoints (
                job_id          TEXT NOT NULL REFERENCES agent_jobs(id),
                seq             INTEGER NOT NULL,
                created_at      TEXT NOT NULL,
                state_json      TEXT NOT NULL,
                PRIMARY KEY (job_id, seq)
            )
            """)
    }
}

// MARK: - AgentJobStatus（ATTR-4 / AGENT-1 的 Job 生命周期）

/// Agent Job 生命周期状态（rollout ATTR-4：queued/running/completed/failed/
/// cancelled）。AGENT-1 已迁至 Agent/AgentJob.swift（同模块移动，此处不再
/// 重复定义）。

// MARK: - 行类型（有领域类型的表）

struct EvidenceRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "evidence"

    let id: String
    let evidenceID: String
    let envelope: ObservationEnvelopeColumns
    let content: String
    let source: String
    let subjectEntityType: String
    let subjectEntityID: String

    init(row: Row) {
        id = row["id"]
        evidenceID = row["evidence_id"]
        envelope = ObservationEnvelopeColumns(row: row)
        content = row["content"]
        source = row["source"]
        subjectEntityType = row["subject_entity_type"]
        subjectEntityID = row["subject_entity_id"]
    }

    init(
        id: String,
        evidenceID: String,
        envelope: ObservationEnvelopeColumns,
        content: String,
        source: String,
        subjectEntityType: String,
        subjectEntityID: String
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.envelope = envelope
        self.content = content
        self.source = source
        self.subjectEntityType = subjectEntityType
        self.subjectEntityID = subjectEntityID
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["evidence_id"] = evidenceID
        envelope.encode(to: &container)
        container["content"] = content
        container["source"] = source
        container["subject_entity_type"] = subjectEntityType
        container["subject_entity_id"] = subjectEntityID
    }

    static func from(_ domain: EvidenceObservation) -> EvidenceRow {
        EvidenceRow(
            id: domain.id.rawValue,
            evidenceID: domain.evidenceID.rawValue,
            envelope: ObservationEnvelopeColumns(
                envelope: domain.temporalEnvelope,
                provenance: domain.availabilityProvenance,
                quality: domain.dataQuality,
                vintage: domain.vintage
            ),
            content: domain.content,
            source: domain.source.rawValue,
            subjectEntityType: domain.subjectCanonical.entityType,
            subjectEntityID: domain.subjectCanonical.entityIDRawValue
        )
    }

    func toDomain() throws -> EvidenceObservation {
        try EvidenceObservation(
            id: ObservationID(rawValue: id),
            evidenceID: EvidenceID(rawValue: evidenceID),
            temporalEnvelope: envelope.envelope(),
            availabilityProvenance: envelope.provenance(),
            dataQuality: envelope.quality(),
            vintage: envelope.vintage(),
            content: content,
            source: CanonicalColumnCodec.decodeEnum(
                EvidenceObservation.EvidenceSource.self, rawValue: source, column: "source"
            ),
            subjectCanonical: CanonicalRef(
                entityType: subjectEntityType, entityIDRawValue: subjectEntityID
            )
        )
    }
}

struct EvidenceFactRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "evidence_facts"

    let id: String
    let evidenceID: String
    let statement: String
    let extractionMethod: String
    let verificationStatus: String
    let subjectEntityType: String
    let subjectEntityID: String
    let numericValue: String?
    let numericUnit: String?

    init(row: Row) {
        id = row["id"]
        evidenceID = row["evidence_id"]
        statement = row["statement"]
        extractionMethod = row["extraction_method"]
        verificationStatus = row["verification_status"]
        subjectEntityType = row["subject_entity_type"]
        subjectEntityID = row["subject_entity_id"]
        numericValue = row["numeric_value"]
        numericUnit = row["numeric_unit"]
    }

    init(
        id: String,
        evidenceID: String,
        statement: String,
        extractionMethod: String,
        verificationStatus: String,
        subjectEntityType: String,
        subjectEntityID: String,
        numericValue: String?,
        numericUnit: String?
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.statement = statement
        self.extractionMethod = extractionMethod
        self.verificationStatus = verificationStatus
        self.subjectEntityType = subjectEntityType
        self.subjectEntityID = subjectEntityID
        self.numericValue = numericValue
        self.numericUnit = numericUnit
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["evidence_id"] = evidenceID
        container["statement"] = statement
        container["extraction_method"] = extractionMethod
        container["verification_status"] = verificationStatus
        container["subject_entity_type"] = subjectEntityType
        container["subject_entity_id"] = subjectEntityID
        container["numeric_value"] = numericValue
        container["numeric_unit"] = numericUnit
    }

    static func from(_ domain: EvidenceFact) -> EvidenceFactRow {
        EvidenceFactRow(
            id: domain.id.rawValue,
            evidenceID: domain.evidenceID.rawValue,
            statement: domain.statement,
            extractionMethod: domain.extractionMethod.rawValue,
            verificationStatus: domain.verificationStatus.rawValue,
            subjectEntityType: domain.subjectCanonical.entityType,
            subjectEntityID: domain.subjectCanonical.entityIDRawValue,
            numericValue: domain.numericValue.map { CanonicalColumnCodec.encodeDecimal($0) },
            numericUnit: domain.numericUnit
        )
    }

    func toDomain() throws -> EvidenceFact {
        try EvidenceFact(
            id: DomainID(rawValue: id),
            evidenceID: EvidenceID(rawValue: evidenceID),
            statement: statement,
            extractionMethod: CanonicalColumnCodec.decodeEnum(
                EvidenceExtractionMethod.self, rawValue: extractionMethod, column: "extraction_method"
            ),
            verificationStatus: CanonicalColumnCodec.decodeEnum(
                EvidenceVerificationStatus.self, rawValue: verificationStatus, column: "verification_status"
            ),
            subjectCanonical: CanonicalRef(
                entityType: subjectEntityType, entityIDRawValue: subjectEntityID
            ),
            numericValue: try numericValue.map { try CanonicalColumnCodec.decodeDecimal($0) },
            numericUnit: numericUnit
        )
    }
}

struct SignalRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "signals"

    let id: String
    let subjectEntityType: String
    let subjectEntityID: String
    let dimension: String
    let direction: String
    let strength: String
    let derivedFromEvidenceIDsJSON: String
    let effectiveAt: String
    let producerKind: String
    let producerModelIdentifier: String?
    let rationale: String?

    init(row: Row) {
        id = row["id"]
        subjectEntityType = row["subject_entity_type"]
        subjectEntityID = row["subject_entity_id"]
        dimension = row["dimension"]
        direction = row["direction"]
        strength = row["strength"]
        derivedFromEvidenceIDsJSON = row["derived_from_evidence_ids"]
        effectiveAt = row["effective_at"]
        producerKind = row["producer_kind"]
        producerModelIdentifier = row["producer_model_identifier"]
        rationale = row["rationale"]
    }

    init(
        id: String,
        subjectEntityType: String,
        subjectEntityID: String,
        dimension: String,
        direction: String,
        strength: String,
        derivedFromEvidenceIDsJSON: String,
        effectiveAt: String,
        producerKind: String,
        producerModelIdentifier: String?,
        rationale: String?
    ) {
        self.id = id
        self.subjectEntityType = subjectEntityType
        self.subjectEntityID = subjectEntityID
        self.dimension = dimension
        self.direction = direction
        self.strength = strength
        self.derivedFromEvidenceIDsJSON = derivedFromEvidenceIDsJSON
        self.effectiveAt = effectiveAt
        self.producerKind = producerKind
        self.producerModelIdentifier = producerModelIdentifier
        self.rationale = rationale
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["subject_entity_type"] = subjectEntityType
        container["subject_entity_id"] = subjectEntityID
        container["dimension"] = dimension
        container["direction"] = direction
        container["strength"] = strength
        container["derived_from_evidence_ids"] = derivedFromEvidenceIDsJSON
        container["effective_at"] = effectiveAt
        container["producer_kind"] = producerKind
        container["producer_model_identifier"] = producerModelIdentifier
        container["rationale"] = rationale
    }

    static func from(_ domain: InvestmentSignal) throws -> SignalRow {
        SignalRow(
            id: domain.id.rawValue,
            subjectEntityType: domain.subjectCanonical.entityType,
            subjectEntityID: domain.subjectCanonical.entityIDRawValue,
            dimension: domain.dimension.rawValue,
            direction: domain.direction.rawValue,
            strength: domain.strength.rawValue,
            derivedFromEvidenceIDsJSON: try CanonicalColumnCodec.encodeJSON(
                domain.derivedFromEvidenceIDs.map { $0.rawValue }
            ),
            effectiveAt: CanonicalColumnCodec.encodeTimestamp(domain.effectiveAt),
            producerKind: domain.producer.kind.rawValue,
            producerModelIdentifier: domain.producer.modelIdentifier,
            rationale: domain.rationale
        )
    }

    func toDomain() throws -> InvestmentSignal {
        try InvestmentSignal(
            id: SignalID(rawValue: id),
            subjectCanonical: CanonicalRef(
                entityType: subjectEntityType, entityIDRawValue: subjectEntityID
            ),
            dimension: CanonicalColumnCodec.decodeEnum(
                SignalDimension.self, rawValue: dimension, column: "dimension"
            ),
            direction: CanonicalColumnCodec.decodeEnum(
                SignalDirection.self, rawValue: direction, column: "direction"
            ),
            strength: CanonicalColumnCodec.decodeEnum(
                SignalStrength.self, rawValue: strength, column: "strength"
            ),
            derivedFromEvidenceIDs: try CanonicalColumnCodec.decodeJSON(
                [String].self, from: derivedFromEvidenceIDsJSON
            ).map { EvidenceID(rawValue: $0) },
            effectiveAt: try CanonicalColumnCodec.decodeTimestamp(effectiveAt),
            producer: SignalProducer(
                kind: CanonicalColumnCodec.decodeEnum(
                    SignalProducer.Kind.self, rawValue: producerKind, column: "producer_kind"
                ),
                modelIdentifier: producerModelIdentifier
            ),
            rationale: rationale
        )
    }
}

// MARK: - Artifact 行（通用形状 + PlaceholderArtifact codec 载体）

struct ArtifactRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "artifacts"

    let id: String
    let artifactKind: String
    let producedAt: String
    let validityPolicyJSON: String
    let payloadJSON: String

    init(row: Row) {
        id = row["id"]
        artifactKind = row["artifact_kind"]
        producedAt = row["produced_at"]
        validityPolicyJSON = row["validity_policy_json"]
        payloadJSON = row["payload_json"]
    }

    init(
        id: String,
        artifactKind: String,
        producedAt: String,
        validityPolicyJSON: String,
        payloadJSON: String
    ) {
        self.id = id
        self.artifactKind = artifactKind
        self.producedAt = producedAt
        self.validityPolicyJSON = validityPolicyJSON
        self.payloadJSON = payloadJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["artifact_kind"] = artifactKind
        container["produced_at"] = producedAt
        container["validity_policy_json"] = validityPolicyJSON
        container["payload_json"] = payloadJSON
    }

    /// PlaceholderArtifact 是当前唯一的具体 Artifact（Epic 7-10 各自落
    /// FactorSnapshot / ExposureEstimate / DailyAttribution /
    /// PortfolioDecisionArtifact 时补各自 codec，本方法届时退役为测试路径）。
    static func from(_ domain: PlaceholderArtifact) throws -> ArtifactRow {
        ArtifactRow(
            id: domain.id.rawValue,
            artifactKind: "PLACEHOLDER",
            producedAt: CanonicalColumnCodec.encodeTimestamp(domain.producedAt),
            validityPolicyJSON: try CanonicalColumnCodec.encodeJSON(domain.validityPolicy),
            payloadJSON: try CanonicalColumnCodec.encodeJSON(domain.payload)
        )
    }

    func toPlaceholderDomain() throws -> PlaceholderArtifact {
        try PlaceholderArtifact(
            id: ArtifactID(rawValue: id),
            producedAt: CanonicalColumnCodec.decodeTimestamp(producedAt),
            validityPolicy: CanonicalColumnCodec.decodeJSON(ValidityPolicy.self, from: validityPolicyJSON),
            dependencies: [],   // dependencies 由 artifact_dependencies 表按 id 补齐
            payload: CanonicalColumnCodec.decodeJSON(String.self, from: payloadJSON)
        )
    }
}

struct ArtifactDependencyRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "artifact_dependencies"

    let artifactID: String
    let depIndex: Int
    let kind: String
    let referenceID: String
    let version: String?

    init(row: Row) {
        artifactID = row["artifact_id"]
        depIndex = row["dep_index"]
        kind = row["kind"]
        referenceID = row["reference_id"]
        version = row["version"]
    }

    init(
        artifactID: String,
        depIndex: Int,
        kind: String,
        referenceID: String,
        version: String?
    ) {
        self.artifactID = artifactID
        self.depIndex = depIndex
        self.kind = kind
        self.referenceID = referenceID
        self.version = version
    }

    func encode(to container: inout PersistenceContainer) {
        container["artifact_id"] = artifactID
        container["dep_index"] = depIndex
        container["kind"] = kind
        container["reference_id"] = referenceID
        container["version"] = version
    }

    static func from(
        _ domain: ArtifactDependency,
        artifactID: ArtifactID,
        index: Int
    ) -> ArtifactDependencyRow {
        ArtifactDependencyRow(
            artifactID: artifactID.rawValue,
            depIndex: index,
            kind: domain.kind.rawValue,
            referenceID: domain.referenceID,
            version: domain.version
        )
    }

    func toDomain() throws -> ArtifactDependency {
        try ArtifactDependency(
            kind: CanonicalColumnCodec.decodeEnum(
                ArtifactDependency.DependencyKind.self, rawValue: kind, column: "kind"
            ),
            referenceID: referenceID,
            version: version
        )
    }
}

// MARK: - 通用形状行（领域类型待 Epic 10/11/13；列语义见文件头）

struct AgentJobRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_jobs"

    let id: String
    let workflow: String
    let idempotencyKey: String?
    let status: String
    let inputJSON: String
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let errorMessage: String?

    init(row: Row) {
        id = row["id"]
        workflow = row["workflow"]
        idempotencyKey = row["idempotency_key"]
        status = row["status"]
        inputJSON = row["input_json"]
        createdAt = row["created_at"]
        startedAt = row["started_at"]
        completedAt = row["completed_at"]
        errorMessage = row["error_message"]
    }

    init(
        id: String,
        workflow: String,
        idempotencyKey: String?,
        status: String,
        inputJSON: String,
        createdAt: String,
        startedAt: String?,
        completedAt: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.workflow = workflow
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.inputJSON = inputJSON
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["workflow"] = workflow
        container["idempotency_key"] = idempotencyKey
        container["status"] = status
        container["input_json"] = inputJSON
        container["created_at"] = createdAt
        container["started_at"] = startedAt
        container["completed_at"] = completedAt
        container["error_message"] = errorMessage
    }

    /// status 列 fail-closed 解码（AGENT-1 落地领域类型前的过渡形态）。
    func decodedStatus() throws -> AgentJobStatus {
        try CanonicalColumnCodec.decodeEnum(
            AgentJobStatus.self, rawValue: status, column: "status"
        )
    }
}

struct AgentJobEventRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_job_events"

    let jobID: String
    let seq: Int
    let occurredAt: String
    let kind: String
    let payloadJSON: String

    init(row: Row) {
        jobID = row["job_id"]
        seq = row["seq"]
        occurredAt = row["occurred_at"]
        kind = row["kind"]
        payloadJSON = row["payload_json"]
    }

    init(jobID: String, seq: Int, occurredAt: String, kind: String, payloadJSON: String) {
        self.jobID = jobID
        self.seq = seq
        self.occurredAt = occurredAt
        self.kind = kind
        self.payloadJSON = payloadJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["job_id"] = jobID
        container["seq"] = seq
        container["occurred_at"] = occurredAt
        container["kind"] = kind
        container["payload_json"] = payloadJSON
    }
}

struct AgentCheckpointRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_checkpoints"

    let jobID: String
    let seq: Int
    let createdAt: String
    let stateJSON: String

    init(row: Row) {
        jobID = row["job_id"]
        seq = row["seq"]
        createdAt = row["created_at"]
        stateJSON = row["state_json"]
    }

    init(jobID: String, seq: Int, createdAt: String, stateJSON: String) {
        self.jobID = jobID
        self.seq = seq
        self.createdAt = createdAt
        self.stateJSON = stateJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["job_id"] = jobID
        container["seq"] = seq
        container["created_at"] = createdAt
        container["state_json"] = stateJSON
    }
}

struct ThesisRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "theses"

    let id: String
    let kind: String
    let subjectEntityType: String
    let subjectEntityID: String
    let statement: String
    let supportingEvidenceIDsJSON: String
    let linkedSignalIDsJSON: String
    let createdAt: String
    let revisedAt: String?

    init(row: Row) {
        id = row["id"]
        kind = row["kind"]
        subjectEntityType = row["subject_entity_type"]
        subjectEntityID = row["subject_entity_id"]
        statement = row["statement"]
        supportingEvidenceIDsJSON = row["supporting_evidence_ids"]
        linkedSignalIDsJSON = row["linked_signal_ids"]
        createdAt = row["created_at"]
        revisedAt = row["revised_at"]
    }

    init(
        id: String,
        kind: String,
        subjectEntityType: String,
        subjectEntityID: String,
        statement: String,
        supportingEvidenceIDsJSON: String,
        linkedSignalIDsJSON: String,
        createdAt: String,
        revisedAt: String?
    ) {
        self.id = id
        self.kind = kind
        self.subjectEntityType = subjectEntityType
        self.subjectEntityID = subjectEntityID
        self.statement = statement
        self.supportingEvidenceIDsJSON = supportingEvidenceIDsJSON
        self.linkedSignalIDsJSON = linkedSignalIDsJSON
        self.createdAt = createdAt
        self.revisedAt = revisedAt
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["kind"] = kind
        container["subject_entity_type"] = subjectEntityType
        container["subject_entity_id"] = subjectEntityID
        container["statement"] = statement
        container["supporting_evidence_ids"] = supportingEvidenceIDsJSON
        container["linked_signal_ids"] = linkedSignalIDsJSON
        container["created_at"] = createdAt
        container["revised_at"] = revisedAt
    }
}

struct DecisionRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisions"

    let id: String
    let decisionKind: String
    let producedAt: String
    let actionPlanJSON: String
    let referencedSignalIDsJSON: String
    let validityPolicyJSON: String

    init(row: Row) {
        id = row["id"]
        decisionKind = row["decision_kind"]
        producedAt = row["produced_at"]
        actionPlanJSON = row["action_plan_json"]
        referencedSignalIDsJSON = row["referenced_signal_ids"]
        validityPolicyJSON = row["validity_policy_json"]
    }

    init(
        id: String,
        decisionKind: String,
        producedAt: String,
        actionPlanJSON: String,
        referencedSignalIDsJSON: String,
        validityPolicyJSON: String
    ) {
        self.id = id
        self.decisionKind = decisionKind
        self.producedAt = producedAt
        self.actionPlanJSON = actionPlanJSON
        self.referencedSignalIDsJSON = referencedSignalIDsJSON
        self.validityPolicyJSON = validityPolicyJSON
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["decision_kind"] = decisionKind
        container["produced_at"] = producedAt
        container["action_plan_json"] = actionPlanJSON
        container["referenced_signal_ids"] = referencedSignalIDsJSON
        container["validity_policy_json"] = validityPolicyJSON
    }
}
