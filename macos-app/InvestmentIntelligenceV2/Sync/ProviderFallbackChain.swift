import Foundation

// MARK: - ProviderFallbackChain（SYNC-7：Provider 失败降级路径）
//
// ADR-DATA006 §Decision 3 的三档降级在**抓取面**的落地：
// 1. **primary**：首选 Provider（如美股日线 Stooq）；
// 2. **secondary**：primary 失败/限流/额度尽时依次尝试的候选
//    （如 Alpha Vantage supplemental——quota 感知，额度尽自动跳过）；
// 3. **local 兜底**：全部候选失败 → 返回 .allFailed（**不抛错、不阻塞**），
//    读取面继续由本地 Canonical Store 服务——sync 失败只是「本轮没有新数据」，
//    已入库数据、查询、下游 Workflow 全不受影响（ADR-DATA004：库是本地
//    积累的派生物，不依赖任何单次抓取成功）。
//
// 与 ProviderHealthMonitor（PROV-8）的分工：monitor 负责**状态**（谁健康、
// 谁在冷却、额度还剩多少——isCallable 是链的前置闸门，unavailable 的候选
// 直接跳过、零网络）；本链负责**一次抓取的编排**（按序尝试、失败换下家、
// 成功上报）。quotaExhausted / rateLimited 的冷却与恢复语义都在 monitor
// （recordFailure 按 ProviderError 归类），链只消费它的判定。
//
// FREE001：secondary 必须仍是免费源；付费源不得进入候选（编译期由
// ProviderAdapter 集合审查保证——现有 Adapter 全部免费）。

// MARK: - 候选与结果

/// 降级链候选（有序）。
struct ProviderFallbackCandidate: Sendable {
    enum Role: String, Sendable, Equatable {
        case primary
        case secondary
    }

    let adapter: any ProviderAdapter
    let role: Role

    init(_ adapter: any ProviderAdapter, role: Role) {
        self.adapter = adapter
        self.role = role
    }
}

/// 一次经降级链的抓取结局。
enum ProviderFallbackOutcome: Sendable {
    /// 成功（可能在降级后的候选上）：records + 用的候选 + 此前跳过/失败的候选
    struct Succeeded: Sendable, Equatable {
        let usedRole: ProviderFallbackCandidate.Role
        let providerID: DataProviderID
        let records: [ProviderRecord]
        let diagnostics: ProviderFetchDiagnostics
        /// 到成功为止每个候选的下场（primary 失败原因 → 为什么降级）
        let attempts: [ProviderFallbackAttempt]
    }

    case succeeded(Succeeded)
    /// 全部候选失败/不可调用——**非致命**：读取面继续本地兜底，本轮无新数据
    case allFailed(attempts: [ProviderFallbackAttempt])

    var records: [ProviderRecord] {
        switch self {
        case .succeeded(let s): return s.records
        case .allFailed: return []
        }
    }
}

/// 单个候选的一次尝试记录（诊断/审计）。
struct ProviderFallbackAttempt: Sendable, Equatable {
    enum Result: String, Sendable, Equatable {
        /// 健康监控判不可调用（unavailable / 额度尽 / 冷却中）——零网络跳过
        case skippedNotCallable
        /// 抓取失败（原因字符串化）
        case failed
        /// 抓取成功
        case succeeded
    }

    let providerID: DataProviderID
    let role: ProviderFallbackCandidate.Role
    let result: Result
    /// failed 时的原因（ProviderError 或底层错误描述）
    let failureReason: String?
}

// MARK: - 链

/// Provider 降级链：primary → secondary → … → local 兜底（allFailed）。
struct ProviderFallbackChain: Sendable {

    let candidates: [ProviderFallbackCandidate]
    let healthMonitor: ProviderHealthMonitor?

