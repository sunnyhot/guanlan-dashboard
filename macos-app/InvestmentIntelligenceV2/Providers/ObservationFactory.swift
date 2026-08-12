import Foundation

// MARK: - ObservationFactory（REPO-5 完整链：ProviderRecord → CanonicalObservation）
//
// 审查 P1 修复：TemporalNormalizer 只算时间包裹，ObservationFactory 才是完整的
// ProviderRecord → CanonicalObservation 转换器。
//
// 流程：
// 1. 按 record.kind 选 AvailabilityPolicy
// 2. 用 TemporalNormalizer 推导 availableAt，组装 TemporalEnvelope + AvailabilityProvenance
// 3. 用 IdentityResolver 把 providerCode 解析为 CanonicalRef（Instrument/Listing/...）
// 4. 解析 rawPayload 为具体字段
// 5. 组装具体 CanonicalObservation（DailyBar / NAVObservation / ...）
//
// 任一步失败返回 nil（Pipeline 拒收，ADR-DATA003）。

/// ProviderRecord → CanonicalObservation 转换错误。
enum ObservationFactoryError: Error, Equatable, Sendable {
    /// rawPayload 无法解析为对应 kind 的 schema
    case payloadDecodeFailed(kind: ProviderRecordKind, detail: String)
    /// Provider 代码未解析到 Canonical（IdentityResolver 未登记或 fuzzy）
    case identityUnresolved(providerCode: ProviderCode)
    /// 时间规范化失败（AvailabilityPolicy 推导失败或不变量违反）
    case temporalNormalizeFailed
}

/// ProviderRecord → CanonicalObservation 转换器。
struct ObservationFactory: Sendable {
    let normalizer: TemporalNormalizer
    let resolver: IdentityResolver

    init(normalizer: TemporalNormalizer, resolver: IdentityResolver) {
        self.normalizer = normalizer
        self.resolver = resolver
    }

    // MARK: - 主转换入口

    /// 把单条 ProviderRecord 转成对应的 CanonicalObservation。
    ///
    /// 返回值是 enum，携带具体观测类型；调用方按需 switch。
    /// 失败抛 ObservationFactoryError（Pipeline 上层捕获决定降级 / 拒收）。
    func makeObservation(
        from record: ProviderRecord,
        observationID: ObservationID,
        vintage: Vintage
    ) throws -> CanonicalObservationKind {
        // 1. 解析 identity
        let resolution = resolver.resolve(
            providerID: record.providerID,
            scheme: record.providerCode.scheme,
            value: record.providerCode.value
        )
        guard case .resolved(let canonical, _) = resolution else {
            throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
        }

        // 2. 选 policy + 算时间
        let policy = Self.policy(for: record.kind)
        let timestamps = ProviderTimestamps(
            effectiveAt: record.effectiveAt,
            publishedAt: record.publishedAt,
            ingestedAt: record.ingestedAt,
            jurisdiction: record.jurisdiction
        )
        guard let normalized = normalizer.normalize(timestamps: timestamps, policy: policy) else {
            throw ObservationFactoryError.temporalNormalizeFailed
        }

        // 3. 按 kind 解析 payload + 组装
        let dataQuality = DataQuality.from(record.reliabilityClass)
        switch record.kind {
        case .dailyBar:
            let payload = try Self.decode(DailyBarPayload.self, from: record, kind: .dailyBar)
            guard case .listing(let listingID) = canonical else {
                throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
            }
            return .dailyBar(DailyBar(
                id: observationID,
                listingID: listingID,
                temporalEnvelope: normalized.envelope,
                availabilityProvenance: normalized.provenance,
                dataQuality: dataQuality,
                vintage: vintage,
                rawOpen: payload.rawOpen, rawHigh: payload.rawHigh,
                rawLow: payload.rawLow, rawClose: payload.rawClose,
                volume: payload.volume,
                adjustmentFactor: payload.adjustmentFactor,
                fxRate: payload.fxRate
            ))
        case .navObservation:
            let payload = try Self.decode(NAVPayload.self, from: record, kind: .navObservation)
            guard case .fundShareClass(let shareClassID) = canonical else {
                throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
            }
            return .navObservation(NAVObservation(
                id: observationID,
                shareClassID: shareClassID,
                temporalEnvelope: normalized.envelope,
                availabilityProvenance: normalized.provenance,
                dataQuality: dataQuality,
                vintage: vintage,
                unitNAV: payload.unitNAV,
                accumulatedNAV: payload.accumulatedNAV,
                cumulativeDividendPerShare: payload.cumulativeDividendPerShare
            ))
        case .fundHoldingSnapshot, .macroObservation, .corporateAction:
            // 这些 kind 的 payload schema 在 Epic 4 各 Provider Adapter 完整定义
            throw ObservationFactoryError.payloadDecodeFailed(
                kind: record.kind,
                detail: "payload schema for \(record.kind) not yet implemented (Epic 4)"
            )
        }
    }

    // MARK: - Helpers

    /// 按 ProviderRecordKind 选 AvailabilityPolicy。
    static func policy(for kind: ProviderRecordKind) -> any AvailabilityPolicy {
        switch kind {
        case .dailyBar: return AvailabilityPolicyV1.MarketClose()
        case .navObservation: return AvailabilityPolicyV1.FundNAV()
        case .fundHoldingSnapshot: return AvailabilityPolicyV1.FundDisclosure()
        case .macroObservation: return AvailabilityPolicyV1.MarketClose()   // 宏观暂复用
        case .corporateAction: return AvailabilityPolicyV1.FundDisclosure()
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, from record: ProviderRecord, kind: ProviderRecordKind
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: record.rawPayload)
        } catch {
            throw ObservationFactoryError.payloadDecodeFailed(kind: kind, detail: "\(error)")
        }
    }
}

/// ObservationFactory.makeObservation 的返回值（带具体观测类型的 enum）。
enum CanonicalObservationKind: Sendable, Hashable {
    case dailyBar(DailyBar)
    case navObservation(NAVObservation)
    // Epic 4 补 fundHoldingSnapshot / macroObservation / corporateAction
}

// MARK: - rawPayload schema（每种 ProviderRecordKind 对应一个 Codable struct）

/// DailyBar 的 rawPayload schema（Provider 原始 OHLCV + 复权因子）。
struct DailyBarPayload: Codable, Hashable, Sendable {
    let rawOpen: Price
    let rawHigh: Price
    let rawLow: Price
    let rawClose: Price
    let volume: Int64?
    let adjustmentFactor: Decimal
    let fxRate: Decimal?
}

/// NAVObservation 的 rawPayload schema。
struct NAVPayload: Codable, Hashable, Sendable {
    let unitNAV: Price
    let accumulatedNAV: Price
    let cumulativeDividendPerShare: Price
}
