import Foundation

// MARK: - Signal Extraction（RES-4，V3.1 §100 Research 链末段）
//
// ResearchNotes → [InvestmentSignal] 的**确定性**转换：direction 来自模型的
// ordinal 研究判断（铁律允许的 Event Interpretation / Thesis Formation 结论
// 形态），但落地前必须过 versioned 提取策略的证据门槛——「自由 reasoning
// 不直接进系统状态」（rollout RES-4 验收）：
// - 无 evidence 引用的 claim：direction 强制 uncertain（无证据方向不进系统）
// - 非中性方向（bullish/bearish）：evidence 数 < minEvidenceCountForDirection
//   → 降级 uncertain
// - LOW 充分度：按策略降级（direction → uncertain，或 strength 封顶 weak）
// - 同维度方向冲突（既有 bullish 又有 bearish）→ uncertain + rationale 注明
// - strength 只由 confidenceLabel 确定性映射（HIGH/MEDIUM/LOW →
//   strong/moderate/weak），不存在数值置信度通道
//
// ordinal→cardinal 防火墙（七轮审查 P1 纪律）：产出物是 InvestmentSignal
//（ordinal），不产任何 cardinal 数值；下游 D002 的 criterion 数值只来自
// FactorMetric / CardinalObservation / PlanMetrics，与本类型无关。

/// 提取策略（versioned——阈值调整必须 bump provenance.policyVersion；
/// policy 版本参与 SignalID 派生：同 notes 在不同版本策略下产出不同 ID，
/// 历史信号可审计是哪个版本策略的产物）。
struct SignalExtractionPolicy: Sendable, Hashable, Codable {
    let provenance: SignalPolicyProvenance
    /// 非中性方向（bullish/bearish）所需的最少独立 evidence 数。
    var minEvidenceCountForDirection: Int = 1
    /// LOW 充分度 claim 的处理。
    var lowConfidenceHandling: LowConfidenceHandling = .downgradeToUncertain

    enum LowConfidenceHandling: String, Sendable, Codable, Hashable {
        /// direction → uncertain（保守默认：低充分度不进方向）
        case downgradeToUncertain = "DOWNGRADE_TO_UNCERTAIN"
        /// 保留方向，strength 封顶 weak
        case capStrengthAtWeak = "CAP_STRENGTH_AT_WEAK"
    }

    init(
        provenance: SignalPolicyProvenance,
        minEvidenceCountForDirection: Int = 1,
        lowConfidenceHandling: LowConfidenceHandling = .downgradeToUncertain
    ) {
        self.provenance = provenance
        self.minEvidenceCountForDirection = minEvidenceCountForDirection
        self.lowConfidenceHandling = lowConfidenceHandling
    }

    /// 默认策略（v1：heuristic 阈值，依据见 rationale）。
    static let defaultValue = SignalExtractionPolicy(
        provenance: SignalPolicyProvenance(
            policyID: "research-signal-extraction",
            policyVersion: "v1",
            basis: .heuristic,
            rationale: "非中性方向至少 1 条独立证据；低充分度降级 uncertain——研究判断进系统状态的最小证据门槛",
            quantileSampleWindow: nil
        )
    )

    /// policy 身份串（参与 SignalID 派生）。
    var identityToken: String {
        "\(provenance.policyID)@\(provenance.policyVersion)"
    }
}

/// 提取器（纯函数；无 IO、无 LLM 调用）。
struct SignalExtractor: Sendable {
    let policy: SignalExtractionPolicy

    init(policy: SignalExtractionPolicy = .defaultValue) {
        self.policy = policy
    }

    /// ResearchNotes → InvestmentSignals。
    ///
    /// - dimension 为 nil 的 claim 无法归入信号维度：跳过（叙述仍留在 notes）
    /// - **去重后 evidence 为空的维度组同样跳过**（审查 P2-2）：无证据支撑的
    ///   不是信号、是叙述——与 SignalStore 写入门禁（空 evidence = malformed）
    ///   对齐，「validate(默认 warning) → extract → write」合法流程不会在
    ///   写库处爆 malformed
    /// - 同 dimension 的 claims 合并为一个 signal（evidence 并集、方向冲突降级）
    /// - 产出信号的 rationale 携带 policy 身份与降级原因（审计可见）
    func extract(from notes: ResearchNotes, now: Date) -> [InvestmentSignal] {
        var byDimension: [SignalDimension: [ResearchClaim]] = [:]
        for claim in notes.claims {
            guard let dimension = claim.dimension else { continue }
            byDimension[dimension, default: []].append(claim)
        }

        return SignalDimension.allCases.compactMap { dimension in
            guard let claims = byDimension[dimension], !claims.isEmpty else { return nil }
            return signal(for: dimension, claims: claims, notes: notes, now: now)
        }
    }

