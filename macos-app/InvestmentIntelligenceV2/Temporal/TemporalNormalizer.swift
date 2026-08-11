import Foundation

// MARK: - TemporalNormalizer（REPO-5，ADR-DATA005）
//
// ProviderRecord → CanonicalObservation 的 PIT 标注核心。
// 基于 AvailabilityPolicy 推导 availableAt，组装 TemporalEnvelope +
// AvailabilityProvenance。不让 Provider 自己声明 availableAt。
//
// 关键不变量（ADR-DATA002 §4）：ingestedAt 与 availableAt 不建立全序。
// Provider 故障延迟抓取时，availableAt 仍记客观可知时间，ingestedAt 记实际抓取时间。

/// Provider 抓取到的原始时间戳（ProviderRecord 的子集，REPO-5 用到的部分）。
/// PROV-1 会完整定义 ProviderRecord（含 raw + adjustment），这里只放时间维度。
struct ProviderTimestamps: Sendable {
    /// Provider 声明的事件时间（如 navDate、tradingDay、报告期）
    let effectiveAt: Date
    /// Provider 声明的公布时间（如公告日、数据源更新时间）
    let publishedAt: Date
    /// 本系统实际抓取时间（Provider 故障时可能远晚于客观可知）
    let ingestedAt: Date
    /// 标的法域（用于 AvailabilityPolicy 推导交易日历）
    let jurisdiction: Jurisdiction

    init(effectiveAt: Date, publishedAt: Date, ingestedAt: Date, jurisdiction: Jurisdiction) {
        self.effectiveAt = effectiveAt
        self.publishedAt = publishedAt
        self.ingestedAt = ingestedAt
        self.jurisdiction = jurisdiction
    }
}

/// TemporalNormalizer：基于 AvailabilityPolicy 推导 availableAt，
/// 组装 TemporalEnvelope + AvailabilityProvenance。
struct TemporalNormalizer: Sendable {
    let calendar: TradingCalendar

    init(calendar: TradingCalendar) {
        self.calendar = calendar
    }

    /// 规范化 Provider 时间戳为 TemporalEnvelope + AvailabilityProvenance。
    ///
    /// 流程：
    /// 1. 用 policy 基于 (effectiveAt, publishedAt, jurisdiction) 推导客观可知的 availableAt
    /// 2. 组装 TemporalEnvelope（四时间，ingestedAt 来自 ProviderTimestamps）
    /// 3. 生成 AvailabilityProvenance（policy id/version + derivedAt）
    /// 4. 校验 TemporalEnvelope 不变量（effective ≤ published ≤ available）
    ///
    /// 若 policy 推导失败或不变量违反，返回 nil（Pipeline 应拒收，ADR-DATA003）。
    func normalize(
        timestamps: ProviderTimestamps,
        policy: any AvailabilityPolicy
    ) -> (envelope: TemporalEnvelope, provenance: AvailabilityProvenance)? {
        guard let availableAt = policy.availableAt(
            effectiveAt: timestamps.effectiveAt,
            publishedAt: timestamps.publishedAt,
            jurisdiction: timestamps.jurisdiction,
            calendar: calendar
        ) else {
            return nil
        }
        let envelope = TemporalEnvelope(
            effectiveAt: timestamps.effectiveAt,
            publishedAt: timestamps.publishedAt,
            availableAt: availableAt,
            ingestedAt: timestamps.ingestedAt
        )
        // 不变量校验（effective ≤ published ≤ available，不校验 available ≤ ingested）
        guard envelope.validate() == nil else { return nil }
        let provenance = AvailabilityProvenance(
            policyID: policy.policyID,
            policyVersion: policy.version,
            derivedAt: Date()
        )
        return (envelope, provenance)
    }
}

// MARK: - REPO-5 便捷：按观测类型选 policy

extension TemporalNormalizer {
    /// 基金 NAV 规范化（用 FundNAV policy）。
    func normalizeFundNAV(
        effectiveAt: Date, publishedAt: Date, ingestedAt: Date
    ) -> (envelope: TemporalEnvelope, provenance: AvailabilityProvenance)? {
        normalize(
            timestamps: ProviderTimestamps(
                effectiveAt: effectiveAt, publishedAt: publishedAt,
                ingestedAt: ingestedAt, jurisdiction: .chinaMainland
            ),
            policy: AvailabilityPolicyV1.FundNAV()
        )
    }

    /// 市场收盘规范化（用 MarketClose policy，法域由调用方指定）。
    func normalizeMarketClose(
        effectiveAt: Date, publishedAt: Date, ingestedAt: Date, jurisdiction: Jurisdiction
    ) -> (envelope: TemporalEnvelope, provenance: AvailabilityProvenance)? {
        normalize(
            timestamps: ProviderTimestamps(
                effectiveAt: effectiveAt, publishedAt: publishedAt,
                ingestedAt: ingestedAt, jurisdiction: jurisdiction
            ),
            policy: AvailabilityPolicyV1.MarketClose()
        )
    }

    /// 基金披露规范化（用 FundDisclosure policy，法域由调用方指定）。
    func normalizeFundDisclosure(
        effectiveAt: Date, publishedAt: Date, ingestedAt: Date, jurisdiction: Jurisdiction
    ) -> (envelope: TemporalEnvelope, provenance: AvailabilityProvenance)? {
        normalize(
            timestamps: ProviderTimestamps(
                effectiveAt: effectiveAt, publishedAt: publishedAt,
                ingestedAt: ingestedAt, jurisdiction: jurisdiction
            ),
            policy: AvailabilityPolicyV1.FundDisclosure()
        )
    }
}
