import Foundation

// 决策事项 Journal Store。
// 按 Case ID 隔离，追加研究运行和复盘记录。
// 与 DecisionCaseStore 互补：Store 存当前状态，Journal 存可审计的过程历史。

struct DecisionCaseJournalStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    // MARK: - 研究运行

    private func researchFile(caseID: UUID, runID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(caseID.uuidString, isDirectory: true)
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).json", isDirectory: false)
    }

    private func researchDirectory(caseID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(caseID.uuidString, isDirectory: true)
            .appendingPathComponent("research", isDirectory: true)
    }

    func saveResearchRun(_ record: DecisionCaseResearchRunRecord) throws {
        let file = researchFile(caseID: record.caseID, runID: record.id)
        try write(record, to: file)
    }

    func loadResearchRuns(caseID: UUID) throws -> [DecisionCaseResearchRunRecord] {
        let dir = researchDirectory(caseID: caseID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var records: [DecisionCaseResearchRunRecord] = []
        for file in files where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            if let record = try? decoder.decode(DecisionCaseResearchRunRecord.self, from: data) {
                records.append(record)
                continue
            }
            // Step 2 曾把裸 DecisionCaseResearchReport 写到同一目录；这不是损坏文件。
            if (try? decoder.decode(DecisionCaseResearchReport.self, from: data)) != nil {
                continue
            }
            // 真正无法识别的 JSON 必须抛错，不能静默吞掉审计历史损坏。
            _ = try decoder.decode(DecisionCaseResearchRunRecord.self, from: data)
        }
        return records.sorted { $0.startedAt < $1.startedAt }
    }

    func loadLatestResearchRun(caseID: UUID) throws -> DecisionCaseResearchRunRecord? {
        try loadResearchRuns(caseID: caseID).last
    }

    /// 兼容 GLM Step 2 已写入的“裸报告”文件；读取后会在下次研究时自然升级为运行记录。
    func loadLegacyLatestResearch(caseID: UUID) -> DecisionCaseResearchReport? {
        let dir = researchDirectory(caseID: caseID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { (a, b) -> Bool in
                let attrsA = try? FileManager.default.attributesOfItem(atPath: a.path)
                let attrsB = try? FileManager.default.attributesOfItem(atPath: b.path)
                let da = (attrsA?[FileAttributeKey.modificationDate] as? Date) ?? Date.distantPast
                let db = (attrsB?[FileAttributeKey.modificationDate] as? Date) ?? Date.distantPast
                return da > db
            }
        for latest in sorted {
            guard let data = try? Data(contentsOf: latest) else { continue }
            if (try? decoder.decode(DecisionCaseResearchRunRecord.self, from: data)) != nil {
                continue
            }
            if let report = try? decoder.decode(DecisionCaseResearchReport.self, from: data) {
                return report
            }
        }
        return nil
    }

    // MARK: - 复盘

    private func reviewsDirectory(caseID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(caseID.uuidString, isDirectory: true)
            .appendingPathComponent("reviews", isDirectory: true)
    }

    func saveReview(_ review: DecisionReview) throws {
        let file = reviewsDirectory(caseID: review.caseID)
            .appendingPathComponent("\(review.id.uuidString).json", isDirectory: false)
        try write(review, to: file)
    }

    func loadReviews(caseID: UUID) throws -> [DecisionReview] {
        let dir = reviewsDirectory(caseID: caseID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "json" }
            .map { file in
                let data = try Data(contentsOf: file)
                return try decoder.decode(DecisionReview.self, from: data)
            }
            .sorted { $0.reviewedAt < $1.reviewedAt }
    }

    // MARK: - 安全写入

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try encoder.encode(value)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
