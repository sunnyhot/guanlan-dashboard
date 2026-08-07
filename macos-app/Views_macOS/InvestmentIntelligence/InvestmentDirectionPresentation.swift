import SwiftUI

extension InvestmentDirectionRecommendation {
    var tint: Color {
        switch self {
        case .considerAdd, .keyOpportunity, .considerBuying, .marketTailwind:
            AppPalette.positive
        case .considerReduce, .marketHeadwind:
            AppPalette.warning
        case .holdAndReview, .startWatching, .marketNeutral:
            AppPalette.info
        }
    }

    var systemImage: String {
        switch self {
        case .considerAdd: "plus.circle.fill"
        case .considerReduce: "minus.circle.fill"
        case .holdAndReview: "pause.circle.fill"
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
        case .heldSector: "已持有板块"
        case .marketSector: "全市场板块"
        }
    }
}
