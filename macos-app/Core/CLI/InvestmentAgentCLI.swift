import CryptoKit
import Foundation
import GRDB

// MARK: - investment-agent CLI（AGENT-2，V3.1 §97 命令面）
//
// 投资智能 Agent 的无 GUI 入口：data sync / health / identity inspect /
// market-research / portfolio-review / attribution / decision replay /
// jobs / resume。与 App 共享同一数据目录（canonical.sqlite3 +
// user-portfolio.json），共享同一模块（V2 引擎 + Core 客户端零复制）。
//
// 入口分流在 main.swift：`--agent <command>`（或直接以已知 agent 子命令
// 启动二进制）走本 CLI 并在 SwiftUI 启动前退出——「不启动 SwiftUI 能跑
// research/sync/factor/attribution/decision」是本 story 的验收项。
//
// 凭据边界：CLI 进程不读 App 的 UserDefaults 域（二进制不同、defaults
// 域不同），LLM / Tavily / Alpha Vantage 凭据一律走环境变量：
// QIEMAN_LLM_BASE_URL / QIEMAN_LLM_MODEL / QIEMAN_LLM_API_KEY（portfolio-review）
// QIEMAN_ALPHAVANTAGE_API_KEY（可选行情降级源）
// QIEMAN_TAVILY_API_KEY（可选 web 研究工具）
//
// 作业纪律：会产生副作用 / 长耗时的命令（data-sync / market-research /
// portfolio-review / attribution）经 AGENT-1 WorkflowRegistry 提交——
// 幂等、事件时间线、崩溃后续跑（resume）全部继承。

// MARK: - 错误

enum AgentCLIError: Error, CustomStringConvertible {
    case missingLLMConfig
    case unknownCommand(String)
    case workflowFailed(String)
    case missingOption(String)
    case invalidOption(String, detail: String)

    var description: String {
        switch self {
        case .missingLLMConfig:
            return "portfolio-review 需要 LLM 配置：设置环境变量 QIEMAN_LLM_BASE_URL / QIEMAN_LLM_MODEL / QIEMAN_LLM_API_KEY"
        case .unknownCommand(let command):
            return "未知命令：\(command)"
        case .workflowFailed(let detail):
            return "workflow 执行失败：\(detail)"
        case .missingOption(let name):
            return "缺少必填选项：--\(name)"
        case .invalidOption(let name, let detail):
            return detail.isEmpty ? "非法选项：--\(name)" : detail
        }
    }
}

// MARK: - CLI 本体

enum InvestmentAgentCLI {

    static let agentVersion = "1.0.0"

    static let knownCommands: Set<String> = [
        "data-sync", "health", "identity-inspect", "market-research",
        "portfolio-review", "attribution", "decision-replay",
        "jobs", "resume", "recover", "version",
    ]

    static let helpText = """
    investment-agent — 投资智能 Agent 命令行（Investment Intelligence V2）

    用法：
      QiemanDashboard --agent <command> [options]
      investment-agent <command> [options]   （scripts/investment-agent 启动器）

    命令：
      data-sync             一轮市场数据维护（identity 建立 → universe 回填 → 收盘增量）
      health                数据库 / 产物 / 作业健康摘要
      identity-inspect      查询 Provider 代码的 Canonical 映射
      market-research       市场发现（本地因子筛选 + top-K 研究任务清单）
      portfolio-review      组合研究（Research → Thesis → Signals → Decision；需 LLM 配置）
      attribution           单日组合归因（本地库 + 成本口径权重）
      decision-replay       决策 artifact 完整重放校验
      jobs                  作业列表（含 attempt / 状态 / 错误）
      resume                恢复 / 重试一个作业（queued 直跑；陈旧 running 重开 attempt）
      recover               扫描并处置全部非终端作业
      version               版本

    通用选项：
      --data-dir <path>     数据目录（默认 ~/Library/Application Support/QiemanDashboard）
      --rounds <n>          data-sync 回填批次上限（默认 3）
      --limit <n>           jobs 列表条数 / market-research 任务上限（默认 20 / 8）
      --stale-after <sec>   resume / recover 的陈旧阈值秒（默认 0——CLI 进程刚起，
                            任何 RUNNING 都不是本进程持有）
      --code <code>         identity-inspect 的 Provider 代码
      --provider <name>     identity-inspect 的 Provider（默认 eastmoney）
      --scheme <name>       identity-inspect 的 scheme（默认按代码形态推导）
      --id <id>             decision-replay 的 artifact ID / resume 的 job ID
      --date <yyyy-mm-dd>   attribution 的归因日（默认今天；非法格式报错不回落）
      --force               显式重跑：同输入 completed 也开新 attempt
                           （日常无需——作业输入含数据锚点，数据变了自然新 job：
                           data-sync/market-research 按运行日、portfolio-review
                           含持仓摘要与最新 discovery 引用、attribution 按归因日）

    凭据（环境变量；CLI 进程不读 App 的 UserDefaults 域）：
      QIEMAN_LLM_BASE_URL / QIEMAN_LLM_MODEL / QIEMAN_LLM_API_KEY
      QIEMAN_ALPHAVANTAGE_API_KEY（可选）
      QIEMAN_TAVILY_API_KEY（可选）
    """

    struct RunOutcome {
        let exitCode: Int32
        let stdout: Data
        let stderr: String?
    }

    // MARK: 入口

