import Foundation

/// 全局 UserDefaults 键常量。集中定义，避免同一字符串散落多处导致拼写漂移。
enum AppStorageKey {
    static let customDataDirectory = "qieman.dashboard.customDataDirectory"
    static let showsInDock = "qieman.dashboard.showsInDock"
    static let autoCheckUpdateOnLaunch = "qieman.dashboard.update.autoCheckOnLaunch"
    static let researchReadingGuideShown = "qieman.dashboard.research.readingGuideShown"
    /// W3.6:上次访问 AI 研判页的时间(timeIntervalSince1970),边栏未读角标的基准。
    static let aiResearchLastSeen = "qieman.dashboard.ai.researchLastSeen"
    /// W2.4(缩窄版):研判详细模式——控制「证据与风险边界」整块显隐,默认简洁。
    static let researchDetailMode = "qieman.dashboard.ai.researchDetailMode"
}
