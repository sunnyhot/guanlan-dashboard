import Foundation

// Evidence 独立性引擎(Slice 4)。
//
// 解决问题:同一底层事件被多个网页转载时,不应算作多个独立来源。
// 分两轨:
// - 外部研究证据(webSearch/officialFiling/officialFinancial/licensedMarketData):
//   按 publisherKey 分组(归一化,排除 nil/unknown,限定 tier)
// - 事实类证据(portfolioSnapshot/marketQuote/fundDisclosure 等):
//   按 sourceKind 兜底(它们天然独立,不跨工具重复)
//
// 见 docs/ai-pipeline-baseline.md 第 9.2 节(需新建:来源独立性/同源去重)。

enum EvidenceIndependencePolicy {

    /// 独立来源数量(达到 tier 要求的外部证据 + 事实类证据)。
    /// - Parameters:
    ///   - evidence: 待评估的证据
    ///   - minTier: 外部证据的最低 tier 要求(默认 secondary,即 primary/authoritative/secondary 都算)
    static func independentCount(
        for evidence: [TrendEvidence],
        minTier: TrendEvidenceSourceTier = .secondary
    ) -> Int {
        // 外部研究证据:按 publisherKey 分组
        let externalEvidence = evidence.filter { $0.metadata.sourceKind.isExternalResearch }
        let externalGroups = Set(
            externalEvidence
                .filter { meetsTierThreshold($0.metadata.sourceTier, minTier: minTier) }
                .compactMap { normalizedPublisherKey($0.metadata.publisherKey) }
        )

        // 事实类证据:按 sourceKind 分组(每个 sourceKind 算一组)
        let factualEvidence = evidence.filter { !$0.metadata.sourceKind.isExternalResearch }
        let factualGroups = Set(factualEvidence.map(\.metadata.sourceKind.rawValue))

        // 合并:外部独立组 + 事实类组
        // 注意:外部组和事实类组不会冲突(键空间不同——一个是 domain,一个是 sourceKind 枚举值)
        return externalGroups.count + factualGroups.count
    }

    // MARK: - 内部辅助

    /// 归一化 publisherKey:trim,排除 nil/空/"unknown"。
    private static func normalizedPublisherKey(_ key: String?) -> String? {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.lowercased() != "unknown"
        else { return nil }
        return key.lowercased()
    }

    /// 判断 tier 是否达到门槛(按层级顺序:primary > authoritative > secondary > community > unknown)。
    private static func meetsTierThreshold(
        _ tier: TrendEvidenceSourceTier,
        minTier: TrendEvidenceSourceTier
    ) -> Bool {
        let order: [TrendEvidenceSourceTier] = [.primary, .authoritative, .secondary, .community, .unknown]
        guard let tierIdx = order.firstIndex(of: tier),
              let minIdx = order.firstIndex(of: minTier)
        else { return false }
        return tierIdx <= minIdx  // 层级越高(primary)index 越小,<= minTier 才达标
    }
}
