import Foundation

// MARK: - ObservationFactory（REPO-5a + REPO-5b：ProviderRecord → CanonicalObservation）
//
// 审查 P1 修复：TemporalNormalizer 只算时间包裹，ObservationFactory 才是完整的
// ProviderRecord → CanonicalObservation 转换器。REPO-5a 覆盖 DailyBar + NAV，
// REPO-5b 补 FundHolding + Macro + CorporateAction 三类（5 kind 完整）。
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
    /// 该 kind 的 Canonical 类型尚未定义（REPO-1b 前的 fundamentalFact），
    /// Pipeline 显式拒收而非静默跳过
    case canonicalConversionDeferred(kind: ProviderRecordKind)
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
        // fundamentalFact 的 Canonical 类型（FundamentalObservation）在 REPO-1b
        // （Epic 7+）定义；此前 Pipeline 对该 kind 显式拒收（staging + schema 校验
        // 仍可用），不静默转成其他观测类型。
        if record.kind == .fundamentalFact {
            throw ObservationFactoryError.canonicalConversionDeferred(kind: record.kind)
        }

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

        // 3. 按 kind 解析 payload + 组装（REPO-2b：注入 sourceProviderID 供跨源去重）
        let dataQuality = DataQuality.from(record.reliabilityClass, providerID: record.providerID)
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
        case .fundHoldingSnapshot:
            let payload = try Self.decode(FundHoldingPayload.self, from: record, kind: .fundHoldingSnapshot)
            guard case .fundProduct(let productID) = canonical else {
                throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
            }
            // 每个 position 的 Provider 代码也要解析为 Canonical ListingID（防火墙 1）。
            // 任意 position 未解析即抛错——持仓是 Product 维度的整体，部分解析会产生
            // 误导性 coverage（disclosedWeightTotal 与实际 positions 不符）。未披露标的的
            // 覆盖缺口由 Epic 8 PortfolioLookthroughCalculator 在更高层处理（unknownWeight）。
            let positions: [FundHoldingPosition] = try payload.positions.map { pos in
                let posResolution = resolver.resolve(
                    providerID: pos.providerID,
                    scheme: pos.providerCode.scheme,
                    value: pos.providerCode.value
                )
                guard case .resolved(let posCanonical, _) = posResolution,
                      case .listing(let listingID) = posCanonical else {
                    throw ObservationFactoryError.identityUnresolved(providerCode: pos.providerCode)
                }
                return FundHoldingPosition(
                    listingID: listingID,
                    weight: pos.weight,
                    shares: pos.shares,
                    marketValue: pos.marketValue,
                    isDisclosed: pos.isDisclosed
                )
            }
            return .fundHoldingSnapshot(FundHoldingSnapshot(
                id: observationID,
                productID: productID,
                temporalEnvelope: normalized.envelope,
                availabilityProvenance: normalized.provenance,
                dataQuality: dataQuality,
                vintage: vintage,
                reportPeriod: payload.reportPeriod,
                positions: positions,
                disclosedWeightTotal: payload.disclosedWeightTotal
            ))
        case .macroObservation:
            let payload = try Self.decode(MacroPayload.self, from: record, kind: .macroObservation)
            guard case .instrument(let indicatorID) = canonical else {
                throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
            }
            return .macroObservation(MacroObservation(
                id: observationID,
                indicatorID: indicatorID,
                temporalEnvelope: normalized.envelope,
                availabilityProvenance: normalized.provenance,
                dataQuality: dataQuality,
                vintage: vintage,
                value: payload.value,
                unit: payload.unit,
                frequency: payload.frequency,
                isSeasonallyAdjusted: payload.isSeasonallyAdjusted,
                basePeriod: payload.basePeriod
            ))
        case .corporateAction:
            let payload = try Self.decode(CorporateActionPayload.self, from: record, kind: .corporateAction)
            guard case .listing(let listingID) = canonical else {
                throw ObservationFactoryError.identityUnresolved(providerCode: record.providerCode)
            }
            return .corporateAction(CorporateAction(
                id: observationID,
                listingID: listingID,
                temporalEnvelope: normalized.envelope,
                availabilityProvenance: normalized.provenance,
                dataQuality: dataQuality,
                vintage: vintage,
                kind: payload.kind,
                exDate: payload.exDate,
                recordDate: payload.recordDate,
                payDate: payload.payDate,
                ratio: payload.ratio,
                currency: payload.currency
            ))
        case .fundamentalFact:
            // 入口 guard 已拦截（防御性重复，保持 switch 完备）
            throw ObservationFactoryError.canonicalConversionDeferred(kind: .fundamentalFact)
        }
    }

    // MARK: - Helpers

    /// 按 ProviderRecordKind 选 AvailabilityPolicy。
    static func policy(for kind: ProviderRecordKind) -> any AvailabilityPolicy {
        switch kind {
        case .dailyBar: return AvailabilityPolicyV1.MarketClose()
        case .navObservation: return AvailabilityPolicyV1.FundNAV()
        case .fundHoldingSnapshot: return AvailabilityPolicyV1.FundDisclosure()
        case .macroObservation: return AvailabilityPolicyV1.MacroRelease()   // 基于发布日 realtime_start（PROV-5）
        case .corporateAction: return AvailabilityPolicyV1.FundDisclosure()
        // 暂定：XBRL 事实随申报发布可知（filed 日次交易日，US）。REPO-1b 定义
        // FundamentalObservation 时若需独立 policy（如 FilingRelease）再版本化拆出。
        case .fundamentalFact: return AvailabilityPolicyV1.MacroRelease()
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
    case fundHoldingSnapshot(FundHoldingSnapshot)
    case macroObservation(MacroObservation)
    case corporateAction(CorporateAction)
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
    /// 累计净值（可选——pingzhongdata 的 Data_ACWorthTrend / LSJZ 的 LJJZ 提供，缺失为 nil）
    let accumulatedNAV: Price?
    /// 累计每份分红（可选——天天基金不直接披露，缺失为 nil，不伪造 0）
    let cumulativeDividendPerShare: Price?
}

/// FundHoldingSnapshot 的 rawPayload schema（REPO-5b）。
///
/// positions 携带的是 **Provider 代码**（非 Canonical）——Adapter 不做 identity 解析，
/// 由 ObservationFactory 在转 Canonical 时逐个解析为 ListingID（ADR-DATA001 防火墙 1）。
struct FundHoldingPayload: Codable, Hashable, Sendable {
    let reportPeriod: FundHoldingSnapshot.ReportPeriod
    let positions: [Position]
    /// Provider 披露的已披露权重总和（0-1，用于 lookthrough coverage 判断）
    let disclosedWeightTotal: Ratio

    struct Position: Codable, Hashable, Sendable {
        /// 持仓标的代码所属的 Provider（基金快照可能来自且慢，但持仓股票代码来自天天基金）
        let providerID: DataProviderID
        /// 持仓标的的 Provider 代码（Adapter 产出，Factory 解析为 Canonical ListingID）
        let providerCode: ProviderCode
        let weight: Ratio
        let shares: Decimal?
        let marketValue: Price?
        let isDisclosed: Bool
    }
}

/// MacroObservation 的 rawPayload schema（REPO-5b，对齐 FRED vintage）。
struct MacroPayload: Codable, Hashable, Sendable {
    let value: Decimal
    let unit: MacroObservation.MacroUnit
    let frequency: MacroObservation.MacroFrequency
    let isSeasonallyAdjusted: Bool
    let basePeriod: MacroObservation.MacroBasePeriod?
}

/// CorporateAction 的 rawPayload schema（REPO-5b）。
struct CorporateActionPayload: Codable, Hashable, Sendable {
    let kind: CorporateAction.Kind
    let exDate: Date
    let recordDate: Date?
    let payDate: Date?
    /// 行动比例（每股分红金额 / 送股比例 / 拆股比例）
    let ratio: Decimal
    let currency: Currency?
}

/// FundamentalFact 的 rawPayload schema（PROV-4，SEC XBRL companyfacts）。
///
/// 一条记录 = 一个 (concept, unit, start/end, filed) 事实行——同一 concept 同一
/// period 被多次申报（10-Q 初报、10-K 修订）是不同 publishedAt 的多条记录，
/// 保留完整 PIT 历史（ADR-DATA008 multi-vintage）。
/// `extractionMethod` 恒 `.xbrlFact`（机器可读字段，PROV-4 验收项），
/// 与 LLM extracted fact（Epic 11 RES-4）在类型层区分（DOM-9）。
struct FundamentalFactPayload: Codable, Hashable, Sendable {
    /// 标准 XBRL 概念名（如 "Revenues"、"NetIncomeLoss"）
    let concept: String
    /// 标准化指标 key（如 "revenue"，由 MetricSpec 配置驱动）
    let metricKey: String
    let value: Decimal
    /// XBRL unit 原始名（如 "USD"、"shares"）
    let unit: String
    /// 期间开始（流量项有；时点项如 Assets 为 nil）
    let start: Date?
    /// 期间结束 / 时点日（→ effectiveAt）
    let end: Date
    /// 申报表单（10-Q / 10-K / 20-F / 40-F）
    let form: String
    /// XBRL frame（如 "CY2023Q2"，可选）
    let frame: String?
    /// 提取方式（PROV-4 验收：XBRL facts 带 extractionMethod）
    let extractionMethod: EvidenceExtractionMethod
}
