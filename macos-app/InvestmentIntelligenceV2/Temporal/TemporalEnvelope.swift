import Foundation

// MARK: - TemporalEnvelope（ADR-DATA002 / DATA005 核心）
//
// 每个 CanonicalObservation 必须带 TemporalEnvelope，Repository 每个 API 必须
// 强制 KnowledgeContext 入参。四时间是 PIT 语义的全部载体。

/// 单条观测的四时间戳包裹（ADR-DATA002 §Decision 1）。
///
/// 这是 V3.1 PIT 系统的原子单位。理解每个字段：
/// - `effectiveAt`：观测值描述的经济事件发生时间
///   （如基金 2024-06-30 持仓、2024-07-20 收盘价）
/// - `publishedAt`：数据源对外公布的时间
///   （如基金季报 2024-07-20 公告日、FRED vintage 发布日）
/// - `availableAt`：客观上数据进入公开世界的最早时间
///   （由 AvailabilityPolicy 推导，≠ publishedAt 也 ≠ ingestedAt）
/// - `ingestedAt`：本系统实际抓到并入库的时间
///   （永远 ≥ availableAt，受 Provider 故障影响）
///
/// 不变量（TemporalEnvelope.validate()）：
/// - `effectiveAt <= publishedAt`：事件发生早于或等于公布
/// - `publishedAt <= availableAt`：公布早于或等于客观可知（保守策略下可放宽到次交易日）
/// - `availableAt <= ingestedAt`：客观可知早于或等于本系统入库
struct TemporalEnvelope: Sendable, Codable, Hashable {
    let effectiveAt: Date
    let publishedAt: Date
    let availableAt: Date
    let ingestedAt: Date

    init(effectiveAt: Date, publishedAt: Date, availableAt: Date, ingestedAt: Date) {
        self.effectiveAt = effectiveAt
        self.publishedAt = publishedAt
        self.availableAt = availableAt
        self.ingestedAt = ingestedAt
    }

    /// 校验四时间不变量。违反返回具体原因，便于 Pipeline 拒收脏数据（ADR-DATA003）。
    func validate() -> TemporalInvariantViolation? {
        if effectiveAt > publishedAt {
            return .effectiveAfterPublished(effectiveAt: effectiveAt, publishedAt: publishedAt)
        }
        if publishedAt > availableAt {
            return .publishedAfterAvailable(publishedAt: publishedAt, availableAt: availableAt)
        }
        if availableAt > ingestedAt {
            return .availableAfterIngested(availableAt: availableAt, ingestedAt: ingestedAt)
        }
        return nil
    }
}

enum TemporalInvariantViolation: Error, Equatable, Sendable {
    case effectiveAfterPublished(effectiveAt: Date, publishedAt: Date)
    case publishedAfterAvailable(publishedAt: Date, availableAt: Date)
    case availableAfterIngested(availableAt: Date, ingestedAt: Date)
}

// MARK: - AvailabilityProvenance（ADR-DATA005）
//
// availableAt 由版本化 AvailabilityPolicy 推导，不能由 Provider 自声明。
// AvailabilityProvenance 记录「这个 availableAt 是用哪条 policy、哪一版算出来的」。

/// `availableAt` 的推导溯源（ADR-DATA005 §Decision 1/4）。
///
/// 每个 TemporalEnvelope 的 availableAt 都附带 AvailabilityProvenance，
/// 说明用了哪条 policy 的哪个 version 推导出来的。policy 修订时旧 vintage
/// 数据保留旧 version 标注（ADR-DATA008）。
struct AvailabilityProvenance: Sendable, Codable, Hashable {
    /// 用的哪条 AvailabilityPolicy（如 "fund_nav_v1"、"market_close_v1"、"fund_disclosure_v1"）
    let policyID: String
    /// policy 版本（如 "v1"）
    let policyVersion: String
    /// 推导时间（用于审计「这个 availableAt 是什么时候算的」）
    let derivedAt: Date

    init(policyID: String, policyVersion: String, derivedAt: Date) {
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.derivedAt = derivedAt
    }
}

// MARK: - Vintage（ADR-DATA008 multi-vintage）
//
// 同一 effectiveAt 可有多个 vintage（首次披露 + 多次修订）。
// 每个 vintage 有自己的 TemporalEnvelope（availableAt 不同）。

/// 数据修订版本（ADR-DATA008）。
///
/// vintage 由 (announcementDate, publisherVersion) 唯一标识。
/// 例如 FRED GDP：advance (v1, 2024-01) / second (v2, 2024-02) / third (v3, 2024-03)。
/// 基金持仓：首次披露 (v1, 2024-07-20) / 修订 (v2, 2024-08-15)。
struct Vintage: Sendable, Codable, Hashable, Comparable {
    /// 公告 / 发布日期（与 publisherVersion 组合唯一）
    let announcementDate: Date
    /// 发布方内部版本号（1 = 首次，2 = 第一次修订…）
    let publisherVersion: Int

    init(announcementDate: Date, publisherVersion: Int) {
        self.announcementDate = announcementDate
        self.publisherVersion = publisherVersion
    }

    /// 比较顺序：先按公告日期，再按 publisher version。
    /// 用于 economicKnowledge(asOf:) 选择「可知的最新 vintage」。
    static func < (lhs: Vintage, rhs: Vintage) -> Bool {
        if lhs.announcementDate != rhs.announcementDate {
            return lhs.announcementDate < rhs.announcementDate
        }
        return lhs.publisherVersion < rhs.publisherVersion
    }
}
