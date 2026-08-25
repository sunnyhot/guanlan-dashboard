import Foundation

// MARK: - Research Validation pipeline（RES-5）
//
// LLM 产出（ResearchNotes）进入系统状态前的统一验证管道（M8 验收）：
// SchemaValidator（结构不变量）→ EvidenceBindingValidator（证据引用绑定）
// → FreshnessValidator（时效）。三层都过才算 valid——任何一层 error 拒绝
// 进 Signal Store（RES-6 落库前的门禁），warning 透明携带（不静默丢弃）。
//
// 与既有层的关系：RES-7 的 Codable 解码保证「形状」，本管道验证「语义」；
// Harness 的提交门禁是运行内最低完整性（未知 evidence 引用拒收），本管道
// 的 EvidenceBinding 是独立可组合的再验证（可对 DB 读回的 notes 复检）；
// RES-8 Evidence Matcher 落地后，knownEvidence 集合可由 matcher 的输出供给。

/// 单个验证问题（error 拒绝 / warning 透明）。
struct ResearchValidationIssue: Sendable, Hashable, Codable {
    enum ValidatorKind: String, Sendable, Codable, Hashable {
        case schema = "SCHEMA"
        case evidenceBinding = "EVIDENCE_BINDING"
        case freshness = "FRESHNESS"
    }

    let validator: ValidatorKind
    let code: String
    let detail: String
    /// 关联的 claim 序号（notes 级问题为 nil）。
    let claimIndex: Int?
}

/// 验证结果：errors 非空 = 拒绝；warnings 伴随通过。
struct ResearchValidationResult: Sendable, Hashable, Codable {
    let errors: [ResearchValidationIssue]
    let warnings: [ResearchValidationIssue]

    var isValid: Bool { errors.isEmpty }
}

// MARK: - SchemaValidator（结构不变量）

/// 结构校验配置。
struct ResearchSchemaValidationConfig: Sendable, Hashable, Codable {
    var maxClaims = 50
    var maxStatementLength = 500
    var maxNotesLength = 20_000
}

struct ResearchSchemaValidator: Sendable {
    var config = ResearchSchemaValidationConfig()

    func validate(_ notes: ResearchNotes) -> [ResearchValidationIssue] {
        var issues: [ResearchValidationIssue] = []
        if notes.claims.isEmpty {
            issues.append(ResearchValidationIssue(
                validator: .schema, code: "empty_claims",
                detail: "研究笔记没有任何 claim", claimIndex: nil
            ))
        }
        if notes.claims.count > config.maxClaims {
            issues.append(ResearchValidationIssue(
                validator: .schema, code: "too_many_claims",
                detail: "claims 数 \(notes.claims.count) 超过上限 \(config.maxClaims)", claimIndex: nil
            ))
        }
        if notes.notes.count > config.maxNotesLength {
            issues.append(ResearchValidationIssue(
                validator: .schema, code: "notes_too_long",
                detail: "叙述长度 \(notes.notes.count) 超过上限 \(config.maxNotesLength)", claimIndex: nil
            ))
        }
        for (index, claim) in notes.claims.enumerated() {
            let trimmed = claim.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append(ResearchValidationIssue(
                    validator: .schema, code: "empty_statement",
                    detail: "claim 陈述为空", claimIndex: index
                ))
            } else if claim.statement.count > config.maxStatementLength {
                issues.append(ResearchValidationIssue(
                    validator: .schema, code: "statement_too_long",
                    detail: "claim 陈述长度 \(claim.statement.count) 超过上限 \(config.maxStatementLength)",
                    claimIndex: index
                ))
            }
            if claim.dimension == nil {
                issues.append(ResearchValidationIssue(
                    validator: .schema, code: "missing_dimension",
                    detail: "claim 缺少 dimension，无法归入信号维度（提取时将被跳过）", claimIndex: index
                ))
            }
        }
        return issues
    }
}

// MARK: - EvidenceBindingValidator（证据引用绑定）

/// 证据绑定配置。
struct ResearchEvidenceBindingConfig: Sendable, Hashable, Codable {
    /// 无 evidence 引用的 claim 是否升级为 error（默认 false：warning，
    /// 由 SignalExtractionPolicy 在提取层强制 uncertain，见 RES-4）。
    var treatMissingEvidenceAsError = false
}

struct ResearchEvidenceBindingValidator: Sendable {
    var config = ResearchEvidenceBindingConfig()

