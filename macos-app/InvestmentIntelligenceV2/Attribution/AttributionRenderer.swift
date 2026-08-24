import Foundation

// MARK: - AttributionRenderer（ATTR-3，Epic 9）
//
// coverage 分级措辞（V2.2 §27）：≥80% / 50-80% / <50% 三档，措辞强度
// 随覆盖度递减——数据不足时**必须**弱化表述，不得把部分归因说成完整结论。
//
// LLM Narrative 补充层：LLM 只补叙述，不改因果确定性。机制约束：
// 1. RenderedAttribution 的全部数字来自 artifact（确定性渲染）；
// 2. LLM 的唯一输入是 AttributionNarrativeSummary（冻结的结构化快照）；
// 3. LLM 输出只是独立的 narrative 字符串，存放与消费都与数字分离，
//    类型层不存在「LLM 改写归因值」的通道。

/// 归因覆盖度分级（V2.2 §27 三档）。
enum AttributionCoverageGrade: String, Sendable, Codable, Hashable {
    /// ≥ 80%：归因完整可信，正常措辞
    case high = "HIGH"
    /// 50-80%：主要驱动已覆盖，措辞明示部分未知
    case partial = "PARTIAL"
    /// < 50%：归因不完整，措辞必须弱化（「不宜据此下结论」）
    case low = "LOW"

    static func grade(coverage: Decimal) -> AttributionCoverageGrade {
        if coverage >= Decimal(string: "0.8")! { return .high }
        if coverage >= Decimal(string: "0.5")! { return .partial }
        return .low
    }

    /// 分级 caveat 措辞（确定性）。
    var caveat: String {
        switch self {
        case .high:
            return "归因覆盖全部持仓收益来源，结果可直接引用。"
        case .partial:
            return "归因覆盖了主要收益来源，但部分持仓当日数据缺失，未覆盖部分不计入上述贡献。"
        case .low:
            return "当日可用数据不足一半，以下归因仅反映已知部分，不宜据此对整体收益下结论。"
        }
    }
}

/// 确定性渲染产物（数字全部来自 artifact）。
struct RenderedAttribution: Sendable, Codable, Hashable {
    let grade: AttributionCoverageGrade
    /// 一行摘要（如「当日归因收益 +0.40%；主要贡献：A +0.06%」）
    let headline: String
    /// 逐成分贡献行（按 |contribution| 降序，与 artifact 一致）
    let contributionLines: [String]
    /// 覆盖度分级 caveat
    let caveat: String
    /// residual 语义明示（无组合实际收益时为 nil）
    let residualNote: String?
    /// LLM 补充叙述（可选；独立字段，不与数字混合渲染）
    let narrative: String?

    /// 附加 LLM 叙述（数字字段原样保留——「LLM 不能改因果确定性」的
    /// 消费形态：narrative 只能整体替换 / 附加，接触不到数字）。
    func withNarrative(_ text: String?) -> RenderedAttribution {
        RenderedAttribution(
            grade: grade,
            headline: headline,
            contributionLines: contributionLines,
            caveat: caveat,
            residualNote: residualNote,
            narrative: text
        )
    }
}

/// 给 LLM 的结构化摘要（冻结视图：LLM 的唯一输入，数字不可被改写）。
struct AttributionNarrativeSummary: Sendable, Codable, Hashable {
    let portfolioKey: String
    let attributionDate: Date
    let attributedReturn: Decimal
    let coverage: Decimal
    let residual: Decimal?
    /// 主要贡献（前 3，含主体键）
    let topContributions: [ContributionSummary]

    struct ContributionSummary: Sendable, Codable, Hashable {
        let subjectKey: String
        let contribution: Decimal
    }

    static func summary(of artifact: DailyAttribution) -> AttributionNarrativeSummary {
        AttributionNarrativeSummary(
            portfolioKey: artifact.portfolioKey,
            attributionDate: artifact.attributionDate,
            attributedReturn: artifact.result.attributedReturn.value,
            coverage: artifact.result.coverage.value,
            residual: artifact.result.residual?.value,
            topContributions: artifact.result.contributions.prefix(3).map {
                ContributionSummary(subjectKey: $0.subject.stableKey, contribution: $0.contribution.value)
            }
        )
    }
}

/// LLM Narrative 补充层协议（实现方在 Epic 11 接 Model Gateway；
/// ATTR-3 只锁契约：输入冻结摘要、输出纯文本，失败 / 拒答返回 nil）。
protocol AttributionNarrativeProvider: Sendable {
    func narrative(for summary: AttributionNarrativeSummary) async -> String?
}

/// 归因渲染器（ATTR-3，确定性）。
struct AttributionRenderer: Sendable {
    static let rendererVersion = "v1"

    func render(_ artifact: DailyAttribution) -> RenderedAttribution {
        let result = artifact.result
        let grade = AttributionCoverageGrade.grade(coverage: result.coverage.value)

        let attributedPct = Self.percent(result.attributedReturn.value)
        var headline: String
        if let top = result.contributions.first {
            headline = "当日归因收益 \(attributedPct)；主要贡献：\(Self.subjectLabel(top.subject)) \(Self.percent(top.contribution.value))"
        } else {
            headline = "当日无已知成分贡献（归因收益 \(attributedPct)）"
        }

        let lines = result.contributions.map { c -> String in
            "\(Self.subjectLabel(c.subject))：权重 \(Self.percent(c.weight.value))，收益 \(Self.percent(c.periodReturn.value))，贡献 \(Self.percent(c.contribution.value))"
        }

        let residualNote = result.residual.map { residual in
            "组合实际收益与已归因部分之差 \(Self.percent(residual.value))（含未覆盖持仓的隐含贡献与估值口径差异）"
        }

        return RenderedAttribution(
            grade: grade,
            headline: headline,
            contributionLines: lines,
            caveat: grade.caveat,
            residualNote: residualNote,
            narrative: nil
        )
    }

    /// 确定性兜底叙述（无 LLM 时的模板文案；与 render 同源数字）。
    func deterministicNarrative(_ artifact: DailyAttribution) -> String {
        let rendered = render(artifact)
        var text = rendered.headline
        if let note = rendered.residualNote {
            text += "。" + note
        }
        text += "。" + rendered.caveat
        return text
    }

    // MARK: - 格式化（确定性，无 locale 依赖）

    private static func percent(_ value: Decimal) -> String {
        var scaled = (value * 100).rounded(toScale: 2)
        NSDecimalCompact(&scaled)   // 去尾零：1.00 → 1
        let sign = scaled > 0 ? "+" : ""
        return "\(sign)\(scaled)%"
    }

    private static func subjectLabel(_ subject: AttributionSubject) -> String {
        switch subject {
        case .fund(let id): return "基金 \(id.rawValue)"
        case .listing(let id): return "标的 \(id.rawValue)"
        }
    }
}
