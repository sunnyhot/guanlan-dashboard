import Foundation

// MARK: - StrategicAssetClassAssignmentStore（持仓战略资产分类 append-only 事件）
//
// Planner 把资产类偏差按类内持仓 pro-rata 分配，每个可交易持仓必须有可信
// AssetClass——本 Store 是「用户显式分类」的持久化事实源（产品重构方案 §6.2）。
// 解析优先级（StrategicAssetClassificationResolver，App 侧）：
// 1. 用户显式分类（本 Store source = .user）
// 2. 直接股票 → .equity（规则恒真，无需存储）
// 3. 基金披露单一资产类占比 ≥80% 且披露未过期 → 系统识别（source = .system，
//    记录披露日期——系统识别不伪装成用户选择）
// 4. 其他 unresolved：禁止生成执行计划，引导用户分类
//
// 文件布局（与 allocation-targets 同住 user-intent/，一对象一文件事件）：
//
// ```
// investment-intelligence-v2/
// └─ user-intent/
//    └─ asset-class-assignments/
//       └─ <event-id>.json
// ```
//
// 当前状态 = 每 subjectKey 按来源分桶取最新事件（用户桶优先级恒高于系统桶，
// 与时间无关——用户意图不被后来的系统识别覆盖）。

/// 持仓战略资产分类事件 Store（无状态纯函数 + 文件系统）。
struct StrategicAssetClassAssignmentStore: Sendable {

    enum Source: String, Sendable, Codable, Hashable {
        /// 用户显式选择（编辑器保存）。
        case user
        /// 系统从基金披露识别（单一资产类 ≥80% 且披露未过期；不伪装用户选择）。
        case systemInferred
    }

    struct Assignment: Sendable, Codable, Hashable {
        /// 事件 schema 版本（不识别的版本按损坏跳过）。
        let schemaVersion: Int
        /// 确定性派生（subjectKey + assetClass + source + recordedAt）。
        let id: String
        /// 与 PortfolioPosition.subjectKey 同域（"fund|000001"）。
        let subjectKey: String
        let assetClass: AssetClass
        let source: Source
        let recordedAt: Date
        let note: String?
        /// 系统识别时的披露日期（source = .system 才有；用户选择为 nil）。
        let disclosureDate: String?
    }

    enum StoreError: Error, Equatable, Sendable {
        case corruptEvent(fileName: String, detail: String)
        /// 同 ID 不同内容（拒绝覆盖历史事件）。
        case idConflict(assignmentID: String)
        case ioFailure(String)
    }

    static let schemaVersion = 1
    static let directoryName = "asset-class-assignments"

    /// asset-class-assignments 目录（V2 工作目录派生）。
    let directory: URL

    /// - Parameter workDirectory: V2 工作目录（CanonicalStorePaths.workDirectory）。
    init(workDirectory: URL) {
        self.directory = workDirectory
            .appendingPathComponent(StrategicAllocationTargetStore.userIntentDirectoryName,
                                    isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: - 写入（append-only）

    /// 追加分类事件（同 ID 同内容幂等；事件不可变，改分类 = 新事件）。
    @discardableResult
    func record(_ assignment: Assignment) throws -> Assignment {
        let url = directory.appendingPathComponent("\(assignment.id).json", isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try loadAssignment(at: url)
            guard existing == assignment else {
                throw StoreError.idConflict(assignmentID: assignment.id)
            }
            return assignment
        }
        try writeAtomic(Self.encode(assignment), to: url)
        return assignment
    }

    /// 构造确定性 Assignment（id 由内容派生，防手工伪造历史）。
    static func makeAssignment(
        subjectKey: String,
        assetClass: AssetClass,
        source: Source,
        recordedAt: Date,
        note: String? = nil,
        disclosureDate: String? = nil
    ) -> Assignment {
        let payload: [String: String] = [
            "subjectKey": subjectKey,
            "assetClass": assetClass.rawValue,
            "source": source.rawValue,
            "recordedAtMillis": String(Int(recordedAt.timeIntervalSince1970 * 1000)),
        ]
        let digest = StableDigest.digest(StableDigest.jsonPayloadOrString(payload))
        return Assignment(
            schemaVersion: schemaVersion,
            id: "aca_\(digest)",
            subjectKey: subjectKey,
            assetClass: assetClass,
            source: source,
            recordedAt: recordedAt,
            note: note,
            disclosureDate: disclosureDate
        )
    }

    // MARK: - 读取

    /// 全部合法事件（recordedAt 升序 + id 字典序，确定性）。
    func allEvents() throws -> [Assignment] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var events: [Assignment] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                let event = try loadAssignment(at: url)
                guard event.schemaVersion == Self.schemaVersion else { continue }
                events.append(event)
            } catch {
                Task {
                    await AIAgentDiagnosticLog.record(
                        "asset-class-assignment-store",
                        message: "分类事件损坏已跳过: \(name) — \(error)")
                }
            }
        }
        return events.sorted {
            $0.recordedAt == $1.recordedAt
                ? $0.id < $1.id
                : $0.recordedAt < $1.recordedAt
        }
    }

    /// 每 subjectKey 的当前有效分类（用户桶恒优先于系统桶，桶内取最新）。
    func currentAssignments() throws -> [String: Assignment] {
        let events = try allEvents()
        var latestBySource: [String: [Source: Assignment]] = [:]
        for event in events {
            var bySource = latestBySource[event.subjectKey] ?? [:]
            if let existing = bySource[event.source] {
                // allEvents 已按时间升序——后来者覆盖，仅记录更新的
                if event.recordedAt >= existing.recordedAt {
                    bySource[event.source] = event
                }
            } else {
                bySource[event.source] = event
            }
            latestBySource[event.subjectKey] = bySource
        }
        var result: [String: Assignment] = [:]
        for (subjectKey, bySource) in latestBySource {
            // 用户意图不被系统识别覆盖（优先级与时间无关）
            result[subjectKey] = bySource[.user] ?? bySource[.systemInferred]
        }
        return result
    }

    // MARK: - 私有

    private func loadAssignment(at url: URL) throws -> Assignment {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(Assignment.self, from: Data(contentsOf: url))
        } catch {
            throw StoreError.corruptEvent(
                fileName: url.lastPathComponent, detail: String(describing: error))
        }
    }

    private static func encode(_ value: Assignment) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try! encoder.encode(value)
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.ioFailure(String(describing: error))
        }
    }
}

