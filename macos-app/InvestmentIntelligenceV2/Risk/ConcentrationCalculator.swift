import Foundation

// MARK: - ConcentrationCalculator（RISK-1，Epic 8）
//
// 组合集中度：基金层 / 穿透后证券层 / 行业层三个颗粒度 + HHI。
// 核心验收「多基金重复持股正确识别」：两只基金各持同一标的时，
// 证券层集中度反映合并后的穿透权重（EX P-1 的跨基金合并是数据基础），
// 而不是各自基金层的分散假象。
//
// HHI 上下界（凸性最坏情况）：确认层 HHI = Σ w_i²；unknown 全部归入
// 最大标的时平方和最大 → 上界 = Σ w_i² + 2·w_max·u + u²（u = unknown）。

/// 单个持仓（基金层）集中度。
struct FundPosition: Sendable, Codable, Hashable {
    let productID: FundProductID
    let weight: Ratio
}

/// 穿透后单标的集中度（含上下界）。
struct UnderlyingConcentration: Sendable, Codable, Hashable {
    let listingID: ListingID
    let weight: Ratio
    let upperBound: Ratio
}

/// 行业集中度。
struct SectorConcentration: Sendable, Codable, Hashable {
    let label: String
    let weight: Ratio
}

/// 集中度评估（多维度，不产单一分数——单一分数是 RISK-3 明确禁止的形态）。
struct ConcentrationAssessment: Sendable, Codable, Hashable {
    let calculatorVersion: String

    // 基金层
    /// 最大单一基金持仓（无基金持仓的组合为 nil）
    let largestSingleFund: FundPosition?
    /// 基金层 HHI（Σ fundWeight²，含披露缺失的基金——基金层权重是完整的）
    let fundHHI: Ratio

    // 穿透证券层（重复持股在此暴露）
    let largestUnderlyingSecurity: UnderlyingConcentration?
    /// 确认层证券 HHI（Σ w_i²，只用披露确认的权重）
    let securityHHI: Ratio
    /// 最坏情况证券 HHI（unknown 全归最大标的：+ 2·w_max·u + u²）
    let securityHHIUpperBound: Ratio
    /// 穿透后前 5 大标的确认权重和
    let top5UnderlyingWeight: Ratio

    // 行业层（无行业分类输入时为 nil）
    let largestSector: SectorConcentration?
    /// 行业 HHI（确认部分；nil = 无行业输入）
    let sectorHHI: Ratio?

    // 数据基础
    let unknownPortfolioWeight: Ratio
    /// 穿透后确认的标的数
    let underlyingCount: Int
}

/// 集中度计算器（RISK-1，纯函数）。
struct ConcentrationCalculator: Sendable {
    static let calculatorVersion = "v1"

    /// 基于 EXP-1 穿透快照计算集中度。
    func compute(lookthrough: LookthroughSnapshot) -> ConcentrationAssessment {
        // 基金层
        let largestFund = lookthrough.fundSummaries
            .sorted {
                if $0.portfolioWeight.value != $1.portfolioWeight.value {
                    return $0.portfolioWeight.value > $1.portfolioWeight.value
                }
                return $0.productID.rawValue < $1.productID.rawValue
            }
            .first
            .map { FundPosition(productID: $0.productID, weight: $0.portfolioWeight) }
        let fundHHI = lookthrough.fundSummaries.reduce(Decimal.zero) {
            $0 + $1.portfolioWeight.value * $1.portfolioWeight.value
        }

        // 穿透证券层
        let positions = lookthrough.underlyingPositions
        let largestSecurity = positions.first.map {
            UnderlyingConcentration(listingID: $0.listingID, weight: $0.weight, upperBound: $0.upperBound)
        }
        let securityHHI = positions.reduce(Decimal.zero) {
            $0 + $1.weight.value * $1.weight.value
        }
        let unknown = lookthrough.unknownPortfolioWeight.value
        let maxWeight = positions.first?.weight.value ?? 0
        let hhiUpper = securityHHI + 2 * maxWeight * unknown + unknown * unknown
        let top5 = positions.prefix(5).reduce(Decimal.zero) { $0 + $1.weight.value }

        // 行业层
        let industries = lookthrough.industryExposures
        let largestSector = industries.first.map {
            SectorConcentration(label: $0.label, weight: $0.confirmedWeight)
        }
        let sectorHHI = industries.isEmpty ? nil : industries.reduce(Decimal.zero) {
            $0 + $1.confirmedWeight.value * $1.confirmedWeight.value
        }

        return ConcentrationAssessment(
            calculatorVersion: Self.calculatorVersion,
            largestSingleFund: largestFund,
            fundHHI: Ratio(value: fundHHI),
            largestUnderlyingSecurity: largestSecurity,
            securityHHI: Ratio(value: securityHHI),
            securityHHIUpperBound: Ratio(value: hhiUpper),
            top5UnderlyingWeight: Ratio(value: top5),
            largestSector: largestSector,
            sectorHHI: sectorHHI.map { Ratio(value: $0) },
            unknownPortfolioWeight: lookthrough.unknownPortfolioWeight,
            underlyingCount: positions.count
        )
    }
}
