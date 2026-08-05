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
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = try c.decodeIfPresent(String.self, forKey: .claim) ?? ""
        direction = try c.decodeIfPresent(ResearchFindingDirection.self, forKey: .direction) ?? .neutral
        significance = try c.decodeIfPresent(ResearchSignificance.self, forKey: .significance) ?? .medium
        evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
    }
}

enum ResearchFindingDirection: String, Codable, Hashable, Sendable {
    case supportive   // 支持 Case 的风险判断(如集中度风险确实存在)
    case counter      // 反向(削弱风险判断)
    case neutral      // 背景信息
}

enum ResearchSignificance: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
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

        findings = (try? c.decode([ResearchFinding].self, forKey: .findings)) ?? []
        if findings.isEmpty { missing.append("findings") }

        counterFindings = (try? c.decode([ResearchFinding].self, forKey: .counterFindings)) ?? []
        // counterFindings 可以为空(单向判断),不强制

        uncertainties = (try? c.decode([String].self, forKey: .uncertainties)) ?? []

        suggestedState = (try? c.decode(PortfolioDecisionState.self, forKey: .suggestedState)) ?? .watch

        rationale = (try? c.decode(String.self, forKey: .rationale)) ?? ""
        if rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("rationale")
        }

        missingFields = missing
    }

    enum CodingKeys: String, CodingKey {
        case findings, counterFindings, uncertainties, suggestedState, rationale
    }
}
