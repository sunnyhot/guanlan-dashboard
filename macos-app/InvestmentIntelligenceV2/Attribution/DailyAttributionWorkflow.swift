import Foundation

// MARK: - DailyAttributionWorkflow（ATTR-4）
//
// AgentJob / AgentEvent 基础形态已随 AGENT-1 迁至 Agent/AgentJob.swift
// （同模块移动；本文件只保留归因 workflow 本体）。

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
