import Foundation
import GRDB

// MARK: - Research Thesis（WF-1：theses 表消费）
//
// Thesis 是研究结论的叙事载体：从 ResearchNotes 确定性合成，链接支撑
// 证据与产出的 signals。与 Signal 的分工——Signal 是 ordinal 系统状态
// （进 Decision 引用层与 cardinal 数学外的 narrative 溯源），Thesis 是
// 「为什么」的完整叙述（PRES-1 ResearchNarrator 的消费素材），不进
// 任何运算。
//
// 合成纪律（与 RES-4 SignalExtraction 同源）：
// - 纯函数、确定性 ID（同 notes + 同 signals → 同 thesis——幂等落库前提）
// - statement 可包含模型叙述，但 evidence / signal 引用一律从结构化字段
//   派生；kind / subject / createdAt 由合成器注入（模型不产身份字段）

/// Thesis 层级：资产级（单标的研究产物）/ 组合级（聚合 + 组合研究产物）。
enum ResearchThesisKind: String, Sendable, Codable, Hashable {
    case asset = "ASSET"
    case portfolio = "PORTFOLIO"
}

/// 研究论点（theses 表的领域形态）。
struct ResearchThesis: Sendable, Codable, Hashable {
    /// 确定性派生（kind + subject + 叙述 + 引用 + 溯源指纹；不含 createdAt）。
    let id: String
    let kind: ResearchThesisKind
    let subject: CanonicalRef
    /// 结论叙述（模型 notes + claims 陈述拼接；叙事载体，不进运算）。
    let statement: String
    /// 支撑证据（claims 的 evidence 引用并集，排序去重）。
    let supportingEvidenceIDs: [EvidenceID]
    /// 关联信号（该研究产出的 InvestmentSignal IDs）。
    let linkedSignalIDs: [SignalID]
    let createdAt: Date
    var revisedAt: Date? = nil
    /// 溯源：合成自哪些 ResearchNotes（contentFingerprint，排序去重）。
    let sourceNotesFingerprints: [String]
}

// MARK: - Thesis 合成器（纯函数）

/// ResearchNotes（+ 产出 signals）→ ResearchThesis 的确定性合成。
struct ThesisSynthesizer: Sendable {

    /// 资产级 thesis：单次研究任务的直接产物。
    /// signals 必须与 notes 同 subject（调用方保证；异主体信号不并入）。
    func assetThesis(
        from notes: ResearchNotes, signals: [InvestmentSignal], now: Date
    ) -> ResearchThesis {
        let evidence = orderedUnique(
            notes.claims.flatMap { $0.evidenceReferences.map(\.rawValue) }
        ).map { EvidenceID(rawValue: $0) }
        let linked = orderedUnique(
            signals
                .filter { $0.subjectCanonical == notes.task.subject }
                .map { $0.id.rawValue }
        ).map { SignalID(rawValue: $0) }
        return ResearchThesis(
            id: Self.deriveID(
                kind: .asset, subject: notes.task.subject,
                statement: Self.statement(from: notes),
                evidence: evidence, signals: linked,
                sources: [notes.contentFingerprint]
            ),
            kind: .asset,
            subject: notes.task.subject,
            statement: Self.statement(from: notes),
            supportingEvidenceIDs: evidence,
            linkedSignalIDs: linked,
            createdAt: now,
            revisedAt: nil,
            sourceNotesFingerprints: [notes.contentFingerprint]
        )
    }

