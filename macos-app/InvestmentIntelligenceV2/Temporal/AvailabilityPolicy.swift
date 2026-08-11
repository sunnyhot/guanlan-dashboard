import Foundation

// MARK: - AvailabilityPolicy（ADR-DATA005）
//
// availableAt 是经济可知语义，由版本化 AvailabilityPolicy 计算，
// 不等于 publishedAt 也不等于 ingestedAt（ADR-DATA005 §Decision）。
// V1 保守规则集覆盖三类数据（rollout DOM-7）。

/// 单条 AvailabilityPolicy。
///
/// 每条 policy 含 id / version / rule / provenance，可审计。
/// policy 修订走新 version，旧 vintage 数据保留旧 version 标注（ADR-DATA008）。
protocol AvailabilityPolicy: Sendable, Codable, Hashable {
    /// Policy 唯一标识（如 "fund_nav"、"market_close"、"fund_disclosure"）
    var policyID: String { get }
    /// Policy 版本（如 "v1"、"v2"）
    var version: String { get }
    /// 该 policy 适用的观测类型
    var applicableKind: AvailabilityPolicyKind { get }
    /// Provenance：policy 来源（manual / derived_from_observation / regulation）
    var provenance: AvailabilityPolicyProvenance { get }
    /// 基于 ProviderRecord 推导 availableAt。
    ///
    /// 输入是 Provider 给的（effectiveAt, publishedAt），输出是客观可知的 availableAt。
    /// 不接受 ingestedAt，因为 ingestedAt 是本系统抓取时间，不该影响客观可知语义。
    func availableAt(effectiveAt: Date, publishedAt: Date, calendar: TradingCalendar) -> Date?
}

/// Policy 适用的观测类型。
enum AvailabilityPolicyKind: String, Sendable, Codable, Hashable, CaseIterable {
    case fundNAV = "FUND_NAV"
    case marketClose = "MARKET_CLOSE"
    case fundDisclosure = "FUND_DISCLOSURE"
}

/// Policy 来源。
enum AvailabilityPolicyProvenance: String, Sendable, Codable, Hashable {
    case manual = "MANUAL"
    case derivedFromObservation = "DERIVED_FROM_OBSERVATION"
    case regulation = "REGULATION"
}

// MARK: - TradingCalendar（最小骨架）
//
// 完整 A 股 + 基金净值交易日历在 Epic 6 SYNC-1 实现。
// 这里只放 AvailabilityPolicy 推导所需的最小接口，V1 policy 用它算「次交易日」。

/// 交易日历协议（完整实现见 Epic 6 SYNC-1）。
///
/// AvailabilityPolicy 用它判断「次交易日」、「当日是否交易日」。
/// M2 阶段用 InMemoryTradingCalendar（固定节假日表）即可，Epic 6 换真实日历。
protocol TradingCalendar: Sendable {
    /// 判断某日是否为该法域的交易日。
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool
    /// 返回 d 之后的第一个交易日（不含 d 当日）。
    func nextTradingDay(after date: Date, jurisdiction: Jurisdiction) -> Date
    /// 返回 d 所在交易日的「日界」（当日 00:00 本地时间）。
    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date
}

// MARK: - V1 保守规则集（ADR-DATA005 §Decision 1）
//
// V1 保守规则：所有数据统一「availableAt = 公告日 / 净值日的次交易日 00:00」。
// 宁可少算不可多算，防 lookahead bias（ADR-DATA005 §Decision 3）。

/// V1 保守规则集：三类数据各自的 policy。
enum AvailabilityPolicyV1 {
    /// 基金 NAV：T 日净值 T+1 日才可知。
    /// availableAt = navDate + 1 trading day 00:00
    struct FundNAV: AvailabilityPolicy {
        let policyID = "fund_nav"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .fundNAV
        let provenance: AvailabilityPolicyProvenance = .manual

        func availableAt(effectiveAt: Date, publishedAt: Date, calendar: TradingCalendar) -> Date? {
            // 保守：取 effectiveAt（navDate）的次交易日，作为可知时刻
            // 不用 publishedAt（Provider 可能晚给但客观可知早于给的时间）
            let nextDay = calendar.nextTradingDay(after: effectiveAt, jurisdiction: .chinaMainland)
            return calendar.tradingDayStart(nextDay, jurisdiction: .chinaMainland)
        }
    }

    /// 市场收盘：T 日收盘 T+1 日才可知。
    /// availableAt = tradingDay + 1 trading day 00:00
    struct MarketClose: AvailabilityPolicy {
        let policyID = "market_close"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .marketClose
        let provenance: AvailabilityPolicyProvenance = .manual

        func availableAt(effectiveAt: Date, publishedAt: Date, calendar: TradingCalendar) -> Date? {
            // 不同法域交易日不同，按 publishedAt 时点推断（Provider 公布时间）
            // V1 简化：统一用 nextTradingDay，法域由调用方传入 calendar 时隐含
            // 这里保守用次交易日（不假设盘后清算完成时刻）
            let nextDay = calendar.nextTradingDay(after: effectiveAt, jurisdiction: .chinaMainland)
            return calendar.tradingDayStart(nextDay, jurisdiction: .chinaMainland)
        }
    }

    /// 基金披露：公告日次日才可知。
    /// availableAt = announcementDate + 1 trading day 00:00
    struct FundDisclosure: AvailabilityPolicy {
        let policyID = "fund_disclosure"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .fundDisclosure
        let provenance: AvailabilityPolicyProvenance = .manual

        func availableAt(effectiveAt: Date, publishedAt: Date, calendar: TradingCalendar) -> Date? {
            // 公告日的次交易日。effectiveAt 是报告期（如 6-30），publishedAt 是公告日（如 7-20）
            // 客观可知是公告日的次交易日（7-21）
            let nextDay = calendar.nextTradingDay(after: publishedAt, jurisdiction: .chinaMainland)
            return calendar.tradingDayStart(nextDay, jurisdiction: .chinaMainland)
        }
    }

    /// V1 三类 policy 集合。
    static let all: [any AvailabilityPolicy] = [
        FundNAV(),
        MarketClose(),
        FundDisclosure(),
    ]

    /// 按 kind 取 policy。
    static func policy(for kind: AvailabilityPolicyKind) -> any AvailabilityPolicy {
        switch kind {
        case .fundNAV: return FundNAV()
        case .marketClose: return MarketClose()
        case .fundDisclosure: return FundDisclosure()
        }
    }
}
