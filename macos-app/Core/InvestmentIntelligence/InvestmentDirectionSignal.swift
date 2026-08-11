import Foundation

struct InvestmentDirectionSignal: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let dimension: InvestmentDirectionDimension
    let recommendation: InvestmentDirectionRecommendation
    let direction: TrendDirection
    let confidence: TrendConfidence
    let rationale: String
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
