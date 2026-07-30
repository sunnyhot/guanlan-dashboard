import Foundation

/// 估值预警触发维度
enum PortfolioValuationAlertMetric: String, Codable, CaseIterable {
    /// 持有收益率（止盈/止损）
    case holdingProfitPct
    /// 盘中估算涨跌幅
    case estimateChangePct
    /// 盘中估算净值绝对值（仅基金有意义）
    case estimatePrice

    var displayName: String {
        switch self {
        case .holdingProfitPct: return "持有收益率"
        case .estimateChangePct: return "盘中估算涨跌"
        case .estimatePrice: return "估算净值"
        }
    }

    var unit: String {
        switch self {
        case .holdingProfitPct, .estimateChangePct: return "%"
        case .estimatePrice: return ""
        }
    }

    /// 股票不支持估算净值维度
    var appliesToStock: Bool {
        self != .estimatePrice
    }
}

/// 买卖方向（用户配规则时选，决定通知文案）
enum PortfolioValuationAlertSide: String, Codable, CaseIterable {
    /// 提醒卖出（止盈/高位）
    case sell
    /// 提醒加仓（止损/低位）
    case buy

    var displayName: String {
        switch self {
        case .sell: return "提醒卖出"
        case .buy: return "提醒加仓"
        }
    }
}

/// 比较方向
enum PortfolioValuationAlertDirection: String, Codable, CaseIterable {
    /// 上穿 >= 阈值
    case above
    /// 下穿 <= 阈值
    case below

    var displayName: String {
        switch self {
        case .above: return "达到或高于"
        case .below: return "跌到或低于"
        }
    }
}

/// 单条预警规则
struct PortfolioValuationAlertRule: Codable, Identifiable, Equatable {
    let id: UUID
    var metric: PortfolioValuationAlertMetric
    var side: PortfolioValuationAlertSide
    var direction: PortfolioValuationAlertDirection
    /// 收益率/涨跌幅为百分点数字（20 = 20%）；估算净值为绝对值
    var threshold: Double
    var note: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        metric: PortfolioValuationAlertMetric,
        side: PortfolioValuationAlertSide,
        direction: PortfolioValuationAlertDirection,
        threshold: Double,
        note: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.metric = metric
        self.side = side
        self.direction = direction
        self.threshold = threshold
        self.note = note
        self.isEnabled = isEnabled
    }
}

/// 一只标的的全部规则 + 去重状态
struct PortfolioValuationAlertProfile: Codable, Equatable {
    let fundCode: String
    var rules: [PortfolioValuationAlertRule]
    /// 当前已触发未回落的规则 id（滞回去重）
    var breachedRuleIDs: Set<UUID>
    /// 每条规则上次触发时间（ISO 字符串）
    var lastTriggeredAt: [UUID: String]

    init(
        fundCode: String,
        rules: [PortfolioValuationAlertRule] = [],
        breachedRuleIDs: Set<UUID> = [],
        lastTriggeredAt: [UUID: String] = [:]
    ) {
        self.fundCode = fundCode
        self.rules = rules
        self.breachedRuleIDs = breachedRuleIDs
        self.lastTriggeredAt = lastTriggeredAt
    }

    /// 存在任意启用规则
    var hasActiveRules: Bool {
        rules.contains { $0.isEnabled }
    }

    /// 当前是否有规则处于已触发态
    var isCurrentlyBreached: Bool {
        !breachedRuleIDs.isEmpty
    }
}

/// 全局设置
struct PortfolioValuationAlertSettings: Codable, Equatable {
    var isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}
