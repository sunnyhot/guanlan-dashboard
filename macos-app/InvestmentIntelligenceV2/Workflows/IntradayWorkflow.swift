import Foundation

// MARK: - Intraday Workflow（WF-3，替代旧 3+1 Agents 盘中链路）
//
// 盘中执行决策 = Signal（叙述层）+ Eligibility（可执行性）+
// Rebalance execution decision（再平衡执行）。核心纪律：
//
// - **非 LLM 猜仓位（D001）**：Δw 唯一来源是 TargetRebalancePlanner 的
//   三类 provenance（target / remediation / user）——本 workflow 不调
//   LLM；InvestmentSignal 只作叙述层引用进 artifact（提醒「有哪些研究
//   判断在场」，不进任何 Δw 数学）
// - **Eligibility 前置**：非交易日 / 组合快照陈旧 / 无 provenance 来源
//   → hold（显式理由，不静默）；带内偏差（|current−target| ≤ tolerance）
//   → hold（不交易是决策）
// - **双层约束门**：plan 动作过 ConstraintGate（裁剪 + 联合约束），
//   gate 拒绝 → hold（violations 显式）
// - 报告是 Artifact，validity = tradingSession（本交易时段有效，下一
//   时段失效——盘口语义）；dependencies 引用 signals + target
// - 确定性：同输入（快照 / target / signals / asOf）→ 同报告 ID

/// 盘中执行决策结论。
enum IntradayDecisionKind: String, Sendable, Codable, Hashable {
    /// 执行再平衡（plan 有动作 + gate 通过）
    case executeRebalance = "EXECUTE_REBALANCE"
    /// 持有不动（理由显式记录）
    case hold = "HOLD"
}

/// Eligibility 策略（versioned heuristic）。
struct IntradayEligibilityPolicy: Sendable, Codable, Hashable {
    let policyID: String
    let version: String
    let rationale: String
    /// 组合快照最大年龄（小时；超过 → hold，数据陈旧不交易）
    var maxSnapshotAgeHours: Int

    init(
        policyID: String = "intraday-eligibility",
        version: String = "v1",
        rationale: String = "交易日 + 快照 ≤ 26h 才考虑执行——陈旧数据上的执行是猜",
        maxSnapshotAgeHours: Int = 26
    ) {
        self.policyID = policyID
        self.version = version
        self.rationale = rationale
        self.maxSnapshotAgeHours = maxSnapshotAgeHours
    }

    var identityToken: String { "\(policyID)@\(version)" }
}

/// 盘中执行报告（INTRADAY_EXECUTION_REPORT artifact）。
struct IntradayExecutionReport: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 本交易时段有效（盘口语义；时区按 Exchange 法域，避免裸 Date 跨时区误判）。
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    let asOf: Date
    let decision: IntradayDecisionKind
    let eligibility: IntradayEligibilityPolicy
    /// 执行时的行动计划（provenance 全部 D001 三类；hold 时为 nil）。
    let plan: PortfolioActionPlan?
    /// 双层约束门结论（执行时必带；hold 时 nil）。
    let gateVerdict: ConstraintGate.GateVerdict?
    /// hold 的显式理由（非交易时段 / 数据陈旧 / 带内 / gate 拒绝等）。
    let holdReasons: [String]
    /// 叙述层引用的研究信号（不进 Δw 数学，D001）。
    let referencedSignalIDs: [SignalID]
    /// 参照 Target（D000 provenance 闭环）。
    let target: AllocationTarget?
}

// MARK: - Workflow 本体

/// 盘中执行工作流（同步纯计算，无 LLM / 无网络）。
struct IntradayWorkflow: Sendable {
    static let workflowKind = "intraday"

    let signalStore: any SignalStore
    let planner: TargetRebalancePlanner
    let gate: ConstraintGate
    let calendar: any TradingCalendar
    let eligibility: IntradayEligibilityPolicy
    /// 双层约束门配置（action 硬约束 + 组合联合约束）。
    let actionRules: [ConstraintGate.ActionRule]
    let portfolioRules: [ConstraintGate.PortfolioRule]

    init(
        signalStore: any SignalStore,
        planner: TargetRebalancePlanner = TargetRebalancePlanner(),
        gate: ConstraintGate = ConstraintGate(),
        calendar: any TradingCalendar,
        eligibility: IntradayEligibilityPolicy = IntradayEligibilityPolicy(),
        actionRules: [ConstraintGate.ActionRule] = [],
        portfolioRules: [ConstraintGate.PortfolioRule] = []
    ) {
        self.signalStore = signalStore
        self.planner = planner
        self.gate = gate
        self.calendar = calendar
        self.eligibility = eligibility
        self.actionRules = actionRules
        self.portfolioRules = portfolioRules
    }

