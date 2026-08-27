import Foundation

// MARK: - LegacyDecisionCaseImport（V1 决策事项 + 手写复盘导入，审计 A2/E）
//
// V1 decision-cases.json 已被 LegacyAIDataMigration 归档到
// legacy-ai-backup/（归档失败时可能仍在数据目录根部）——本导入从两处
// 读取，导入「开放事项」到 V2 DecisionCaseStore：
// - 用户显式关闭 / 已结束的事项不导入（历史保留在备份文件中）
// - kind trendAction → actionMigration；decisionState exitReview → adjustReview
// - V1 journals 目录下的用户手写复盘（<dataDir>/investment-intelligence/
//   journals/<v1-case-id>/reviews/*.json）内嵌进对应事项——**原文件保留
//   不动**（审计 E：含用户手写内容，不可静默清理；导入是复制语义）
//
// 幂等：完成（或确认无源文件）后写标记文件，重复调用 no-op；
// 单条事项按 caseKey 去重（已有同 key 事项跳过）。

enum LegacyDecisionCaseImport {

    struct Outcome: Sendable, Equatable {
        /// 导入的开放事项数。
        let importedCases: Int
        /// 随案导入的手写复盘数。
        let importedReviews: Int
        /// 跳过的已关闭事项数。
        let skippedClosedCases: Int
    }

    static let markerFileName = ".legacy-decision-case-import.json"
    static let legacyCaseFileName = "decision-cases.json"

    /// 执行导入（幂等）。store 为 V2 Store；dataDirectory 为 App 数据目录。
    static func run(store: DecisionCaseStore, dataDirectory: URL) throws -> Outcome {
        let markerURL = store.directory.appendingPathComponent(markerFileName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: markerURL.path) else {
            return Outcome(importedCases: 0, importedReviews: 0, skippedClosedCases: 0)
        }

        // 源文件：备份目录优先（LegacyAIDataMigration 的正常归档位），
        // 根部兜底（归档移动失败时仍在原位）
        let backupURL = dataDirectory
            .appendingPathComponent(LegacyAIDataMigration.backupDirectoryName, isDirectory: true)
            .appendingPathComponent(legacyCaseFileName)
        let rootURL = dataDirectory.appendingPathComponent(legacyCaseFileName)
        let sourceURL: URL?
        if fm.fileExists(atPath: backupURL.path) {
            sourceURL = backupURL
        } else if fm.fileExists(atPath: rootURL.path) {
            sourceURL = rootURL
        } else {
            sourceURL = nil
        }

        // 标记先行写入（即使本轮没有源文件也落标记——版本升级只导入一次）
        try? FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true)
        let markerPayload: [String: String] = [
            "importedAtMillis": String(Int(Date().timeIntervalSince1970 * 1000)),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: markerPayload, options: [.sortedKeys]) {
            try? data.write(to: markerURL, options: [.atomic])
        }

        guard let sourceURL,
              let rawData = try? Data(contentsOf: sourceURL)
        else {
            return Outcome(importedCases: 0, importedReviews: 0, skippedClosedCases: 0)
        }

        let legacyCases = try decodeLegacyCases(from: rawData)
        var existingKeys = Set(try store.loadAll().map(\.caseKey))

        var imported: [DecisionCase] = []
        var reviewCount = 0
        var skippedClosed = 0

        for legacyCase in legacyCases {
            guard legacyCase.lifecycle != "closed" else {
                skippedClosed += 1
                continue
            }
            let mapped = mapCase(
                legacyCase,
                reviews: loadLegacyReviews(
                    caseID: legacyCase.id, dataDirectory: dataDirectory))
            guard !existingKeys.contains(mapped.caseKey) else { continue }
            existingKeys.insert(mapped.caseKey)
            reviewCount += mapped.reviews.count
            imported.append(mapped)
        }