    /// 校验 claims 的 evidence 引用是否全部可解析到已知证据集。
    /// - Parameter knownEvidence: 可解析的 EvidenceID rawValue 集合
    ///  （运行内登记簿 / DB 已有 evidence / RES-8 matcher 输出）。
    func validate(
        _ notes: ResearchNotes,
        knownEvidence: Set<String>
    ) -> [ResearchValidationIssue] {
        var issues: [ResearchValidationIssue] = []
        for (index, claim) in notes.claims.enumerated() {
            let unknown = claim.evidenceReferences
                .map(\.rawValue)
                .filter { !knownEvidence.contains($0) }
            if !unknown.isEmpty {
                issues.append(ResearchValidationIssue(
                    validator: .evidenceBinding, code: "unresolved_evidence_reference",
                    detail: "引用了未知 evidence：\(unknown.sorted().joined(separator: ", "))",
                    claimIndex: index
                ))
            }
            if claim.evidenceReferences.isEmpty {
                // error/warning 分流统一在 split()（按 treatMissingEvidenceAsError）。
                issues.append(ResearchValidationIssue(
                    validator: .evidenceBinding, code: "missing_evidence",
                    detail: "claim 无证据引用（提取时方向将强制 uncertain）", claimIndex: index
                ))
            }
        }
        return issues
    }

    /// 按配置分流 error / warning。
    func split(_ issues: [ResearchValidationIssue]) -> (errors: [ResearchValidationIssue], warnings: [ResearchValidationIssue]) {
        let errors = issues.filter { issue in
            issue.code != "missing_evidence" || config.treatMissingEvidenceAsError
        }
        let warnings = issues.filter { issue in
            issue.code == "missing_evidence" && !config.treatMissingEvidenceAsError
        }
        return (errors, warnings)
    }
}

// MARK: - FreshnessValidator（时效）

/// 时效配置。
struct ResearchFreshnessConfig: Sendable, Hashable, Codable {
    /// notes 产出超龄（秒）→ error（过时研究不进系统）。
    var maxNotesAge: TimeInterval = 24 * 3600
    /// 单条 evidence 证据时间超龄（秒）→ warning（透明提示，不拒绝——
    /// 老证据支撑的弱结论经 RES-4 提取层已充分降级）。
    var evidenceStalenessWarning: TimeInterval = 30 * 24 * 3600
}

struct ResearchFreshnessValidator: Sendable {
    var config = ResearchFreshnessConfig()

    /// - Parameter evidenceDates: EvidenceID rawValue → 证据时间（获取/发布），
    ///   调用方供给（运行登记簿时间或 DB evidence 的 availableAt）。
    func validate(
        _ notes: ResearchNotes,
        now: Date,
        evidenceDates: [String: Date]
    ) -> [ResearchValidationIssue] {
        var issues: [ResearchValidationIssue] = []
        let age = now.timeIntervalSince(notes.producedAt)
        if age > config.maxNotesAge {
            issues.append(ResearchValidationIssue(
                validator: .freshness, code: "notes_stale",
                detail: "研究笔记产出已 \(Int(age / 3600)) 小时，超过 \(Int(config.maxNotesAge / 3600)) 小时上限",
                claimIndex: nil
            ))
        }
        for (index, claim) in notes.claims.enumerated() {
            let stale = claim.evidenceReferences
                .compactMap { evidenceDates[$0.rawValue] }
                .filter { now.timeIntervalSince($0) > config.evidenceStalenessWarning }
            if !stale.isEmpty {
                issues.append(ResearchValidationIssue(
                    validator: .freshness, code: "evidence_stale",
                    detail: "引用了 \(stale.count) 条超 \(Int(config.evidenceStalenessWarning / 86400)) 天的陈旧证据",
                    claimIndex: index
                ))
            }
        }
        return issues
    }
}

// MARK: - 统一管道

/// LLM 输出后的统一验证管道（M8 验收：三层全过才进系统状态）。
struct ResearchValidationPipeline: Sendable {
    var schema = ResearchSchemaValidator()
    var evidenceBinding = ResearchEvidenceBindingValidator()
    var freshness = ResearchFreshnessValidator()

    /// 完整验证。evidenceDates 缺省为空（evidence 时效检查跳过——
    /// 没有证据时间信息时不猜，不产生 stale 误报）。
    func validate(
        _ notes: ResearchNotes,
        now: Date,
        knownEvidence: Set<String>,
        evidenceDates: [String: Date] = [:]
    ) -> ResearchValidationResult {
        // Schema 层全为 error（结构不完整直接拒绝）。
        var errors = schema.validate(notes)
        var warnings: [ResearchValidationIssue] = []

        // Evidence 绑定层按配置分流。
        let bindingIssues = evidenceBinding.validate(notes, knownEvidence: knownEvidence)
        let split = evidenceBinding.split(bindingIssues)
        errors.append(contentsOf: split.errors)
        warnings.append(contentsOf: split.warnings)

        // 时效层：notes 超龄为 error；evidence 陈旧为 warning。
        for issue in freshness.validate(notes, now: now, evidenceDates: evidenceDates) {
            if issue.code == "notes_stale" {
                errors.append(issue)
            } else {
                warnings.append(issue)
            }
        }
        return ResearchValidationResult(errors: errors, warnings: warnings)
    }
}