    struct Input: Sendable {
        /// 组合主体（signal 查询锚点）。
        let subject: CanonicalRef
        let portfolio: PortfolioSnapshot
        let target: AllocationTarget?
        let remediationTargets: [RemediationTargetInput]
        let userDirectives: [UserDirectiveInput]
        let actionDomain: ActionDomain
        /// 执行交易所（交易时段 / 时区判定）。
        let exchange: Exchange

        init(
            subject: CanonicalRef,
            portfolio: PortfolioSnapshot,
            target: AllocationTarget?,
            remediationTargets: [RemediationTargetInput] = [],
            userDirectives: [UserDirectiveInput] = [],
            actionDomain: ActionDomain,
            exchange: Exchange
        ) {
            self.subject = subject
            self.portfolio = portfolio
            self.target = target
            self.remediationTargets = remediationTargets
            self.userDirectives = userDirectives
            self.actionDomain = actionDomain
            self.exchange = exchange
        }
    }

    struct RunOutcome: Sendable {
        let job: AgentJob
        let report: IntradayExecutionReport?
        let errorDetail: String?

        var succeeded: Bool { job.state == .completed }
    }

    /// 执行盘中决策 job。
    ///
    /// hold 不是失败——job completed + decision = .hold + holdReasons 显式；
    /// 抛错只在真异常（signal 查询失败等）。
    func run(input: Input, asOf: Date, now: Date) -> RunOutcome {
        let fingerprint = StableDigest.digest(
            "\(input.subject.stableKey)|\(Int(input.portfolio.asOf.timeIntervalSince1970))|\(input.target?.id.rawValue ?? "-")|\(Int(asOf.timeIntervalSince1970))|\(eligibility.identityToken)"
        )
        var job = AgentJob(
            workflowKind: Self.workflowKind,
            inputFingerprint: fingerprint,
            createdAt: now
        )
        if job.state == .cancelled {
            return RunOutcome(job: job, report: nil, errorDetail: nil)
        }
        do {
            try job.transition(to: .running, at: now, detail: nil)

            // ---- Signal 层（叙述层；查询失败 = 真异常）----

            let signals = try signalStore.signals(subject: input.subject)

            // ---- Eligibility 层 ----

            var holdReasons: [String] = []
            let jurisdiction = input.exchange.jurisdiction
            if !calendar.isTradingDay(asOf, jurisdiction: jurisdiction) {
                holdReasons.append("非交易日（\(input.exchange.rawValue) 法域）")
            }
            let snapshotAge = asOf.timeIntervalSince(input.portfolio.asOf)
            if snapshotAge > TimeInterval(eligibility.maxSnapshotAgeHours) * 3600 {
                holdReasons.append(
                    "组合快照陈旧（\(Int(snapshotAge / 3600))h > \(eligibility.maxSnapshotAgeHours)h）"
                )
            }
            if input.target == nil
                && input.remediationTargets.isEmpty
                && input.userDirectives.isEmpty {
                holdReasons.append("无 provenance 来源（target / remediation / user 全空）——D001 下不产 Δw")
            }

            if !holdReasons.isEmpty {
                let report = Self.assemble(
                    input: input, asOf: asOf, now: now,
                    decision: .hold, plan: nil, gateVerdict: nil,
                    holdReasons: holdReasons,
                    signalIDs: signals.map(\.id),
                    eligibility: eligibility
                )
                try job.transition(to: .completed, at: now, detail: report.id.rawValue)
                return RunOutcome(job: job, report: report, errorDetail: nil)
            }

            // ---- Execution 层（Δw 唯一来源：planner）----

            let plan = planner.plan(
                portfolio: input.portfolio,
                target: input.target,
                remediationTargets: input.remediationTargets,
                userDirectives: input.userDirectives,
                actionDomain: input.actionDomain,
                now: asOf
            )
            if plan.actions.isEmpty {
                let reason = plan.notes.first
                    ?? "全部资产类偏差在容忍带内（|current − target| ≤ \(planner.parameters.rebalanceToleranceBand)）——不交易"
                let report = Self.assemble(
                    input: input, asOf: asOf, now: now,
                    decision: .hold, plan: plan, gateVerdict: nil,
                    holdReasons: [reason],
                    signalIDs: signals.map(\.id),
                    eligibility: eligibility
                )
                try job.transition(to: .completed, at: now, detail: report.id.rawValue)
                return RunOutcome(job: job, report: report, errorDetail: nil)
            }

            // 双层约束门
            let pruned = gate.prune(actions: plan.actions, rules: actionRules)
            let surviving = pruned.kept
            let projected = ProjectedPortfolio.project(
                base: input.portfolio,
                applying: surviving.map(\.action)
            )
            let verdict = gate.evaluate(
                projected: projected,
                actions: surviving.map(\.action),
                rules: portfolioRules
            )
            var holdReasonsAfterGate: [String] = []
            if surviving.isEmpty {
                holdReasonsAfterGate.append(
                    "全部动作被 action-level 约束裁剪：\(pruned.pruned.map { "\($0.action.action.subjectKey)@\($0.ruleLabel)" }.joined(separator: ", "))"
                )
            } else if !verdict.passed {
                holdReasonsAfterGate.append(contentsOf: verdict.violations)
            }
            if !holdReasonsAfterGate.isEmpty {
                let report = Self.assemble(
                    input: input, asOf: asOf, now: now,
                    decision: .hold, plan: plan, gateVerdict: verdict,
                    holdReasons: holdReasonsAfterGate,
                    signalIDs: signals.map(\.id),
                    eligibility: eligibility
                )
                try job.transition(to: .completed, at: now, detail: report.id.rawValue)
                return RunOutcome(job: job, report: report, errorDetail: nil)
            }

            let report = Self.assemble(
                input: input, asOf: asOf, now: now,
                decision: .executeRebalance, plan: plan, gateVerdict: verdict,
                holdReasons: pruned.pruned.map {
                    "动作 \($0.action.action.subjectKey) 被 \($0.ruleLabel) 裁剪（留证）"
                },
                signalIDs: signals.map(\.id),
                eligibility: eligibility
            )
            try job.transition(to: .completed, at: now, detail: report.id.rawValue)
            return RunOutcome(job: job, report: report, errorDetail: nil)
        } catch {
            let detail = String(describing: error)
            if job.state == .running {
                try? job.transition(to: .failed, at: now, detail: detail)
            }
            return RunOutcome(job: job, report: nil, errorDetail: detail)
        }
    }

