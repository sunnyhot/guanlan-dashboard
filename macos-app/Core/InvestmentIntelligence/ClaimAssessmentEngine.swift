import Foundation

// Claim Assessment Engine(Slice 4)。
//
// 把独立性(EvidenceIndependencePolicy)+ 时效(EvidenceFreshnessPolicy)+
// 关联性(TrendClaimEvidencePolicy)+ tier 组合成结构化评估。
//
// 输出 ClaimAssessment:支持/反证/独立来源/时效/覆盖/disposition。
// disposition:supported / mixed / weak / contradicted / insufficient
//
// 见 docs/ai-pipeline-baseline.md 第 9.2 节(Claim Assessment)。

enum ClaimAssessmentEngine {

    /// 评估一组研究发现(支持 + 反证)对应的证据强度。
    /// - Parameters:
    ///   - supportingEvidence: 支持性证据
    ///   - counterEvidence: 反证证据
    ///   - targetCode: 目标标的代码(关联性判定)
    ///   - targetName: 目标标的名称
    ///   - sectorKey: 目标板块
    static func assess(
        supportingEvidence: [TrendEvidence],
        counterEvidence: [TrendEvidence],
        targetCode: String? = nil,
        targetName: String? = nil,
        sectorKey: String? = nil
    ) -> ClaimAssessment {
        let allEvidence = supportingEvidence + counterEvidence

        // 独立性
        let supportingIndependence = EvidenceIndependencePolicy.independentCount(for: supportingEvidence)
        let counterIndependence = EvidenceIndependencePolicy.independentCount(for: counterEvidence)

        // 时效
        let freshness = EvidenceFreshnessPolicy.assessBatch(allEvidence)

        // 关联性(复用 TrendClaimEvidencePolicy)
        let policy = TrendClaimEvidencePolicy()
        let hasAssociatedSupport = supportingEvidence.contains { e in
            !policy.lacksAssociatedSupport(
                evidence: TrendClaimEvidence(supportingEvidenceIDs: [e.id]),
                evidenceByID: [e.id: e],
                entityCode: targetCode,
                entityName: targetName,
                sectorKey: sectorKey
            )
        }

        // tier 统计(外部研究证据中,primary/authoritative 的数量)
        let strongTierCount = supportingEvidence.filter {
            $0.metadata.sourceKind.isExternalResearch
                && ($0.metadata.sourceTier == .primary || $0.metadata.sourceTier == .authoritative)
        }.count

        // 综合判定
        let disposition = computeDisposition(
            supportingCount: supportingEvidence.count,
            counterCount: counterEvidence.count,
            supportingIndependence: supportingIndependence,
            counterIndependence: counterIndependence,
            hasAssociatedSupport: hasAssociatedSupport,
            freshExternalCount: freshness.perEvidence.filter {
                $0.0.metadata.sourceKind.isExternalResearch && $0.1 == .fresh
            }.count,
            strongTierCount: strongTierCount
        )

        return ClaimAssessment(
            supportingEvidenceIDs: supportingEvidence.map(\.id),
            counterEvidenceIDs: counterEvidence.map(\.id),
            independentSourceGroupCount: supportingIndependence,
            counterIndependentGroupCount: counterIndependence,
            supportScore: min(100, supportingIndependence * 25 + strongTierCount * 15),
            counterScore: min(100, counterIndependence * 25),
            netSupport: min(100, supportingIndependence * 25 + strongTierCount * 15) - min(100, counterIndependence * 25),
            dataCoverage: allEvidence.isEmpty ? 0 : min(100, freshness.usableCount * 100 / allEvidence.count),
            freshnessStatus: dominantFreshness(freshness),
            hasAssociatedSupport: hasAssociatedSupport,
            strongTierCount: strongTierCount,
            disposition: disposition
        )
    }

    // MARK: - disposition 判定

    private static func computeDisposition(
        supportingCount: Int,
        counterCount: Int,
        supportingIndependence: Int,
        counterIndependence: Int,
        hasAssociatedSupport: Bool,
        freshExternalCount: Int,
        strongTierCount: Int
    ) -> ClaimDisposition {
        // 无关联证据 → insufficient
        if !hasAssociatedSupport && supportingCount > 0 { return .insufficient }

        // 无支持证据 → insufficient
        if supportingCount == 0 { return .insufficient }

        // 反证强于支持 → contradicted
        if counterIndependence >= 2 && counterIndependence >= supportingIndependence {
            return .contradicted
        }

        // 支持证据充分(≥2 独立来源 + ≥1 强 tier + ≥1 新鲜外部)
        if supportingIndependence >= 2 && strongTierCount >= 1 && freshExternalCount >= 1 {
            return .supported
        }

        // 支持证据存在但不够充分
        if supportingIndependence >= 1 {
            // 有反证但不压倒 → mixed
            if counterIndependence >= 1 { return .mixed }
            return .weak
        }

        return .insufficient
    }

    private static func dominantFreshness(_ summary: EvidenceFreshnessSummary) -> TrendFreshnessStatus {
        if summary.freshCount > 0 { return .fresh }
        if summary.perEvidence.contains(where: { $0.1 == .previousSessionClose }) { return .previousSessionClose }
        if summary.staleCount > 0 { return .stale }
        return .unknown
    }
}

// MARK: - 评估结果

/// Claim 评估结果。
struct ClaimAssessment: Hashable {
    let supportingEvidenceIDs: [String]
    let counterEvidenceIDs: [String]
    let independentSourceGroupCount: Int
    let counterIndependentGroupCount: Int
    let supportScore: Int        // 规则质量分(非概率)
    let counterScore: Int
    let netSupport: Int          // supportScore - counterScore
    let dataCoverage: Int        // 可用证据占比(0-100)
    let freshnessStatus: TrendFreshnessStatus
    let hasAssociatedSupport: Bool
    let strongTierCount: Int     // primary/authoritative 证据数
    let disposition: ClaimDisposition

    /// 是否满足 exitReview 门槛(≥2 独立反向来源 + 关联 + 充分时效)。
    var meetsExitReviewThreshold: Bool {
        counterIndependentGroupCount >= 2
    }
}

/// Claim 判定结果(不能简单用正确/错误)。
enum ClaimDisposition: String, Codable, Hashable, Sendable {
    case supported          // 充分支持
    case mixed              // 支持和反证并存
    case weak               // 支持但不充分
    case contradicted       // 反证压倒支持
    case insufficient       // 证据不足
}
