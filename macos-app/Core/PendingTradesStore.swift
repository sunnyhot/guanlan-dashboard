import Foundation

struct PendingTradesStore {
    func load(from fileURL: URL) throws -> [PersonalPendingTrade] {
        try JSONFilePersistence.load(
            [PersonalPendingTrade].self,
            from: fileURL,
            defaultValue: []
        )
    }

    func save(_ trades: [PersonalPendingTrade], to fileURL: URL) throws {
        try JSONFilePersistence.save(trades, to: fileURL)
    }

    func delete(at fileURL: URL) throws {
        try JSONFilePersistence.delete(at: fileURL)
    }
}
