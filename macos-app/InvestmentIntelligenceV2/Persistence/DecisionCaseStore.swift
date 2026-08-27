import Foundation

// MARK: - DecisionCaseStore（决策事项文件事实源，审计 A2）
//
// 用户意图域存储（不进 SQLite——删库重放不丢用户动作与手写复盘）：
// 一案一文件原子写（AGENTS.md「一对象一文件」约定），文件内容 = 该案
// 最新全量状态（含追加式事件历史与复盘记录）。
//
// 文件布局（与 allocation-targets / asset-class-assignments 同住 user-intent/）：
//
// ```
// investment-intelligence-v2/
// └─ user-intent/
//    └─ decision-cases/
//       └─ dcase_<digest>.json
// ```
//
// 与 append-only 事件 Store 的差异：case 是可变状态机（生命周期流转 +
// 指标刷新），save 为覆盖式全量写；审计能力由 case 内嵌的 events /
// reviews 承担。损坏文件跳过并记诊断日志（原文件保留在盘，不删——
// 与 StrategicAssetClassAssignmentStore 同策略）。

struct DecisionCaseStore: Sendable {

    enum StoreError: Error, Equatable, Sendable {
        case corruptCase(fileName: String, detail: String)
        case ioFailure(String)
    }

    static let directoryName = "decision-cases"

    /// decision-cases 目录（V2 工作目录派生）。
    let directory: URL

    /// - Parameter workDirectory: V2 工作目录（CanonicalStorePaths.workDirectory）。
    init(workDirectory: URL) {
        self.directory = workDirectory
            .appendingPathComponent(StrategicAllocationTargetStore.userIntentDirectoryName,
                                    isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: - 写入（一案一文件，覆盖式全量）

    /// 保存单个事项（文件名 = case id，确定性）。
    func save(_ decisionCase: DecisionCase) throws {
        let url = directory
            .appendingPathComponent("\(decisionCase.id).json", isDirectory: false)
        try writeAtomic(Self.encode(decisionCase), to: url)
    }

    /// 批量保存（逐文件原子写；中途失败保留已写文件）。
    func saveAll(_ cases: [DecisionCase]) throws {
        for decisionCase in cases {
            try save(decisionCase)
        }
    }

    // MARK: - 读取

    /// 全部事项（createdAt 降序 + caseKey 字典序，确定性）。损坏文件
    /// 跳过并记诊断日志（原文件保留）。
    func loadAll() throws -> [DecisionCase] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var cases: [DecisionCase] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                let decisionCase = try loadCase(at: url)
                guard decisionCase.schemaVersion == DecisionCase.currentSchemaVersion else {
                    Task {
                        await AIAgentDiagnosticLog.record(
                            "decision-case-store",
                            message: "事项 schema 版本不识别已跳过: \(name) — \(decisionCase.schemaVersion)")
                    }
                    continue
                }
                cases.append(decisionCase)
            } catch {
                Task {
                    await AIAgentDiagnosticLog.record(
                        "decision-case-store",
                        message: "事项文件损坏已跳过: \(name) — \(error)")
                }
            }
        }
        return cases.sorted {
            $0.createdAt == $1.createdAt
                ? $0.caseKey < $1.caseKey
                : $0.createdAt > $1.createdAt
        }
    }

    // MARK: - 私有

    private func loadCase(at url: URL) throws -> DecisionCase {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(DecisionCase.self, from: Data(contentsOf: url))
        } catch {
            throw StoreError.corruptCase(
                fileName: url.lastPathComponent, detail: String(describing: error))
        }
    }

    private static func encode(_ value: DecisionCase) -> Data {
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
