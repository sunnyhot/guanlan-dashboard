import Foundation

/// 投资方向模块使用的条件式结论。
///
/// “可考虑买入/加配/减配”只表示达到研究门槛，仍须结合用户约束和触发条件，
/// 不等同于自动交易指令。
enum InvestmentDirectionRecommendation: String, Hashable, Sendable {
    case considerAdd
    case considerReduce
    case holdAndReview
    case startWatching
    case keyOpportunity
    case considerBuying
    case marketTailwind
    case marketNeutral
    case marketHeadwind

    var displayName: String {
        switch self {
        case .considerAdd: "可考虑加配"
        case .considerReduce: "可考虑减配"
        case .holdAndReview: "持有观察"
        case .startWatching: "开始关注"
        case .keyOpportunity: "重点机会"
        case .considerBuying: "可考虑买入"
        case .marketTailwind: "环境偏强"
        case .marketNeutral: "保持观察"
        case .marketHeadwind: "环境偏弱"
        }
    }

    var priority: Int {
        switch self {
        case .considerReduce: 0
        case .considerBuying: 1
        case .considerAdd: 2
        case .keyOpportunity: 3
        case .startWatching: 4
        case .holdAndReview: 5
        case .marketTailwind: 6
        case .marketHeadwind: 7
        case .marketNeutral: 8
        }
    }
}
