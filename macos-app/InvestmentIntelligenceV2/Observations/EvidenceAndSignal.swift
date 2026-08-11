import Foundation

// MARK: - Evidence / Signal 分层（ADR-DOM-9，V3.1 §53-55）
//
// 三层语义：
// - Evidence：客观事实证据（来自 Provider / SEC / 公告）
// - EvidenceFact：证据中提取的「事实 + extractionMethod + verificationStatus」，
//   区分 XBRL fact（机器可读）vs LLM extracted fact（自然语言抽取）
// - InvestmentSignal：从 Evidence/EvidenceFact 推导的 ordinal 信号
//   （如「momentum 偏弱」），LLM Research 的主要产物

/// Evidence 事实提取方式（ADR-DATA001/DOM-9 §53）。
///
/// 关键区分：XBRL fact 是 SEC filing 的机器可读字段，可信度高；
/// LLM extracted fact 是从自然语言文本抽取，需要 verificationStatus 标注。
enum EvidenceExtractionMethod: String, Sendable, Codable, Hashable {
    /// XBRL 机器可读字段（如 SEC 10-K 的 Revenue）
    case xbrlFact = "XBRL_FACT"
    /// 结构化数据库字段（如 Provider API 返回的财务指标）
    case structuredField = "STRUCTURED_FIELD"
    /// LLM 从自然语言文本抽取
    case llmExtracted = "LLM_EXTRACTED"
    /// 人工登记
    case manualEntry = "MANUAL_ENTRY"
}

/// 事实验证状态（用于 LLM extracted fact 标注可信度）。
enum EvidenceVerificationStatus: String, Sendable, Codable, Hashable {
    /// 已验证（有 ≥2 个独立来源交叉确认）
    case verified = "VERIFIED"
    /// 单一来源（待 secondary 验证）
    case singleSourced = "SINGLE_SOURCED"
    /// 不可验证（如 LLM 的主观判断）
    case unverifiable = "UNVERIFIABLE"
    /// 与其他证据冲突
    case conflicting = "CONFLICTING"

    /// 是否可信（业务层消费门槛）。
    var isTrustworthy: Bool {
        switch self {
        case .verified: return true
        case .singleSourced, .unverifiable, .conflicting: return false
        }
    }
}

/// 单条事实（Evidence 中提取的原子事实，V3.1 §53）。
///
/// 与 EvidenceObservation（DOM-5）的关系：
/// - EvidenceObservation 是 Observation 层的载体（带 temporalEnvelope / vintage）
/// - EvidenceFact 是其内部的「原子事实 + 提取方式 + 验证状态」
///
/// `evidenceID` 用强类型 `EvidenceID`（不是 ObservationID），编译期保证只有
/// 真正的 Evidence 观测能被引用，DailyBar/NAV 的 ObservationID 无法冒充
/// （审查 P1 修复点）。
///
/// LLM 输出的事实默认 verificationStatus = .unverifiable，
/// 需经 Evidence Matcher（RES-8）匹配已有 Evidence 才升级。
struct EvidenceFact: Sendable, Codable, Hashable {
    let id: DomainID
    /// 该事实的来源 evidence（强类型 EvidenceID，不是 ObservationID）
    let evidenceID: EvidenceID
    /// 事实陈述（如「茅台 Q2 营收 450 亿，同比 +17%」）
    let statement: String
    /// 提取方式
    let extractionMethod: EvidenceExtractionMethod
    /// 验证状态
    let verificationStatus: EvidenceVerificationStatus
    /// 关联的 Canonical 实体（事实陈述的对象）
    let subjectCanonical: CanonicalRef
    /// 数值（若事实是数值型，如营收 / 增长率）
    let numericValue: Decimal?
    let numericUnit: String?

    init(
        id: DomainID,
        evidenceID: EvidenceID,
        statement: String,
        extractionMethod: EvidenceExtractionMethod,
        verificationStatus: EvidenceVerificationStatus,
        subjectCanonical: CanonicalRef,
        numericValue: Decimal? = nil,
        numericUnit: String? = nil
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.statement = statement
        self.extractionMethod = extractionMethod
        self.verificationStatus = verificationStatus
        self.subjectCanonical = subjectCanonical
        self.numericValue = numericValue
        self.numericUnit = numericUnit
    }
}