    // MARK: - 私有

    private func signal(
        for dimension: SignalDimension,
        claims: [ResearchClaim],
        notes: ResearchNotes,
        now: Date
    ) -> InvestmentSignal? {
        // 独立 evidence 并集（排序保证 ID 稳定）；空组不产信号（P2-2，见 extract 注释）
        let evidence = claims
            .flatMap { $0.evidenceReferences }
            .map(\.rawValue)
            .sorted()
        guard !evidence.isEmpty else { return nil }
        var evidenceIDs = Array(Set(evidence)).map { EvidenceID(rawValue: $0) }
        evidenceIDs.sort { $0.rawValue < $1.rawValue }

        // 逐 claim 的方向门槛判定
        var demotionNotes: [String] = []
        var admittedDirections: [SignalDirection] = []
        var strengthCap: SignalStrength?

        for claim in claims {
            var direction = claim.direction ?? .uncertain
            // 无证据的方向不进系统
            if direction.isDeterministic, claim.evidenceReferences.isEmpty {
                direction = .uncertain
                demotionNotes.append("「\(claim.statement)」无证据引用，方向降级 uncertain")
            }
            // 证据数门槛
            if direction.isDeterministic,
               claim.evidenceReferences.count < policy.minEvidenceCountForDirection {
                direction = .uncertain
                demotionNotes.append("「\(claim.statement)」证据数 < \(policy.minEvidenceCountForDirection)，方向降级 uncertain")
            }
            // LOW 充分度处理
            if claim.confidenceLabel == .low {
                switch policy.lowConfidenceHandling {
                case .downgradeToUncertain:
                    if direction.isDeterministic {
                        direction = .uncertain
                        demotionNotes.append("「\(claim.statement)」充分度 LOW，方向降级 uncertain")
                    }
                case .capStrengthAtWeak:
                    if strengthCap != .weak {
                        strengthCap = .weak
                        demotionNotes.append("「\(claim.statement)」充分度 LOW，强度封顶 weak")
                    }
                }
            }
            if direction.isDeterministic {
                admittedDirections.append(direction)
            }
        }

        // 同维度方向冲突 → uncertain（证据冲突 fail-closed，不择边）
        var direction: SignalDirection
        let distinct = Set(admittedDirections)
        if distinct.count > 1 {
            direction = .uncertain
            demotionNotes.append("同维度证据方向冲突（\(distinct.map(\.rawValue).sorted().joined(separator: " vs "))），方向降级 uncertain")
        } else {
            direction = distinct.first ?? .uncertain
        }

        // strength：confidenceLabel 确定性映射（取组内最高充分度）
        let bestLabel = claims.map(\.confidenceLabel).max { lhs, rhs in
            rank(lhs) < rank(rhs)
        } ?? .low
        var strength = mappedStrength(bestLabel)
        if let strengthCap, rankStrength(strength) > rankStrength(strengthCap) {
            strength = strengthCap
        }
        // uncertain 方向的强度固定 weak（方向不明无所谓强弱）
        if !direction.isDeterministic {
            strength = .weak
        }

        var rationale = claims.map(\.statement).joined(separator: "；")
        if !demotionNotes.isEmpty {
            rationale += "｜策略降级：\(demotionNotes.joined(separator: "；"))"
        }
        rationale += "｜policy=\(policy.identityToken)"

        // 确定性 ID：subject + dimension + direction + strength + evidence + policy
        //（不含 effectiveAt——同 notes 同 policy 重提取幂等）
        let idPayload = [
            "subject": "\(notes.task.subject.entityType)|\(notes.task.subject.entityIDRawValue)",
            "dimension": dimension.rawValue,
            "direction": direction.rawValue,
            "strength": strength.rawValue,
            "evidence": evidenceIDs.map(\.rawValue).joined(separator: ","),
            "policy": policy.identityToken,
        ].sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "|")
        let id = SignalID(rawValue: "sig_\(StableDigest.digest(idPayload))")

        return InvestmentSignal(
            id: id,
            subjectCanonical: notes.task.subject,
            dimension: dimension,
            direction: direction,
            strength: strength,
            derivedFromEvidenceIDs: evidenceIDs,
            effectiveAt: now,
            producer: SignalProducer(
                kind: .llm,
                modelIdentifier: notes.producedBy.model
            ),
            rationale: rationale
        )
    }

    private func rank(_ label: ResearchConfidenceLabel) -> Int {
        switch label {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    private func mappedStrength(_ label: ResearchConfidenceLabel) -> SignalStrength {
        switch label {
        case .high: return .strong
        case .medium: return .moderate
        case .low: return .weak
        }
    }

    private func rankStrength(_ strength: SignalStrength) -> Int {
        switch strength {
        case .strong: return 3
        case .moderate: return 2
        case .weak: return 1
        }
    }
}
