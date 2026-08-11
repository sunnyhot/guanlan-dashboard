import SwiftUI

extension InvestmentDirectionRecommendation {
    var tint: Color {
        switch self {
        case .keyOpportunity, .considerBuying, .marketTailwind:
            AppPalette.positive
        case .marketHeadwind:
            AppPalette.warning
        case .startWatching, .marketNeutral:
            AppPalette.info
        }
    }

    var systemImage: String {
        switch self {
        case .startWatching: "eye.fill"
        case .keyOpportunity: "scope"
        case .considerBuying: "arrow.up.right.circle.fill"
        case .marketTailwind: "wind"
        case .marketNeutral: "equal.circle.fill"
        case .marketHeadwind: "exclamationmark.triangle.fill"
        }
    }
}

extension InvestmentDirectionDimension {
    var displayName: String {
        switch self {
        case .assetClass: "大类资产"
        case .broadMarket: "大盘/宽基"
        case .marketSector: "全市场板块"
        }
    }
}
