import Foundation

// MARK: - PortfolioRiskProfile（RISK-3，Epic 8）
//
// 组合风险画像：多维度聚合（RISK-1 集中度 + RISK-2 相关性 + 数据基础），
// **不产单一分数**——「风险分 7.2/10」这类黑箱形态是明确禁止的：
// 各维度独立呈现，聚合判断交给 Decision（D002 criterion）与用户。
//
// 刻意的类型保证：PortfolioRiskProfile 没有任何聚合分数字段
//（无 score / riskLevel / rating），只有结构化维度。

/// 风险画像的数据基础（画像可信度前提，透明呈现）。
struct RiskDataBasis: Sendable, Codable, Hashable {
    /// 证券明细披露覆盖（0-1，来自 lookthrough）
    let disclosedSecurityCoverage: Ratio
    /// 未穿透权重（0-1）
    let unknownPortfolioWeight: Ratio
    /// 相关性覆盖：已知对数 / unknown 对数（不足三态都算 unknown）
    let knownCorrelationPairs: Int
    let unknownCorrelationPairs: Int
}

/// 组合风险画像（RISK-3，多维度，不产单一分数）。
struct PortfolioRiskProfile: Artifact {
    let id: ArtifactID
    let producedAt: Date
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    let asOf: Date
    let profileVersion: String

    /// 维度一：集中度（RISK-1）
    let concentration: ConcentrationAssessment
    /// 维度二：穿透后前 N 标的的两两相关（RISK-2；不足对显式 unknown）
    let correlations: [CorrelationPair]
    /// 维度三：数据基础（覆盖情况）
    let dataBasis: RiskDataBasis
}

/// 风险画像器（RISK-3，纯函数聚合）。
struct PortfolioRiskProfiler: Sendable {
    static let profileVersion = "v1"

    /// 参数（versioned）。
    struct Parameters: Sendable, Codable, Hashable {
        /// 参与相关性计算的穿透后前 N 标的（两两 C(N,2) 对）
        let correlationTopN: Int
        let correlationParameters: CorrelationCalculator.Parameters

        init(correlationTopN: Int = 5, correlationParameters: CorrelationCalculator.Parameters = .init()) {
            self.correlationTopN = correlationTopN
            self.correlationParameters = correlationParameters
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 生成风险画像。
    ///
    /// - lookthrough：EXP-1 产出（集中度 + 相关性标的选择的依据）
    /// - series：相关标的的价格序列（调用方按 KnowledgeContext 取好）
    func profile(
        lookthrough: LookthroughSnapshot,
        series: [ListingID: [AdjustedClosePoint]],
        producedAt: Date
    ) -> PortfolioRiskProfile {
        // 维度一：集中度
        let concentration = ConcentrationCalculator().compute(lookthrough: lookthrough)

        // 维度二：穿透后前 N 标的的两两相关
        let topListings = Array(lookthrough.underlyingPositions.prefix(parameters.correlationTopN))
            .map(\.listingID)
        let pairs: [(ListingID, ListingID)] = combinations(of: topListings)
        let correlations = CorrelationCalculator(parameters: parameters.correlationParameters)
            .compute(series: series, pairs: pairs)
        let known = correlations.filter { $0.pearson != nil }.count

        // 维度三：数据基础
        let dataBasis = RiskDataBasis(
            disclosedSecurityCoverage: lookthrough.disclosedSecurityCoverage,
            unknownPortfolioWeight: lookthrough.unknownPortfolioWeight,
            knownCorrelationPairs: known,
            unknownCorrelationPairs: correlations.count - known
        )

        // provenance：lookthrough 源 + 相关序列的全部 observation
        let seriesIDs = series.values
            .flatMap { $0.map(\.observationID) }
            .map(\.rawValue)
        let sourceIDs = Set(
            lookthrough.sourceObservationIDs.map(\.rawValue) + seriesIDs
        ).sorted()

        let canonical = "risk-profile|\(lookthrough.id.rawValue)|\(Self.profileVersion)|\(sourceIDs.joined(separator: ","))"
        let id = ArtifactID(rawValue: "risk_\(Self.digest(canonical))")

        return PortfolioRiskProfile(
            id: id,
            producedAt: producedAt,
            validityPolicy: .untilDependencyChanges,
            dependencies: sourceIDs.map { ArtifactDependency(kind: .observation, referenceID: $0) },
            asOf: lookthrough.asOf,
            profileVersion: Self.profileVersion,
            concentration: concentration,
            correlations: correlations,
            dataBasis: dataBasis
        )
    }

    // MARK: - helpers

    /// 有序列表的两两组合（确定性顺序）。
    private func combinations(of items: [ListingID]) -> [(ListingID, ListingID)] {
        var result: [(ListingID, ListingID)] = []
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                result.append((items[i], items[j]))
            }
        }
        return result
    }

    /// 双 FNV-1a 确定性摘要（与同模块其他 id 派生同算法）。
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