    /// 组合级 thesis：聚合各资产 thesis + 组合研究 notes。
    /// statement 是程序化汇总（各来源方向 / 信号计数）——聚合叙述不由
    /// 模型生成（LLM 输出只在各自 notes 里，不跨任务拼接）。
    func portfolioThesis(
        subject: CanonicalRef,
        assetTheses: [ResearchThesis],
        portfolioNotes: ResearchNotes?,
        signals: [InvestmentSignal],
        now: Date
    ) -> ResearchThesis {
        let evidence = orderedUnique(
            assetTheses.flatMap { $0.supportingEvidenceIDs.map(\.rawValue) }
                + (portfolioNotes?.claims.flatMap { $0.evidenceReferences.map(\.rawValue) } ?? [])
        ).map { EvidenceID(rawValue: $0) }
        let linked = orderedUnique(
            assetTheses.flatMap { $0.linkedSignalIDs.map(\.rawValue) }
                + signals.filter { $0.subjectCanonical == subject }
                    .map { $0.id.rawValue }
        ).map { SignalID(rawValue: $0) }
        let sources = orderedUnique(
            assetTheses.flatMap { $0.sourceNotesFingerprints }
                + (portfolioNotes.map { [$0.contentFingerprint] } ?? [])
        )
        let statement = Self.portfolioStatement(
            subject: subject, assetTheses: assetTheses,
            portfolioNotes: portfolioNotes, signals: signals
        )
        return ResearchThesis(
            id: Self.deriveID(
                kind: .portfolio, subject: subject,
                statement: statement,
                evidence: evidence, signals: linked, sources: sources
            ),
            kind: .portfolio,
            subject: subject,
            statement: statement,
            supportingEvidenceIDs: evidence,
            linkedSignalIDs: linked,
            createdAt: now,
            revisedAt: nil,
            sourceNotesFingerprints: sources
        )
    }

    // MARK: - 私有

    private static func statement(from notes: ResearchNotes) -> String {
        var parts: [String] = []
        if !notes.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(notes.notes)
        }
        parts.append(
            contentsOf: notes.claims.map { claim in
                var line = "· \(claim.statement)"
                if let direction = claim.direction {
                    line += "（\(direction.rawValue)）"
                }
                return line
            }
        )
        return parts.joined(separator: "\n")
    }

    private static func portfolioStatement(
        subject: CanonicalRef,
        assetTheses: [ResearchThesis],
        portfolioNotes: ResearchNotes?,
        signals: [InvestmentSignal]
    ) -> String {
        var lines: [String] = []
        let scoped = signals.filter { $0.subjectCanonical == subject }
        let directional = scoped.filter { $0.direction.isDeterministic }
        lines.append(
            "组合研究聚合：\(assetTheses.count) 份资产论点、\(scoped.count) 条信号"
            + "（确定方向 \(directional.count) 条）"
            + "、\(assetTheses.reduce(0) { $0 + $1.supportingEvidenceIDs.count }) 条证据引用。"
        )
        for thesis in assetTheses.sorted(by: { $0.subject.entityIDRawValue < $1.subject.entityIDRawValue }) {
            let directions = thesis.linkedSignalIDs.count > 0
                ? "（含 \(thesis.linkedSignalIDs.count) 条关联信号）" : ""
            lines.append("· \(thesis.subject.entityIDRawValue)\(directions)")
        }
        if let portfolioNotes {
            lines.append("组合级研究叙述：\(portfolioNotes.notes)")
        }
        return lines.joined(separator: "\n")
    }

    private static func deriveID(
        kind: ResearchThesisKind,
        subject: CanonicalRef,
        statement: String,
        evidence: [EvidenceID],
        signals: [SignalID],
        sources: [String]
    ) -> String {
        let payload: [String: String] = [
            "kind": kind.rawValue,
            "subject": "\(subject.entityType)|\(subject.entityIDRawValue)",
            "statement": statement,
            "evidence": evidence.map(\.rawValue).joined(separator: ","),
            "signals": signals.map(\.rawValue).joined(separator: ","),
            "sources": sources.joined(separator: ","),
        ]
        return "thesis_\(StableDigest.digest(StableDigest.jsonPayloadOrString(payload)))"
    }

    private func orderedUnique(_ raw: [String]) -> [String] {
        Array(Set(raw)).sorted()
    }
}

// MARK: - Thesis Store（幂等持久化，纪律与 SignalStore 同源）

enum ThesisStoreError: Error, Equatable, Sendable {
    /// 同 ID 异语义内容（拒绝覆盖历史论点）。
    case conflict(thesisID: String, field: String)
    /// 形态非法（空 statement / 空证据引用 / 未知 kind）。
    case malformed(thesisID: String, detail: String)
}