    static func main(arguments: [String]) -> Int32 {
        // 同步出口的 async 桥（二十轮 P0）：Result 区分「未完成」与
        // 「完成但抛错」——nil 哨兵会把 submit/resume 的存储错误变成
        // 永久自旋挂死，这里只能出现一处桥，错误如实穿透。
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Result<RunOutcome, Error>?
            var result: Result<RunOutcome, Error>? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); defer { lock.unlock() }; stored = newValue }
            }
        }
        let box = ResultBox()
        Task.detached {
            do { box.result = .success(await run(arguments: arguments)) }
            catch { box.result = .failure(error) }
        }
        // nil 严格等于「未完成」——完成必置 success/failure（区别于旧实现的
        // nil 双义哨兵），自旋等待必然终止
        while box.result == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let outcome: RunOutcome
        switch box.result! {
        case .success(let value): outcome = value
        case .failure(let error):
            outcome = RunOutcome(
                exitCode: 1, stdout: Data(),
                stderr: "agent 执行异常：\(String(describing: error))\n"
            )
        }
        FileHandle.standardOutput.write(outcome.stdout)
        if let text = outcome.stderr, !text.isEmpty {
            FileHandle.standardError.write(Data(text.utf8))
        }
        return outcome.exitCode
    }

    /// 可测入口（不碰真实 stdio / 环境；测试注入临时目录与凭据）。
    /// async——命令内部直接 await registry，不再有 nil 哨兵同步桥。
    static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> RunOutcome {
        let parsed: QiemanCommandArguments
        do {
            parsed = try QiemanCommandArguments(arguments)
        } catch {
            return failure(errorText: helpText, exitCode: 64)
        }
        do {
            let command = try await dispatch(parsed, environment: environment, now: now)
            return RunOutcome(
                exitCode: command.exitCode,
                stdout: try Self.encode(command.body),
                stderr: nil
            )
        } catch let error as AgentCLIError {
            return RunOutcome(
                exitCode: 1, stdout: Data(),
                stderr: "\(error.description)\n用 --agent help 查看用法\n"
            )
        } catch {
            return failure(errorText: String(describing: error), exitCode: 1)
        }
    }

    private static func failure(errorText: String, exitCode: Int32) -> RunOutcome {
        RunOutcome(exitCode: exitCode, stdout: Data(), stderr: errorText + "\n")
    }

    /// JSON 输出（sortedKeys 确定性；与 qieman-cli 的机器可读口径一致）。
    private static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: 命令分发

    /// 命令结果（body + 退出码——作业终态 FAILED 时按 unix 惯例非零，
    /// JSON 仍完整输出，脚本可两用）。
    struct CommandOutcome {
        let body: [String: Any]
        let exitCode: Int32

        init(_ body: [String: Any], exitCode: Int32 = 0) {
            self.body = body
            self.exitCode = exitCode
        }
    }

    private static func dispatch(
        _ args: QiemanCommandArguments,
        environment: [String: String],
        now: @escaping @Sendable () -> Date
    ) async throws -> CommandOutcome {
        switch args.command {
        case "help", "--help", "-h":
            return CommandOutcome(["help": helpText])
        case "version":
            return CommandOutcome([
                "agent_version": agentVersion,
                "schema_version": CanonicalDatabase.schemaVersion,
                "workflows": ["marketDataMaintenance", "marketDiscovery", "portfolioReview", "attribution"],
            ])
        case "health":
            let directory = try resolveDataDirectory(args)
            return CommandOutcome(try health(dataDirectory: directory))
        case "data-sync":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return try await submitJob(
                runtime.registry, kind: AgentDataSyncRunner.kindID,
                input: dataSyncInput(args, now: now())
            )
        case "market-research":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return try await submitJob(
                runtime.registry, kind: AgentMarketDiscoveryRunner.kindID,
                input: marketResearchInput(args, now: now())
            )
        case "portfolio-review":
            guard llmConfiguration(environment) != nil else {
                throw AgentCLIError.missingLLMConfig
            }
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return try await submitJob(
                runtime.registry, kind: AgentPortfolioReviewRunner.kindID,
                input: try portfolioReviewInput(runtime, args: args, now: now())
            )
        case "attribution":
            let date = args.string("date")
            if !date.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                guard formatter.date(from: date) != nil else {
                    throw AgentCLIError.invalidOption(
                        "date", detail: "非法日期：\(date)（格式 yyyy-MM-dd）"
                    )
                }
            }
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return try await submitJob(
                runtime.registry, kind: AgentAttributionRunner.kindID,
                input: attributionInput(args, now: now())
            )
        case "identity-inspect":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return CommandOutcome(try identityInspect(
                runtime, code: args.string("code"),
                provider: args.string("provider", default: "eastmoney"),
                scheme: args.string("scheme")
            ))
        case "decision-replay":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            let id = args.string("id")
            guard !id.isEmpty else { throw AgentCLIError.missingOption("id") }
            return CommandOutcome(try decisionReplay(runtime, artifactID: id))
        case "jobs":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            return CommandOutcome(try jobs(runtime, limit: args.int("limit", default: 20)))
        case "resume":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            let id = args.string("id")
            guard !id.isEmpty else { throw AgentCLIError.missingOption("id") }
            return try await resume(
                runtime.registry, jobID: id,
                staleAfter: TimeInterval(args.int("stale-after", default: 0))
            )
        case "recover":
            let runtime = try makeRuntime(args, environment: environment, now: now)
            let recovery = JobRecovery(registry: runtime.registry)
            let outcomes = try await recovery.recover(
                staleAfter: TimeInterval(args.int("stale-after", default: 0))
            )
            var breakdown: [String: Int] = [:]
            for outcome in outcomes {
                breakdown[recoveryOutcomeKind(outcome), default: 0] += 1
            }
            return CommandOutcome([
                "processed": outcomes.count,
                "breakdown": breakdown,
                "outcomes": outcomes.map(recoveryOutcomeBody),
            ])
        default:
            throw AgentCLIError.unknownCommand(args.command)
        }
    }

    /// recovery outcome 的短类名（processed breakdown 用）。
    private static func recoveryOutcomeKind(_ outcome: JobRecovery.Outcome) -> String {
        switch outcome {
        case .continuedQueued: return "continued-queued"
        case .reattempted: return "reattempted"
        case .skippedActive: return "skipped-active"
        case .alreadyTerminal: return "already-terminal"
        case .unknownWorkflow: return "unknown-workflow"
        case .failed: return "failed"
        }
    }

    // MARK: 装配

    struct AgentRuntimeContext {
        let dataDirectory: URL
        let database: CanonicalDatabase
        let repository: GRDBRepository
        let store: AgentJobStore
        let registry: WorkflowRegistry
    }

    /// 数据目录：--data-dir 覆盖 > App 约定路径。CLI 进程不读 App 的
    /// UserDefaults 自定义目录（域不同）——需要时用 --data-dir 显式指定。
    static func resolveDataDirectory(_ args: QiemanCommandArguments) throws -> URL {
        let override = args.string("data-dir")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw AgentCLIError.missingOption("data-dir（无法定位 Application Support）")
        }
        return appSupport.appendingPathComponent("QiemanDashboard", isDirectory: true)
    }

    private static func makeRuntime(
        _ args: QiemanCommandArguments,
        environment: [String: String],
        now: @escaping @Sendable () -> Date
    ) throws -> AgentRuntimeContext {
        let dataDirectory = try resolveDataDirectory(args)
        let database = try CanonicalStorePaths.openDatabase(in: dataDirectory)
        let repository = GRDBRepository(
            database: database, calendarBackend: HolidayTableTradingCalendar.bundled
        )
        let store = AgentJobStore(database: database)
        let runners: [any AgentWorkflowRunner] = [
            AgentDataSyncRunner(
                repository: repository, dataDirectory: dataDirectory,
                environment: environment
            ),
            AgentMarketDiscoveryRunner(repository: repository),
            AgentPortfolioReviewRunner(
                repository: repository, dataDirectory: dataDirectory,
                environment: environment
            ),
            AgentAttributionRunner(repository: repository, dataDirectory: dataDirectory),
        ]
        let registry = WorkflowRegistry(store: store, runners: runners, clock: now)
        return AgentRuntimeContext(
            dataDirectory: dataDirectory, database: database,
            repository: repository, store: store, registry: registry
        )
    }

    // MARK: 命令实现

    private static func health(dataDirectory: URL) throws -> [String: Any] {
        let database = try CanonicalStorePaths.openDatabase(in: dataDirectory)
        var body: [String: Any] = [
            "data_directory": dataDirectory.path,
            "schema_version": CanonicalDatabase.schemaVersion,
        ]
        try database.queue.read { db in
            let artifactCounts = try Dictionary(
                uniqueKeysWithValues:
                    String.fetchAll(db, sql: "SELECT artifact_kind FROM artifacts")
                        .reduce(into: [String: Int]()) { counts, kind in
                            counts[kind, default: 0] += 1
                        }
                        .map { ($0.key, $0.value) }
            )
            body["artifact_counts"] = artifactCounts
            body["signal_count"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM signals") ?? 0
            body["evidence_count"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM evidence") ?? 0
            body["thesis_count"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM theses") ?? 0
            body["non_terminal_jobs"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM agent_jobs WHERE status IN ('QUEUED','RUNNING')") ?? 0
            body["daily_bar_count"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM daily_bars") ?? 0
            body["nav_observation_count"] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM nav_observations") ?? 0
        }
        let portfolioFile = dataDirectory.appendingPathComponent("user-portfolio.json")
        if let holdings = try? UserPortfolioStore().load(from: portfolioFile) {
            body["portfolio_holdings"] = holdings.filter { !$0.isArchived }.count
        }
        return body
    }

    // MARK: 作业输入的幂等口径（二十轮 P1-1）
    //
    // 指纹必须覆盖真实业务输入，否则 completed 后同参数重提永远
    // alreadyCompleted、workflow 变一次性：
    // - data-sync / market-research 以「运行日」为锚——同日重跑幂等命中
    //   （当日数据已同步），次日新数据自然开新 job；
    // - portfolio-review 纳入持仓文件摘要 + 最新 discovery 报告引用
    //   （选择性研究的实际输入）；
    // - attribution 以归因日为锚（默认今天）；
    // - `--force` 附加一次性 nonce：显式声明「这次就是要重跑」。

    private static func anchorDay(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: now)
    }

    private static func withForce(
        _ args: QiemanCommandArguments, input: [String: Any]
    ) -> [String: Any] {
        guard args.bool("force") else { return input }
        var forced = input
        forced["nonce"] = UUID().uuidString
        return forced
    }

    private static func dataSyncInput(
        _ args: QiemanCommandArguments, now: Date
    ) -> [String: Any] {
        withForce(args, input: [
            "rounds": args.int("rounds", default: 3),
            "anchor": anchorDay(now),
        ])
    }

    private static func marketResearchInput(
        _ args: QiemanCommandArguments, now: Date
    ) -> [String: Any] {
        withForce(args, input: [
            "topK": args.int("limit", default: 8),
            "anchor": anchorDay(now),
        ])
    }

    private static func portfolioReviewInput(
        _ runtime: AgentRuntimeContext, args: QiemanCommandArguments, now: Date
    ) throws -> [String: Any] {
        var input: [String: Any] = [
            "anchor": anchorDay(now),
            "holdings": fileDigest(
                runtime.dataDirectory.appendingPathComponent("user-portfolio.json")
            ),
            "discovery": try ArtifactQueryService(repository: runtime.repository)
                .latestMarketDiscoveryReports(limit: 1).first?.id.rawValue ?? "",
        ]
        return withForce(args, input: input)
    }

    private static func attributionInput(
        _ args: QiemanCommandArguments, now: Date
    ) -> [String: Any] {
        // 缺省显式归因日（anchor 日）：同日幂等、跨日新 job；不静默用
        // 「解析失败回落今天」（二十轮 P2-5：非法 --date 在 dispatch 报错）
        let date = args.string("date")
        return withForce(args, input: [
            "date": date.isEmpty ? anchorDay(now) : date,
        ])
    }

    /// 文件内容摘要（不存在 = "none"；SHA256 hex 前 16 位足够做指纹成分）。
    private static func fileDigest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "none" }
        return SHA256.hash(data: data).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func submitJob(
        _ registry: WorkflowRegistry, kind: String, input: [String: Any]
    ) async throws -> CommandOutcome {
        let inputJSON: String
        if let data = try? JSONSerialization.data(
            withJSONObject: input.isEmpty ? [:] : input, options: [.sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            inputJSON = text
        } else {
            inputJSON = "{}"
        }
        // 二十轮 P0：直接 await——存储错误 / requiredInput 拒收 / attemptExhausted
        // 如实上抛（原先 try? + nil 哨兵会把它们变成永久自旋挂死）
        let outcome = try await registry.submit(kind: kind, inputJSON: inputJSON)
        switch outcome {
        case .ran(let job, let result):
            var body = jobBody(job)
            body["executed"] = true
            if let result {
                body["summary"] = result.summary
                body["artifact_ids"] = result.artifactIDs
            }
            if job.state == .failed {
                body["error"] = job.events.last?.detail ?? "unknown"
                return CommandOutcome(body, exitCode: 1)
            }
            return CommandOutcome(body)
        case .alreadyCompleted(let job):
            var body = jobBody(job)
            body["executed"] = false
            body["note"] = "同输入已 completed（幂等命中，不重跑）"
            return CommandOutcome(body)
        case .inProgress(let job):
            var body = jobBody(job)
            body["executed"] = false
            body["note"] = "同输入正在排队 / 执行中"
            return CommandOutcome(body)
        case .unknownWorkflow(let kind):
            throw AgentCLIError.unknownCommand("workflow \(kind) 未注册")
        }
    }

    private static func identityInspect(
        _ runtime: AgentRuntimeContext, code: String, provider: String, scheme: String
    ) throws -> [String: Any] {
        guard !code.isEmpty else { throw AgentCLIError.missingOption("code") }
        // 双 scheme 依次尝试（二十轮 P2-4）：A 股股票代码（600519 等）与
        // 基金代码同为全数字，形态启发无法可靠区分——缺省时先 fund_code
        // 再 stock_symbol，命中即报；显式 --scheme 只查声明的 scheme。
        let schemes = scheme.isEmpty ? ["fund_code", "stock_symbol"] : [scheme]
        let resolver = IdentityResolver(
            identifiers: runtime.repository.allProviderIdentifiers()
        )
        let providerID = DataProviderID(rawValue: provider)
        for candidateScheme in schemes {
            switch resolver.resolve(
                providerID: providerID, scheme: candidateScheme, value: code
            ) {
            case .resolved(let canonical, let via):
                return [
                    "resolved": true,
                    "canonical_type": canonical.entityType,
                    "canonical_id": canonical.entityIDRawValue,
                    "via": via.rawValue,
                    "provider": provider, "scheme": candidateScheme, "code": code,
                ]
            case .candidates(let candidates):
                return [
                    "resolved": false,
                    "reason": "fuzzy candidate（未验证，不可用于数据解析）",
                    "scheme": candidateScheme,
                    "candidates": candidates.map {
                        ["canonical_id": $0.candidate.entityIDRawValue, "confidence": $0.confidence]
                    },
                ]
            case .unresolved:
                continue
            }
        }
        return [
            "resolved": false,
            "reason": "未登记（运行 data-sync 建立 universe identity，或人工 verified 映射）",
            "provider": provider, "schemes": schemes, "code": code,
        ]
    }

    private static func decisionReplay(
        _ runtime: AgentRuntimeContext, artifactID: String
    ) throws -> [String: Any] {
        guard let artifact = try runtime.repository.portfolioDecision(id: artifactID) else {
            return ["replayed": false, "reason": "artifact 不存在：\(artifactID)"]
        }
        do {
            let outcome = try DecisionReplayer().verify(
                artifact: artifact,
                resolver: AgentReplayResolver(repository: runtime.repository)
            )
            return [
                "replayed": true,
                "artifact_id": artifact.id.rawValue,
                "decision_status": outcome.decision.status.rawValue,
                "plan_count": outcome.plans.count,
                "signal_ids": artifact.signalIDs.map(\.rawValue),
                "produced_at": Self.iso(artifact.producedAt),
            ]
        } catch {
            return [
                "replayed": false,
                "artifact_id": artifact.id.rawValue,
                "reason": String(describing: error),
            ]
        }
    }

    private static func jobs(_ runtime: AgentRuntimeContext, limit: Int) throws -> [String: Any] {
        let summaries = try runtime.store.summaries(limit: max(limit, 1))
        return [
            "jobs": summaries.map { summary in
                [
                    "id": summary.id,
                    "workflow": summary.workflow,
                    "status": summary.status.rawValue,
                    "attempt": summary.attempt,
                    "created_at": Self.iso(summary.createdAt),
                    "started_at": summary.startedAt.map(Self.iso) as Any?,
                    "completed_at": summary.completedAt.map(Self.iso) as Any?,
                    "error": summary.errorMessage as Any?,
                    "last_activity_at": Self.iso(summary.lastActivityAt),
                ] as [String: Any]
            },
            "count": summaries.count,
        ]
    }

    private static func resume(
        _ registry: WorkflowRegistry, jobID: String, staleAfter: TimeInterval
    ) async throws -> CommandOutcome {
        // 二十轮 P0：直接 await（同 submitJob——错误穿透不挂死）
        let outcome = try await registry.resume(jobID: jobID, staleAfter: staleAfter)
        switch outcome {
        case .ran(let job, let result):
            var body = jobBody(job)
            body["mode"] = "queued-continued"
            if let result { body["summary"] = result.summary }
            if job.state == .failed { return CommandOutcome(body, exitCode: 1) }
            return CommandOutcome(body)
        case .reattempted(let abandoned, let job, let result):
            var body = jobBody(job)
            body["mode"] = "reattempted"
            body["abandoned_job_id"] = abandoned.id
            if let result { body["summary"] = result.summary }
            if job.state == .failed { return CommandOutcome(body, exitCode: 1) }
            return CommandOutcome(body)
        case .alreadyTerminal(let job):
            var body = jobBody(job)
            body["mode"] = "already-terminal"
            return CommandOutcome(body)
        case .stillActive(let job, let lastActivity):
            var body = jobBody(job)
            body["mode"] = "still-active"
            body["last_activity_at"] = Self.iso(lastActivity)
            return CommandOutcome(body)
        case .notFound:
            return CommandOutcome(["mode": "not-found", "job_id": jobID])
        case .unknownWorkflow(let kind):
            return CommandOutcome(["mode": "unknown-workflow", "workflow": kind])
        }
    }

    // MARK: 输出工具

    private static func jobBody(_ job: AgentJob) -> [String: Any] {
        [
            "job_id": job.id,
            "workflow": job.workflowKind,
            "status": AgentJobRow.statusColumn(for: job.state),
            "attempt": AgentJobStore.attemptNumber(of: job.inputFingerprint),
        ]
    }

    private static func recoveryOutcomeBody(_ outcome: JobRecovery.Outcome) -> [String: Any] {
        switch outcome {
        case .continuedQueued(let id):
            return ["job_id": id, "outcome": "continued-queued"]
        case .reattempted(let abandoned, let newJob):
            return ["job_id": abandoned, "outcome": "reattempted", "new_job_id": newJob]
        case .skippedActive(let id):
            return ["job_id": id, "outcome": "skipped-active"]
        case .alreadyTerminal(let id):
            return ["job_id": id, "outcome": "already-terminal"]
        case .unknownWorkflow(let id, let kind):
            return ["job_id": id, "outcome": "unknown-workflow", "workflow": kind]
        case .failed(let id, let detail):
            return ["job_id": id, "outcome": "failed", "detail": detail]
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: 凭据

    static func llmConfiguration(_ environment: [String: String]) -> LLMProviderConfiguration? {
        let baseURL = (environment["QIEMAN_LLM_BASE_URL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (environment["QIEMAN_LLM_MODEL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (environment["QIEMAN_LLM_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else { return nil }
        return LLMProviderConfiguration(
            providerID: "agent-cli", baseURL: baseURL, model: model, apiKey: apiKey
        )
    }
}

// MARK: - Runners（V2 workflow / 引擎 → AgentWorkflowRunner 适配）

/// data-sync：一轮市场数据维护（复用十八轮生产引擎；分轮落检查点）。
struct AgentDataSyncRunner: AgentWorkflowRunner {
    static let kindID = "marketDataMaintenance"
    let kind = Self.kindID

    let repository: GRDBRepository
    let dataDirectory: URL
    let environment: [String: String]

    func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult {
        struct Input: Codable { let rounds: Int? }
        let input = try? JSONDecoder().decode(Input.self, from: Data(inputJSON.utf8))
        let rounds = max(input?.rounds ?? 3, 1)

        // 检查点消费（二十轮 P1-2）：崩溃行已完成的轮次直接跳过——
        // 每轮是一个完整维护批次（state 文件推进 + 幂等提交），轮是
        // 本 runner 唯一有意义的续跑单位；同轮数配置才算数（配置变了
        // 从头跑）。其余三个 runner 是单相任务（产物幂等落库，重跑即
        // 恢复），无中间阶段可跳——检查点通道面向这种多阶段形态。
        struct RoundCheckpoint: Codable { let round: Int; let rounds: Int }
        let doneRounds = context.resumeCheckpoints.compactMap { checkpoint -> Int? in
            guard let payload = try? JSONDecoder().decode(
                RoundCheckpoint.self, from: Data(checkpoint.stateJSON.utf8)
            ), payload.rounds == rounds else { return nil }
            return payload.round
        }.max() ?? 0
        if doneRounds >= rounds {
            return AgentRunResult(
                summary: "检查点显示 \(doneRounds)/\(rounds) 轮已完成（前次 attempt 崩溃于收尾前）——无剩余批次"
            )
        }

        // 真实时钟（二十轮 P1-3）：限流冷却判定与 quota 周期滚动都依赖
        // now() 前进——固定 context.now 会让冷却永不解除、quota 永不重置
        let monitor = ProviderHealthMonitor()
        let alphaVantage = Self.alphaVantageSettings(environment)
        await MarketDataMaintenanceEngine.registerProductionProviders(
            healthMonitor: monitor, alphaVantage: alphaVantage
        )
        let engine = MarketDataMaintenanceEngine(
            repository: repository,
            dataDirectory: dataDirectory,
            chainFactory: MarketDataMaintenanceEngine.productionChainFactory(
                healthMonitor: monitor, alphaVantage: alphaVantage
            )
        )
        var summary = ""
        for round in (doneRounds + 1)...rounds {
            summary = try await engine.runMaintenance(backfillRounds: 1)
            try context.saveCheckpoint(
                "round-\(round)",
                "{\"round\":\(round),\"rounds\":\(rounds)}"
            )
        }
        return AgentRunResult(summary: summary.isEmpty
            ? "从检查点第 \(doneRounds) 轮续跑完成" : summary)
    }

    private static func alphaVantageSettings(
        _ environment: [String: String]
    ) -> AlphaVantageSettings? {
        let key = (environment["QIEMAN_ALPHAVANTAGE_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return AlphaVantageSettings(
            enabled: true, apiKey: key,
            dailyRequestLimit: AlphaVantageSettings.freeDailyRequestLimit
        )
    }
}

/// market-research：市场发现（纯本地因子；数据先行供给属 data-sync）。
struct AgentMarketDiscoveryRunner: AgentWorkflowRunner {
    static let kindID = "marketDiscovery"
    let kind = Self.kindID

    let repository: GRDBRepository

    func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult {
        struct Input: Codable { let topK: Int? }
        let input = try? JSONDecoder().decode(Input.self, from: Data(inputJSON.utf8))
        let topK = max(input?.topK ?? 8, 0)

        // identity 建立兜底（幂等；缺失时 factor 读取仍可用既有映射）
        try MarketDataMaintenanceEngine.establishUniverseIdentity(repository: repository)

        let buffer = FactorSnapshotBuffer()
        let workflow = MarketDiscoveryWorkflow(
            repository: repository,
            snapshotSink: { snapshot in buffer.append(snapshot) }
        )
        let outcome = workflow.run(asOf: context.now, now: context.now)
        let snapshots = buffer.drain()
        if !snapshots.isEmpty {
            try await repository.database.queue.write { db in
                for snapshot in snapshots {
                    try ArtifactRow.write(try ArtifactRow.from(snapshot), into: db)
                }
            }
        }
        guard let report = outcome.report else {
            throw AgentCLIError.workflowFailed(outcome.errorDetail ?? "unknown")
        }
        try repository.writeMarketDiscoveryReport(report)
        let tasks = report.researchTasks(limit: topK)
        return AgentRunResult(
            summary: "候选 \(report.candidates.count) 个，覆盖缺口 \(report.coverageGaps.count) 个，研究任务 top-\(topK) 共 \(tasks.count) 条",
            artifactIDs: [report.id.rawValue]
        )
    }
}

/// portfolio-review：WF-1 全链（需 LLM 配置；选择性研究接 market-research 产出）。
struct AgentPortfolioReviewRunner: AgentWorkflowRunner {
    static let kindID = "portfolioReview"
    let kind = Self.kindID

    let repository: GRDBRepository
    let dataDirectory: URL
    let environment: [String: String]

    func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult {
        guard let configuration = InvestmentAgentCLI.llmConfiguration(environment) else {
            throw AgentCLIError.missingLLMConfig
        }
        let holdings = try UserPortfolioStore().load(
            from: dataDirectory.appendingPathComponent("user-portfolio.json")
        )
        let provider = OpenAICompatibleModelProvider(configuration: configuration)
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 1
        let harness = ResearchHarness(
            gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
            tools: ResearchToolRegistry().tools,
            sources: ResearchSourcesConfiguration(
                tavilyAPIKey: environment["QIEMAN_TAVILY_API_KEY"] ?? "",
                alphaVantageEnabled: true,
                alphaVantageAPIKey: environment["QIEMAN_ALPHAVANTAGE_API_KEY"] ?? ""
            ),
            dataAccess: RepositoryResearchDataAccess(nav: repository, market: repository)
        )
        let subject = CanonicalRef.fundShareClass(
            FundShareClassID(rawValue: "portfolio_live")
        )
        // 选择性研究（十八轮 P2-4 同款）：最新 discovery 报告的 top-4 任务
        let discoveryTasks = try ArtifactQueryService(repository: repository)
            .latestMarketDiscoveryReports(limit: 1).first?
            .researchTasks(limit: 4) ?? []
        let workflow = PortfolioResearchWorkflow(
            dependencies: PortfolioResearchWorkflow.Dependencies(
                harness: harness,
                signalStore: repository,
                thesisStore: repository,
                evidenceStore: repository,
                decisionMaterials: CLIPortfolioMaterials(
                    holdings: holdings, now: context.now
                ),
                artifactSink: { artifact in
                    try repository.writeArtifact(artifact)
                }
            )
        )
        let input = PortfolioResearchWorkflow.Input(
            portfolioSubject: subject,
            assetTasks: discoveryTasks,
            portfolioTask: ResearchTask(
                subject: subject,
                objective: "评估组合当前配置的动量、估值与主要风险"
            )
        )
        let outcome = try await workflow.run(input: input)
        guard outcome.succeeded, let artifact = outcome.artifact else {
            throw AgentCLIError.workflowFailed(outcome.errorDetail ?? "unknown")
        }
        return AgentRunResult(
            summary: "signals \(outcome.signals.count) · theses \(outcome.theses.count) · decision \(artifact.decision.status.rawValue)",
            artifactIDs: [artifact.id.rawValue]
        )
    }
}

/// attribution：单日组合归因（本地库 NAV / 行情收益率；成本口径权重）。
struct AgentAttributionRunner: AgentWorkflowRunner {
    static let kindID = "attribution"
    let kind = Self.kindID

    let repository: GRDBRepository
    let dataDirectory: URL

    func run(inputJSON: String, context: AgentRunContext) async throws -> AgentRunResult {
        struct Input: Codable { let date: String? }
        let input = try? JSONDecoder().decode(Input.self, from: Data(inputJSON.utf8))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        // 日期 fail-closed（二十轮 P2-5）：dispatch 已拦非法 --date，这里
        // 对直接调用 runner 的路径同样拒绝——不静默回落今天
        let date: Date
        if let raw = input?.date {
            guard let parsed = formatter.date(from: raw) else {
                throw AgentCLIError.invalidOption(
                    "date", detail: "非法日期：\(raw)（格式 yyyy-MM-dd）"
                )
            }
            date = parsed
        } else {
            date = context.now
        }

        let holdings = try UserPortfolioStore().load(
            from: dataDirectory.appendingPathComponent("user-portfolio.json")
        )
        .filter { !$0.isArchived && $0.units > 0 && ($0.costPrice ?? 0) > 0 }

        // 成本口径金额（units × costPrice）——与 App 的估值口径（实时市值）
        // 有差异：无网络依赖、确定性；coverage 由收益率已知比例如实呈现
        let amounts = holdings.compactMap { holding -> (UserPortfolioHolding, Decimal)? in
            guard let cost = holding.costPrice else { return nil }
            let amount = Decimal(
                string: String(format: "%.4f", holding.units * cost)
            ) ?? Decimal.zero
            guard amount > 0 else { return nil }
            return (holding, amount)
        }
        let total = amounts.map(\.1).reduce(Decimal.zero, +)
        guard total > 0 else {
            throw AgentCLIError.workflowFailed("组合无可用持仓（user-portfolio.json 为空或全无成本价）")
        }

        let resolver = IdentityResolver(identifiers: repository.allProviderIdentifiers())
        let knowledgeEnd = date.addingTimeInterval(48 * 3600)   // T+1 公布语义的保守可见上界
        var positions: [AttributionPositionInput] = []
        var unresolvedReturns: [String] = []
        for (holding, amount) in amounts {
            let weight = Ratio(value: amount / total)
            switch holding.assetType {
            case .stock:
                // 股票：identity 解析到 Listing 才有本地行情；未解析进缺口
                if case .resolved(let canonical, _) = resolver.resolve(
                    providerID: .eastmoney, scheme: "stock_symbol", value: holding.fundCode
                ), case .listing(let listingID) = canonical {
                    let bars = repository.dailyBars(
                        listingID: listingID,
                        context: .economicKnowledge(asOf: knowledgeEnd)
                    ).sorted { $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt }
                    if let index = bars.lastIndex(where: {
                        $0.temporalEnvelope.effectiveAt <= knowledgeEnd
                    }), index >= 1 {
                        let prev = bars[index - 1].rawClose.value
                        let curr = bars[index].rawClose.value
                        guard prev != 0 else {
                            unresolvedReturns.append(holding.fundCode)
                            break
                        }
                        positions.append(AttributionPositionInput(
                            subject: .listing(listingID),
                            weight: weight,
                            periodReturn: Ratio(value: curr / prev - 1),
                            sourceObservationID: bars[index].id
                        ))
                        continue
                    }
                }
                unresolvedReturns.append(holding.fundCode)
            default:
                // 基金：份额类 NAV（fund_code ≙ share class 代码的 seed 约定）
                let navs = repository.navObservations(
                    shareClassID: FundShareClassID(rawValue: holding.fundCode),
                    context: .economicKnowledge(asOf: knowledgeEnd)
                ).sorted { $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt }
                if let index = navs.lastIndex(where: {
                    $0.temporalEnvelope.effectiveAt <= knowledgeEnd
                }), index >= 1 {
                    let prev = navs[index - 1].unitNAV.value
                    let curr = navs[index].unitNAV.value
                    if prev != 0 {
                        positions.append(AttributionPositionInput(
                            subject: .fund(FundProductID(rawValue: holding.fundCode)),
                            weight: weight,
                            periodReturn: Ratio(value: curr / prev - 1),
                            sourceObservationID: navs[index].id
                        ))
                        continue
                    }
                }
                unresolvedReturns.append(holding.fundCode)
            }
        }
        // 收益率未知的持仓仍进引擎（weight 已知、return nil → coverage 缺口，
        // 不猜）。兜底 subject 按资产类型取 kind（二十轮 P2-5）：股票走
        // universe 目录同款 lst_<code> 约定（listing 维度），基金用 fund 维度
        func fallbackSubject(_ holding: UserPortfolioHolding) -> AttributionSubject {
            holding.assetType == .stock
                ? .listing(ListingID(rawValue: "lst_\(holding.fundCode)"))
                : .fund(FundProductID(rawValue: holding.fundCode))
        }
        let knownCodes = Set(positions.map { $0.subject.stableKey })
        for (holding, amount) in amounts
        where !knownCodes.contains(fallbackSubject(holding).stableKey) {
            let weight = Ratio(value: amount / total)
            positions.append(AttributionPositionInput(
                subject: fallbackSubject(holding),
                weight: weight, periodReturn: nil, sourceObservationID: nil
            ))
        }

        let provider = StaticAttributionProvider(positions: positions)
        let outcome = DailyAttributionWorkflow(provider: provider)
            .run(portfolioKey: "agent:userPortfolio", on: date, now: context.now)
        guard let artifact = outcome.artifact else {
            throw AgentCLIError.workflowFailed(outcome.errorDetail ?? "unknown")
        }
        try await repository.database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(artifact), into: db)
        }
        return AgentRunResult(
            summary: String(
                format: "归因日 %@ · coverage %.1f%% · 收益率未知 %@",
                formatter.string(from: date),
                NSDecimalNumber(decimal: artifact.result.coverage.value).doubleValue * 100,
                unresolvedReturns.isEmpty ? "0 只" : "\(unresolvedReturns.count) 只（\(unresolvedReturns.joined(separator: ","))）"
            ),
            artifactIDs: [artifact.id.rawValue]
        )
    }
}

/// 静态位置供给（CLI 已在 runner 内解析完持仓与收益率）。
private struct StaticAttributionProvider: DailyAttributionInputProvider {
    let positions: [AttributionPositionInput]

    func positions(portfolioKey: String, on date: Date) throws -> [AttributionPositionInput] {
        self.positions
    }

    func portfolioReturn(portfolioKey: String, on date: Date) throws -> Ratio? {
        nil   // CLI 无实时估值面：residual 留空，coverage 如实呈现
    }
}

// MARK: - CLI 决策材料（user-portfolio.json → V2 决策输入）

/// CLI 侧决策材料供给：与 App 的 LivePortfolioDecisionMaterials 同一套
/// 常量（costIntensity v1 + live-band v1 + 单 plannerRun「维持当前配置」
/// 对照 target），差异只在权重口径——CLI 用成本金额（units × costPrice），
/// App 用估值市值。同常量使 decision-replay 对两条链路产出的 artifact
/// 都能解析 criterion / band 绑定。
struct CLIPortfolioMaterials: PortfolioDecisionMaterialsProviding {
    let holdings: [UserPortfolioHolding]
    let now: Date

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let positions = Self.positions(from: holdings)
        guard !positions.isEmpty else {
            throw AgentCLIError.workflowFailed("组合无可用持仓（user-portfolio.json 为空）")
        }
        let portfolio = PortfolioSnapshot(asOf: asOf, positions: positions)

        // 「维持当前配置」对照 target（与 Live 同语义：类聚合归一 + 残差归最大类）
        var classTotals: [AssetClass: Decimal] = [:]
        for position in positions {
            classTotals[position.assetClass, default: 0] += position.weight.value
        }
        guard let largestClass = classTotals.max(by: {
            $0.value == $1.value
                ? $0.key.rawValue < $1.key.rawValue
                : $0.value < $1.value
        })?.key else {
            throw AgentCLIError.workflowFailed("组合无可用持仓")
        }
        let othersSum = classTotals
            .filter { $0.key != largestClass }
            .values.reduce(Decimal.zero, +)
        classTotals[largestClass] = Decimal(1) - othersSum
        let entries = classTotals
            .map { AllocationTargetEntry(assetClass: $0.key, targetWeight: Ratio(value: $0.value)) }
            .sorted { $0.assetClass.rawValue < $1.assetClass.rawValue }
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: entries, note: "维持当前配置（对照检查漂移，CLI 成本口径）", now: asOf
        )

        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio, higherIsBetter: false
        )
        let bounds = Dictionary(
            uniqueKeysWithValues: positions.map {
                ($0.subjectKey, ActionDomain.SubjectBounds(
                    lower: Ratio(value: Decimal(string: "-1")!),
                    upper: Ratio(value: Decimal(string: "1")!)))
            }
        )
        let actionDomain = ActionDomain(
            perSubjectBounds: bounds,
            eligibleNewSubjects: [:],
            builderVersion: "live-v1",
            newSubjectBuyUpper: Ratio(value: Decimal(string: "1")!)
        )
        let plannerRun = DecisionReplayer.PlannerRun(
            portfolio: portfolio, target: target, remediationTargets: [],
            userDirectives: [], actionDomain: actionDomain,
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
        return PortfolioDecisionMaterials(
            replayerMaterials: DecisionReplayer.ReplayMaterials(
                criterionDefinitions: [definition.fingerprint: definition],
                factorSnapshots: [:], observations: [:],
                band: IndifferenceBand(
                    policyID: "live-band", version: "v1",
                    defaultBand: Decimal(string: "0.01")!,
                    rationale: "生产默认带——turnover 差 1% 内视为无差异"
                )
            ),
            plannerRuns: ["current": plannerRun],
            target: target,
            knowledgeContextSummary: "economicKnowledge(自 \(now))· agent CLI 成本口径"
        )
    }

    /// 成本口径权重（归一化 + 残差归最大仓——与 Live 同纪律）。
    private static func positions(from holdings: [UserPortfolioHolding]) -> [PortfolioPosition] {
        let amounts = holdings.compactMap {
            holding -> (code: String, amount: Decimal, assetClass: AssetClass)? in
            guard !holding.isArchived, holding.units > 0, let cost = holding.costPrice
            else { return nil }
            let amount = Decimal(string: String(format: "%.4f", holding.units * cost)) ?? .zero
            guard amount > 0 else { return nil }
            return (
                holding.fundCode, amount,
                holding.assetType == .stock ? .equity : .alternative
            )
        }
        let total = amounts.map(\.amount).reduce(Decimal.zero, +)
        guard total > 0 else { return [] }
        var normalized = amounts.map {
            (code: $0.code, assetClass: $0.assetClass, weight: $0.amount / total)
        }
        let largestIndex = normalized.indices.max(by: {
            normalized[$0].weight == normalized[$1].weight
                ? normalized[$0].code < normalized[$1].code
                : normalized[$0].weight < normalized[$1].weight
        })
        if let largestIndex {
            let othersSum = normalized.enumerated()
                .filter { $0.offset != largestIndex }
                .reduce(Decimal.zero) { $0 + $1.element.weight }
            normalized[largestIndex].weight = Decimal(1) - othersSum
        }
        return normalized.map {
            PortfolioPosition(
                subjectKey: "fund|\($0.code)",
                assetClass: $0.assetClass,
                weight: Ratio(value: $0.weight)
            )
        }
    }
}

// MARK: - 决策重放 resolver（CLI）

/// decision-replay 的材料解析：criterion 定义 / band 用与生产材料同一套
/// 常量重建（artifact 只存版本与内容摘要，定义实例不落库）；factor 实例
/// 按 artifact 引用逐个 typed fetch。observation 引用当前生产材料不产生
/// （Live/CLI 均为空域）——非空引用的 artifact 会诚实报不可解析。
struct AgentReplayResolver: DecisionReplayer.InputResolving {
    let repository: GRDBRepository

    func resolveMaterials(for artifact: PortfolioDecisionArtifact) throws -> DecisionReplayer.ReplayMaterials {
        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio, higherIsBetter: false
        )
        let band = IndifferenceBand(
            policyID: "live-band", version: "v1",
            defaultBand: Decimal(string: "0.01")!,
            rationale: "生产默认带——turnover 差 1% 内视为无差异"
        )
        var snapshots: [String: FactorSnapshot] = [:]
        try repository.database.queue.read { db in
            for id in artifact.factorSnapshotIDs {
                snapshots[id.rawValue] = try ArtifactRow.fetchFactorSnapshot(
                    id: id.rawValue, from: db
                )
            }
        }
        return DecisionReplayer.ReplayMaterials(
            criterionDefinitions: [definition.fingerprint: definition],
            factorSnapshots: snapshots,
            observations: [:],
            band: band
        )
    }
}
