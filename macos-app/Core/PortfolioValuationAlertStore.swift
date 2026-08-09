import Foundation

/// 持仓估值预警 profiles 持久化（profile 集合 JSON）
struct PortfolioValuationAlertStore {
    func load(from fileURL: URL) throws -> [String: PortfolioValuationAlertProfile] {
        let array = try JSONFilePersistence.load(
            [PortfolioValuationAlertProfile].self,
            from: fileURL,
            defaultValue: []
        )
        // 用 uniquingKeysWith 容忍手改 JSON 等导致的重复 fundCode，取最后一条，避免 uniqueKeysWithValues 在异常输入时崩溃。
        return Dictionary(array.map { ($0.fundCode, $0) }, uniquingKeysWith: { last, _ in last })
    }

    func save(_ profiles: [String: PortfolioValuationAlertProfile], to fileURL: URL) throws {
        let array = profiles.values.sorted { $0.fundCode < $1.fundCode }
        try JSONFilePersistence.save(array, to: fileURL)
    }

}

/// 持仓估值预警全局设置持久化
struct PortfolioValuationAlertSettingsStore {
    func load(from fileURL: URL) throws -> PortfolioValuationAlertSettings {
        try JSONFilePersistence.load(
            PortfolioValuationAlertSettings.self,
            from: fileURL,
            defaultValue: PortfolioValuationAlertSettings()
        )
    }

    func save(_ settings: PortfolioValuationAlertSettings, to fileURL: URL) throws {
        try JSONFilePersistence.save(settings, to: fileURL)
    }
}