/// Thesis 存取 API（GRDB / InMemory 双实现）。
protocol ThesisStore: Sendable {
    /// 写入（幂等；同 ID 同语义 no-op，保留首条 createdAt）。
    @discardableResult
    func write(_ thesis: ResearchThesis) throws -> String

    /// 按 ID 点查。
    func thesis(id: String) throws -> ResearchThesis?

    /// 按 kind + 主体查（跨运行；createdAt 降序）。
    func theses(kind: ResearchThesisKind, subject: CanonicalRef) throws -> [ResearchThesis]
}

/// 写入前形态校验：thesis 必须有叙述与证据支撑（无证据的是叙述不是论点，
/// 与 SignalStore「空 evidence = malformed」门禁对齐）。
enum ThesisFormValidator {
    static func validate(_ thesis: ResearchThesis) throws {
        guard !thesis.supportingEvidenceIDs.isEmpty else {
            throw ThesisStoreError.malformed(
                thesisID: thesis.id,
                detail: "supportingEvidenceIDs 为空——无证据支撑的不是论点"
            )
        }
        guard !thesis.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThesisStoreError.malformed(thesisID: thesis.id, detail: "statement 为空")
        }
        guard Set(thesis.supportingEvidenceIDs.map(\.rawValue)).count
            == thesis.supportingEvidenceIDs.count else {
            throw ThesisStoreError.malformed(
                thesisID: thesis.id, detail: "supportingEvidenceIDs 含重复"
            )
        }
    }
}

// MARK: - GRDB 实现

extension ThesisRow {
    static func from(_ domain: ResearchThesis) -> ThesisRow {
        let evidenceJSON = (try? CanonicalColumnCodec.encodeJSON(
            domain.supportingEvidenceIDs.map(\.rawValue)
        )) ?? "[]"
        let signalsJSON = (try? CanonicalColumnCodec.encodeJSON(
            domain.linkedSignalIDs.map(\.rawValue)
        )) ?? "[]"
        return ThesisRow(
            id: domain.id,
            kind: domain.kind.rawValue,
            subjectEntityType: domain.subject.entityType,
            subjectEntityID: domain.subject.entityIDRawValue,
            statement: Self.statementWithSources(
                statement: domain.statement,
                sources: domain.sourceNotesFingerprints
            ),
            supportingEvidenceIDsJSON: evidenceJSON,
            linkedSignalIDsJSON: signalsJSON,
            createdAt: CanonicalColumnCodec.encodeTimestamp(domain.createdAt),
            revisedAt: domain.revisedAt.map { CanonicalColumnCodec.encodeTimestamp($0) }
        )
    }

    func toDomain() throws -> ResearchThesis {
        guard let kind = ResearchThesisKind(rawValue: kind) else {
            throw CanonicalColumnCodecError.unknownEnumValue(column: "kind", rawValue: kind)
        }
        let evidence: [String] = try CanonicalColumnCodec
            .decodeJSON([String].self, from: supportingEvidenceIDsJSON)
        let signals: [String] = try CanonicalColumnCodec
            .decodeJSON([String].self, from: linkedSignalIDsJSON)
        let (statement, sources) = try Self.splitStatementSources(statement)
        return ResearchThesis(
            id: id,
            kind: kind,
            subject: try CanonicalRef(
                entityType: subjectEntityType, entityIDRawValue: subjectEntityID
            ),
            statement: statement,
            supportingEvidenceIDs: evidence.map { EvidenceID(rawValue: $0) },
            linkedSignalIDs: signals.map { SignalID(rawValue: $0) },
            createdAt: try CanonicalColumnCodec.decodeTimestamp(createdAt),
            revisedAt: try revisedAt.map {
                try CanonicalColumnCodec.decodeTimestamp($0)
            },
            sourceNotesFingerprints: sources
        )
    }

