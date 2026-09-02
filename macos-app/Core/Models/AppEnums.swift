import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case portfolio = "我的持仓"
    case platform = "平台动态"
    case enhancement = "AI研判"
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
        case .enhancement:
            return "sparkles"
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

/// AI 研判页内容 Tab（2026-09-02 布局优化）：三链路大块互斥切换，
/// 一屏只承载一条链路——参照平台板块的 ModuleTabBar 模式。
enum AIResearchTab: String, CaseIterable, Identifiable {
    case intraday = "盘中指引"
    case closeReview = "收盘复盘"
    case longTerm = "组合研判"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .intraday: return "clock.arrow.circlepath"
        case .closeReview: return "sunset.fill"
        case .longTerm: return "briefcase.fill"
        }
    }

    /// 通知深链锚点 → Tab 联动。
    var sectionAnchor: InvestmentTodayResearchRow.Kind {
        switch self {
        case .intraday: return .intraday
        case .closeReview: return .closeReview
        case .longTerm: return .longTerm
        }
    }

    static func tab(for anchor: InvestmentTodayResearchRow.Kind) -> AIResearchTab? {
        switch anchor {
        case .intraday: return .intraday
        case .closeReview: return .closeReview
        case .longTerm: return .longTerm
        case .marketRadar: return nil
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
