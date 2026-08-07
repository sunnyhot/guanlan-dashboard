import Foundation

struct InvestmentDirectionSignal: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let dimension: InvestmentDirectionDimension
    let recommendation: InvestmentDirectionRecommendation
    let direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
    /// 研判报告基于基金穿透和直接持仓形成的可读暴露说明。
    /// 不使用东方财富 F10 的宽泛统计行业占比冒充投资板块仓位。
    let portfolioExposureText: String?
    let triggerConditions: [String]
    let invalidatingConditions: [String]
    let counterSignals: [String]
    let evidence: [TrendEvidence]
    let independentExternalSourceCount: Int
    let hasAuthoritativeEvidence: Bool

    var evidenceCount: Int {
        evidence.count
    }
}
