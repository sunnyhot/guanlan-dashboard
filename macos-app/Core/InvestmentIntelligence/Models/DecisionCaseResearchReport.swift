import Foundation

// DecisionCaseResearchAgent 的输出模型。
//
// Agent 输出 DecisionCaseResearchReport(研究发现 + 建议状态 + Evidence)。
// AppModel 收到后用本地 Policy 校验(不满足门槛则降级),
// 再更新 DecisionCase 的 decisionState。
//
// 设计(见 docs/ai-pipeline-baseline.md 第 9 节 + Slice 3 设计):
// - Agent 只输出 findings + 建议状态,不直接改 Case(AppModel 校验后才改)。
// - Evidence 只能引用工具返回的真实 ID(防伪造,AppModel 用 Ledger 过滤)。
// - exitReview 需 ≥2 个独立反向证据组(Slice 3 用 contributor fundCode 去重)。

// MARK: - 单条研究发现

/// 一条研究发现:支持、反证或背景。
struct ResearchFinding: Codable, Hashable, Sendable {
    let claim: String
    /// 方向:正向(支持 Case 的风险判断)/ 反向(削弱)/ 中性(背景)。
    let direction: ResearchFindingDirection
    /// 重要性:high / medium / low。
    let significance: ResearchSignificance
    /// 引用的证据 ID(必须是工具返回的真实 ID)。
    let evidenceIDs: [String]

    init(
        claim: String,
        direction: ResearchFindingDirection,
        significance: ResearchSignificance,
        evidenceIDs: [String]
    ) {
        self.claim = claim
        self.direction = direction
        self.significance = significance
        self.evidenceIDs = evidenceIDs
    }

    /// 解码时收集缺失字段(参考 NextHourGuidance 的 missingFields 模式)。
    ///
    /// direction / significance 用容错解码：模型输出同义词（如 supports/positive、
    /// moderate/middle）或非法值时降级到默认，而不是抛错——避免单条 finding 的枚举值
    /// 不规范导致整个 findings 数组解码失败（表现为「字段类型不匹配 findings.Index 0」）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = try c.decodeIfPresent(String.self, forKey: .claim) ?? ""
        let directionRaw = try? c.decodeIfPresent(String.self, forKey: .direction)
        direction = ResearchFindingDirection(fallback: .neutral, raw: directionRaw)
        let significanceRaw = try? c.decodeIfPresent(String.self, forKey: .significance)
        significance = ResearchSignificance(fallback: .medium, raw: significanceRaw)
        evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
    }
}

enum ResearchFindingDirection: String, Codable, Hashable, Sendable {
    case supportive   // 支持 Case 的风险判断(如集中度风险确实存在)
    case counter      // 反向(削弱风险判断)
    case neutral      // 背景信息

    /// 容错构造：raw 缺失/非法时用 fallback，不抛错。接受常见同义词。
    init(fallback: ResearchFindingDirection, raw: String?) {
        guard let raw else { self = fallback; return }
        switch raw.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
        case "supportive", "support", "supports", "positive", "for", "confirm", "confirms", "uphold":
            self = .supportive
        case "counter", "negative", "against", "oppose", "opposes", "refute", "refutes", "weaken", "weakens":
            self = .counter
        default:
            self = fallback
        }
    }
}

enum ResearchSignificance: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low

    /// 容错构造：raw 缺失/非法时用 fallback，不抛错。接受常见同义词。
    init(fallback: ResearchSignificance, raw: String?) {
        guard let raw else { self = fallback; return }
        switch raw.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
        case "high", "important", "major", "strong", "critical":
            self = .high
        case "low", "minor", "weak", "negligible":
            self = .low
        default:
            self = fallback
        }
    }
}

// MARK: - 研究报告

/// Agent 提交的完整研究报告。
struct DecisionCaseResearchReport: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let caseID: UUID
    let generatedAt: String

    /// 支持性发现(支持风险判断)。
    let findings: [ResearchFinding]
    /// 反向发现(削弱风险判断)。
    let counterFindings: [ResearchFinding]
    /// 不确定性/数据缺口。
    let uncertainties: [String]
    /// 引用的证据(只含 Ledger 真实产出的,AppModel 过滤后填充)。
    let evidence: [TrendEvidence]
    /// Agent 建议的决策状态(AppModel 校验后才采纳)。
    let suggestedState: PortfolioDecisionState
    /// 建议理由。
    let rationale: String

    init(
        schemaVersion: Int = DecisionCaseResearchReport.currentSchemaVersion,
        caseID: UUID,
        generatedAt: String,
        findings: [ResearchFinding] = [],
        counterFindings: [ResearchFinding] = [],
        uncertainties: [String] = [],
        evidence: [TrendEvidence] = [],
        suggestedState: PortfolioDecisionState,
        rationale: String
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.generatedAt = generatedAt
        self.findings = findings
        self.counterFindings = counterFindings
        self.uncertainties = uncertainties
        self.evidence = evidence
        self.suggestedState = suggestedState
        self.rationale = rationale
    }
}

// MARK: - Agent 内部解码模型(从 submit 工具的 JSON 解码)

/// Agent 内部用:从 submit_case_research 工具的 arguments JSON 解码。
/// 收集缺失字段,一次性报错给模型修正(参考 NextHourGuidanceAgent 的 Submission 模式)。
struct DecisionCaseResearchSubmission: Decodable {
    let findings: [ResearchFinding]
    let counterFindings: [ResearchFinding]
    let uncertainties: [String]
    let suggestedState: PortfolioDecisionState
    let rationale: String

    /// 解码时收集的缺失字段(非空时校验失败)。
    let missingFields: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var missing: [String] = []

        // findings / counterFindings 用 decodeIfPresent：缺键 → []；
        // 若键存在但解码失败（如传成了对象而非数组、枚举值非法）则直接抛 DecodingError，
        // 由上层 processSubmission 的 catch 捕获并回灌具体原因给模型，
        // 而不是被 try? 吞成 [] 再误报"缺少必填字段:findings"。
        // findings 不强制非空：研究结论为风险不成立（stable/insufficientEvidence）时
        // 支持性 findings 自然为空，此时只需在 rationale 说明。
        findings = try c.decodeIfPresent([ResearchFinding].self, forKey: .findings) ?? []

        counterFindings = try c.decodeIfPresent([ResearchFinding].self, forKey: .counterFindings) ?? []

        uncertainties = try c.decodeIfPresent([String].self, forKey: .uncertainties) ?? []

        suggestedState = try c.decodeIfPresent(PortfolioDecisionState.self, forKey: .suggestedState) ?? .watch

        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        if rationale.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            missing.append("rationale")
        }

        missingFields = missing
    }

    enum CodingKeys: String, CodingKey {
        case findings, counterFindings, uncertainties, suggestedState, rationale
    }
}
