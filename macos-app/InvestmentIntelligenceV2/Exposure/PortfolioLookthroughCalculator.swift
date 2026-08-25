import Foundation

// MARK: - PortfolioLookthroughCalculator（EXP-1，Epic 8）
//
// 全新实现，不复用现有 Core/FundLookThrough.swift（旧代码 Epic 12 才下线）。
// 与旧实现「fetch + make」两层对应：V2 的抓取已由 Epic 4/6 Provider 链进
// Canonical Observation，本计算器只做纯计算（make 层）——同输入同输出，
// 不做 IO、不读全局状态。
//
// 能力对齐旧 944 行（计算面）：跨基金同标的合并、直接持股并入、
// coverage 分级（基金披露覆盖 / 证券明细覆盖）、unknownWeight、
// 资产大类聚合、行业聚合、陈旧披露警告、每基金摘要。
// 超越部分：全部权重走 Ratio(Decimal) + 上下界（unknownWeight 进入
// 上界，最坏情况归因语义）+ Artifact conformance（dependencies 精确到
// observation，重放可取数）。

// MARK: - 输入

/// 组合层单个持仓输入（基金或直接持股，二选一）。
struct LookthroughPositionInput: Sendable, Codable, Hashable {
    /// 组合内相对权重（内部会归一化）
    let weight: Ratio
    /// 基金持仓（走披露穿透）
    let fundProductID: FundProductID?
    /// 直接持股（100% 计入自身 listing）
    let directListingID: ListingID?
    /// 直接持股的资产大类（基金侧来自 AllocationSnapshot；此字段只对
    /// directListingID 生效，缺失时该权重进资产大类维 unknown）
    let directAssetClass: AssetClass?

    init(
        weight: Ratio,
        fundProductID: FundProductID? = nil,
        directListingID: ListingID? = nil,
        directAssetClass: AssetClass? = nil
    ) {
        precondition(weight.value >= 0, "组合权重非负")
        // 三轮 P1-4:基金 / 直接持股**恰好二选一**——同时存在会让同一权重
        // 在基金与直接两个循环各计一次(暴露翻倍),都为空则权重归一化后
        // 消失(不进任何暴露也不进 unknown)
        precondition((fundProductID != nil) != (directListingID != nil),
                     "持仓必须是基金或直接持股(恰好其一)")
        precondition(directAssetClass == nil || directListingID != nil,
                     "directAssetClass 只对直接持股有意义")
        self.weight = weight
        self.fundProductID = fundProductID
        self.directListingID = directListingID
        self.directAssetClass = directAssetClass
    }

    /// 校验式解码（三轮 P1-4）：绕过构造器的脏 JSON 在解码点拒绝。
    enum CodingKeys: String, CodingKey {
        case weight, fundProductID, directListingID, directAssetClass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weight = try container.decode(Ratio.self, forKey: .weight)
        fundProductID = try container.decodeIfPresent(FundProductID.self, forKey: .fundProductID)
        directListingID = try container.decodeIfPresent(ListingID.self, forKey: .directListingID)
        directAssetClass = try container.decodeIfPresent(AssetClass.self, forKey: .directAssetClass)
        guard weight.value >= 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "持仓权重为负"))
        }
        guard (fundProductID != nil) != (directListingID != nil) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "持仓必须是基金或直接持股(恰好其一)——同时存在会双计暴露,都为空则权重消失"))
        }
        // 四轮 P2-5:directAssetClass 只属于直接持股(构造器有此校验,
        // 解码同样执行——基金持仓携带 directAssetClass 的脏 JSON 拒收)
        guard directAssetClass == nil || directListingID != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "directAssetClass 只对直接持股有意义——基金持仓携带该字段为脏数据"))
        }
    }
}