    /// 报告组装（确定性 ID：全部语义字段，不含 producedAt）。
    private static func assemble(
        input: Input,
        asOf: Date,
        now: Date,
        decision: IntradayDecisionKind,
        plan: PortfolioActionPlan?,
        gateVerdict: ConstraintGate.GateVerdict?,
        holdReasons: [String],
        signalIDs: [SignalID],
        eligibility: IntradayEligibilityPolicy
    ) -> IntradayExecutionReport {
        var dependencies: [ArtifactDependency] =
            signalIDs.map { ArtifactDependency(kind: .signal, referenceID: $0.rawValue) }
        if let target = input.target {
            dependencies.append(
                ArtifactDependency(kind: .target, referenceID: target.id.rawValue)
            )
        }
        let payload = try! StableDigest.jsonPayload(ReportIdentity(
            subjectKey: input.subject.stableKey,
            asOfEpoch: Int(asOf.timeIntervalSince1970),
            portfolioAsOfEpoch: Int(input.portfolio.asOf.timeIntervalSince1970),
            decision: decision,
            eligibility: eligibility,
            plan: plan,
            gateVerdict: gateVerdict,
            holdReasons: holdReasons,
            signalIDs: signalIDs.map(\.rawValue).sorted(),
            targetID: input.target?.id.rawValue
        ))
        return IntradayExecutionReport(
            id: ArtifactID(rawValue: "itd_\(StableDigest.digest(payload))"),
            producedAt: now,
            validityPolicy: .tradingSession(
                exchange: input.exchange, sessionDate: asOf
            ),
            dependencies: dependencies,
            asOf: asOf,
            decision: decision,
            eligibility: eligibility,
            plan: plan,
            gateVerdict: gateVerdict,
            holdReasons: holdReasons,
            referencedSignalIDs: signalIDs,
            target: input.target
        )
    }

    private struct ReportIdentity: Encodable {
        let subjectKey: String
        let asOfEpoch: Int
        let portfolioAsOfEpoch: Int
        let decision: IntradayDecisionKind
        let eligibility: IntradayEligibilityPolicy
        let plan: PortfolioActionPlan?
        let gateVerdict: ConstraintGate.GateVerdict?
        let holdReasons: [String]
        let signalIDs: [String]
        let targetID: String?
    }
}
