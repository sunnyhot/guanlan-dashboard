import Foundation
import GRDB

// MARK: - Research Evidence 落库（WF-1 接线：rollout Epic 11 状态块遗留项）
//
// RES-3 工具在研究运行内产出 EvidenceID + 信封内容，但 Harness 只在
// 运行内登记 ID——证据本体（EvidenceObservation）不落库，signals 的
// derivedFrom 跨运行不可溯源。本文件补上这一段：
// - `ResearchEvidenceFactory`：工具结果 → EvidenceObservation（确定性，
//   同 evidenceID + 同内容 → 同 ObservationID，重复落库幂等）
// - `ResearchEvidenceStore`：evidence 表存取 API（GRDB / InMemory 双实现）
//
// 语义纪律：
// - 研究工具结果是**点观测**：四时间全部取执行时刻（effective ==
//   published == available == ingested）。工具结果不携带独立的事件时间
//   （那是 Provider 链路 Observation 的职责）——不猜时间是 DATA006 精神。
// - source / reliability 按工具名映射（表内白名单）；未知工具 fail-closed
//   拒绝构造（宁可少落一条证据，不落一条来源不明的证据）。
// - 同 EvidenceID 不同内容 → 不同 ObservationID（multi-vintage 语义，
//   DATA008）：同 evidence 两次不同参数的工具调用是两次独立观测。

// MARK: - 工具 → 证据来源映射（白名单）

enum ResearchEvidenceSourceMapping {
    struct MappedSource: Sendable, Hashable {
        let source: EvidenceObservation.EvidenceSource
        let reliability: ProviderReliabilityClass
    }

    static let whitelist: [String: MappedSource] = [
        "official_sec_research": MappedSource(
            source: .secFiling, reliability: .officialStable),
        "web_search": MappedSource(
            source: .webSearch, reliability: .communityAggregated),
        "alpha_vantage_research": MappedSource(
            source: .research, reliability: .documentFreeAPI),
        "get_local_data": MappedSource(
            source: .research, reliability: .documentFreeAPI),
    ]

    static func mapped(toolName: String) throws -> MappedSource {
        guard let mapped = whitelist[toolName] else {
            throw ResearchEvidenceError.unknownToolSource(toolName)
        }
        return mapped
    }
}

enum ResearchEvidenceError: Error, Equatable, Sendable {
    /// 工具不在证据来源白名单内（fail-closed，不猜来源）。
    case unknownToolSource(String)
    /// 信封内容编码失败（确定性类型编码失败 = 编程错误路径）。
    case contentEncodingFailed(String)
}

// MARK: - EvidenceObservation 工厂（工具结果 → 本体）

struct ResearchEvidenceFactory: Sendable {
    /// 研究证据的 AvailabilityPolicy 溯源标识（点观测：无推迟推导）。
    static let availabilityPolicyID = "research_tool_instant_v1"

    /// 从工具结果构造证据本体。
    /// - Parameters:
    ///   - evidenceID: 工具产出的证据 ID
    ///   - toolName: 执行的工具名（来源映射）
    ///   - content: 工具结果信封（客观记录工具产出，JSON 编码）
    ///   - subject: 研究任务主体
    ///   - sourceDate: 证据的**来源时间**（SEC filed_at / 网页 published_date /
    ///     日线最新交易日——描述事件何时发生/发布）。nil 时回退执行时刻
    ///     （实时查询结果语义：内容本身就是「此刻查到的」，不存在更早的
    ///     客观事件时间）。TemporalEnvelope 语义：effective = published =
    ///     available = 来源时间（点观测无推迟推导）；**ingested = 执行时刻**
    ///     ——Freshness 判定用来源时间，抓取再新也救不了旧证据（十五轮
    ///     审查 P1-4）。
    func observation(
        evidenceID: EvidenceID,
        toolName: String,
        content: ModelJSONValue,
        subject: CanonicalRef,
        sourceDate: Date? = nil,
        at timestamp: Date
    ) throws -> EvidenceObservation {
        let mapped = try ResearchEvidenceSourceMapping.mapped(toolName: toolName)
        guard let contentData = try? JSONEncoder().encode(content),
              let contentJSONString = String(
                data: contentData, encoding: .utf8
              )
        else {
            throw ResearchEvidenceError.contentEncodingFailed(evidenceID.rawValue)
        }
        // ObservationID：evidenceID + 内容摘要确定性派生（同证据同内容幂等；
        // 同证据不同内容 = 新 vintage）
        let idPayload = "\(evidenceID.rawValue)|\(StableDigest.digest(contentJSONString))"
        let observationID = ObservationID(
            rawValue: "obs_\(StableDigest.digest(idPayload))"
        )
        let sourceTime = sourceDate ?? timestamp
        return EvidenceObservation(
            id: observationID,
            evidenceID: evidenceID,
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: sourceTime,
                publishedAt: sourceTime,
                availableAt: sourceTime,
                ingestedAt: timestamp
            ),
            availabilityProvenance: AvailabilityProvenance(
                policyID: Self.availabilityPolicyID,
                policyVersion: "v1",
                derivedAt: timestamp
            ),
            dataQuality: DataQuality(
                providerReliability: mapped.reliability,
                sourceProviderID: DataProviderID(rawValue: toolName)
            ),
            vintage: Vintage(announcementDate: sourceTime, publisherVersion: 1),
            content: contentJSONString,
            source: mapped.source,
            subjectCanonical: subject
        )
    }
}

