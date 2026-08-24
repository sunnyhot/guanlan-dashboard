import Foundation

// MARK: - AgentJob / AgentEvent（ATTR-4，Epic 9）
//
// Agent 作业的基础形态：状态机 + 事件时间线。Epic 13（AGENT-1）在此之上
// 扩展 WorkflowRegistry / JobRecovery（checkpoint + idempotency key）；
// ATTR-4 只需要「job 可观察、状态迁移合法、事件留痕」。

/// 作业状态（ATTR-4 验收：queued / running / completed / failed / cancelled）。
enum AgentJobState: String, Sendable, Codable, Hashable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

/// 作业事件（时间线留痕，状态迁移的佐证）。
struct AgentEvent: Sendable, Codable, Hashable {
    let timestamp: Date
    let kind: Kind
    let detail: String?

    enum Kind: String, Sendable, Codable, Hashable {
        case queued = "QUEUED"
        case started = "STARTED"
        case completed = "COMPLETED"
        case failed = "FAILED"
        case cancelled = "CANCELLED"
    }
}

/// 非法状态迁移（状态机守护）。
enum AgentJobStateError: Error, Equatable, Sendable {
    case illegalTransition(from: AgentJobState, to: AgentJobState)
}

/// Agent 作业（轻量基础形态；id 由 workflowKind + 输入指纹确定性派生，
/// 同输入重跑 = 同 job，幂等）。
struct AgentJob: Sendable, Codable, Hashable {
    let id: String
    /// workflow 种类（如 "dailyAttribution"）
    let workflowKind: String
    let createdAt: Date
    /// 输入指纹（幂等键；同指纹 = 同 job）
    let inputFingerprint: String
    private(set) var state: AgentJobState
    private(set) var events: [AgentEvent]

    init(workflowKind: String, inputFingerprint: String, createdAt: Date) {
        let canonical = "\(workflowKind)|\(inputFingerprint)"
        self.id = "job_\(AgentJob.digest(canonical))"
        self.workflowKind = workflowKind
        self.createdAt = createdAt
        self.inputFingerprint = inputFingerprint
        self.state = .queued
        self.events = [AgentEvent(timestamp: createdAt, kind: .queued, detail: nil)]
    }

    /// 合法迁移：queued→running/cancelled；running→completed/failed/cancelled；
    /// 终态不可再迁（重放 / 重复回调的守护）。
    mutating func transition(to next: AgentJobState, at timestamp: Date, detail: String? = nil) throws {
        let legal: Bool
        switch (state, next) {
        case (.queued, .running), (.queued, .cancelled),
             (.running, .completed), (.running, .failed), (.running, .cancelled):
            legal = true
        default:
            legal = false
        }
        guard legal else {
            throw AgentJobStateError.illegalTransition(from: state, to: next)
        }
        state = next
        let eventKind: AgentEvent.Kind
        switch next {
        case .queued: eventKind = .queued
        case .running: eventKind = .started
        case .completed: eventKind = .completed
        case .failed: eventKind = .failed
        case .cancelled: eventKind = .cancelled
        }
        events.append(AgentEvent(timestamp: timestamp, kind: eventKind, detail: detail))
    }

    /// 双 FNV-1a 确定性摘要（与同模块其他 id 派生同算法）。
    static func digest(_ input: String) -> String {
        let data = Data(input.utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in data {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0xbf58476d1ce4e5b9
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}

// MARK: - DailyAttributionWorkflow（ATTR-4）

/// 归因输入供给（App 集成时由真实现读取 NAV / 行情；测试 mock）。
/// 抛错 = 组合数据本身不可得（区别于「成分收益率未知」——后者返回 nil
/// 进 coverage 缺口，不是失败）。
protocol DailyAttributionInputProvider: Sendable {
    func positions(portfolioKey: String, on date: Date) throws -> [AttributionPositionInput]
    func portfolioReturn(portfolioKey: String, on date: Date) throws -> Ratio?
}

/// 单日归因 workflow：取数 → 归因引擎 → artifact + 渲染。
///
/// 同步执行（归因是纯计算，无 IO 等待语义）；取消点只有 queued 阶段——
/// 调用方在 run 前把 job 置为 cancelled，run 直接返回不执行。
struct DailyAttributionWorkflow: Sendable {
    static let workflowKind = "dailyAttribution"

    let provider: any DailyAttributionInputProvider
    let renderer: AttributionRenderer

    init(provider: any DailyAttributionInputProvider, renderer: AttributionRenderer = AttributionRenderer()) {
        self.provider = provider
        self.renderer = renderer
    }

    struct RunOutcome: Sendable, Codable, Hashable {
        let job: AgentJob
        let artifact: DailyAttribution?
        let rendered: RenderedAttribution?
        /// failed 时的错误摘要
        let errorDetail: String?

        var succeeded: Bool { job.state == .completed }
    }

    /// 执行归因 job。
    func run(portfolioKey: String, on date: Date, now: Date) -> RunOutcome {
        let fingerprint = "\(portfolioKey)|\(Int(date.timeIntervalSince1970))"
        var job = AgentJob(workflowKind: Self.workflowKind, inputFingerprint: fingerprint, createdAt: now)

        // queued 阶段的取消点(同步执行无中途取消)
        if job.state == .cancelled {
            return RunOutcome(job: job, artifact: nil, rendered: nil, errorDetail: nil)
        }

        do {
            try job.transition(to: .running, at: now, detail: nil)
            let positions = try provider.positions(portfolioKey: portfolioKey, on: date)
            let portfolioReturn = try provider.portfolioReturn(portfolioKey: portfolioKey, on: date)
            guard let result = AttributionEngine().compute(
                positions: positions, portfolioReturn: portfolioReturn
            ) else {
                throw WorkflowError.emptyPortfolio
            }
            let artifact = DailyAttribution(
                attributionDate: date, portfolioKey: portfolioKey,
                result: result, producedAt: now
            )
            let rendered = renderer.render(artifact)
            try job.transition(to: .completed, at: now, detail: artifact.id.rawValue)
            return RunOutcome(job: job, artifact: artifact, rendered: rendered, errorDetail: nil)
        } catch {
            let detail = String(describing: error)
            if job.state == .running {
                try? job.transition(to: .failed, at: now, detail: detail)
            }
            return RunOutcome(job: job, artifact: nil, rendered: nil, errorDetail: detail)
        }
    }

    enum WorkflowError: Error, Equatable, Sendable {
        /// 组合持仓为空 / 全零(引擎无法归因)
        case emptyPortfolio
    }
}