    /// 候选按序尝试（primary 语义上应排首位，构造不强制，调用方按序给）。
    /// 空链是合法形态（= 无远程候选，fetch 直接 allFailed → local 兜底），
    /// 不做 trap——配置错误用降级语义表达比崩溃更符合 DATA006。
    init(candidates: [ProviderFallbackCandidate], healthMonitor: ProviderHealthMonitor? = nil) {
        self.candidates = candidates
        self.healthMonitor = healthMonitor
    }

    /// 便捷构造：按序传 adapter（首者为 primary，其余 secondary）。
    init(adapters: [any ProviderAdapter], healthMonitor: ProviderHealthMonitor? = nil) {
        self.candidates = adapters.enumerated().map { index, adapter in
            ProviderFallbackCandidate(adapter, role: index == 0 ? .primary : .secondary)
        }
        self.healthMonitor = healthMonitor
    }

    /// 按序尝试抓取，失败降级到下一候选；全部失败返回 .allFailed（不抛错）。
    ///
    /// 唯一上抛的路径：健康监控上报自身异常（理论不发生，actor 调用安全）。
    func fetch(code: ProviderCode, from: Date, to: Date) async -> ProviderFallbackOutcome {
        var attempts: [ProviderFallbackAttempt] = []

        for candidate in candidates {
            let providerID = candidate.adapter.providerID

            // 前置闸门：unavailable / 额度尽 / 限流冷却中 → 零网络跳过
            if let monitor = healthMonitor, await !monitor.isCallable(providerID) {
                attempts.append(ProviderFallbackAttempt(
                    providerID: providerID, role: candidate.role,
                    result: .skippedNotCallable, failureReason: nil
                ))
                continue
            }

            do {
                let fetched = try await candidate.adapter.fetchWithDiagnostics(
                    code: code, from: from, to: to
                )
                await healthMonitor?.recordSuccess(providerID)
                attempts.append(ProviderFallbackAttempt(
                    providerID: providerID, role: candidate.role,
                    result: .succeeded, failureReason: nil
                ))
                // 记录 quota 用量（Alpha Vantage 类 quota 感知 adapter 的
                // 「每次成功调用 +1」近似；有精确 budget 的 adapter 自行 recordQuota）
                await healthMonitor?.incrementQuota(providerID)
                return .succeeded(ProviderFallbackOutcome.Succeeded(
                    usedRole: candidate.role,
                    providerID: providerID,
                    records: fetched.records,
                    diagnostics: fetched.diagnostics,
                    attempts: attempts
                ))
            } catch let error as ProviderError {
                await healthMonitor?.recordFailure(providerID, error: error)
                attempts.append(ProviderFallbackAttempt(
                    providerID: providerID, role: candidate.role,
                    result: .failed, failureReason: "\(error)"
                ))
            } catch {
                let mapped = ProviderError.unavailable(providerID: providerID, underlying: "\(error)")
                await healthMonitor?.recordFailure(providerID, error: mapped)
                attempts.append(ProviderFallbackAttempt(
                    providerID: providerID, role: candidate.role,
                    result: .failed, failureReason: "\(mapped)"
                ))
            }
        }

        return .allFailed(attempts: attempts)
    }
}

// MARK: - local 兜底语义（读取面）

extension ProviderFallbackOutcome {

    /// 「local 兜底」的显式化：全候选失败时，本轮**没有新数据**，但本地
    /// Canonical Store 仍在服务——读取查询、下游 Workflow 不受本次失败影响。
    ///
    /// 提供给诊断面/日志的归一描述（DATA006 降级语义的可观测出口）。
    var localFallbackSummary: String {
        switch self {
        case .succeeded(let s):
            return "provider=\(s.providerID.rawValue) role=\(s.usedRole.rawValue) "
                + "records=\(s.records.count)"
        case .allFailed(let attempts):
            let reasons = attempts
                .map { "\($0.providerID.rawValue)(\($0.role.rawValue)):\($0.failureReason ?? $0.result.rawValue)" }
                .joined(separator: "; ")
            return "all providers failed → local canonical only（\(reasons)）"
        }
    }
}
