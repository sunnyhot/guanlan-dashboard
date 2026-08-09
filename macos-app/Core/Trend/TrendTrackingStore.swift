import Foundation

/// 跟踪项集合的本地 JSON 持久化（模板 C：集合 Store）
struct TrendTrackingStore {
    func load(from fileURL: URL) throws -> [TrendTrackingItem] {
        try JSONFilePersistence.load(
            [TrendTrackingItem].self,
            from: fileURL,
            defaultValue: []
        )
    }

    func save(_ items: [TrendTrackingItem], to fileURL: URL) throws {
        try JSONFilePersistence.save(items, to: fileURL)
    }
}
