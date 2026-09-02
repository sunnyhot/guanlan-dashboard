import Foundation

struct TrendAnalysisSettingsStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let readSecret: (String) -> String?
    private let writeSecret: (String, String) -> Void
    private let userDefaults: UserDefaults

    init(
        // 2026-09-02 起 API Key 存 UserDefaults(LocalSecretStore),不再碰 Keychain——
        // 旧签名创建的钥匙串条目读取会弹授权框(见 LocalSecretStore 头注释)。
        readSecret: @escaping (String) -> String? = {
            LocalSecretStore.get(account: $0)
        },
        writeSecret: @escaping (String, String) -> Void = { value, account in
            LocalSecretStore.set(value, account: account)
        },
        userDefaults: UserDefaults = .standard
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.userDefaults = userDefaults
    }

    func load(from fileURL: URL) throws -> TrendAnalysisSettings {
        var settings = try JSONFilePersistence.load(
            TrendAnalysisSettings.self,
            from: fileURL,
            defaultValue: .default,
            decoder: decoder
        )
        // API Key 从 LocalSecretStore(UserDefaults)读取,JSON 不存明文。
        // LocalSecretStore 内部完成旧 Keychain 的一次性迁移与清理。
        migrateAPIKeysIfNeeded(into: &settings)
        fillAPIKeysFromSecretStore(into: &settings)
        return settings
    }

    func save(_ settings: TrendAnalysisSettings, to fileURL: URL) throws {
        // 存之前把 API Key 存进 LocalSecretStore,JSON 里只存空串(不含明文)。
        saveAPIKeysToSecretStore(settings)
        var sanitized = settings
        sanitized.provider.apiKey = ""
        sanitized.alphaVantage.apiKey = ""
        try JSONFilePersistence.save(sanitized, to: fileURL, encoder: encoder)
    }

    // MARK: - API Key <-> LocalSecretStore

    /// 从本地密钥存储填充 API Key 到 settings(覆盖空串)。
    private func fillAPIKeysFromSecretStore(into settings: inout TrendAnalysisSettings) {
        if let key = readSecret(LocalSecretStore.Account.openAIKey) {
            settings.provider.apiKey = key
        }
        if let key = readSecret(LocalSecretStore.Account.alphaVantageKey) {
            settings.alphaVantage.apiKey = key
        }
        // Tavily 已下线(2026-08-28),清掉旧 UserDefaults 孤儿密钥;
        // 旧 Keychain 条目(含 Tavily)由 LocalSecretStore 的一次性迁移统一 delete(不弹窗)。
        userDefaults.removeObject(forKey: "qieman.trend.tavily.key")
    }

    /// 迁移:存储无值但 settings JSON 里仍有旧明文 key(更早版本遗留)时补写。
    private func migrateAPIKeysIfNeeded(into settings: inout TrendAnalysisSettings) {
        if readSecret(LocalSecretStore.Account.openAIKey) == nil,
           !settings.provider.apiKey.isEmpty {
            writeSecret(settings.provider.apiKey, LocalSecretStore.Account.openAIKey)
        }
        if readSecret(LocalSecretStore.Account.alphaVantageKey) == nil,
           !settings.alphaVantage.apiKey.isEmpty {
            writeSecret(settings.alphaVantage.apiKey, LocalSecretStore.Account.alphaVantageKey)
        }
    }

    private func saveAPIKeysToSecretStore(_ settings: TrendAnalysisSettings) {
        if !settings.provider.apiKey.isEmpty {
            writeSecret(settings.provider.apiKey, LocalSecretStore.Account.openAIKey)
        }
        if !settings.alphaVantage.apiKey.isEmpty {
            writeSecret(settings.alphaVantage.apiKey, LocalSecretStore.Account.alphaVantageKey)
        }
    }
}

struct TrendAnalysisReportStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> TrendAnalysisReport? {
        try JSONFilePersistence.load(
            TrendAnalysisReport.self,
            from: fileURL,
            decoder: decoder
        )
    }

    func save(_ report: TrendAnalysisReport, to fileURL: URL) throws {
        try JSONFilePersistence.save(report, to: fileURL, encoder: encoder)
    }
}
