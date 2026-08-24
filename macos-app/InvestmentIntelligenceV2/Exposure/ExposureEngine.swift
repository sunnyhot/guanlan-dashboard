import Foundation

// MARK: - ExposureEngine（EXP-2，Epic 8）
//
// 消费 EXP-1 的 LookthroughSnapshot（asset class / sector / single
// security 三维已带上下界——unknownWeight 进入上下界是 EXP-1 落地的
// 语义），规范化为统一 ExposureEstimate 形状；新增 fund overlap 维度
// （基金两两披露持仓重叠，含 unknown 上界）。
//
// 全部纯计算（D002 确定性），不读 Repository / 全局状态——数据由调用方
// 按 KnowledgeContext 取好传入。

// MARK: - ExposureEstimate（统一形状，V3.1 §33 上下界语义）

/// 单个维度的暴露估计。
///
/// 上下界语义（与 LookthroughSnapshot 一致的最坏情况归因，非概率区间）：
/// - lowerBound = 已确认（披露 / 直接持股归入）的部分
/// - upperBound = lowerBound + 对应维度的 unknown（unknown 理论上可能
///   全部属于本 key）
struct ExposureEstimate: Sendable, Codable, Hashable {
    let dimension: Dimension
    /// 维度内标识：assetClass rawValue / sector label / listingID / 基金对 "A|B"
    let key: String
    let lowerBound: Ratio
    let upperBound: Ratio
    /// 参与计算的 observation IDs（溯源；fund overlap 维度含两只基金的披露）
    let sourceObservationIDs: [ObservationID]

    enum Dimension: String, Sendable, Codable, Hashable {
        case assetClass = "ASSET_CLASS"
        case sector = "SECTOR"
        case singleSecurity = "SINGLE_SECURITY"
        case fundOverlap = "FUND_OVERLAP"
    }
}

/// 基金两两披露持仓重叠（诊断「多只基金重复持股」）。
struct FundOverlap: Sendable, Codable, Hashable {
    let fundA: FundProductID
    let fundB: FundProductID
    /// 披露内重叠 = Σ min(wA_i, wB_i)（0-1 绝对权重和；双方满仓时上确界 1）
    let disclosedOverlap: Ratio
    /// 最坏情况上界 = disclosedOverlap + min(unknownA, unknownB)
    ///（未披露部分理论上可能完全重叠）
    let upperBound: Ratio
    /// 共同持仓（按双方较小权重降序）
    let commonListings: [ListingID]
}

// MARK: - ExposureReport（Artifact）

/// 组合暴露报告（EXP-2 产出，RISK-1 集中度 / DEC-2 状态约束的输入）。
struct ExposureReport: Artifact {
    let id: ArtifactID
    let producedAt: Date
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    let asOf: Date
    let engineVersion: String
    /// 组合级未穿透权重（从 lookthrough 透传；所有维度的上界共用它或维度 unknown）
    let unknownPortfolioWeight: Ratio
    /// 全部维度的估计（按 dimension 分组内 lowerBound 降序）
    let estimates: [ExposureEstimate]
    /// 基金重叠明细（disclosedOverlap 降序，topN 截断；无披露时空）
    let fundOverlaps: [FundOverlap]
}

// MARK: - 引擎

/// 暴露引擎（EXP-2）：lookthrough 三维规范化 + fund overlap 现算。
struct ExposureEngine: Sendable {
    static let engineVersion = "v1"

