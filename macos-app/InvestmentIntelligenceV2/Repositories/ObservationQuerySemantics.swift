import Foundation

// MARK: - ObservationQuerySemantics（GRDB-7，Repository 查询语义的单一权威）
//
// PIT 过滤 / multi-vintage 择优 / 跨源去重的**行为定义**只有一个地方：
// 本 enum 的纯函数。InMemoryRepository（M2 载体）与 GRDBRepository（M4
// Canonical Store）都经由它实现 Repository 协议——golden test「InMemory 时代
// 的行为在 GRDB 时代同样过」由结构保证：不是两份近似实现，是同一份语义。
//
// 行为契约（ADR-DATA002 §Decision 2 + ADR-DATA008 + REPO-2b）：
// - economicKnowledge / operationalKnowledge：可见性过滤 → 按分组键分组 →
//   每组保留择优后的单条（修订与原版不同时进序列；跨源确定性选一）
// - exactSnapshot：effectiveAt == at 的全部 vintage（不分组不去重）
// - vintageFilter 精确匹配优先

/// Repository 观测查询语义（纯函数命名空间）。
enum ObservationQuerySemantics {

    /// 按 KnowledgeContext 过滤观测序列（泛型，所有 Observation 域共用）。
    ///
    /// - `economicKnowledge` / `operationalKnowledge`：先按 mode 过滤可见性，
    ///   再按 `grouping` 键分组、每组只保留可见的最新 vintage（防修订版与原版
    ///   同时进入时间序列导致因子重复计算，审查 P1 修复点）。
    ///   同 (分组键, vintage) 跨 Provider 时按确定性 tie-breaker 择优（REPO-2b）。
    ///   若 `context.vintageFilter` 非空且精确匹配某 vintage，则只返回那一条。
    /// - `exactSnapshot`：返回 `effectiveAt == at` 的全部 vintage（不分组、不去重）。
    ///
    /// `grouping` 默认按 effectiveAt 分组（时间序列域：一天一条）。基本面域
    /// 传期间键 (metricKey, unit, periodStart, periodEnd)——多个事实可共享
    /// effectiveAt（REPO-1b）。
    static func filterByContext<T: CanonicalObservation>(
        _ observations: [T],
        context: KnowledgeContext,
        grouping: (T) -> AnyHashable = { $0.temporalEnvelope.effectiveAt }
    ) -> [T] {
        // 精确 vintage 过滤优先：若指定且匹配，只返回那一条
        if let wanted = context.vintageFilter {
            let matched = observations.filter { $0.vintage == wanted }
            return matched.filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
                .sorted(by: byVintageThenDeterministicOrder)
        }

        switch context.mode {
        case .exactSnapshot:
            // 返回该 effectiveAt 的全部 vintage；vintage 优先，等值 vintage 的相对
            // 顺序由确定性 tie-break 兜底（GRDB 侧 SQL 索引扫描顺序与内存侧插入
            // 顺序不同，排序键必须与输入顺序无关——parity 的前提）
            return observations
                .filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
                .sorted(by: byVintageThenDeterministicOrder)
        case .economicKnowledge, .operationalKnowledge:
            // 先按可见性过滤
            let visible = observations.filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
            // 按 grouping 键分组，每组只保留择优后的单条（REPO-2b：含跨源去重）
            var bestPerGroup: [AnyHashable: T] = [:]
            for obs in visible {
                let key = grouping(obs)
                if let existing = bestPerGroup[key] {
                    if isPreferred(candidate: obs, over: existing, preferredProvider: context.preferredProvider) {
                        bestPerGroup[key] = obs
                    }
                } else {
                    bestPerGroup[key] = obs
                }
            }
            // 多组可共享 effectiveAt（如基本面多指标同期），id 兜底保证跨运行稳定
            return bestPerGroup.values.sorted {
                if $0.temporalEnvelope.effectiveAt != $1.temporalEnvelope.effectiveAt {
                    return $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt
                }
                return $0.id.rawValue < $1.id.rawValue
            }
        }
    }

    /// 单点查询（dailyBar(on:) / navObservation(on:) 的共享语义）。
    ///
    /// 与序列查询同一套 context 语义（一轮审查 P1 修复：此前单点只按可见性
    /// 过滤 + 最大 vintage，绕过 vintageFilter / preferredProvider / 跨源择优；
    /// 二轮审查 P2 修复：vintageFilter / exactSnapshot 分支此前又漏了
    /// preferredProvider）：
    /// - `vintageFilter` 指定：可见的该 vintage 候选中按 `isPreferred` 全序
    ///   取最优（含来源偏好）
    /// - `exactSnapshot`：先取可见的最新 vintage，再在该 vintage 候选中按
    ///   `isPreferred` 全序取最优（序列型 exactSnapshot 保留全部来源，单点
    ///   必须选一条，故走择优）
    /// - `economic / operational`：走 filterByContext 的分组择优（同日一组，
    ///   择优链已含 preferredProvider），多组时取确定性末位兜底
    static func selectPointObservation<T: CanonicalObservation>(
        _ observations: [T],
        context: KnowledgeContext
    ) -> T? {
        if let wanted = context.vintageFilter {
            let matched = observations
                .filter { $0.vintage == wanted }
                .filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
            return best(of: matched, preferredProvider: context.preferredProvider)
        }
        switch context.mode {
        case .exactSnapshot:
            let visible = observations
                .filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
            guard let latestVintage = visible.map(\.vintage).max() else { return nil }
            let atLatest = visible.filter { $0.vintage == latestVintage }
            return best(of: atLatest, preferredProvider: context.preferredProvider)
        case .economicKnowledge, .operationalKnowledge:
            return filterByContext(observations, context: context)
                .max(by: byVintageThenDeterministicOrder)
        }
    }

