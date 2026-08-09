import Foundation

struct ManagerWatchStore {
    func load(from fileURL: URL) throws -> ManagerWatchSettings {
        try JSONFilePersistence.load(
            ManagerWatchSettings.self,
            from: fileURL,
            defaultValue: .default
        )
    }

    func save(_ settings: ManagerWatchSettings, to fileURL: URL) throws {
        try JSONFilePersistence.save(settings, to: fileURL)
    }
}
