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

/// 设置中心分区路由（macOS / iOS 共用；产品重构 §9——跨板块精确跳转）。
///
/// Core 只发布「待跳转分区」，Settings View 消费后清空——避免 Core 反向
/// 引用 SwiftUI View 类型（原 macOS View 私有的 SettingsFocus 收敛于此）。
enum AppSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case watch
    case menuBar
    case valuationAlert
    case sync
    case intelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .watch: return "提醒与巡检"
        case .menuBar: return "菜单栏"
        case .valuationAlert: return "估值预警"
        case .sync: return "数据同步"
        case .intelligence: return "投资智能"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观、启动与更新"
        case .watch: return "主理人动态通知"
        case .menuBar: return "摘要样式与内容"
        case .valuationAlert: return "持仓目标买卖提醒"
        case .sync: return "跨设备同步数据"
        case .intelligence: return "AI 模型、市场数据与隐私"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .watch: return "bell.badge"
        case .menuBar: return "menubar.rectangle"
        case .valuationAlert: return "target"
        case .sync: return "icloud.and.arrow.up.and.down"
        case .intelligence: return "brain.head.profile"
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
