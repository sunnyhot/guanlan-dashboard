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

// MARK: - 交易所交易时段（P1-4：盘外 fail-closed）

/// 交易所开市区间（交易所所在地钟表时间）。盘中执行只在开市区间内考虑——
/// 工作日凌晨 / 午休 / 收盘后一律 HOLD（此前只判「交易日」，盘外也可能
/// 产出 EXECUTE_REBALANCE）。
///
/// 已知限制（诚实记录，不编造日历）：半日市（除夕下午休市等）依赖
/// TradingCalendar 的交易日判定，精确半日市日历没有免费数据源——
/// 半日市的下午时段可能被误判开市；该误差方向是「多 HOLD 少执行」的
/// 反面，生产接线时如引入节假日数据源应在此收紧。
struct ExchangeSessionSchedule: Sendable, Hashable, Codable {
    struct Session: Sendable, Hashable, Codable {
        /// 当日分钟数（本地钟表时间，0 = 00:00）
        let startMinute: Int
        let endMinute: Int

        func contains(_ minuteOfDay: Int) -> Bool {
            minuteOfDay >= startMinute && minuteOfDay < endMinute
        }
    }

    let exchange: Exchange
    let sessions: [Session]

    /// 交易所时区（A 股沪/深同区；美股按美东——DST 由 TimeZone 自行处理）。
    static func timeZone(for exchange: Exchange) -> TimeZone {
        switch exchange {
        case .sse, .szse: return TimeZone(identifier: "Asia/Shanghai")!
        case .hkex: return TimeZone(identifier: "Asia/Hong_Kong")!
        case .nyse, .nasdaq, .amex, .arca, .otc:
            return TimeZone(identifier: "America/New_York")!
        case .platform: return TimeZone(identifier: "Asia/Shanghai")!
        }
    }

    /// 各交易所常规时段（分钟）：A 股 / 港股午休分两段；美股单段。
    static func schedule(for exchange: Exchange) -> ExchangeSessionSchedule {
        let sessions: [Session]
        switch exchange {
        case .sse, .szse:
            // 09:30-11:30 / 13:00-15:00（午休休市）
            sessions = [
                Session(startMinute: 9 * 60 + 30, endMinute: 11 * 60 + 30),
                Session(startMinute: 13 * 60, endMinute: 15 * 60),
            ]
        case .hkex:
            // 09:30-12:00 / 13:00-16:00
            sessions = [
                Session(startMinute: 9 * 60 + 30, endMinute: 12 * 60),
                Session(startMinute: 13 * 60, endMinute: 16 * 60),
            ]
        case .nyse, .nasdaq, .amex, .arca:
            // 09:30-16:00（常规时段；盘前盘后不属执行窗口）
            sessions = [Session(startMinute: 9 * 60 + 30, endMinute: 16 * 60)]
        case .otc, .platform:
            // 场外（基金申赎）与平台内部挂牌无固定盘中时段——按「交易日
            // 全天可执行」处理（T 日任意时刻申赎同口径），不设时段门槛。
            sessions = [Session(startMinute: 0, endMinute: 24 * 60)]
        }
        return ExchangeSessionSchedule(exchange: exchange, sessions: sessions)
    }

    /// asOf 是否落在开市区间内（按交易所时区的本地钟表时间判定；
    /// isTradingDay 的交易日判定由调用方（Eligibility）负责）。
    func isOpen(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone(for: exchange)
        let minuteOfDay = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        return sessions.contains { $0.contains(minuteOfDay) }
    }

    /// 人读时段描述（HOLD 理由用）。
    var label: String {
        sessions
            .map { session in
                String(format: "%02d:%02d-%02d:%02d",
                       session.startMinute / 60, session.startMinute % 60,
                       session.endMinute / 60, session.endMinute % 60)
            }
            .joined(separator: " / ")
    }
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
        /// 交易日历法域覆盖（十七轮 P0-2）：**场外基金组合必填中国法域**——
        /// Exchange.otc 的默认法域是美域（NYSE 节假日表），A 股春节长假
        /// 期间会误判可执行；nil = 沿用 exchange.jurisdiction。时段判定
        /// 仍按 exchange（场外无盘中时段门槛）。
        var tradingJurisdiction: Jurisdiction? = nil