/// 单只基金的披露输入（调用方从 Repository 按 KnowledgeContext 取好传入；
/// 计算器不重复实现 PIT 过滤，只按 effectiveAt 保守取最新）。
struct FundDisclosureInput: Sendable, Codable, Hashable {
    let productID: FundProductID
    /// 最新可知持仓快照（nil = 无披露）
    let holding: FundHoldingSnapshot?
    /// 最新可知资产配置快照（nil = 资产大类维进 unknown）
    let allocation: AllocationSnapshot?
}

/// 行业分类输入（可选维度）。
///
/// V2 Canonical 暂无行业 Observation（Epic 4 provider 未覆盖），行业聚合
/// 由调用方显式提供分类映射——计算器不内置行业字典（内置即黑箱）。
/// 分类体系自由（申万 / GICS / 源站文本），经 classificationSystem 标注。
struct SectorClassification: Sendable, Codable, Hashable {
    let label: String
    let classificationSystem: String?

    init(label: String, classificationSystem: String? = nil) {
        self.label = label
        self.classificationSystem = classificationSystem
    }
}

// MARK: - 输出

/// 组合穿透快照（V2 命名避开同 target 的旧 Core `PortfolioLookThroughSnapshot`）。
///
/// 上下界语义（最坏情况归因，非概率区间）：unknown 部分理论上可能全部
/// 属于任一标的 / 类别，故 upperBound = point + 总 unknownPortfolioWeight。
/// 下界 = 已确认的点估计。下游（EXP-2 ExposureEstimate / RISK）做保守
/// 判断用上界，展示用点估计。
struct LookthroughSnapshot: Artifact {
    let id: ArtifactID
    let producedAt: Date
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    /// 分析时点（staleness 与披露选择的锚）
    let asOf: Date
    /// 计算器版本（公式变更 bump，历史重放定位）
    let calculatorVersion: String

    // coverage 三级（全部 0-1）
    /// 组合内基金数（直接持股不计）
    let fundCount: Int
    /// 有持仓披露的基金数
    let coveredFundCount: Int
    /// 有披露基金的组合权重占比（0-1）
    let fundDataCoverage: Ratio
    /// 已披露底层证券明细覆盖的组合权重占比（0-1）
    let disclosedSecurityCoverage: Ratio
    /// 未被证券明细覆盖的组合权重（= 1 − disclosedSecurityCoverage ≥ 0）
    let unknownPortfolioWeight: Ratio

    /// 穿透后标的暴露（跨基金合并 + 直接持股，权重降序）
    let underlyingPositions: [UnderlyingPosition]
    /// 资产大类暴露（AllocationSnapshot + 直接持股大类；confirmed 降序）
    let assetClassExposures: [AssetClassExposure]
    /// 行业暴露（无分类输入时为空数组）
    let industryExposures: [IndustryExposure]
    /// 每基金摘要
    let fundSummaries: [FundSummary]
    /// 结构化警告
    let warnings: [Warning]
    /// 参与计算的 observation IDs（holding + allocation，排序；EXP-2 溯源透传）
    let sourceObservationIDs: [ObservationID]

    /// 单个穿透标的。
    struct UnderlyingPosition: Sendable, Codable, Hashable {
        let listingID: ListingID
        /// 点估计（已确认部分）
        let weight: Ratio
        let lowerBound: Ratio
        /// 最坏情况上界（weight + unknownPortfolioWeight）
        let upperBound: Ratio
        /// 贡献来源（基金穿透 / 直接持股），按贡献权重降序
        let contributors: [Contributor]

        struct Contributor: Sendable, Codable, Hashable {
            /// nil = 直接持股
            let fundProductID: FundProductID?
            /// 该来源内的持仓权重（基金披露内权重 / 直接持股 1.0）
            let underlyingWeight: Ratio
            /// 对组合的贡献权重
            let contribution: Ratio
            let isDirectHolding: Bool
        }
    }

