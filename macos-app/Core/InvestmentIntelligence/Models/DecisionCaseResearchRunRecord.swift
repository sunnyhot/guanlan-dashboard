import Foundation

// 研究运行记录(Schema V2)。
//
// 成功和失败都必须持久化。App 重启时,遗留的 running 自动转成 interrupted。
// 自动研究不得重复运行相同 inputFingerprint;手动研究允许强制重跑。

enum DecisionCaseResearchTrigger: String, Codable, Hashable, Sendable {
    case manual
    case automatic
}

enum DecisionCaseResearchRunStatus: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted  // App 重启时遗留的 running 转为此

    var isTerminal: Bool {
        switch self {
        case .running: return false
        case .succeeded, .failed, .cancelled, .interrupted: return true
        }
    }
}

struct DecisionCaseResearchRunRecord: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let caseID: UUID
    let trigger: DecisionCaseResearchTrigger
    /// 输入指纹(caseKey + snapshotHash + profileHash),用于自动研究去重。
    let inputFingerprint: String
    let startedAt: String
    var completedAt: String?
    let providerName: String
    let modelName: String
    var status: DecisionCaseResearchRunStatus
    var report: DecisionCaseResearchReport?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        caseID: UUID,
        trigger: DecisionCaseResearchTrigger,
        inputFingerprint: String,
        startedAt: String,
        completedAt: String? = nil,
        providerName: String,
        modelName: String,
        status: DecisionCaseResearchRunStatus = .running,
        report: DecisionCaseResearchReport? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.trigger = trigger
        self.inputFingerprint = inputFingerprint
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.providerName = providerName
        self.modelName = modelName
        self.status = status
        self.report = report
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        caseID = try c.decode(UUID.self, forKey: .caseID)
        trigger = try c.decodeIfPresent(DecisionCaseResearchTrigger.self, forKey: .trigger) ?? .manual
        inputFingerprint = try c.decodeIfPresent(String.self, forKey: .inputFingerprint) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        status = try c.decodeIfPresent(DecisionCaseResearchRunStatus.self, forKey: .status) ?? .interrupted
        report = try c.decodeIfPresent(DecisionCaseResearchReport.self, forKey: .report)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
