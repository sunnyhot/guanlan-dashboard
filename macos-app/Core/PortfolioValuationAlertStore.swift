import Foundation

/// 持仓估值预警 profiles 持久化（profile 集合 JSON）
struct PortfolioValuationAlertStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> [String: PortfolioValuationAlertProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let array = try decoder.decode([PortfolioValuationAlertProfile].self, from: data)
        return Dictionary(uniqueKeysWithValues: array.map { ($0.fundCode, $0) })
    }

    func save(_ profiles: [String: PortfolioValuationAlertProfile], to fileURL: URL) throws {
        let array = profiles.values.sorted { $0.fundCode < $1.fundCode }
        let data = try encoder.encode(array)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 持仓估值预警全局设置持久化
struct PortfolioValuationAlertSettingsStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> PortfolioValuationAlertSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PortfolioValuationAlertSettings()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(PortfolioValuationAlertSettings.self, from: data)
    }

    func save(_ settings: PortfolioValuationAlertSettings, to fileURL: URL) throws {
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