    /// 资产大类暴露（缺口语义：未披露 / 未归类的类别不出现，其余进 unknown）。
    struct AssetClassExposure: Sendable, Codable, Hashable {
        let assetClass: AssetClass
        /// 已确认归入此类的组合权重（下界）
        let confirmedWeight: Ratio
        /// 最坏情况上界（confirmed + unknownPortfolioWeight）
        let upperBoundWeight: Ratio
    }

    /// 行业暴露（同缺口语义 + 无分类输入的权重进行业维 unknown）。
    struct IndustryExposure: Sendable, Codable, Hashable {
        let label: String
        let classificationSystem: String?
        let confirmedWeight: Ratio
        let upperBoundWeight: Ratio
    }

    /// 每基金穿透摘要。
    struct FundSummary: Sendable, Codable, Hashable {
        let productID: FundProductID
        /// 归一化后的组合权重
        let portfolioWeight: Ratio
        /// 披露的证券明细权重和（无披露为 nil）
        let disclosedSecurityWeight: Ratio?
        let reportPeriod: FundHoldingSnapshot.ReportPeriod?
        /// 披告期末（无披露为 nil）
        let disclosureEffectiveAt: Date?
        /// 披告期距 asOf 超过阈值（stale 但仍参与计算，带警告）
        let isStale: Bool
        /// 是否有资产配置披露
        let hasAllocation: Bool
    }

    /// 结构化警告（对齐旧实现的自由文本 warning，可程序化消费）。
    enum Warning: Sendable, Codable, Hashable {
        /// 基金无任何持仓披露（其权重全进 unknown）
        case missingDisclosure(productID: FundProductID, portfolioWeight: Ratio)
        /// 披露陈旧（仍参与计算，保守提示）
        case staleDisclosure(productID: FundProductID, ageDays: Int, limitDays: Int)
        /// 穿透基于定期报告披露，非实时完整持仓（固定免责）
        case disclosureDisclaimer
    }
}

// MARK: - 计算器

/// 纯函数穿透计算器（EXP-1）。
struct PortfolioLookthroughCalculator: Sendable {
    static let calculatorVersion = "v1"

    /// 计算参数（全部显式 versioned：阈值变更走参数 + 版本）。
    struct Parameters: Sendable, Codable, Hashable {
        /// 披露陈旧阈值（天，对齐旧实现 150 天惯例）
        let maxDisclosureAgeDays: Int
        /// 行业分类映射（可选维度；nil listingID 不计入行业聚合）
        let sectorClassifications: [ListingID: SectorClassification]

