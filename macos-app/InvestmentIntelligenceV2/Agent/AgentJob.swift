import Foundation

// MARK: - AgentJob / AgentEvent（ATTR-4 建立，AGENT-1 迁入 Agent/ 并扩展）
//
// Agent 作业的基础形态：状态机 + 事件时间线。ATTR-4 只需要「job 可观察、
// 状态迁移合法、事件留痕」；AGENT-1 在此之上补持久化读面（AgentJobStore）、
// 调度（WorkflowRegistry）与恢复（JobRecovery）。
//
// 身份纪律：id 由 workflowKind + inputFingerprint 确定性派生，同输入重跑 =
// 同 job，幂等。重试语义由 fingerprint 的 attempt 后缀表达（见
// AgentJobStore.fingerprint(base:attempt:)）——每次尝试是一行独立的完整
// 时间线（审计友好），逻辑上是同一输入的延续。

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

/// Agent Job 生命周期状态（持久化列形态；rawValue = agent_jobs.status 列）。
/// ATTR-4 起定义于 schema 文件，AGENT-1 落地 Agent/ 目录时迁入此处
/// （同模块移动，消费方零改动）。
enum AgentJobStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
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
