import Foundation

// DecisionCase 持久化 Store。
//
// 单文件 JSON,套 TrendTrackingStore 模板(见 docs/ai-pipeline-baseline.md 第 5 节)。
// 与 TrendTrackingStore 的关键区别:从一开始就带 schemaVersion(吸取旧 Tracking 无版本的教训)。
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
