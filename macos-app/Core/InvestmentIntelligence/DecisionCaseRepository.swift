import Foundation

// DecisionCase 目录式 Repository(Schema V2)。
//
// 替代单文件 decision-cases.json。每个 Case 独立目录,
// 含 case.json + metrics/ + research/ + reviews/。
// 单文件损坏不影响其他 Case。
// 所有写入 atomic + 0600。
//
// 见重构方案第 8 节。

// MARK: - Case 摘要(用于 index.json)

struct DecisionCaseIndexEntry: Codable, Hashable, Sendable {
    let id: UUID
    let caseKey: String
    let title: String
    let subjectName: String
    let lifecycle: DecisionCaseLifecycle
    let decisionState: PortfolioDecisionState
    let userDisposition: DecisionCaseUserDisposition
    let updatedAt: String
    let hasResearch: Bool
    let hasReview: Bool

    init(from cs: DecisionCase) {
        self.id = cs.id
        self.caseKey = cs.caseKey
        self.title = cs.title
        self.subjectName = cs.subjectName
        self.lifecycle = cs.lifecycle
        self.decisionState = cs.decisionState
        self.userDisposition = cs.userDisposition
        self.updatedAt = cs.updatedAt
        self.hasResearch = cs.latestResearchRunID != nil
        self.hasReview = cs.latestReviewID != nil
    }
}

// MARK: - Repository

struct DecisionCaseRepository {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    // MARK: - 路径辅助

    private var casesDirectory: URL { baseDirectory.appendingPathComponent("cases", isDirectory: true) }
    private var indexFile: URL { casesDirectory.appendingPathComponent("index.json", isDirectory: false) }
    private func caseDirectory(_ id: UUID) -> URL { casesDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func caseFile(_ id: UUID) -> URL { caseDirectory(id).appendingPathComponent("case.json", isDirectory: false) }
    private func metricsDirectory(_ id: UUID) -> URL { caseDirectory(id).appendingPathComponent("metrics", isDirectory: true) }
    private func researchDirectory(_ id: UUID) -> URL { caseDirectory(id).appendingPathComponent("research", isDirectory: true) }
    private func reviewsDirectory(_ id: UUID) -> URL { caseDirectory(id).appendingPathComponent("reviews", isDirectory: true) }

    // MARK: - 索引

    func loadCaseIndex() -> [DecisionCaseIndexEntry] {
        guard let data = try? Data(contentsOf: indexFile),
              let entries = try? decoder.decode([DecisionCaseIndexEntry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveCaseIndex(_ entries: [DecisionCaseIndexEntry]) throws {
        try ensureDirectory(casesDirectory)
        let data = try encoder.encode(entries)
        try atomicWrite(data, to: indexFile)
    }

    // MARK: - Case CRUD

    func loadAllCases() -> [DecisionCase] {
        let fm = FileManager.default
        guard let caseDirs = try? fm.contentsOfDirectory(at: casesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var cases: [DecisionCase] = []
        for dir in caseDirs where dir.lastPathComponent != "index.json" {
            let file = dir.appendingPathComponent("case.json", isDirectory: false)
            guard let data = try? Data(contentsOf: file),
                  let cs = try? decoder.decode(DecisionCase.self, from: data)
            else { continue }  // 单个损坏不影响其他
            cases.append(cs)
        }
        return cases.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadCase(id: UUID) -> DecisionCase? {
        let file = caseFile(id)
        guard let data = try? Data(contentsOf: file),
              let cs = try? decoder.decode(DecisionCase.self, from: data)
        else { return nil }
        return cs
    }

    func upsertCase(_ cs: DecisionCase) throws {
        let dir = caseDirectory(cs.id)
        try ensureDirectory(dir)
        let data = try encoder.encode(cs)
        try atomicWrite(data, to: caseFile(cs.id))

        // 更新索引
        var entries = loadCaseIndex()
        entries.removeAll { $0.id == cs.id }
        entries.append(DecisionCaseIndexEntry(from: cs))
        try saveCaseIndex(entries)
    }

    func upsertCases(_ cases: [DecisionCase]) throws {
        for cs in cases {
            try upsertCase(cs)
        }
    }

    // MARK: - 指标快照

    func appendMetricSnapshot(_ snapshot: DecisionCaseMetricSnapshot) throws {
        let dir = metricsDirectory(snapshot.caseID)
        try ensureDirectory(dir)
        let file = dir.appendingPathComponent("\(snapshot.id.uuidString).json", isDirectory: false)
        let data = try encoder.encode(snapshot)
        try atomicWrite(data, to: file)
    }

    func loadMetricSnapshots(caseID: UUID) -> [DecisionCaseMetricSnapshot] {
        let dir = metricsDirectory(caseID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(DecisionCaseMetricSnapshot.self, from: data)
            else { return nil }
            return snapshot
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    // MARK: - 研究运行

    func appendResearchRun(_ run: DecisionCaseResearchRunRecord) throws {
        let dir = researchDirectory(run.caseID)
        try ensureDirectory(dir)
        let file = dir.appendingPathComponent("\(run.id.uuidString).json", isDirectory: false)
        let data = try encoder.encode(run)
        try atomicWrite(data, to: file)
    }

    func loadResearchRuns(caseID: UUID) -> [DecisionCaseResearchRunRecord] {
        let dir = researchDirectory(caseID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let run = try? decoder.decode(DecisionCaseResearchRunRecord.self, from: data)
            else { return nil }
            return run
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func loadLatestResearch(caseID: UUID) -> DecisionCaseResearchRunRecord? {
        loadResearchRuns(caseID: caseID).first
    }

    // MARK: - 复盘

    func appendReview(_ review: DecisionReview) throws {
        let dir = reviewsDirectory(review.caseID)
        try ensureDirectory(dir)
        let file = dir.appendingPathComponent("\(review.id.uuidString).json", isDirectory: false)
        let data = try encoder.encode(review)
        try atomicWrite(data, to: file)
    }

    func loadReviews(caseID: UUID) -> [DecisionReview] {
        let dir = reviewsDirectory(caseID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let review = try? decoder.decode(DecisionReview.self, from: data)
            else { return nil }
            return review
        }.sorted { $0.reviewedAt < $1.reviewedAt }
    }

    // MARK: - 时间线(全部历史)

    func loadTimeline(caseID: UUID) -> DecisionCaseTimeline {
        DecisionCaseTimeline(
            caseEvents: loadCase(id: caseID)?.events ?? [],
            metrics: loadMetricSnapshots(caseID: caseID),
            researchRuns: loadResearchRuns(caseID: caseID),
            reviews: loadReviews(caseID: caseID)
        )
    }

    // MARK: - App 重启恢复

    /// 把所有遗留的 running 研究运行标记为 interrupted。
    func interruptAbandonedRuns() {
        let cases = loadAllCases()
        for cs in cases {
            let runs = loadResearchRuns(caseID: cs.id)
            for run in runs where run.status == .running {
                var interrupted = run
                interrupted.status = .interrupted
                interrupted.completedAt = cs.updatedAt
                interrupted.errorMessage = "App 重启中断"
                try? appendResearchRun(interrupted)
            }
        }
    }

    // MARK: - 内部

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - 时间线汇总

struct DecisionCaseTimeline: Hashable {
    let caseEvents: [DecisionCaseEvent]
    let metrics: [DecisionCaseMetricSnapshot]
    let researchRuns: [DecisionCaseResearchRunRecord]
    let reviews: [DecisionReview]
}
