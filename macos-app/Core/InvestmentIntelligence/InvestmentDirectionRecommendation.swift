import Foundation

/// 投资方向模块使用的条件式结论。
///
/// “可考虑买入/加配/减配”只表示达到研究门槛，仍须结合用户约束和触发条件，
/// 不等同于自动交易指令。
enum InvestmentDirectionRecommendation: String, Hashable, Sendable {
    case startWatching
    case keyOpportunity
    case considerBuying
    case marketTailwind
    case marketNeutral
    case marketHeadwind

    var displayName: String {
        switch self {
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
        case .considerBuying: 0
        case .keyOpportunity: 1
        case .startWatching: 2
        case .marketTailwind: 3
        case .marketHeadwind: 4
        case .marketNeutral: 5
        }
    }
}
