import Foundation

// DecisionCase 持久化 Store。
//
// 单文件 JSON，从一开始就带 schemaVersion，避免无版本的磁盘契约。
// 不用目录式:DecisionCase 是可变状态对象(会被 resolve/close/reopen 改写),
// 单文件数组 + 原子写更简单。未来如需历史审计,再拆独立的 HistoryStore。

struct DecisionCaseStore {
    func load(from fileURL: URL) throws -> [DecisionCase] {
        try JSONFilePersistence.load(
            [DecisionCase].self,
            from: fileURL,
            defaultValue: []
        )
    }

    func save(_ cases: [DecisionCase], to fileURL: URL) throws {
        try JSONFilePersistence.save(cases, to: fileURL)
    }
}
