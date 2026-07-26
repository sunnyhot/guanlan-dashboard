import Foundation

// 阶段二：工具协议、执行上下文、统一结果信封与证据账本。
//
// 工具只读不可变快照，不允许写入用户数据。普通工具的成功/失败都作为 tool result
// 回灌给模型；只有网络失败、取消、总超时和内部不变量破坏才由 Agent 终止整次运行。

// MARK: - 工具协议

protocol TrendResearchTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// 发送给模型的参数 JSON Schema。
    var parameters: AgentJSONValue { get }

    func execute(
        argumentsJSON: String,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult
}

struct TrendResearchToolContext: Sendable {
    let snapshot: TrendResearchSnapshot
    let evidenceLedger: TrendEvidenceLedger
    let webSearchSettings: TavilySearchSettings
    let webSearchGovernor: TrendWebSearchGovernor
    /// 分模块报告暂存器；Agent 每次运行独享一个实例。
    let reportDraftStore: TrendReportDraftStore?
    /// 整次运行允许的无效提交次数上限（来自 Agent 运行策略，默认 2）。
    var invalidSubmissionBudget: Int = 2
    /// 本次 submit 之前已经发生的无效提交次数，由 Agent 循环按轮更新。
    var invalidSubmissionsUsed: Int = 0

    init(
        snapshot: TrendResearchSnapshot,
        evidenceLedger: TrendEvidenceLedger,
        webSearchSettings: TavilySearchSettings = .empty,
        webSearchGovernor: TrendWebSearchGovernor = TrendWebSearchGovernor(maxNetworkSearches: 10),
        reportDraftStore: TrendReportDraftStore? = nil
    ) {
        self.snapshot = snapshot
        self.evidenceLedger = evidenceLedger
        self.webSearchSettings = webSearchSettings
        self.webSearchGovernor = webSearchGovernor
        self.reportDraftStore = reportDraftStore
    }
}

struct TrendResearchToolResult: Sendable {
    /// 回灌给模型的工具结果内容（字符串化的 JSON 信封）。
    let contentJSON: String
    let isError: Bool
    /// 仅 submit_trend_report 填充，表示 Agent 应结束并返回该报告。
    let completion: TrendResearchCompletion?

    static func content(_ contentJSON: String, isError: Bool = false) -> TrendResearchToolResult {
        TrendResearchToolResult(contentJSON: contentJSON, isError: isError, completion: nil)
    }

    static func report(_ contentJSON: String, isError: Bool, report: TrendAnalysisReport) -> TrendResearchToolResult {
        TrendResearchToolResult(contentJSON: contentJSON, isError: isError, completion: .report(report))
    }
}

enum TrendResearchCompletion: Sendable {
    case report(TrendAnalysisReport)
}

// MARK: - 证据账本

/// 记录本次运行中所有工具读取到的证据（App 生成，非模型创造）。
/// submit_trend_report 据此校验模型引用的证据确实来自本次快照。
actor TrendEvidenceLedger {
    private var evidenceByID: [String: TrendEvidence] = [:]

    func record(_ evidence: [TrendEvidence]) {
        for item in evidence {
            evidenceByID[item.id] = item
        }
    }

    func contains(_ id: String) -> Bool {
        evidenceByID[id] != nil
    }

    func canonical(for id: String) -> TrendEvidence? {
        evidenceByID[id]
    }

    func allIDs() -> Set<String> {
        Set(evidenceByID.keys)
    }

    func allEvidence() -> [TrendEvidence] {
        evidenceByID.values.sorted { $0.id < $1.id }
    }
}

// MARK: - 结果信封

/// 构造回灌给模型的统一 JSON 信封。
enum TrendResearchToolEnvelope {
    /// 普通工具成功。
    static func success(
        _ data: [String: Any],
        warnings: [String] = [],
        evidenceIDs: [String] = []
    ) -> String {
        var payload: [String: Any] = [
            "ok": true,
            "data": data,
            "warnings": warnings,
            "evidence_ids": evidenceIDs
        ]
        if evidenceIDs.isEmpty { payload["evidence_ids"] = [] }
        return serialize(payload)
    }

    /// 普通工具失败（参数错误、未知工具、数据不可用）。
    static func error(code: String, message: String) -> String {
        serialize([
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    /// submit_trend_report 校验失败，附带详细错误和剩余修正次数。
    static func submitValidationError(code: String, message: String, errors: [String], remainingRepairAttempts: Int) -> String {
        serialize([
            "ok": false,
            "error": ["code": code, "message": message],
            "errors": errors,
            "remaining_repair_attempts": remainingRepairAttempts
        ])
    }

    private static func serialize(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"serialization_failed\",\"message\":\"工具结果序列化失败\"}}"
        }
        return string
    }
}
