import Foundation

// MARK: - Artifact（V2.2 §84，V3.1 §38）
//
// Artifact 是决策子系统的「产出物」：归因报告、风险画像、因子快照、决策方案。
// 每个 Artifact 有 ValidityPolicy 决定「何时失效」，有 ArtifactDependency 决定
// 「依赖什么、依赖变化时是否需要重算」。

/// 所有 Artifact 的统一协议。
///
/// 协议要求：
/// - 稳定 `id`（ArtifactID）
/// - 产出时间 `producedAt`
/// - `validityPolicy` 决定何时失效
/// - `dependencies` 声明依赖（其他 Artifact / Observation / Signal）
///
/// Artifact 一旦写入 Repository，引用 IDs 不可变（ADR-D004）。
/// 业务层 / Presentation 层只消费 Artifact，不直接重算。
protocol Artifact: Sendable, Codable, Hashable {
    var id: ArtifactID { get }
    var producedAt: Date { get }
    var validityPolicy: ValidityPolicy { get }
    var dependencies: [ArtifactDependency] { get }
}

/// Artifact 有效性策略（V2.2 §84）。
enum ValidityPolicy: Sendable, Codable, Hashable {
    /// 时间绑定：在 `validUntil` 之前有效
    case timeBound(validUntil: Date)
    /// 直到依赖变化：任一 dependency 失效则本 Artifact 失效
    case untilDependencyChanges
    /// 交易时段绑定：本交易时段内有效，下一时段失效
    case tradingSession(sessionDate: Date)
    /// 不可变历史：历史 Artifact 永不失效（如已发生的归因报告）
    case immutableHistorical
    /// 组合：多个条件任一满足即失效
    case composite([ValidityPolicy])

    /// 判断在给定时间点是否仍有效（粗粒度，精确判断需结合 dependency 状态）。
    func isStillValid(at queryAt: Date) -> Bool {
        switch self {
        case .timeBound(let validUntil):
            return queryAt <= validUntil
        case .untilDependencyChanges:
            // 粗粒度：时间维度永远 valid，精确需查 dependency 是否变化
            return true
        case .tradingSession(let sessionDate):
            // 同一交易日内有效（简化：当日 00:00 ~ 次日 00:00）
            let cal = Calendar(identifier: .gregorian)
            return cal.isDate(queryAt, inSameDayAs: sessionDate)
        case .immutableHistorical:
            return true
        case .composite(let policies):
            // 任一失效即失效
            return policies.allSatisfy { $0.isStillValid(at: queryAt) }
        }
    }
}

/// Artifact 依赖（V2.2 §84）。
///
/// 描述本 Artifact 依赖什么，用于：
/// - dependency 失效时让 Artifact 失效（untilDependencyChanges）
/// - D004 replay 时按引用取依赖，不重跑上游
struct ArtifactDependency: Sendable, Codable, Hashable {
    /// 依赖的类型
    let kind: DependencyKind
    /// 依赖的具体 ID（ObservationID / SignalID / ArtifactID 的 rawValue，统一字符串）
    let referenceID: String
    /// 依赖的版本（如 criterion version / factor snapshot version）
    let version: String?

    init(kind: DependencyKind, referenceID: String, version: String? = nil) {
        self.kind = kind
        self.referenceID = referenceID
        self.version = version
    }

    enum DependencyKind: String, Sendable, Codable, Hashable {
        case observation = "OBSERVATION"
        case signal = "SIGNAL"
        case artifact = "ARTIFACT"
        case factorSnapshot = "FACTOR_SNAPSHOT"
        case target = "TARGET"
        case policy = "POLICY"   // 如 IndifferenceBand version / SignalPolicy version
    }
}

// MARK: - 具体 Artifact 占位（Epic 7-10 完整实现）
//
// 这里只放协议 conformance 的最小骨架，供 DOM-10 验证 Artifact 系统能跑通。
// Epic 7（FactorSnapshot）/ Epic 8（ExposureEstimate/RiskProfile）/
// Epic 9（DailyAttribution）/ Epic 10（PortfolioDecisionArtifact）会各自扩展。

/// 测试用最小 Artifact 实现（DOM-10 验证协议 + ValidityPolicy 用）。
struct PlaceholderArtifact: Artifact {
    let id: ArtifactID
    let producedAt: Date
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]
    let payload: String

    init(
        id: ArtifactID,
        producedAt: Date,
        validityPolicy: ValidityPolicy,
        dependencies: [ArtifactDependency],
        payload: String
    ) {
        self.id = id
        self.producedAt = producedAt
        self.validityPolicy = validityPolicy
        self.dependencies = dependencies
        self.payload = payload
    }
}