// MARK: - InvestmentSignal（V3.1 §54-55，ordinal 信号）
//
// Signal 是 LLM Research 的主要产物，是 ordinal（序数）语义。
// Cardinal（基数）转换由 SignalPolicy（FAC-2）完成，业务层不直接消费 ordinal。
//
// ADR-D002：Criterion evaluator 只接受 cardinal，ordinal signal 必须先经
// SignalPolicy 转换。LLM 不能直接产 criterion 分数。

/// 投资信号的方向（ordinal）。
enum SignalDirection: String, Sendable, Codable, Hashable, CaseIterable {
    case bullish = "BULLISH"
    case bearish = "BEARISH"
    case neutral = "NEUTRAL"
    case uncertain = "UNCERTAIN"   // 数据不足 / 冲突 / unknown（ADR-DATA006 联动）

    /// 是否为确定方向（非 uncertain）。
    var isDeterministic: Bool {
        self != .uncertain
    }
}

/// 信号的 cardinality 档位（ordinal → cardinal 转换时由 SignalPolicy 用）。
enum SignalStrength: String, Sendable, Codable, Hashable {
    case weak = "WEAK"
    case moderate = "MODERATE"
    case strong = "STRONG"
}

/// 单条投资信号（LLM Research 或 Factor 转换的产物）。
struct InvestmentSignal: Sendable, Codable, Hashable {
    let id: SignalID
    /// 信号主题（关联的 Canonical 实体）
    let subjectCanonical: CanonicalRef
    /// 信号维度（如 momentum / value / sentiment / risk）
    let dimension: SignalDimension
    /// 方向（ordinal）
    let direction: SignalDirection
    /// 强度
    let strength: SignalStrength
    /// 推导此 signal 的 evidence IDs（强类型 EvidenceID，ADR-D004 replay 引用）。
    /// 不允许用 ObservationID 冒充——只有真正的 Evidence 观测能被引用。
    let derivedFromEvidenceIDs: [EvidenceID]
    /// 信号生效时间
    let effectiveAt: Date
    /// 信号产出方（LLM model / Factor engine / manual）
    let producer: SignalProducer
    /// 自由文本理由（Narrative 用，不进 cardinal 运算）
    let rationale: String?

    init(
        id: SignalID,
        subjectCanonical: CanonicalRef,
        dimension: SignalDimension,
        direction: SignalDirection,
        strength: SignalStrength,
        derivedFromEvidenceIDs: [EvidenceID],
        effectiveAt: Date,
        producer: SignalProducer,
        rationale: String? = nil
    ) {
        self.id = id
        self.subjectCanonical = subjectCanonical
        self.dimension = dimension
        self.direction = direction
        self.strength = strength
        self.derivedFromEvidenceIDs = derivedFromEvidenceIDs
        self.effectiveAt = effectiveAt
        self.producer = producer
        self.rationale = rationale
    }
}

/// 信号维度（用于 SignalPolicy 分维度转 cardinal）。
enum SignalDimension: String, Sendable, Codable, Hashable, CaseIterable {
    case momentum = "MOMENTUM"
    case value = "VALUE"
    case quality = "QUALITY"
    case sentiment = "SENTIMENT"
    case macro = "MACRO"
    case risk = "RISK"
    case technical = "TECHNICAL"
}

/// 信号产出方。
struct SignalProducer: Sendable, Codable, Hashable {
    let kind: Kind
    /// 若是 LLM，记录 model 标识（如 "gpt-4" / "claude-3"）
    let modelIdentifier: String?

    enum Kind: String, Sendable, Codable, Hashable {
        case llm = "LLM"
        case factorEngine = "FACTOR_ENGINE"
        case manual = "MANUAL"
    }

    static let llmDefault = SignalProducer(kind: .llm, modelIdentifier: "unknown")
    static let factorEngine = SignalProducer(kind: .factorEngine, modelIdentifier: nil)
}
