import Foundation

struct PersonalWatchlistStore {
    func load(from fileURL: URL) throws -> [PersonalWatchlistRecord] {
        let records = try JSONFilePersistence.load(
            [PersonalWatchlistRecord].self,
            from: fileURL,
            defaultValue: []
        )
        return records.map {
            PersonalWatchlistRecord(
                item: $0.item,
                baseline: $0.baseline,
                dailyPoints: $0.dailyPoints,
                alertRules: $0.alertRules,
                alertState: $0.alertState
            )
        }
    }

    func save(_ records: [PersonalWatchlistRecord], to fileURL: URL) throws {
        let normalized = records.map {
            PersonalWatchlistRecord(
                item: $0.item,
                baseline: $0.baseline,
                dailyPoints: $0.dailyPoints,
                alertRules: $0.alertRules,
                alertState: $0.alertState
            )
        }
        try JSONFilePersistence.save(normalized, to: fileURL)
    }

    func delete(at fileURL: URL) throws {
        try JSONFilePersistence.delete(at: fileURL)
    }
}