    /// 候选集内按 `isPreferred` 全序取最优（确定性：isPreferred 是与输入顺序
    /// 无关的全序，reduce 收敛到唯一最优；空集返回 nil）。
    private static func best<T: CanonicalObservation>(
        of candidates: [T],
        preferredProvider: DataProviderID?
    ) -> T? {
        guard var best = candidates.first else { return nil }
        for next in candidates.dropFirst() {
            if isPreferred(candidate: next, over: best, preferredProvider: preferredProvider) {
                best = next
            }
        }
        return best
    }

    /// vintage → effectiveAt → id 的全序确定性排序（exactSnapshot /
    /// vintageFilter 分支用；与输入顺序无关）。
    private static func byVintageThenDeterministicOrder<T: CanonicalObservation>(_ a: T, _ b: T) -> Bool {
        if a.vintage != b.vintage { return a.vintage < b.vintage }
        if a.temporalEnvelope.effectiveAt != b.temporalEnvelope.effectiveAt {
            return a.temporalEnvelope.effectiveAt < b.temporalEnvelope.effectiveAt
        }
        return a.id.rawValue < b.id.rawValue
    }

    // MARK: - REPO-2b：跨源确定性择优（preferredProvider tie-breaker）

    /// 同 effectiveAt 分组内的择优比较：candidate 是否优于 existing。
    ///
    /// 全序、确定性（不依赖数组顺序），规则（ADR-DATA006 §Decision 1 + rollout REPO-2b）：
    /// 1. 更高 vintage 优先（数据修订，ADR-DATA008）
    /// 2. 同 vintage：**context.preferredProvider 命中者优先**（调用方显式
    ///    声明的数据源偏好，REPO-2b 契约；nil = 未声明，跳过本层）
    /// 3. 更高 reliabilityClass 优先（更可信的 Provider 胜）
    /// 4. 同 reliability：sourceProviderID 确定性 tie-break（"unspecified" 排最后，
    ///    其余按 rawValue 字典序，保证跨运行稳定）
    /// 5. 完全同源：ObservationID rawValue 字典序（最终稳定兜底）
    ///
    /// preferredProvider 只在**同 vintage 跨源**间生效：修订（更高 vintage）
    /// 仍优先于来源偏好——旧 vintage 的偏好源数据不能盖过新修订。
    static func isPreferred<T: CanonicalObservation>(
        candidate: T,
        over existing: T,
        preferredProvider: DataProviderID? = nil
    ) -> Bool {
        // 1. vintage（数据修订）
        if candidate.vintage > existing.vintage { return true }
        if candidate.vintage < existing.vintage { return false }
        // 2. preferredProvider（调用方显式来源偏好，REPO-2b）
        if let preferred = preferredProvider {
            let candHit = candidate.dataQuality.sourceProviderID == preferred
            let exHit = existing.dataQuality.sourceProviderID == preferred
            if candHit != exHit { return candHit }
        }
        // 3. reliabilityClass（跨源偏好）
        let candRel = reliabilityPreferenceRank(candidate.dataQuality.providerReliability)
        let exRel = reliabilityPreferenceRank(existing.dataQuality.providerReliability)
        if candRel != exRel { return candRel > exRel }
        // 4. sourceProviderID 确定性 tie-break
        let candProv = providerSortKey(candidate.dataQuality.sourceProviderID.rawValue)
        let exProv = providerSortKey(existing.dataQuality.sourceProviderID.rawValue)
        if candProv != exProv { return candProv < exProv }
        // 5. ObservationID 兜底
        return candidate.id.rawValue < existing.id.rawValue
    }

    /// ProviderReliabilityClass 的偏好序（越高越优先）。
    /// officialStable > documentFreeAPI > communityAggregated > undocumentedPublicEndpoint
    static func reliabilityPreferenceRank(_ cls: ProviderReliabilityClass) -> Int {
        switch cls {
        case .officialStable: return 4
        case .documentFreeAPI: return 3
        case .communityAggregated: return 2
        case .undocumentedPublicEndpoint: return 1
        }
    }

    /// sourceProviderID 的稳定排序键。"unspecified"（测试 fixture 默认值）排最后，
    /// 其余按 rawValue 字典序。返回值越小越优先。
    static func providerSortKey(_ rawValue: String) -> String {
        // 用高位字符前缀确保 unspecified 永远大于任何真实 providerID
        rawValue == "unspecified" ? "\u{10FFFF}\(rawValue)" : rawValue
    }

    /// 单个 envelope 是否符合 context 的可见性部分。
    static func contextIncludes(_ context: KnowledgeContext, envelope: TemporalEnvelope) -> Bool {
        context.mode.includes(envelope: envelope)
    }
}