    /// 计算参数（versioned）。
    struct Parameters: Sendable, Codable, Hashable {
        /// fund overlap 输出前 N 对（按重叠度降序）
        let overlapTopN: Int
        init(overlapTopN: Int = 10) {
            self.overlapTopN = overlapTopN
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 计算暴露报告。
    ///
    /// - lookthrough：EXP-1 产出（调用方先算）
    /// - holdings：参与 overlap 计算的基金披露（key = productID；nil 时
    ///   fundOverlaps 为空，三维估计仍产出）
    func compute(
        lookthrough: LookthroughSnapshot,
        holdings: [FundProductID: FundHoldingSnapshot],
        producedAt: Date
    ) -> ExposureReport {
        var estimates: [ExposureEstimate] = []

        // 1) 三维规范化（bounds 语义原样保持——EXP-1 已含 unknown）
        for exposure in lookthrough.assetClassExposures {
            estimates.append(ExposureEstimate(
                dimension: .assetClass,
                key: exposure.assetClass.rawValue,
                lowerBound: exposure.confirmedWeight,
                upperBound: exposure.upperBoundWeight,
                sourceObservationIDs: lookthrough.sourceObservationIDs
            ))
        }
        for exposure in lookthrough.industryExposures {
            estimates.append(ExposureEstimate(
                dimension: .sector,
                key: exposure.label,
                lowerBound: exposure.confirmedWeight,
                upperBound: exposure.upperBoundWeight,
                sourceObservationIDs: lookthrough.sourceObservationIDs
            ))
        }
        for position in lookthrough.underlyingPositions {
            estimates.append(ExposureEstimate(
                dimension: .singleSecurity,
                key: position.listingID.rawValue,
                lowerBound: position.weight,
                upperBound: position.upperBound,
                sourceObservationIDs: lookthrough.sourceObservationIDs
            ))
        }
        estimates.sort {
            if $0.dimension != $1.dimension {
                return $0.dimension.rawValue < $1.dimension.rawValue
            }
            if $0.lowerBound.value != $1.lowerBound.value {
                return $0.lowerBound.value > $1.lowerBound.value
            }
            return $0.key < $1.key
        }

        // 2) fund overlap 现算（披露内 min 权重和 + unknown 上界）
        let overlaps = computeOverlaps(holdings: holdings)
        let sortedOverlaps = overlaps
            .sorted {
                if $0.disclosedOverlap.value != $1.disclosedOverlap.value {
                    return $0.disclosedOverlap.value > $1.disclosedOverlap.value
                }
                return ($0.fundA.rawValue, $0.fundB.rawValue) < ($1.fundA.rawValue, $1.fundB.rawValue)
            }
            .prefix(max(parameters.overlapTopN, 0))

        // 3) overlap 维度也进统一 estimates（key = "A|B"）
        for overlap in sortedOverlaps {
            estimates.append(ExposureEstimate(
                dimension: .fundOverlap,
                key: "\(overlap.fundA.rawValue)|\(overlap.fundB.rawValue)",
                lowerBound: overlap.disclosedOverlap,
                upperBound: overlap.upperBound,
                sourceObservationIDs: [
                    holdings[overlap.fundA]?.id, holdings[overlap.fundB]?.id,
                ].compactMap { $0 }
            ))
        }

        // 4) provenance
        let holdingIDs = holdings.values.map(\.id).sorted { $0.rawValue < $1.rawValue }
        let lookthroughIDs = lookthrough.sourceObservationIDs
        let sourceIDs = (lookthroughIDs + holdingIDs).sorted { $0.rawValue < $1.rawValue }
        let canonical = "exposure|\(lookthrough.id.rawValue)|\(Self.engineVersion)|\(holdings.keys.map(\.rawValue).sorted().joined(separator: ","))"
        let id = ArtifactID(rawValue: "exp_\(Self.digest(canonical))")

        return ExposureReport(
            id: id,
            producedAt: producedAt,
            validityPolicy: .untilDependencyChanges,
            dependencies: sourceIDs.map { ArtifactDependency(kind: .observation, referenceID: $0.rawValue) },
            asOf: lookthrough.asOf,
            engineVersion: Self.engineVersion,
            unknownPortfolioWeight: lookthrough.unknownPortfolioWeight,
            estimates: estimates,
            fundOverlaps: Array(sortedOverlaps)
        )
    }

    // MARK: - overlap

    /// 基金两两重叠（全部对，外层按 key 排序保证确定性）。
    private func computeOverlaps(holdings: [FundProductID: FundHoldingSnapshot]) -> [FundOverlap] {
        let products = holdings.keys.sorted { $0.rawValue < $1.rawValue }
        var result: [FundOverlap] = []
        for i in 0..<products.count {
            for j in (i + 1)..<products.count {
                result.append(overlap(between: holdings[products[i]]!, and: holdings[products[j]]!))
            }
        }
        return result
    }

    /// 单对基金重叠：Σ min(wA, wB)（仅双方披露范围内）。
    private func overlap(between a: FundHoldingSnapshot, and b: FundHoldingSnapshot) -> FundOverlap {
        let weightsA = Dictionary(a.positions.map { ($0.listingID, $0.weight.value) }, uniquingKeysWith: +)
        let weightsB = Dictionary(b.positions.map { ($0.listingID, $0.weight.value) }, uniquingKeysWith: +)

        var common: [(listing: ListingID, minWeight: Decimal)] = []
        var disclosed: Decimal = .zero
        for (listing, wa) in weightsA {
            guard let wb = weightsB[listing] else { continue }
            let m = min(wa, wb)
            disclosed += m
            common.append((listing, m))
        }
        common.sort {
            if $0.minWeight != $1.minWeight { return $0.minWeight > $1.minWeight }
            return $0.listing.rawValue < $1.listing.rawValue
        }

        let unknownA = max(Decimal.one - min(a.disclosedWeightTotal.value, Decimal.one), 0)
        let unknownB = max(Decimal.one - min(b.disclosedWeightTotal.value, Decimal.one), 0)
        let upper = disclosed + min(unknownA, unknownB)

        return FundOverlap(
            fundA: a.productID,
            fundB: b.productID,
            disclosedOverlap: Ratio(value: disclosed),
            upperBound: Ratio(value: upper),
            commonListings: common.map(\.listing)
        )
    }

    /// 双 FNV-1a 确定性摘要（与 FactorEngine / LookthroughCalculator 同算法）。
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
