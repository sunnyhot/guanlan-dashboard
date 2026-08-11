import Foundation

// MARK: - IdentityResolver（REPO-4，ADR-DATA001 §13 四路径 + fuzzy）
//
// 给定 Provider 代码，解析到 Canonical。4 条正式映射路径按优先级：
// 1. providerAuthoritative：Provider 自带官方 cross-ref
// 2. exchangeSymbolExact：交易所 + symbol 精确匹配
// 3. isinOrCik：ISIN / CIK 全局唯一标识
// 4. manualVerified：人工审核登记
// fuzzy 匹配只产 candidate，必须经 Verification 才能写入 Canonical
//（ADR-DATA001 §Decision 3：fuzzy 不直接写 canonical）。

/// IdentityResolver 的解析结果。
enum IdentityResolution: Sendable, Hashable {
    /// 已确认映射到 Canonical（来自 4 条正式路径）。
    case resolved(CanonicalRef, via: IdentityResolutionMethod)
    /// fuzzy 匹配产出的候选（必须经 Verification 升级为 resolved）。
    case candidates([IdentityCandidate])
    /// 无匹配。
    case unresolved
}

/// fuzzy 匹配产出的候选映射。
struct IdentityCandidate: Sendable, Codable, Hashable {
    let providerID: DataProviderID
    let identifierScheme: String
    let identifierValue: String
    /// 候选 Canonical
    let candidate: CanonicalRef
    /// 匹配置信度（0-1，由 fuzzy 算法决定）
    let confidence: Double
    /// 匹配理由（如「名称相似度 0.92」）
    let rationale: String
}

/// Verification 决策（人工 / 上游系统对 fuzzy candidate 的裁决）。
enum IdentityVerificationDecision: Sendable, Codable, Hashable {
    /// 接受 candidate，升级为 manualVerified 映射
    case accept
    /// 拒绝 candidate（不是同一标的）
    case reject
    /// 标记为「无法判断」（数据不足，留待后续）
    case inconclusive
}

/// IdentityResolver：基于已登记的 ProviderIdentifier 解析 Provider 代码到 Canonical。
///
/// 不直接写 Canonical Master——verification 后的 accept 由调用方
/// （IdentitySync / REPO-4b 初始数据加载）调用 `applyVerification` 把
/// manualVerified 映射写入 Repository。
struct IdentityResolver: Sendable {
    /// 已登记的 ProviderIdentifier 索引（key = provider+scheme+value）。
    /// 由 Repository 提供（resolver 是无状态查询器）。
    private let identifiersByProvider: [String: ProviderIdentifier]

    init(identifiers: [ProviderIdentifier]) {
        var dict: [String: ProviderIdentifier] = [:]
        for pid in identifiers {
            let key = Self.key(pid.providerID, scheme: pid.identifierScheme, value: pid.identifierValue)
            dict[key] = pid
        }
        identifiersByProvider = dict
    }

    /// 从 InMemoryRepository 的 ProviderIdentifier 集合构造（便捷）。
    static func from(_ identifiers: [ProviderIdentifier]) -> IdentityResolver {
        IdentityResolver(identifiers: identifiers)
    }

    // MARK: - 主查询入口

    /// 解析单个 Provider 代码。
    func resolve(
        providerID: DataProviderID,
        scheme: String,
        value: String
    ) -> IdentityResolution {
        let key = Self.key(providerID, scheme: scheme, value: value)
        if let pid = identifiersByProvider[key], pid.resolutionMethod.isAuthoritative {
            return .resolved(pid.canonical, via: pid.resolutionMethod)
        }
        // 已登记但是 fuzzy candidate：返回 candidate
        if let pid = identifiersByProvider[key], pid.resolutionMethod == .fuzzyCandidate {
            let candidate = IdentityCandidate(
                providerID: pid.providerID,
                identifierScheme: pid.identifierScheme,
                identifierValue: pid.identifierValue,
                candidate: pid.canonical,
                confidence: 0.5,   // 简化：已登记的 fuzzy 默认 0.5 置信度
                rationale: "pre-registered fuzzy candidate"
            )
            return .candidates([candidate])
        }
        return .unresolved
    }

    // MARK: - Verification 升级入口

    /// 对 fuzzy candidate 做 Verification，产出的 manualVerified 映射
    /// 由调用方写入 Repository（不在此处直接写）。
    static func applyVerification(
        to candidate: IdentityCandidate,
        decision: IdentityVerificationDecision
    ) -> ProviderIdentifier? {
        switch decision {
        case .accept:
            // 升级为 manualVerified
            return ProviderIdentifier(
                providerID: candidate.providerID,
                identifierScheme: candidate.identifierScheme,
                identifierValue: candidate.identifierValue,
                canonical: candidate.candidate,
                resolutionMethod: .manualVerified,
                resolvedAt: Date()
            )
        case .reject, .inconclusive:
            // 不写入 canonical master
            return nil
        }
    }

    // MARK: - Helper

    static func key(_ providerID: DataProviderID, scheme: String, value: String) -> String {
        "\(providerID.rawValue)::\(scheme)::\(value)"
    }
}
