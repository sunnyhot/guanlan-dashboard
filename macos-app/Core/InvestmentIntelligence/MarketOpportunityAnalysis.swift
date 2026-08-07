import Foundation

struct MarketOpportunityAnalysis: Hashable, Sendable {
    let assetClasses: [InvestmentDirectionSignal]
    let markets: [InvestmentDirectionSignal]
    let heldSectors: [InvestmentDirectionSignal]
    let marketSectorOpportunities: [InvestmentDirectionSignal]
    let marketScanCompleted: Bool
    let generatedAt: String

    var surfacedSignalCount: Int {
        assetClasses.count + markets.count + heldSectors.count + marketSectorOpportunities.count
    }
}
