import Foundation

// MARK: - DailyAttribution artifact（ATTR-2，Epic 9）
//
// 单日组合归因的 Artifact 化。ValidityPolicy = immutableHistorical：
// 已发生交易日的归因是历史事实，永不失效（下游缓存 / 重放依赖此语义；
// 修订上游数据走重新计算产出新 artifact，不是让旧 artifact「失效」）。
//
// portfolioKey 是调用方定义的语义化组合键（且慢组合 prodCode / 自建组合
// 标识等）；V2 尚无组合 Canonical Entity，不为此提前造类型。

/// 单日组合归因 artifact。
struct DailyAttribution: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 历史归因永不失效（ATTR-2 验收）
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    /// 归因交易日（区间 [date 当日, 次日)，单日语义）
    let attributionDate: Date
    /// 调用方定义的组合键（且慢 prodCode / 自建组合标识）
    let portfolioKey: String
    /// 归因引擎产出
    let result: AttributionResult

    init(attributionDate: Date, portfolioKey: String, result: AttributionResult, producedAt: Date) {
        self.attributionDate = attributionDate
        self.portfolioKey = portfolioKey
        self.result = result
        self.producedAt = producedAt
        self.validityPolicy = .immutableHistorical

        let sourceIDs = result.contributions.compactMap(\.sourceObservationID)
        self.dependencies = sourceIDs
            .map { ArtifactDependency(kind: .observation, referenceID: $0.rawValue) }
            .sorted { $0.referenceID < $1.referenceID }

        let canonical = "daily-attribution|\(portfolioKey)|\(Int(attributionDate.timeIntervalSince1970))|\(result.engineVersion)|\(result.attributedReturn.value)|\(result.coverage.value)|\(sourceIDs.map(\.rawValue).sorted().joined(separator: ","))"
        self.id = ArtifactID(rawValue: "attr_\(Self.digest(canonical))")
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
