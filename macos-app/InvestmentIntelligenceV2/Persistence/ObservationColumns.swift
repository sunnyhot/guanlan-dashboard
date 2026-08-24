import Foundation
import GRDB

// MARK: - ObservationEnvelopeColumns（GRDB-3..5 观测表共享列组）
//
// 所有 CanonicalObservation 表（daily_bars / nav_observations / corporate_actions /
// holding_snapshots / fundamental_observations / macro_observations）共有同一组
// envelope / provenance / quality / vintage 列。本 struct 是这组列的单一权威：
// 列名、编码、解码只写一处，各表 row struct 持有它再补自己的域列。
//
// 列清单（snake_case）：
// - 四时间：effective_at / published_at / available_at / ingested_at
//   （ISO8601 UTC 毫秒——**字典序 = 时间序**，PIT 断言 `available_at <= ?`
//   可直接在 SQL 里比较字符串，GRDB-7 的 Repository 查询依赖此约定）
// - availableAt 溯源（ADR-DATA005）：policy_id / policy_version / policy_derived_at
// - 数据质量（ADR-DATA006）：reliability_class / source_provider_id /
//   is_revised / is_superseded
// - vintage（ADR-DATA008）：vintage_announcement_date / vintage_publisher_version

/// 观测表共享的 envelope / provenance / quality / vintage 列组。
struct ObservationEnvelopeColumns {
    let effectiveAt: String
    let publishedAt: String
    let availableAt: String
    let ingestedAt: String
    let policyID: String
    let policyVersion: String
    let policyDerivedAt: String
    let reliabilityClass: String
    let sourceProviderID: String
    let isRevised: Bool
    let isSuperseded: Bool
    let vintageAnnouncementDate: String
    let vintagePublisherVersion: Int

    init(
        envelope: TemporalEnvelope,
        provenance: AvailabilityProvenance,
        quality: DataQuality,
        vintage: Vintage
    ) {
        effectiveAt = CanonicalColumnCodec.encodeTimestamp(envelope.effectiveAt)
        publishedAt = CanonicalColumnCodec.encodeTimestamp(envelope.publishedAt)
        availableAt = CanonicalColumnCodec.encodeTimestamp(envelope.availableAt)
        ingestedAt = CanonicalColumnCodec.encodeTimestamp(envelope.ingestedAt)
        policyID = provenance.policyID
        policyVersion = provenance.policyVersion
        policyDerivedAt = CanonicalColumnCodec.encodeTimestamp(provenance.derivedAt)
        reliabilityClass = quality.providerReliability.rawValue
        sourceProviderID = quality.sourceProviderID.rawValue
        isRevised = quality.isRevised
        isSuperseded = quality.isSuperseded
        vintageAnnouncementDate = CanonicalColumnCodec.encodeTimestamp(vintage.announcementDate)
        vintagePublisherVersion = vintage.publisherVersion
    }

    init(row: Row) {
        effectiveAt = row["effective_at"]
        publishedAt = row["published_at"]
        availableAt = row["available_at"]
        ingestedAt = row["ingested_at"]
        policyID = row["policy_id"]
        policyVersion = row["policy_version"]
        policyDerivedAt = row["policy_derived_at"]
        reliabilityClass = row["reliability_class"]
        sourceProviderID = row["source_provider_id"]
        isRevised = row["is_revised"]
        isSuperseded = row["is_superseded"]
        vintageAnnouncementDate = row["vintage_announcement_date"]
        vintagePublisherVersion = row["vintage_publisher_version"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["effective_at"] = effectiveAt
        container["published_at"] = publishedAt
        container["available_at"] = availableAt
        container["ingested_at"] = ingestedAt
        container["policy_id"] = policyID
        container["policy_version"] = policyVersion
        container["policy_derived_at"] = policyDerivedAt
        container["reliability_class"] = reliabilityClass
        container["source_provider_id"] = sourceProviderID
        container["is_revised"] = isRevised
        container["is_superseded"] = isSuperseded
        container["vintage_announcement_date"] = vintageAnnouncementDate
        container["vintage_publisher_version"] = vintagePublisherVersion
    }

    // MARK: - 还原 domain

    func envelope() throws -> TemporalEnvelope {
        TemporalEnvelope(
            effectiveAt: try CanonicalColumnCodec.decodeTimestamp(effectiveAt),
            publishedAt: try CanonicalColumnCodec.decodeTimestamp(publishedAt),
            availableAt: try CanonicalColumnCodec.decodeTimestamp(availableAt),
            ingestedAt: try CanonicalColumnCodec.decodeTimestamp(ingestedAt)
        )
    }

    func provenance() throws -> AvailabilityProvenance {
        AvailabilityProvenance(
            policyID: policyID,
            policyVersion: policyVersion,
            derivedAt: try CanonicalColumnCodec.decodeTimestamp(policyDerivedAt)
        )
    }

    func quality() throws -> DataQuality {
        try DataQuality(
            providerReliability: CanonicalColumnCodec.decodeEnum(
                ProviderReliabilityClass.self, rawValue: reliabilityClass, column: "reliability_class"
            ),
            sourceProviderID: DataProviderID(rawValue: sourceProviderID),
            isRevised: isRevised,
            isSuperseded: isSuperseded
        )
    }

    func vintage() throws -> Vintage {
        Vintage(
            announcementDate: try CanonicalColumnCodec.decodeTimestamp(vintageAnnouncementDate),
            publisherVersion: vintagePublisherVersion
        )
    }
}

// MARK: - 观测表共享 DDL 片段

extension ObservationEnvelopeColumns {

    /// 共享列的 DDL 片段（各表 CREATE TABLE 里逐列拼进，约束与索引由各表
    /// 自行声明——维度键 + vintage 的唯一索引是 DATA008 合规项，逐表落）。
    static let ddlColumns = """
        effective_at                TEXT NOT NULL,
        published_at                TEXT NOT NULL,
        available_at                TEXT NOT NULL,
        ingested_at                 TEXT NOT NULL,
        policy_id                   TEXT NOT NULL,
        policy_version              TEXT NOT NULL,
        policy_derived_at           TEXT NOT NULL,
        reliability_class           TEXT NOT NULL,
        source_provider_id          TEXT NOT NULL,
        is_revised                  INTEGER NOT NULL,
        is_superseded               INTEGER NOT NULL,
        vintage_announcement_date   TEXT NOT NULL,
        vintage_publisher_version   INTEGER NOT NULL
    """
}
