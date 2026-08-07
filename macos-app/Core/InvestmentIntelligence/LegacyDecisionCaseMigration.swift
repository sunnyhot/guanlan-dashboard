import Foundation

/// 只读兼容 GLM 中间版本的目录式 Repository，并迁到当前唯一 Store/Journal。
/// 旧目录始终保留，不做删除；迁移完成后写标记避免重复扫描。
struct LegacyDecisionCaseMigration {
    private let baseDirectory: URL
    private let decoder = JSONDecoder()

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    private var casesDirectory: URL {
        baseDirectory.appendingPathComponent("cases", isDirectory: true)
    }

    private var markerFile: URL {
        baseDirectory.appendingPathComponent("legacy-repository-migrated-v1", isDirectory: false)
    }

    var needsMigration: Bool {
        FileManager.default.fileExists(atPath: casesDirectory.path)
            && !FileManager.default.fileExists(atPath: markerFile.path)
    }

    func migrate(into journalStore: DecisionCaseJournalStore) throws -> [DecisionCase] {
        guard needsMigration else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: casesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        var cases: [DecisionCase] = []
        for directory in directories where directory.lastPathComponent != "index.json" {
            let caseFile = directory.appendingPathComponent("case.json", isDirectory: false)
            guard let data = try? Data(contentsOf: caseFile),
                  let decisionCase = try? decoder.decode(DecisionCase.self, from: data)
            else { continue }

            cases.append(decisionCase)
            try migrateReviews(in: directory, caseID: decisionCase.id, into: journalStore)
            try migrateResearchRuns(in: directory, caseID: decisionCase.id, into: journalStore)
        }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("migrated".utf8).write(to: markerFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerFile.path)
        return cases
    }

    private func migrateReviews(
        in caseDirectory: URL,
        caseID: UUID,
        into journalStore: DecisionCaseJournalStore
    ) throws {
        let directory = caseDirectory.appendingPathComponent("reviews", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let review = try? decoder.decode(DecisionReview.self, from: data),
                  review.caseID == caseID
            else { continue }
            try journalStore.saveReview(review)
        }
    }

    private func migrateResearchRuns(
        in caseDirectory: URL,
        caseID: UUID,
        into journalStore: DecisionCaseJournalStore
    ) throws {
        let directory = caseDirectory.appendingPathComponent("research", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let legacy = try? decoder.decode(LegacyResearchRun.self, from: data),
                  legacy.caseID == caseID
            else { continue }
            try journalStore.saveResearchRun(legacy.currentRecord)
        }
    }
}

private struct LegacyResearchRun: Decodable {
    let id: UUID
    let caseID: UUID
    let trigger: String
    let startedAt: String
    let completedAt: String?
    let status: String
    let report: DecisionCaseResearchReport?
    let errorMessage: String?

    var currentRecord: DecisionCaseResearchRunRecord {
        DecisionCaseResearchRunRecord(
            id: id,
            caseID: caseID,
            startedAt: startedAt,
            finishedAt: completedAt,
            trigger: trigger == "automatic" ? "自动触发" : "用户手动",
            status: currentStatus,
            report: report,
            errorMessage: errorMessage
        )
    }

    private var currentStatus: DecisionCaseResearchRunStatus {
        switch status {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "running", "cancelled", "interrupted": return .interrupted
        default: return .interrupted
        }
    }
}