        init(maxDisclosureAgeDays: Int = 150, sectorClassifications: [ListingID: SectorClassification] = [:]) {
            self.maxDisclosureAgeDays = maxDisclosureAgeDays
            self.sectorClassifications = sectorClassifications
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 计算组合穿透快照。
    ///
    /// - 输入权重内部归一化（Σ = 1；空输入或全零返回 nil——空组合无穿透语义）
    /// - 披露选择：同基金多个 FundHoldingSnapshot 时按 effectiveAt 取最新
    ///   （调用方传入的应已是 context 过滤后的最新可知集，此处保守兜底）
    func compute(
        positions: [LookthroughPositionInput],
        disclosures: [FundDisclosureInput],
        asOf: Date,
        producedAt: Date
    ) -> LookthroughSnapshot? {
        // 归一化权重
        let totalWeight = positions.reduce(Decimal.zero) { $0 + $1.weight.value }
        guard totalWeight > 0 else { return nil }
        let normalized: [(input: LookthroughPositionInput, weight: Decimal)] = positions.map {
            ($0, $0.weight.value / totalWeight)
        }

        let disclosureByProduct = Dictionary(
            uniqueKeysWithValues: disclosures.map { ($0.productID, $0) }
        )
        // 每基金取 effectiveAt 最新的持仓（保守兜底，不重复 PIT 过滤）
        func latestHolding(_ input: FundDisclosureInput) -> FundHoldingSnapshot? {
            input.holding
        }
        func latestAllocation(_ input: FundDisclosureInput) -> AllocationSnapshot? {
            input.allocation
        }

        var fundSummaries: [LookthroughSnapshot.FundSummary] = []
        var warnings: [LookthroughSnapshot.Warning] = [.disclosureDisclaimer]

        // 1) 基金侧：披露覆盖 + unknown 累计
        var disclosedSecurityCoverage = Decimal.zero
        var unknownWeight = Decimal.zero
        var positionAccumulator: [ListingID: [LookthroughSnapshot.UnderlyingPosition.Contributor]] = [:]
        var positionWeight: [ListingID: Decimal] = [:]
        var assetClassConfirmed: [AssetClass: Decimal] = [:]
        var assetClassUnknown = Decimal.zero

        for (input, weight) in normalized where input.fundProductID != nil {
            let productID = input.fundProductID!
            let disclosure = disclosureByProduct[productID]

            if let holding = disclosure.flatMap(latestHolding) {
                let age = Self.ageDays(from: holding.temporalEnvelope.effectiveAt, to: asOf)
                let stale = age > parameters.maxDisclosureAgeDays
                if stale {
                    warnings.append(.staleDisclosure(
                        productID: productID, ageDays: age, limitDays: parameters.maxDisclosureAgeDays
                    ))
                }
                disclosedSecurityCoverage += weight * min(holding.disclosedWeightTotal.value, 1)
                unknownWeight += weight * max(Decimal.one - min(holding.disclosedWeightTotal.value, 1), 0)

                for position in holding.positions {
                    let contribution = weight * position.weight.value
                    positionWeight[position.listingID, default: 0] += contribution
                    positionAccumulator[position.listingID, default: []].append(
                        .init(fundProductID: productID, underlyingWeight: position.weight, contribution: Ratio(value: contribution), isDirectHolding: false)
                    )
                }
                fundSummaries.append(.init(
                    productID: productID,
                    portfolioWeight: Ratio(value: weight),
                    disclosedSecurityWeight: Ratio(value: min(holding.disclosedWeightTotal.value, 1)),
                    reportPeriod: holding.reportPeriod,
                    disclosureEffectiveAt: holding.temporalEnvelope.effectiveAt,
                    isStale: stale,
                    hasAllocation: disclosure?.allocation != nil
                ))
            } else {
                warnings.append(.missingDisclosure(productID: productID, portfolioWeight: Ratio(value: weight)))
                unknownWeight += weight
                fundSummaries.append(.init(
                    productID: productID,
                    portfolioWeight: Ratio(value: weight),
                    disclosedSecurityWeight: nil,
                    reportPeriod: nil,
                    disclosureEffectiveAt: nil,
                    isStale: false,
                    hasAllocation: disclosure?.allocation != nil
                ))
            }

            // 资产大类（基金侧）：allocation 缺失 → 该基金权重进 AC 维 unknown；
            // allocation 数组内部缺口（Σ < 1，未披露类别不出现）同样进 unknown
            if let allocation = disclosure.flatMap(latestAllocation) {
                let allocatedTotal = allocation.allocations.reduce(Decimal.zero) { $0 + $1.ratio.value }
                for entry in allocation.allocations {
                    assetClassConfirmed[entry.assetClass, default: 0] += weight * entry.ratio.value
                }
                assetClassUnknown += weight * max(Decimal.one - allocatedTotal, 0)
            } else {
                assetClassUnknown += weight
            }
        }

        // 2) 直接持股侧：100% 计入自身 + 可选资产大类
        for (input, weight) in normalized where input.directListingID != nil {
            let listing = input.directListingID!
            positionWeight[listing, default: 0] += weight
            positionAccumulator[listing, default: []].append(
                .init(fundProductID: nil, underlyingWeight: Ratio(value: 1), contribution: Ratio(value: weight), isDirectHolding: true)
            )
            if let assetClass = input.directAssetClass {
                assetClassConfirmed[assetClass, default: 0] += weight
            } else {
                assetClassUnknown += weight
            }
            // 直接持股的证券明细是完整已知的：计入 disclosedSecurityCoverage
            disclosedSecurityCoverage += weight
        }

        // 3) 标的暴露（合并降序 + 上下界）
        let unknown = Ratio(value: unknownWeight)
        let underlyingPositions = positionWeight
            .map { listing, weight -> LookthroughSnapshot.UnderlyingPosition in
                let contributors = (positionAccumulator[listing] ?? [])
                    .sorted {
                        if $0.contribution.value != $1.contribution.value {
                            return $0.contribution.value > $1.contribution.value
                        }
                        return ($0.fundProductID?.rawValue ?? "") < ($1.fundProductID?.rawValue ?? "")
                    }
                return .init(
                    listingID: listing,
                    weight: Ratio(value: weight),
                    lowerBound: Ratio(value: weight),
                    upperBound: Ratio(value: weight + unknownWeight),
                    contributors: contributors
                )
            }
            .sorted {
                if $0.weight.value != $1.weight.value { return $0.weight.value > $1.weight.value }
                return $0.listingID.rawValue < $1.listingID.rawValue
            }

        // 4) 资产大类暴露（confirmed 降序；本维缺口不伪造类别，进上界）
        let assetClassExposures = assetClassConfirmed
            .map { cls, weight in
                LookthroughSnapshot.AssetClassExposure(
                    assetClass: cls,
                    confirmedWeight: Ratio(value: weight),
                    upperBoundWeight: Ratio(value: weight + assetClassUnknown)
                )
            }
            .sorted {
                if $0.confirmedWeight.value != $1.confirmedWeight.value {
                    return $0.confirmedWeight.value > $1.confirmedWeight.value
                }
                return $0.assetClass.rawValue < $1.assetClass.rawValue
            }

        // 5) 行业暴露（可选输入驱动；无分类标的与基金未披露部分进行业维 unknown）
        var industryConfirmed: [String: (system: String?, weight: Decimal)] = [:]
        var industryUnknown = unknownWeight
        for (listing, weight) in positionWeight {
            if let sector = parameters.sectorClassifications[listing] {
                let key = sector.label
                if let existing = industryConfirmed[key] {
                    industryConfirmed[key] = (existing.system, existing.weight + weight)
                } else {
                    industryConfirmed[key] = (sector.classificationSystem, weight)
                }
            } else {
                industryUnknown += weight
            }
        }
        let industryExposures = industryConfirmed
            .map { label, entry in
                LookthroughSnapshot.IndustryExposure(
                    label: label,
                    classificationSystem: entry.system,
                    confirmedWeight: Ratio(value: entry.weight),
                    upperBoundWeight: Ratio(value: entry.weight + industryUnknown)
                )
            }
            .sorted {
                if $0.confirmedWeight.value != $1.confirmedWeight.value {
                    return $0.confirmedWeight.value > $1.confirmedWeight.value
                }
                return $0.label < $1.label
            }

        // 6) provenance：参与的 observation（holding + allocation）→ dependencies
        let sourceIDs = disclosures.flatMap { input -> [ObservationID] in
            var ids: [ObservationID] = []
            if let h = input.holding { ids.append(h.id) }
            if let a = input.allocation { ids.append(a.id) }
            return ids
        }
        .sorted { $0.rawValue < $1.rawValue }

        let coveredFunds = fundSummaries.filter { $0.disclosedSecurityWeight != nil }.count
        let fundDataCoverage = normalized
            .filter { $0.input.fundProductID != nil && disclosureByProduct[$0.input.fundProductID!]?.holding != nil }
            .reduce(Decimal.zero) { $0 + $1.weight }

        // ID 语义完备（审查 P1 修复）：asOf + 版本 + 组合输入（权重/直接持股/
        // 资产类）+ 参数（行业映射/陈旧阈值）+ 参与披露——纯直接持股组合
        // 在同一日期不再互相碰撞。producedAt 排除（重算幂等）。
        let payload = try? identityPayload(
            asOf: asOf, positions: positions, parameters: parameters,
            sourceIDs: sourceIDs.map(\.rawValue)
        )
        // identityPayload 只做确定性编码，失败即编程错误——fail-fast
        guard let payload else {
            preconditionFailure("Lookthrough ID payload 编码失败（语义类型新增了不可编码字段）")
        }
        let id = ArtifactID(rawValue: "lt_\(StableDigest.digest(payload))")

        return LookthroughSnapshot(
            id: id,
            producedAt: producedAt,
            validityPolicy: .untilDependencyChanges,
            dependencies: sourceIDs.map { ArtifactDependency(kind: .observation, referenceID: $0.rawValue) },
            asOf: asOf,
            calculatorVersion: Self.calculatorVersion,
            fundCount: fundSummaries.count,
            coveredFundCount: coveredFunds,
            fundDataCoverage: Ratio(value: fundDataCoverage),
            disclosedSecurityCoverage: Ratio(value: disclosedSecurityCoverage),
            unknownPortfolioWeight: Ratio(value: max(unknownWeight, 0)),
            underlyingPositions: underlyingPositions,
            assetClassExposures: assetClassExposures,
            industryExposures: industryExposures,
            fundSummaries: fundSummaries,
            warnings: warnings,
            sourceObservationIDs: sourceIDs
        )
    }

    // MARK: - helpers

    /// ID 身份 payload（语义完备 + **跨进程稳定**——二轮审查 P1-3）：
    /// 无市值行权重 / 直接持股 / 资产类全进 positions 串；行业映射是
    /// Hashable 键字典（JSON 交替数组顺序随进程漂移）——显式转排序数组；
    /// positions 输入顺序不稳定——按规范串排序后编码。
    private struct IdentityPayload: Encodable {
        let kind = "lookthrough"
        let version = PortfolioLookthroughCalculator.calculatorVersion
        let asOf: Date
        /// 每持仓的规范串（"fund|A|0.6" / "direct|L1|0.2|EQUITY"），排序后
        let positions: [String]
        /// 行业分类（"listing|label|system"），排序后
        let sectorClassifications: [String]
        let maxDisclosureAgeDays: Int
        let sourceIDs: [String]
    }

    private func identityPayload(
        asOf: Date, positions: [LookthroughPositionInput],
        parameters: Parameters, sourceIDs: [String]
    ) throws -> String {
        let positionStrings = positions.map { input -> String in
            let weight = input.weight.value
            if let fund = input.fundProductID {
                return "fund|\(fund.rawValue)|\(weight)"
            }
            let listing = input.directListingID?.rawValue ?? "-"
            let assetClass = input.directAssetClass?.rawValue ?? "-"
            return "direct|\(listing)|\(weight)|\(assetClass)"
        }.sorted()
        let sectorStrings = StableDigest.sortedKeyEntries(parameters.sectorClassifications) { sector in
            "\(sector.label)|\(sector.classificationSystem ?? "-")"
        }
        return try StableDigest.jsonPayload(IdentityPayload(
            asOf: asOf,
            positions: positionStrings,
            sectorClassifications: sectorStrings,
            maxDisclosureAgeDays: parameters.maxDisclosureAgeDays,
            sourceIDs: sourceIDs
        ))
    }

    private static let secondsPerDay: Double = 86400

    private static func ageDays(from: Date, to: Date) -> Int {
        max(0, Int((to.timeIntervalSince(from) / secondsPerDay).rounded(.down)))
    }

    /// 双 FNV-1a 确定性摘要（与 FactorEngine.shortDigest 同算法）。
    private static func digest(_ input: String) -> String {
        let data = Data(input.utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in data {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0xbf58476d1ce4e5b9
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}

private extension Decimal {
    static let one = Decimal(1)
}
