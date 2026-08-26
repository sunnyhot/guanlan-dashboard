import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case portfolio = "我的持仓"
    case platform = "平台动态"
    case intelligence = "投资智能"
    case settings = "设置"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .portfolio:
            return "briefcase"
        case .settings:
            return "gearshape"
        case .platform:
            return "rectangle.stack.badge.play"
        case .intelligence:
            return "brain.head.profile"
        }
    }
}

enum PlatformActivityTab: String, CaseIterable, Identifiable {
    case adjustments = "调仓动态"
    case forum = "论坛发言"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .adjustments: return "chart.bar.xaxis"
        case .forum: return "text.bubble"
        }
    }
}

enum PlatformAdjustmentViewMode: String, CaseIterable, Identifiable {
    case longWin
    case alfa

    var id: Self { self }

    var label: String {
        switch self {
        case .longWin: return "长赢调仓"
        case .alfa: return "投顾组合"
        }
    }
}

enum PersonalAssetDeleteScope: String, CaseIterable, Identifiable {
    case holding
    case pendingTrades
    case investmentPlans
    case all

    var id: String { rawValue }

    var includesHolding: Bool {
        self == .holding || self == .all
    }

    var includesPendingTrades: Bool {
        self == .pendingTrades || self == .all
    }

    var includesInvestmentPlans: Bool {
        self == .investmentPlans || self == .all
    }
}

enum PersonalAssetUnitAdjustmentMode: String, Identifiable {
    case add
    case remove

    var id: String { rawValue }
}

struct PersonalAssetCodeResolution: Hashable {
    let assetType: PersonalAssetType
    let code: String
    let displayName: String?
    let stockMarket: StockMarket?
    let fundMarket: FundMarket?

    init(
        assetType: PersonalAssetType,
        code: String,
        displayName: String?,
        stockMarket: StockMarket? = nil,
        fundMarket: FundMarket? = nil
    ) {
        self.assetType = assetType
        self.code = code
        self.displayName = displayName
        self.stockMarket = stockMarket
        self.fundMarket = fundMarket
    }
}