        if !imported.isEmpty {
            try store.saveAll(imported)
        }
        return Outcome(
            importedCases: imported.count,
            importedReviews: reviewCount,
            skippedClosedCases: skippedClosed)
    }

    // MARK: - V1 JSON 形状（字段名对齐 V1 schemaVersion 2）

    private struct V1Case: Decodable {
        let id: UUID
        let schemaVersion: Int?
        let caseKey: String?
        let kind: String
        let dimension: String
        let subjectName: String
        let subjectCode: String?
        let lifecycle: String
        let decisionState: String
        let metricValue: Double?
        let metricLabel: String?
        let metricDescription: String?
        let title: String?
        let detail: String?
        let createdAt: String
        let updatedAt: String?
        let lastEvaluatedAt: String?
        let reviewDueAt: String?
        let resolvedAt: String?
        let events: [V1Event]?
        let userDisposition: String?
    }

    private struct V1Event: Decodable {
        let id: UUID?
        let at: String
        let type: String
        let previousLifecycle: String?
        let newLifecycle: String
        let previousDecisionState: String?
        let newDecisionState: String
        let reason: String?
        let actor: String?
    }

    private struct V1Review: Decodable {
        let id: UUID
        let caseID: UUID
        let reviewedAt: String
        let originalDecisionState: String?
        let originalMetricValue: Double?
        let currentMetricValue: Double?
        let conclusion: String
        let lessons: String?
    }

    private static func decodeLegacyCases(from data: Data) throws -> [V1Case] {
        do {
            return try JSONDecoder().decode([V1Case].self, from: data)
        } catch {
            throw DecisionCaseStore.StoreError.corruptCase(
                fileName: legacyCaseFileName, detail: String(describing: error))
        }
    }

    // MARK: - 映射

    private static func mapCase(_ legacy: V1Case, reviews: [DecisionReview]) -> DecisionCase {
        let kind = mapKind(legacy.kind)
        let dimension = mapDimension(legacy.dimension)
        let createdAt = parseDate(legacy.createdAt)
        let updatedAt = legacy.updatedAt.flatMap(parseDate) ?? createdAt
        let caseKey = DecisionCase.makeCaseKey(
            kind: kind, dimension: dimension,
            subjectCode: legacy.subjectCode, subjectName: legacy.subjectName)
        // 复盘记录回填新确定性 caseID（V1 journal 以 UUID 关联，导入后换绑）
        let caseID = DecisionCase.makeCaseID(caseKey: caseKey)
        let reboundReviews = reviews.map { review in
            DecisionReview(
                id: review.id,
                caseID: caseID,
                reviewedAt: review.reviewedAt,
                originalDecisionState: review.originalDecisionState,
                originalMetricValue: review.originalMetricValue,
                currentMetricValue: review.currentMetricValue,
                conclusion: review.conclusion,
                lessons: review.lessons)
        }

        let events = (legacy.events ?? []).map { event in
            DecisionCaseEvent(
                id: event.id ?? UUID(),
                at: parseDate(event.at),
                type: mapEventType(event.type),
                previousLifecycle: event.previousLifecycle.flatMap(mapLifecycle),
                newLifecycle: mapLifecycle(event.newLifecycle) ?? .decisionReady,
                previousDecisionState: event.previousDecisionState.flatMap(mapState),
                newDecisionState: mapState(event.newDecisionState) ?? .watch,
                reason: event.reason ?? "",
                actor: mapActor(event.actor))
        }

        var mapped = DecisionCase(
            caseKey: caseKey,
            kind: kind,
            dimension: dimension,
            subjectName: legacy.subjectName,
            subjectCode: legacy.subjectCode,
            lifecycle: mapLifecycle(legacy.lifecycle) ?? .decisionReady,
            decisionState: mapState(legacy.decisionState) ?? .watch,
            metricValue: legacy.metricValue ?? 0,
            metricLabel: legacy.metricLabel ?? "",
            metricDescription: legacy.metricDescription ?? "",
            title: legacy.title ?? "",
            detail: legacy.detail ?? "",
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastEvaluatedAt: legacy.lastEvaluatedAt.flatMap(parseDate) ?? updatedAt,
            reviewDueAt: legacy.reviewDueAt.flatMap(parseDate),
            resolvedAt: nil,  // 开放事项导入时一律未解决
            events: events,
            reviews: reboundReviews,
            userDisposition: mapDisposition(legacy.userDisposition))
        // 迁移事件（审计可见）
        mapped.events.append(DecisionCaseEvent(
            at: updatedAt,
            type: .migrated,
            previousLifecycle: nil,
            newLifecycle: mapped.lifecycle,
            previousDecisionState: nil,
            newDecisionState: mapped.decisionState,
            reason: "从旧版决策事项导入（V1 schema \(legacy.schemaVersion ?? 1)）",
            actor: .migration))
        return mapped
    }

    /// V1 journals 目录下的复盘记录（复制语义——原文件不动）。
    private static func loadLegacyReviews(caseID: UUID, dataDirectory: URL) -> [DecisionReview] {
        let reviewsDirectory = dataDirectory
            .appendingPathComponent("investment-intelligence", isDirectory: true)
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent(caseID.uuidString, isDirectory: true)
            .appendingPathComponent("reviews", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reviewsDirectory.path) else {
            return []
        }
        var reviews: [DecisionReview] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: reviewsDirectory.appendingPathComponent(name)),
                  let legacy = try? JSONDecoder().decode(V1Review.self, from: data)
            else { continue }
            let conclusion: DecisionReviewConclusion
            switch legacy.conclusion {
            case "supported": conclusion = .supported
            case "partiallySupported": conclusion = .partiallySupported
            case "contradicted": conclusion = .contradicted
            case "unresolved": conclusion = .unresolved
            case "invalidatedBeforeEvaluation": conclusion = .invalidatedBeforeEvaluation
            case "insufficientData": conclusion = .insufficientData
            default: conclusion = .unresolved
            }
            reviews.append(DecisionReview(
                id: "drev_legacy_\(legacy.id.uuidString)",
                caseID: "pending",  // 占位——mapCase 内回填新确定性 caseID
                reviewedAt: parseDate(legacy.reviewedAt),
                originalDecisionState: mapState(legacy.originalDecisionState ?? "") ?? .watch,
                originalMetricValue: legacy.originalMetricValue ?? 0,
                currentMetricValue: legacy.currentMetricValue ?? 0,
                conclusion: conclusion,
                lessons: legacy.lessons ?? ""))
        }
        return reviews
    }

    // MARK: - 枚举映射（fail-soft：未知值落到保守默认）

    private static func mapKind(_ raw: String) -> DecisionCaseKind {
        switch raw {
        case "concentrationRisk": return .concentrationRisk
        case "drawdownExpansion": return .drawdownExpansion
        case "targetDeviation": return .targetDeviation
        case "trendAction": return .actionMigration
        default: return .concentrationRisk
        }
    }

    private static func mapDimension(_ raw: String) -> ConcentrationDimension {
        switch raw {
        case "lookThrough": return .lookThrough
        case "lookThroughOverlap": return .lookThroughOverlap
        case "sector": return .sector
        default: return .directHolding
        }
    }

    private static func mapLifecycle(_ raw: String) -> DecisionCaseLifecycle? {
        DecisionCaseLifecycle(rawValue: raw)
    }

    private static func mapState(_ raw: String) -> PortfolioDecisionState? {
        switch raw {
        case "exitReview": return .adjustReview  // V2 去掉了从不产出的 exitReview
        default: return PortfolioDecisionState(rawValue: raw)
        }
    }

    private static func mapEventType(_ raw: String) -> DecisionCaseEventType {
        switch raw {
        case "created": return .created
        case "reassessed": return .reassessed
        case "userAcknowledged": return .userAcknowledged
        case "userResolved": return .userResolved
        case "userClosed": return .userClosed
        case "userReopened": return .userReopened
        case "reviewRecorded": return .reviewRecorded
        case "migrated": return .migrated
        case "profileUpdated": return .reassessed  // V2 无画像，归并为指标刷新
        default: return .reassessed
        }
    }

    private static func mapActor(_ raw: String?) -> DecisionCaseActor {
        switch raw {
        case "user": return .user
        case "migration": return .migration
        default: return .system
        }
    }

    private static func mapDisposition(_ raw: String?) -> DecisionCaseUserDisposition {
        switch raw {
        case "acknowledged": return .acknowledged
        case "resolved": return .resolved
        case "closed": return .closed
        default: return .pending
        }
    }

    // MARK: - 时间解析（V1 "yyyy-MM-dd HH:mm:ss" 上海时区；兼容 ISO8601）

    private static func parseDate(_ raw: String) -> Date {
        let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: raw) { return date }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        return Date(timeIntervalSince1970: 0)
    }
}