    /// theses 表没有独立的溯源列（GRDB-6 已发布 schema 不改写，坑点 18），
    /// sourceNotesFingerprints 以 JSON 行内嵌在 statement 头部，读写成对。
    private static let sourcesPrefix = "⟦sources:"
    private static let sourcesSuffix = "⟧"

    private static func statementWithSources(
        statement: String, sources: [String]
    ) -> String {
        guard !sources.isEmpty else { return statement }
        let joined = sources.joined(separator: ",")
        return "\(sourcesPrefix)\(joined)\(sourcesSuffix)\(statement)"
    }

    private static func splitStatementSources(
        _ combined: String
    ) throws -> (statement: String, sources: [String]) {
        guard combined.hasPrefix(sourcesPrefix) else {
            return (combined, [])
        }
        let remainder = combined.dropFirst(sourcesPrefix.count)
        guard let end = remainder.range(of: sourcesSuffix) else {
            throw ThesisStoreError.malformed(
                thesisID: "-", detail: "statement 溯源头损坏：\(combined.prefix(80))"
            )
        }
        let joined = remainder[..<end.lowerBound]
        let sources = joined.isEmpty ? [] : joined.split(separator: ",").map(String.init)
        return (String(remainder[end.upperBound...]), sources)
    }
}

extension GRDBRepository: ThesisStore {

    func write(_ thesis: ResearchThesis) throws -> String {
        try ThesisFormValidator.validate(thesis)
        let row = ThesisRow.from(thesis)
        try database.queue.write { db in
            if let existingRow = try ThesisRow.fetchOne(db, key: thesis.id) {
                let existing = try existingRow.toDomain()
                if let field = thesisDivergentField(existing, thesis) {
                    throw ThesisStoreError.conflict(thesisID: thesis.id, field: field)
                }
                return // 幂等 no-op：保留首条 createdAt
            }
            try row.insert(db)
        }
        return thesis.id
    }

    func thesis(id: String) throws -> ResearchThesis? {
        try database.queue.read { db in
            try ThesisRow.fetchOne(db, key: id)?.toDomain()
        }
    }

    func theses(kind: ResearchThesisKind, subject: CanonicalRef) throws -> [ResearchThesis] {
        try database.queue.read { db in
            try ThesisRow
                .filter(
                    sql: """
                    kind = ? AND subject_entity_type = ? AND subject_entity_id = ?
                    """,
                    arguments: [kind.rawValue, subject.entityType, subject.entityIDRawValue]
                )
                .order(sql: "created_at DESC")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }
}

// MARK: - InMemory 实现（测试 parity / 无库环境）

final class InMemoryThesisStore: ThesisStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ResearchThesis] = [:]

    func write(_ thesis: ResearchThesis) throws -> String {
        try ThesisFormValidator.validate(thesis)
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage[thesis.id] {
            if let field = thesisDivergentField(existing, thesis) {
                throw ThesisStoreError.conflict(thesisID: thesis.id, field: field)
            }
            return thesis.id // 幂等 no-op
        }
        storage[thesis.id] = thesis
        return thesis.id
    }

    func thesis(id: String) throws -> ResearchThesis? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func theses(kind: ResearchThesisKind, subject: CanonicalRef) throws -> [ResearchThesis] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { $0.kind == kind && $0.subject == subject }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// 语义分歧字段定位（GRDB / InMemory 共用；剥 createdAt / revisedAt——
/// ID 派生不含时间，重合成稍晚产出不推迟建账时间）。
private func thesisDivergentField(
    _ lhs: ResearchThesis, _ rhs: ResearchThesis
) -> String? {
    if lhs.kind != rhs.kind { return "kind" }
    if lhs.subject != rhs.subject { return "subject_entity_type" }
    if lhs.statement != rhs.statement { return "statement" }
    if lhs.supportingEvidenceIDs != rhs.supportingEvidenceIDs {
        return "supporting_evidence_ids"
    }
    if lhs.linkedSignalIDs != rhs.linkedSignalIDs { return "linked_signal_ids" }
    if lhs.sourceNotesFingerprints != rhs.sourceNotesFingerprints {
        return "statement(sources)"
    }
    return nil
}
