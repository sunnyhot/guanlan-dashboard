import Foundation

// MARK: - Personal Asset Filter & Sort

/// Scope filter for the personal asset browser. Pure value type, shared by
/// both macOS and iOS asset views.
enum PersonalAssetFilterScope: String, CaseIterable, Identifiable {
    case all = "全部"
    case holding = "已持有"
    case archivedHolding = "已归档"
    case pending = "待确认"
    case activePlan = "进行中计划"
    case archivedPlan = "已暂停/终止"
    case drawdownMode = "涨跌幅计划"

    var id: String { rawValue }
}

/// Sort option for the personal asset browser. Pure value type, shared by
/// both macOS and iOS asset views.
enum PersonalAssetSortOption: String, CaseIterable, Identifiable {
    case dailyChange = "今日涨跌"
    case dailyChangePct = "今日涨跌幅"
    case exposure = "综合敞口"
    case marketValue = "市值"
    case pendingAmount = "待确认金额"
    case nextExecution = "下次定投时间"
    case planCumulative = "累计计划金额"
    case name = "标的名"

    static let defaultOption: PersonalAssetSortOption = .dailyChange

    var id: String { rawValue }
}
