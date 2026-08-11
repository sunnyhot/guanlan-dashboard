import Foundation

enum NextHourGuidanceProgressStage: String, CaseIterable, Hashable, Sendable {
    case idle
    case refreshingPortfolio
    case refreshingMarket
    case preparingResearch
    case analyzing
    case finalizing
    case completed
    case failed

    var title: String {
        switch self {
        case .idle:
            "等待开始"
        case .refreshingPortfolio:
            "刷新持仓与场内报价"
        case .refreshingMarket:
            "刷新大盘与宽基行情"
        case .preparingResearch:
            "冻结快照并准备研究上下文"
        case .analyzing:
            "行情、新闻、持仓三团队并行分析"
        case .finalizing:
            "汇总决策并执行证据校验"
        case .completed:
            "盘中研判已完成"
        case .failed:
            "盘中研判未完成"
        }
    }

    var completedStepCount: Int {
        switch self {
        case .idle:
            0
        case .refreshingPortfolio:
            0
        case .refreshingMarket:
            1
        case .preparingResearch:
            2
        case .analyzing:
            3
        case .finalizing:
            4
        case .completed:
            5
        case .failed:
            0
        }
    }
}
