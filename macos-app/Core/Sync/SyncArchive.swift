import Foundation

// MARK: - SyncPayload(同步明文格式,加密前)
//
// 稳定 DTO,不直接绑内部 Codable。schemaVersion 用于迁移。
// 运行态字段(巡检状态/告警触发态/watchlist 历史价)在组装时清洗掉。

struct SyncPayload: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let sourceDeviceName: String

    // 纯 config(直接用内部类型,无运行态)
    var holdings: [UserPortfolioHolding]
    var pendingTrades: [PersonalPendingTrade]
    var investmentPlans: [PersonalInvestmentPlan]
    var alfaPortfolios: [AlfaPortfolioCatalogItem]

    // 清洗过运行态的子 DTO
    var valuationAlerts: [ValuationAlertProfileConfig]
    var valuationAlertSettings: ValuationAlertSettingsConfig
    var managerWatch: ManagerWatchSyncConfig
    var watchlist: [WatchlistItemSync]

    // 趋势配置(含 API Key,加密保护;内存短暂存在)

    static let currentSchemaVersion = 1
}

// MARK: - 清洗运行态的子 DTO

/// 估值告警 profile config(排除 breachedRuleIDs/lastTriggeredAt 运行态)。
struct ValuationAlertProfileConfig: Codable {
    let fundCode: String
    var rules: [PortfolioValuationAlertRule]

    init(from profile: PortfolioValuationAlertProfile) {
        self.fundCode = profile.fundCode
        self.rules = profile.rules
    }

    /// 还原成完整 profile(运行态字段置空)。
    func toProfile() -> PortfolioValuationAlertProfile {
        PortfolioValuationAlertProfile(fundCode: fundCode, rules: rules,
                                       breachedRuleIDs: [], lastTriggeredAt: [:])
    }
}

/// 估值告警全局设置(仅 isEnabled)。
struct ValuationAlertSettingsConfig: Codable {
    var isEnabled: Bool
    init(from s: PortfolioValuationAlertSettings) { self.isEnabled = s.isEnabled }
    func toSettings() -> PortfolioValuationAlertSettings { .init(isEnabled: isEnabled) }
}

/// 主理人巡检 config(排除 10 个运行态字段)。
struct ManagerWatchSyncConfig: Codable {
    var isEnabled: Bool
    var notificationsEnabled: Bool
    var intervalMinutes: Int
    var prodCode: String
    var managerName: String
    var watchForum: Bool
    var selectedAdjustmentSourceIDs: Set<String>

    init(from s: ManagerWatchSettings) {
        self.isEnabled = s.isEnabled
        self.notificationsEnabled = s.notificationsEnabled
        self.intervalMinutes = s.intervalMinutes
        self.prodCode = s.prodCode
        self.managerName = s.managerName
        self.watchForum = s.watchForum
        self.selectedAdjustmentSourceIDs = s.selectedAdjustmentSourceIDs
    }

    /// 合并进现有 settings(保留本机运行态,只覆盖 config)。
    func merge(into settings: inout ManagerWatchSettings) {
        settings.isEnabled = isEnabled
        settings.notificationsEnabled = notificationsEnabled
        settings.intervalMinutes = intervalMinutes
        settings.prodCode = prodCode
        settings.managerName = managerName
        settings.watchForum = watchForum
        settings.selectedAdjustmentSourceIDs = selectedAdjustmentSourceIDs
    }
}

/// watchlist 项(排除 dailyPoints 历史价 + alertState 运行态)。
struct WatchlistItemSync: Codable {
    let item: PersonalWatchlistItem
    let baseline: PersonalWatchlistBaseline?
    let alertRules: PersonalWatchlistAlertRules?

    init(from r: PersonalWatchlistRecord) {
        self.item = r.item
        self.baseline = r.baseline
        self.alertRules = r.alertRules
    }

    /// 还原成 record(dailyPoints 空,alertState nil,各设备自己刷新累积)。
    func toRecord() -> PersonalWatchlistRecord {
        PersonalWatchlistRecord(item: item, baseline: baseline,
                                dailyPoints: [], alertRules: alertRules, alertState: nil)
    }
}

// MARK: - 导入预览(用于确认对话框)

struct SyncImportPreview {
    let exportedAt: Date
    let sourceDeviceName: String
    let schemaVersion: Int
    let holdingsCount: Int
    let pendingTradesCount: Int
    let plansCount: Int
    let watchlistCount: Int
    let alfaCount: Int
    let hasTrendConfig: Bool

    var confirmationText: String {
        """
        导出时间：\(exportedAt.formatted(date: .abbreviated, time: .shortened))
        来源设备：\(sourceDeviceName)
        持仓 \(holdingsCount) · 待确认 \(pendingTradesCount) · 计划 \(plansCount) · 关注 \(watchlistCount) · 投顾 \(alfaCount)
        \(hasTrendConfig ? "含 AI 模型配置" : "")
        此操作将完全覆盖本机数据；如有需要，可以使用“撤销上次下载”恢复。
        """
    }
}
