import Foundation

// MARK: - AvailabilityPolicy（ADR-DATA005）
//
// availableAt 是经济可知语义，由版本化 AvailabilityPolicy 计算，
// 不等于 publishedAt 也不等于 ingestedAt（ADR-DATA005 §Decision）。
// V1 保守规则集覆盖三类数据（rollout DOM-7）。
//
// 审查 P1 修复点：
// 1. rule 数据化为 AvailabilityRule 结构（base + offset + jurisdictionSource），
//    不再藏在方法体里，可持久化、可审计、可跨市场执行
// 2. 法域由 jurisdictionSource 动态推导（不硬编码 chinaMainland），
//    支持 HK/US Listing
// 3. 自定义 Codable：解码时验证 policyID/version，损坏或版本不匹配的数据
//    抛错而非静默解成 v1

/// 单条 AvailabilityPolicy。
///
/// 每条 policy 含 id / version / rule / provenance，可审计（ADR-DATA005）。
/// policy 修订走新 version，旧 vintage 数据保留旧 version 标注（ADR-DATA008）。
protocol AvailabilityPolicy: Sendable, Codable, Hashable {
    /// Policy 唯一标识（如 "fund_nav"、"market_close"、"fund_disclosure"）
    var policyID: String { get }
    /// Policy 版本（如 "v1"、"v2"）
    var version: String { get }
    /// 该 policy 适用的观测类型
    var applicableKind: AvailabilityPolicyKind { get }
    /// 数据化的规则（base + offset + jurisdictionSource）
    var rule: AvailabilityRule { get }
    /// Provenance：policy 来源（manual / derived_from_observation / regulation）
    var provenance: AvailabilityPolicyProvenance { get }
    /// 基于 ProviderRecord 推导 availableAt。
    ///
    /// 输入是 Provider 给的（effectiveAt, publishedAt）+ 标的法域，输出是客观可知的 availableAt。
    /// 不接受 ingestedAt，因为 ingestedAt 是本系统抓取时间，不该影响客观可知语义（ADR-DATA002 §4）。
    func availableAt(
        effectiveAt: Date,
        publishedAt: Date,
        jurisdiction: Jurisdiction,
        calendar: TradingCalendar
    ) -> Date?
}

/// Policy 适用的观测类型。
enum AvailabilityPolicyKind: String, Sendable, Codable, Hashable, CaseIterable {
    case fundNAV = "FUND_NAV"
    case marketClose = "MARKET_CLOSE"
    case fundDisclosure = "FUND_DISCLOSURE"
    /// 宏观指标发布（如 FRED GDP/CPI）：availableAt 基于发布日 realtime_start（PROV-5）
    case macroRelease = "MACRO_RELEASE"
}

/// Policy 来源。
enum AvailabilityPolicyProvenance: String, Sendable, Codable, Hashable {
    case manual = "MANUAL"
    case derivedFromObservation = "DERIVED_FROM_OBSERVATION"
    case regulation = "REGULATION"
}

/// Policy 解码错误（审查 P1 修复：损坏或版本不匹配的数据抛错而非静默解成 v1）。
enum AvailabilityPolicyDecodeError: Error, Equatable, Sendable {
    /// 解码出的 policyID/version/rule 与预期不符（如 v2 数据解到 v1 类型）
    case identityMismatch(policyID: String, version: String)
}

// MARK: - AvailabilityRule（数据化的规则）
//
// 规则 = 从某个基准时间（effectiveAt / publishedAt）出发，加 N 个交易日 offset，
// 在该法域的交易日 00:00 取 availableAt。
// 法域由 jurisdictionSource 指定（从 listing 推导 / 固定 / 从 publishedAt 推断）。

/// 数据化的可用性规则（可持久化、可审计、可跨市场执行）。
struct AvailabilityRule: Sendable, Codable, Hashable {
    /// 基准时间来源
    let base: Base
    /// 交易日 offset（保守 V1 全是 +1）
    let offset: TradingDayOffset
    /// 法域来源（决定用哪个市场的交易日历）
    let jurisdictionSource: JurisdictionSource

