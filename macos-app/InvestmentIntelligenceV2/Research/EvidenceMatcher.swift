import Foundation

// MARK: - Evidence Matcher（RES-8，V2.2 §51）
//
// LLM 输出 Fact Claims → 匹配已有 Evidence 的确定性通道：
// - **ID 引用核对**：模型自报的 evidence ID 必须存在于证据集（M8 验收：
//   「LLM 无法生成不存在的 evidence ID」——编造的 ID 在这里被拦截）。
// - **内容匹配**：claim 陈述与证据文本的字符 bigram Jaccard 相似度——
//   模型未引用（或引用被拒）时，由 matcher 从证据集确定性绑定支撑证据；
//   绑定是代码产出，模型文本中的「自报 ID」永远不直接生效。
//
// 匹配是纯函数：无 IO、无随机、无外部依赖（不引分词库——中文按字符
// bigram，跨语言一致、跨进程稳定）。

/// 证据匹配器配置。
struct EvidenceMatcherConfig: Sendable, Hashable, Codable {
    /// bigram Jaccard 相似度阈值（低于此值不算匹配）。
    var similarityThreshold: Double = 0.25
    /// 每个 claim 最多绑定的证据数（按得分降序截断）。
    var maxMatchesPerClaim: Int = 3
}

/// 单条 claim 的匹配结果。
struct EvidenceMatchOutcome: Sendable, Hashable, Codable {
    let claimIndex: Int
    /// 匹配到的证据（得分降序；同分按 ID 排序保证确定性）。
    let matched: [EvidenceID]
    let unmatchedReason: UnmatchedReason?

    enum UnmatchedReason: String, Sendable, Codable, Hashable {
        case noCandidateAboveThreshold = "NO_CANDIDATE_ABOVE_THRESHOLD"
        case emptyCorpus = "EMPTY_CORPUS"
    }
}

struct EvidenceMatcher: Sendable {
    var config = EvidenceMatcherConfig()

    // MARK: - 相似度

    /// 字符 bigram Jaccard（确定性；空/单字符文本无 bigram → 0）。
    func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsGrams = Self.bigrams(lhs)
        let rhsGrams = Self.bigrams(rhs)
        guard !lhsGrams.isEmpty, !rhsGrams.isEmpty else { return 0 }
        let intersection = lhsGrams.intersection(rhsGrams).count
        let union = lhsGrams.union(rhsGrams).count
        return Double(intersection) / Double(union)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(normalized)
        guard characters.count >= 2 else { return [] }
        var grams: [String] = []
        for index in 0..<(characters.count - 1) {
            let first = String(characters[index])
            let second = String(characters[index + 1])
            grams.append(first + second)
        }
        return Set(grams)
    }

    // MARK: - 内容匹配

    /// 单条陈述 → 证据集匹配。
    func match(
        statement: String,
        corpus: [EvidenceID: String]
    ) -> [EvidenceID] {
        rankedCandidates(statement: statement, corpus: corpus)
            .prefix(config.maxMatchesPerClaim)
            .map(\.id)
    }

    /// 批量匹配（claims 陈述列表）。
    func match(
        claims: [String],
        corpus: [EvidenceID: String]
    ) -> [EvidenceMatchOutcome] {
        claims.enumerated().map { index, statement in
            if corpus.isEmpty {
                return EvidenceMatchOutcome(claimIndex: index, matched: [], unmatchedReason: .emptyCorpus)
            }
            let ranked = rankedCandidates(statement: statement, corpus: corpus)
            let top = Array(ranked.prefix(config.maxMatchesPerClaim).map(\.id))
            return EvidenceMatchOutcome(
                claimIndex: index,
                matched: top,
                unmatchedReason: top.isEmpty ? .noCandidateAboveThreshold : nil
            )
        }
    }

    private struct Candidate: Comparable {
        let id: EvidenceID
        let score: Double

        static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private func rankedCandidates(
        statement: String,
        corpus: [EvidenceID: String]
    ) -> [Candidate] {
        corpus
            .map { id, text in
                Candidate(id: id, score: similarity(statement, text))
            }
            .filter { $0.score >= config.similarityThreshold }
            .sorted()
    }

    // MARK: - ID 引用核对（M8 验收：编造的 ID 被拦截）

    /// 返回引用中**不存在于证据集**的 ID（空 = 全部可解析）。
    static func unresolvedReferences(
        _ references: [EvidenceID],
        corpus: Set<String>
    ) -> [EvidenceID] {
        references.filter { !corpus.contains($0.rawValue) }
    }

    // MARK: - 重绑定

    /// 对空引用的 claim 用内容匹配补绑定（非空引用的 claim 原样保留——
    /// 无效引用是 binding 层 error 语义，matcher 不越权清洗）。
    /// 返回新 notes；无可补绑时原样返回（值相等）。
    func rebind(
        _ notes: ResearchNotes,
        corpus: [EvidenceID: String]
    ) -> ResearchNotes {
        guard !corpus.isEmpty else { return notes }
        var changed = false
        let claims = notes.claims.map { claim -> ResearchClaim in
            guard claim.evidenceReferences.isEmpty else { return claim }
            let matched = match(statement: claim.statement, corpus: corpus)
            guard !matched.isEmpty else { return claim }
            changed = true
            return ResearchClaim(
                statement: claim.statement,
                evidenceReferences: matched,
                confidenceLabel: claim.confidenceLabel,
                dimension: claim.dimension,
                direction: claim.direction
            )
        }
        guard changed else { return notes }
        return ResearchNotes(
            task: notes.task,
            notes: notes.notes,
            claims: claims,
            producedBy: notes.producedBy,
            producedAt: notes.producedAt
        )
    }
}
