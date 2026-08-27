import Foundation

/// 链路 A(趋势研究)完成/失败的本地通知载荷(R2-P1 W3.1)。
///
/// 与链路 B 的 `nextHourGuidanceNotificationSender` 同构:AppModel 持有可注入的
/// 发送闭包,是否发送由 `TrendAnalysisSettings.notifications` 判定;
/// 通知点击经 `NotificationDeepLinkType.investmentIntelligenceSection` 深链
/// 滚动到对应区段锚点。
struct TrendCompletionNotification: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case succeeded
        case failed
    }

    let scope: TrendResearchRunScope
    let outcome: Outcome
    /// 手动触发时用户在场,失败不打扰;只有自动调度失败才通知。
    let userInitiated: Bool
    /// 本次成功前是否已有任何报告(手动首份研判的「第一份研判已生成」用)。
    let isFirstReport: Bool
    /// 机会方向数(仅 marketRadar/full 成功时有意义)。
    let opportunityCount: Int
    let failureSummary: String?

    var title: String {
        switch outcome {
        case .succeeded:
            if userInitiated && isFirstReport { return "你的第一份研判已生成" }
            switch scope {
            case .closeReview: return "今日复盘已生成"
            case .marketRadar: return "今日市场机会已更新"
            case .longTerm: return "本周组合研判已更新"
            case .full: return "研判已生成"
            }
        case .failed:
            return "\(scope.displayName)未完成"
        }
    }

    var body: String {
        switch outcome {
        case .succeeded:
            if userInitiated && isFirstReport { return "点击查看你的第一份 AI 研判。" }
            switch scope {
            case .closeReview: return "点击查看今天的收盘复盘。"
            case .marketRadar:
                return opportunityCount > 0 ? "\(opportunityCount) 个方向,点击查看。" : "点击查看今日扫描结果。"
            case .longTerm: return "点击查看组合方向与行动候选。"
            case .full: return "点击查看完整研判。"
            }
        case .failed:
            guard let failureSummary, !failureSummary.isEmpty else {
                return "可打开 App 手动补做。"
            }
            return "原因:\(String(failureSummary.prefix(60)))。可打开 App 手动补做。"
        }
    }

    /// 通知点击后滚动到的区段(与「今日研判」摘要行的锚点同源)。
    var sectionAnchor: InvestmentTodayResearchRow.Kind? {
        switch scope {
        case .closeReview: return .closeReview
        case .marketRadar: return .marketRadar
        case .longTerm: return .longTerm
        case .full: return .longTerm
        }
    }
}