    /// 基准时间从哪个字段取。
    enum Base: String, Sendable, Codable, Hashable {
        case effectiveAt = "EFFECTIVE_AT"     // 如 fund NAV 用 navDate
        case publishedAt = "PUBLISHED_AT"     // 如 fund disclosure 用 announcementDate
    }

    /// 交易日偏移量。
    struct TradingDayOffset: Sendable, Codable, Hashable {
        /// 偏移天数（正数 = 未来第 N 个交易日；0 = 当日）
        let tradingDays: Int
        init(tradingDays: Int) { self.tradingDays = tradingDays }
    }

    /// 法域来源。
    enum JurisdictionSource: Sendable, Codable, Hashable {
        /// 从 Listing 的 exchange 推导（最准确，调用方传入）
        case fromListing
        /// 固定法域（如 fund NAV 默认 CN）
        case fixed(Jurisdiction)
    }
}

// MARK: - TradingCalendar（最小骨架）
//
// 完整 A 股 + 基金净值交易日历在 Epic 6 SYNC-1 实现。
// 这里只放 AvailabilityPolicy 推导所需的最小接口。

/// 交易日历协议（完整实现见 Epic 6 SYNC-1）。
///
/// AvailabilityPolicy 用它判断「次交易日」、「当日是否交易日」。
/// M2 阶段用 InMemoryTradingCalendar（固定节假日表）即可，Epic 6 换真实日历。
protocol TradingCalendar: Sendable {
    /// 判断某日是否为该法域的交易日。
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool
    /// 返回 d 之后的第 N 个交易日（N = offset.tradingDays，不含 d 当日）。
    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date
    /// 返回 d 所在交易日的「日界」（当日 00:00 本地时间）。
    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date
}

// MARK: - AvailabilityPolicy 默认 availableAt 实现（基于 AvailabilityRule）

extension AvailabilityPolicy {
    /// 基于 rule 推导 availableAt 的默认实现。具体 policy 只需提供 rule 字段。
    func availableAt(
        effectiveAt: Date,
        publishedAt: Date,
        jurisdiction: Jurisdiction,
        calendar: TradingCalendar
    ) -> Date? {
        let resolvedJurisdiction: Jurisdiction
        switch rule.jurisdictionSource {
        case .fromListing:
            resolvedJurisdiction = jurisdiction   // 调用方按 listing.exchange.jurisdiction 传入
        case .fixed(let j):
            resolvedJurisdiction = j
        }
        let baseDate: Date
        switch rule.base {
        case .effectiveAt: baseDate = effectiveAt
        case .publishedAt: baseDate = publishedAt
        }
        let targetDay = calendar.tradingDay(
            after: baseDate,
            offset: rule.offset.tradingDays,
            jurisdiction: resolvedJurisdiction
        )
        return calendar.tradingDayStart(targetDay, jurisdiction: resolvedJurisdiction)
    }
}

// MARK: - V1 保守规则集（ADR-DATA005 §Decision 1）

/// V1 保守规则集：三类数据各自的 policy。
///
/// 所有 V1 policy 的 offset 都是 +1 交易日（保守：宁可少算不可多算，
/// ADR-DATA005 §Decision 3）。差异在 base 字段：
/// - FundNAV：base = effectiveAt（navDate）
/// - MarketClose：base = effectiveAt（tradingDay）
/// - FundDisclosure：base = publishedAt（announcementDate）
enum AvailabilityPolicyV1 {
    /// 基金 NAV：T 日净值 T+1 日才可知。
    struct FundNAV: AvailabilityPolicy {
        let policyID = "fund_nav"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .fundNAV
        let provenance: AvailabilityPolicyProvenance = .manual
        let rule: AvailabilityRule
        init() {
            rule = AvailabilityRule(
                base: .effectiveAt,
                offset: .init(tradingDays: 1),
                jurisdictionSource: .fixed(.chinaMainland)   // 公募基金默认 CN
            )
        }

