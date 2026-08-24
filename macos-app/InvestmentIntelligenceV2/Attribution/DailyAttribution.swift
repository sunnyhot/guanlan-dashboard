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

        // ID 语义完备（审查 P1 修复）：日期 + 组合键 + 完整结果
        // （attributed/coverage/residual/贡献分布）+ 源 IDs——只排除 producedAt。
        // 确定性类型的编码失败 = 编程错误,fail-fast
        let payload = try! StableDigest.jsonPayload(IdentityPayload(
            attributionDate: attributionDate, portfolioKey: portfolioKey,
            result: result, sourceIDs: sourceIDs.map(\.rawValue).sorted()
        ))
        self.id = ArtifactID(rawValue: "attr_\(StableDigest.digest(payload))")
    }

    /// ID 身份 payload（语义完备；审查 P1-3）。
    private struct IdentityPayload: Encodable {
        let attributionDate: Date
        let portfolioKey: String
        let result: AttributionResult
        let sourceIDs: [String]
    }

}
