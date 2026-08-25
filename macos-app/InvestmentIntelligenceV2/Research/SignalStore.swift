import Foundation
import GRDB

// MARK: - Signal Store（RES-6，V3.1 §38：Signal ≠ Evidence 分开存储）
//
// InvestmentSignal 的持久化 API：signals 表（GRDB-6 已落 schema + SignalRow
// codec）。验收语义：
// - **跨运行可查**：按主体 / 按证据溯源两个查询面（Decision 侧的
//   referenced_signal_ids 与失效传播都靠它们）
// - **幂等写**（ArtifactRow.write 同款纪律）：同 ID 同语义内容 no-op
//  （保留首条 effectiveAt——重提取稍晚产出不推迟生效时间）；同 ID 异内容
//   conflict 抛错（静默覆盖 = 篡改历史信号）
// - **语义比较剥 effectiveAt**：ID 派生不含时间（RES-4），重提取幂等靠
//   「剥时间列后全等」；direction/strength/evidence/producer 分毫必较
// - derivedFrom 不建跨表 FK（JSON 数组做不到行级 FK），完整性由 RES-5
//   Validation + RES-8 Matcher 在写入前保证——本层只做形态校验
//   （非空、去重）

/// Signal 持久化错误。
enum SignalStoreError: Error, Equatable, Sendable {
    /// 同 ID 异语义内容（拒绝覆盖历史信号）。
    case conflict(signalID: String, field: String)
    /// 信号形态非法（空 evidence 引用去重后仍空 / rationale 缺失等）。
    case malformed(signalID: String, detail: String)
}

/// Signal 存取 API（GRDB / InMemory 双实现）。
protocol SignalStore: Sendable {
    /// 写入（幂等；同 ID 同语义 no-op）。写入前做形态校验。
    @discardableResult
    func write(_ signal: InvestmentSignal) throws -> SignalID

    /// 按 ID 点查。
    func signal(id: SignalID) throws -> InvestmentSignal?

    /// 按主体查（跨运行；effectiveAt 降序）。
    func signals(subject: CanonicalRef) throws -> [InvestmentSignal]

    /// 按证据溯源查（derivedFrom 引用了该证据的全部信号）。
    func signals(derivedFromEvidence evidenceID: EvidenceID) throws -> [InvestmentSignal]
}

// MARK: - 形态校验（写入前门禁）

enum SignalFormValidator {
    /// 写入前校验：evidence 引用去重后非空（无证据不是信号，是叙述）、
    /// 主体非空、rationale 携带（审计要求 policy 身份可追）。
    static func validate(_ signal: InvestmentSignal) throws {
        let uniqueEvidence = Set(signal.derivedFromEvidenceIDs.map(\.rawValue))
        guard !uniqueEvidence.isEmpty else {
            throw SignalStoreError.malformed(
                signalID: signal.id.rawValue,
                detail: "derivedFromEvidenceIDs 为空——无证据支撑的不是信号"
            )
        }
        guard !signal.subjectCanonical.stableKey.isEmpty else {
            throw SignalStoreError.malformed(signalID: signal.id.rawValue, detail: "主体为空")
        }
        guard let rationale = signal.rationale, !rationale.isEmpty else {
            throw SignalStoreError.malformed(signalID: signal.id.rawValue, detail: "rationale 缺失（policy 溯源要求）")
        }
    }
}

// MARK: - GRDB 实现

extension GRDBRepository: SignalStore {

    func write(_ signal: InvestmentSignal) throws -> SignalID {
        try SignalFormValidator.validate(signal)
        let row = try SignalRow.from(signal)
        try database.queue.write { db in
            if let existing = try SignalRow.fetchOne(
                db, key: signal.id.rawValue
            ) {
                guard Self.signalsSemanticallyEqual(row, existing) else {
                    throw SignalStoreError.conflict(
                        signalID: signal.id.rawValue,
                        field: Self.firstDivergentField(row, existing) ?? "unknown"
                    )
                }
                return // 幂等 no-op：保留首条（含首条 effectiveAt）
            }
            try row.insert(db)
        }
        return signal.id
    }