        // 显式解码：校验 id/version/rule 与 V1 一致，损坏或版本不匹配的数据抛错，
        // 不静默解成 v1（审查 P1 修复点）。
        private enum CodingKeys: String, CodingKey {
            case policyID, version, applicableKind, provenance, rule
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try c.decode(String.self, forKey: .policyID)
            let decodedVersion = try c.decode(String.self, forKey: .version)
            let decodedKind = try c.decode(AvailabilityPolicyKind.self, forKey: .applicableKind)
            let decodedProvenance = try c.decode(AvailabilityPolicyProvenance.self, forKey: .provenance)
            let decodedRule = try c.decode(AvailabilityRule.self, forKey: .rule)
            guard decodedID == "fund_nav", decodedVersion == "v1",
                  decodedKind == .fundNAV,
                  decodedProvenance == .manual,   // 审查 P2：provenance 必须匹配，防静默重置
                  decodedRule == AvailabilityRule(
                      base: .effectiveAt, offset: .init(tradingDays: 1),
                      jurisdictionSource: .fixed(.chinaMainland)
                  )
            else {
                throw AvailabilityPolicyDecodeError.identityMismatch(
                    policyID: decodedID, version: decodedVersion
                )
            }
            // 所有字段都是常量，校验通过后保留默认值；rule 从解码值取
            rule = decodedRule
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(policyID, forKey: .policyID)
            try c.encode(version, forKey: .version)
            try c.encode(applicableKind, forKey: .applicableKind)
            try c.encode(provenance, forKey: .provenance)
            try c.encode(rule, forKey: .rule)
        }
    }

    /// 市场收盘：T 日收盘 T+1 日才可知。
    /// 法域从 listing 推导（A股 / 美股 / 港股各自下一交易日）。
    struct MarketClose: AvailabilityPolicy {
        let policyID = "market_close"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .marketClose
        let provenance: AvailabilityPolicyProvenance = .manual
        let rule: AvailabilityRule
        init() {
            rule = AvailabilityRule(
                base: .effectiveAt,
                offset: .init(tradingDays: 1),
                jurisdictionSource: .fromListing   // 不硬编码 CN，跨市场生效
            )
        }

        private enum CodingKeys: String, CodingKey {
            case policyID, version, applicableKind, provenance, rule
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try c.decode(String.self, forKey: .policyID)
            let decodedVersion = try c.decode(String.self, forKey: .version)
            let decodedKind = try c.decode(AvailabilityPolicyKind.self, forKey: .applicableKind)
            let decodedProvenance = try c.decode(AvailabilityPolicyProvenance.self, forKey: .provenance)
            let decodedRule = try c.decode(AvailabilityRule.self, forKey: .rule)
            guard decodedID == "market_close", decodedVersion == "v1",
                  decodedKind == .marketClose,
                  decodedProvenance == .manual,   // 审查 P2：provenance 必须匹配
                  decodedRule == AvailabilityRule(
                      base: .effectiveAt, offset: .init(tradingDays: 1),
                      jurisdictionSource: .fromListing
                  )
            else {
                throw AvailabilityPolicyDecodeError.identityMismatch(
                    policyID: decodedID, version: decodedVersion
                )
            }
            rule = decodedRule
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(policyID, forKey: .policyID)
            try c.encode(version, forKey: .version)
            try c.encode(applicableKind, forKey: .applicableKind)
            try c.encode(provenance, forKey: .provenance)
            try c.encode(rule, forKey: .rule)
        }
    }

    /// 基金披露：公告日次日才可知。
    /// 法域从 listing 推导（披露规则各地不同，但保守统一用上市地法域）。
    struct FundDisclosure: AvailabilityPolicy {
        let policyID = "fund_disclosure"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .fundDisclosure
        let provenance: AvailabilityPolicyProvenance = .manual
        let rule: AvailabilityRule
        init() {
            rule = AvailabilityRule(
                base: .publishedAt,
                offset: .init(tradingDays: 1),
                jurisdictionSource: .fromListing
            )
        }

