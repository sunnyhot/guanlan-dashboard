import Foundation

struct MarketOpportunityAnalysis: Hashable, Sendable {
    let assetClasses: [InvestmentDirectionSignal]
    let markets: [InvestmentDirectionSignal]
    let marketSectorOpportunities: [InvestmentDirectionSignal]
    let marketScanCompleted: Bool
    let generatedAt: String

    var marketSignalCount: Int {
        assetClasses.count + markets.count + marketSectorOpportunities.count
    }
}