    func signal(id: SignalID) throws -> InvestmentSignal? {
        try database.queue.read { db in
            try SignalRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func signals(subject: CanonicalRef) throws -> [InvestmentSignal] {
        try database.queue.read { db in
            try SignalRow
                .filter(
                    sql: "subject_entity_type = ? AND subject_entity_id = ?",
                    arguments: [subject.entityType, subject.entityIDRawValue]
                )
                .order(sql: "effective_at DESC")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func signals(derivedFromEvidence evidenceID: EvidenceID) throws -> [InvestmentSignal] {
        // JSON1 的 json_each 精确匹配数组元素（LIKE 会在 EV-1/EV-10 上误配）。
        try database.queue.read { db in
            let rows = try SignalRow.fetchAll(
                db,
                sql: """
                SELECT * FROM signals
                WHERE EXISTS (
                    SELECT 1 FROM json_each(signals.derived_from_evidence_ids)
                    WHERE json_each.value = ?
                )
                ORDER BY effective_at DESC
                """,
                arguments: [evidenceID.rawValue]
            )
            return try rows.map { try $0.toDomain() }
        }
    }

    // MARK: 语义相等（剥 effective_at；列级比对报告首个分歧字段）

    private static func signalsSemanticallyEqual(_ lhs: SignalRow, _ rhs: SignalRow) -> Bool {
        firstDivergentField(lhs, rhs) == nil
    }

    private static func firstDivergentField(_ lhs: SignalRow, _ rhs: SignalRow) -> String? {
        if lhs.subjectEntityType != rhs.subjectEntityType { return "subject_entity_type" }
        if lhs.subjectEntityID != rhs.subjectEntityID { return "subject_entity_id" }
        if lhs.dimension != rhs.dimension { return "dimension" }
        if lhs.direction != rhs.direction { return "direction" }
        if lhs.strength != rhs.strength { return "strength" }
        // evidence 引用是集合语义：JSON 顺序无关（RES-4 产出已排序，
        // 仍按集合比较防御手写行）
        let lhsEvidence = Set((try? CanonicalColumnCodec.decodeJSON([String].self, from: lhs.derivedFromEvidenceIDsJSON)) ?? [])
        let rhsEvidence = Set((try? CanonicalColumnCodec.decodeJSON([String].self, from: rhs.derivedFromEvidenceIDsJSON)) ?? [])
        if lhsEvidence != rhsEvidence { return "derived_from_evidence_ids" }
        if lhs.producerKind != rhs.producerKind { return "producer_kind" }
        if lhs.producerModelIdentifier != rhs.producerModelIdentifier { return "producer_model_identifier" }
        if lhs.rationale != rhs.rationale { return "rationale" }
        return nil
    }
}

// MARK: - InMemory 实现（测试 parity / 无库环境）

final class InMemorySignalStore: SignalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: InvestmentSignal] = [:]

    func write(_ signal: InvestmentSignal) throws -> SignalID {
        try SignalFormValidator.validate(signal)
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage[signal.id.rawValue] {
            if let field = Self.firstDivergentField(existing, signal) {
                throw SignalStoreError.conflict(signalID: signal.id.rawValue, field: field)
            }
            return signal.id // 幂等 no-op：保留首条 effectiveAt
        }
        storage[signal.id.rawValue] = signal
        return signal.id
    }

    func signal(id: SignalID) throws -> InvestmentSignal? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id.rawValue]
    }

    func signals(subject: CanonicalRef) throws -> [InvestmentSignal] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { $0.subjectCanonical == subject }
            .sorted { $0.effectiveAt > $1.effectiveAt }
    }

    func signals(derivedFromEvidence evidenceID: EvidenceID) throws -> [InvestmentSignal] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { $0.derivedFromEvidenceIDs.contains(evidenceID) }
            .sorted { $0.effectiveAt > $1.effectiveAt }
    }

    /// 与 GRDB 实现同粒度的分歧字段定位（parity：错误信息可比较）。
    private static func firstDivergentField(
        _ lhs: InvestmentSignal, _ rhs: InvestmentSignal
    ) -> String? {
        if lhs.subjectCanonical != rhs.subjectCanonical { return "subject_entity_type" }
        if lhs.dimension != rhs.dimension { return "dimension" }
        if lhs.direction != rhs.direction { return "direction" }
        if lhs.strength != rhs.strength { return "strength" }
        if Set(lhs.derivedFromEvidenceIDs.map(\.rawValue))
            != Set(rhs.derivedFromEvidenceIDs.map(\.rawValue)) {
            return "derived_from_evidence_ids"
        }
        if lhs.producer != rhs.producer { return "producer_kind" }
        if lhs.rationale != rhs.rationale { return "rationale" }
        return nil
    }
}