        private enum CodingKeys: String, CodingKey {
            case policyID, version, applicableKind, provenance, rule
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try c.decode(String.self, forKey: .policyID)
            let decodedVersion = try c.decode(String.self, forKey: .version)
            let decodedKind = try c.decode(AvailabilityPolicyKind.self, forKey: .applicableKind)
            let decodedProvenance = try c.decode(AvailabilityPolicyProvenance.self, forKey: .provenance)
            let decodedRule = try c.decode(AvailabilityRule.self, forKey: .rule)
            guard decodedID == "fund_disclosure", decodedVersion == "v1",
                  decodedKind == .fundDisclosure,
                  decodedProvenance == .manual,   // 审查 P2：provenance 必须匹配
                  decodedRule == AvailabilityRule(
                      base: .publishedAt, offset: .init(tradingDays: 1),
                      jurisdictionSource: .fromListing
                  )
            else {
                throw AvailabilityPolicyDecodeError.identityMismatch(
                    policyID: decodedID, version: decodedVersion
                )
            }
            rule = decodedRule
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(policyID, forKey: .policyID)
            try c.encode(version, forKey: .version)
            try c.encode(applicableKind, forKey: .applicableKind)
            try c.encode(provenance, forKey: .provenance)
            try c.encode(rule, forKey: .rule)
        }
    }

    /// 宏观指标发布：以发布日（realtime_start）+1 交易日才可知（PROV-5）。
    ///
    /// 宏观数据（FRED GDP/CPI 等）的 availableAt 应基于「发布日」而非观测期
    /// （GDP Q1 值 effectiveAt=2024-01-01，但 2024-04-25 才发布）。base=publishedAt
    /// 让 MarketClose 式推导用发布日做基准。法域固定 US（FRED 按美国联邦日历发布）。
    struct MacroRelease: AvailabilityPolicy {
        let policyID = "macro_release"
        let version = "v1"
        let applicableKind: AvailabilityPolicyKind = .macroRelease
        let provenance: AvailabilityPolicyProvenance = .manual
        let rule: AvailabilityRule
        init() {
            rule = AvailabilityRule(
                base: .publishedAt,
                offset: .init(tradingDays: 1),
                jurisdictionSource: .fixed(.unitedStates)
            )
        }

        private enum CodingKeys: String, CodingKey {
            case policyID, version, applicableKind, provenance, rule
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try c.decode(String.self, forKey: .policyID)
            let decodedVersion = try c.decode(String.self, forKey: .version)
            let decodedKind = try c.decode(AvailabilityPolicyKind.self, forKey: .applicableKind)
            let decodedProvenance = try c.decode(AvailabilityPolicyProvenance.self, forKey: .provenance)
            let decodedRule = try c.decode(AvailabilityRule.self, forKey: .rule)
            guard decodedID == "macro_release", decodedVersion == "v1",
                  decodedKind == .macroRelease,
                  decodedProvenance == .manual,
                  decodedRule == AvailabilityRule(
                      base: .publishedAt, offset: .init(tradingDays: 1),
                      jurisdictionSource: .fixed(.unitedStates)
                  )
            else {
                throw AvailabilityPolicyDecodeError.identityMismatch(
                    policyID: decodedID, version: decodedVersion
                )
            }
            rule = decodedRule
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(policyID, forKey: .policyID)
            try c.encode(version, forKey: .version)
            try c.encode(applicableKind, forKey: .applicableKind)
            try c.encode(provenance, forKey: .provenance)
            try c.encode(rule, forKey: .rule)
        }
    }

    /// V1 三类 policy 集合。
    static let all: [any AvailabilityPolicy] = [
        FundNAV(),
        MarketClose(),
        FundDisclosure(),
        MacroRelease(),
    ]

    /// 按 kind 取 policy。
    static func policy(for kind: AvailabilityPolicyKind) -> any AvailabilityPolicy {
        switch kind {
        case .fundNAV: return FundNAV()
        case .marketClose: return MarketClose()
        case .fundDisclosure: return FundDisclosure()
        case .macroRelease: return MacroRelease()
        }
    }
}
