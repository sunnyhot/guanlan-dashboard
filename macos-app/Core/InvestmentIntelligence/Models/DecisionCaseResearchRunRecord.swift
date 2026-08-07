import Foundation

/// 一次专项研究的可恢复运行记录。
///
/// DecisionCase 保存当前结论；该记录保存研究过程和最后一次结果，避免应用重启后
/// 只剩一份报告、却不知道它是否失败或被中断。
enum DecisionCaseResearchRunStatus: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case interrupted
}

struct DecisionCaseResearchRunRecord: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let caseID: UUID
    let startedAt: String
    let finishedAt: String?
    let trigger: String
    let status: DecisionCaseResearchRunStatus
    let report: DecisionCaseResearchReport?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        schemaVersion: Int = DecisionCaseResearchRunRecord.currentSchemaVersion,
        caseID: UUID,
        startedAt: String,
        finishedAt: String? = nil,
        trigger: String,
        status: DecisionCaseResearchRunStatus,
        report: DecisionCaseResearchReport? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.status = status
        self.report = report
        self.errorMessage = errorMessage
    }
}
