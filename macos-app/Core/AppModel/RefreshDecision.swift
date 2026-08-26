import Foundation

enum RefreshDecision: Equatable {
    enum SkipReason: Equatable {
        case unsupportedSection
        case missingPortfolio
        case alreadyRefreshing
        case freshDataAvailable
    }

    case refreshLatest
    case refreshPortfolio
    case skip(reason: SkipReason)

    static let latestFreshnessInterval: TimeInterval = 120
    static let portfolioFreshnessInterval: TimeInterval = 120

    static func sectionTriggered(
        section: AppSection,
        now: Date = Date(),
        lastLatestRefreshAt: Date? = nil,
        lastPortfolioRefreshAt: Date? = nil,
        hasForumPosts: Bool,
        hasPlatformActions: Bool,
        hasPersonalPortfolio: Bool,
        hasPortfolioSnapshot: Bool,
        isRefreshingLatest: Bool,
        isRefreshingPortfolio: Bool
    ) -> RefreshDecision {
        switch section {
        case .overview:
            guard !isRefreshingLatest else { return .skip(reason: .alreadyRefreshing) }
            if hasForumPosts, hasPlatformActions {
                return hasFreshData(since: lastLatestRefreshAt, now: now, interval: latestFreshnessInterval)
                    ? .skip(reason: .freshDataAvailable)
                    : .refreshLatest
            }
            return .refreshLatest
        case .platform:
            guard !isRefreshingLatest else { return .skip(reason: .alreadyRefreshing) }
            if hasForumPosts,
               hasPlatformActions,
               hasFreshData(since: lastLatestRefreshAt, now: now, interval: latestFreshnessInterval) {
                return .skip(reason: .freshDataAvailable)
            }
            return .refreshLatest
        case .portfolio:
            guard hasPersonalPortfolio else { return .skip(reason: .missingPortfolio) }
            guard !isRefreshingPortfolio else { return .skip(reason: .alreadyRefreshing) }
            if hasPortfolioSnapshot, hasFreshData(since: lastPortfolioRefreshAt, now: now, interval: portfolioFreshnessInterval) {
                return .skip(reason: .freshDataAvailable)
            }
            return .refreshPortfolio
        case .intelligence, .settings:
            return .skip(reason: .unsupportedSection)
        }
    }

    private static func hasFreshData(since date: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < interval
    }
}