        init(
            subject: CanonicalRef,
            portfolio: PortfolioSnapshot,
            target: AllocationTarget?,
            remediationTargets: [RemediationTargetInput] = [],
            userDirectives: [UserDirectiveInput] = [],
            actionDomain: ActionDomain,
            exchange: Exchange,
            tradingJurisdiction: Jurisdiction? = nil
        ) {
            self.subject = subject
            self.portfolio = portfolio
            self.target = target
            self.remediationTargets = remediationTargets
            self.userDirectives = userDirectives
            self.actionDomain = actionDomain
            self.exchange = exchange
            self.tradingJurisdiction = tradingJurisdiction
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
        // 指纹覆盖全部决策输入（十六轮审查 P2：缺输入会让语义不同的运行
        // 撞同一 job ID）：主体 / 持仓权重快照 / target / remediation /
        // directives / 动作域 / 约束门配置 / asOf / 策略。
        //（signals 运行时查询、非输入——经 artifact 引用层体现,不进指纹。）
        var fingerprintPayload: [String: String] = [
            "subject": input.subject.stableKey,
            "portfolioAsOf": String(Int(input.portfolio.asOf.timeIntervalSince1970)),
            "target": input.target?.id.rawValue ?? "-",
            "exchange": input.exchange.rawValue,
            "tradingJurisdiction": (input.tradingJurisdiction ?? input.exchange.jurisdiction).rawValue,
            "maxSnapshotAgeHours": String(eligibility.maxSnapshotAgeHours),
            "asOf": String(Int(asOf.timeIntervalSince1970)),
            "policy": eligibility.identityToken,
        ]
        let portfolioDigest: String = input.portfolio.positions
            .map { "\($0.subjectKey):\($0.weight.value)" }
            .sorted().joined(separator: ",")
        let remediationDigest: String = input.remediationTargets
            .map { "\($0.subjectKey):\($0.maxWeight.value):\($0.requirement.constraintID)" }
            .sorted().joined(separator: ",")
        let directivesDigest: String = input.userDirectives
            .map { "\($0.subjectKey):\($0.deltaWeight.value):\($0.directiveID)" }
            .sorted().joined(separator: ",")
        let domainDigest: String = input.actionDomain.perSubjectBounds
            .map { "\($0.key):\($0.value.lower.value)..\($0.value.upper.value)" }
            .sorted().joined(separator: ",")
        let actionRulesDigest: String = actionRules.map(\.label).sorted().joined(separator: ",")
        let portfolioRulesDigest: String = portfolioRules.map(\.label).sorted().joined(separator: ",")
        fingerprintPayload["portfolio"] = portfolioDigest
        fingerprintPayload["remediation"] = remediationDigest
        fingerprintPayload["directives"] = directivesDigest
        fingerprintPayload["domain"] = domainDigest
        fingerprintPayload["actionRules"] = actionRulesDigest
        fingerprintPayload["portfolioRules"] = portfolioRulesDigest
        let fingerprint = StableDigest.digest(
            StableDigest.jsonPayloadOrString(fingerprintPayload)
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
            let jurisdiction = input.tradingJurisdiction ?? input.exchange.jurisdiction
            if !calendar.isTradingDay(asOf, jurisdiction: jurisdiction) {
                holdReasons.append("非交易日（\(input.exchange.rawValue) · \(jurisdiction.rawValue) 法域）")
            } else {
                // 交易日还要在开市区间内——盘前 / 午休 / 收盘后 fail-closed
                //（交易所时区判定，盘外不产执行决策）
                let session = ExchangeSessionSchedule.schedule(for: input.exchange)
                if !session.isOpen(at: asOf) {
                    holdReasons.append(
                        "非交易时段（\(input.exchange.rawValue) \(session.label)，交易所本地时间）"
                    )
                }
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

            // execute 报告内嵌的 plan 只含**通过约束门存活的动作**（十七轮
            // P2:下游按 plan.actions 执行,被裁剪动作进报告会被原样执行）;
            // 裁剪明细留在 holdReasons 留证。
            let executablePlan = PortfolioActionPlan(
                id: plan.id, asOf: plan.asOf, targetID: plan.targetID,
                actions: surviving, notes: plan.notes, plannerVersion: plan.plannerVersion
            )
            let report = Self.assemble(
                input: input, asOf: asOf, now: now,
                decision: .executeRebalance, plan: executablePlan, gateVerdict: verdict,
                holdReasons: pruned.pruned.map {
                    "动作 \($0.action.action.subjectKey) 被 \($0.ruleLabel) 裁剪（不执行,留证）"
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