// MARK: - Research Evidence Store

/// 研究证据存取 API（evidence 表；GRDB / InMemory 双实现）。
protocol ResearchEvidenceStore: Sendable {
    /// 写入（幂等：同 ObservationID 已存在 → no-op——ID 由 evidenceID +
    /// 内容派生，同 ID 异内容在工厂层就不可能发生）。
    @discardableResult
    func write(_ evidence: EvidenceObservation) throws -> ObservationID

    /// 按 EvidenceID 查（同 ID 多 vintage 时返回全部，ingestedAt 降序）。
    func observations(evidenceID: EvidenceID) throws -> [EvidenceObservation]

    /// 已知证据 ID 集（RES-5 EvidenceBinding 的 knownEvidence 供给）。
    func knownEvidenceIDs() throws -> Set<String>

    /// 证据时间索引（RES-5 Freshness 的 evidenceDates 供给：
    /// EvidenceID → 最新一次观测的 availableAt）。
    func evidenceDates() throws -> [String: Date]
}

// MARK: - GRDB 实现

extension GRDBRepository: ResearchEvidenceStore {

    @discardableResult
    func write(_ evidence: EvidenceObservation) throws -> ObservationID {
        try database.queue.write { db in
            let exists = try EvidenceRow
                .filter(Column("id") == evidence.id.rawValue)
                .fetchCount(db) > 0
            if !exists {
                try EvidenceRow.from(evidence).insert(db)
            }
        }
        return evidence.id
    }

    func observations(evidenceID: EvidenceID) throws -> [EvidenceObservation] {
        try database.queue.read { db in
            try EvidenceRow
                .filter(Column("evidence_id") == evidenceID.rawValue)
                .order(sql: "ingested_at DESC")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func knownEvidenceIDs() throws -> Set<String> {
        try database.queue.read { db in
            let raws = try String.fetchAll(
                db, sql: "SELECT DISTINCT evidence_id FROM evidence"
            )
            return Set(raws)
        }
    }

    func evidenceDates() throws -> [String: Date] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT evidence_id, available_at FROM evidence ORDER BY available_at ASC"
            )
            var dates: [String: Date] = [:]
            for row in rows {
                let raw: String = row["available_at"]
                if let date = try? CanonicalColumnCodec.decodeTimestamp(raw) {
                    dates[row["evidence_id"]] = date
                }
            }
            return dates
        }
    }
}

// MARK: - InMemory 实现（测试 parity / 无库环境）

final class InMemoryResearchEvidenceStore: ResearchEvidenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObservationID: EvidenceObservation] = [:]

    func write(_ evidence: EvidenceObservation) throws -> ObservationID {
        lock.lock()
        defer { lock.unlock() }
        storage[evidence.id] = evidence
        return evidence.id
    }

    func observations(evidenceID: EvidenceID) throws -> [EvidenceObservation] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { $0.evidenceID == evidenceID }
            .sorted { $0.temporalEnvelope.ingestedAt > $1.temporalEnvelope.ingestedAt }
    }

    func knownEvidenceIDs() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(storage.values.map { $0.evidenceID.rawValue })
    }

    func evidenceDates() throws -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        var dates: [String: Date] = [:]
        for evidence in storage.values {
            let available = evidence.temporalEnvelope.availableAt
            if let existing = dates[evidence.evidenceID.rawValue] {
                if available > existing {
                    dates[evidence.evidenceID.rawValue] = available
                }
            } else {
                dates[evidence.evidenceID.rawValue] = available
            }
        }
        return dates
    }
}
