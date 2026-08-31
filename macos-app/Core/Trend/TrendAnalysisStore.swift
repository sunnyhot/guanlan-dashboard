import Foundation

struct TrendAnalysisSettingsStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let readSecret: (String) -> String?
    private let writeSecret: (String, String) -> Void
    private let userDefaults: UserDefaults

    init(
        readSecret: @escaping (String) -> String? = {
            KeychainHelper.get(account: $0)
        },
        writeSecret: @escaping (String, String) -> Void = { value, account in
            KeychainHelper.set(value, account: account)
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
        // API Key 从 Keychain 读取(JSON 不再存明文 key)。
        // 迁移:若 Keychain 无值但 JSON 里有旧明文,迁移进 Keychain。
        migrateAPIKeysIfNeeded(into: &settings)
        fillAPIKeysFromKeychain(into: &settings)
        return settings
    }

    func save(_ settings: TrendAnalysisSettings, to fileURL: URL) throws {
        // 存之前把 API Key 存进 Keychain,JSON 里只存空串(不含明文)。
        saveAPIKeysToKeychain(settings)
        var sanitized = settings
        sanitized.provider.apiKey = ""
        sanitized.alphaVantage.apiKey = ""
        try JSONFilePersistence.save(sanitized, to: fileURL, encoder: encoder)
    }

    // MARK: - API Key <-> Keychain

    /// 从 Keychain 填充 API Key 到 settings(覆盖空串)。
    private func fillAPIKeysFromKeychain(into settings: inout TrendAnalysisSettings) {
        // 优先 Keychain，fallback UserDefaults(Keychain 弹窗被拒时)。
        // 只要成功读到旧 Keychain 值就自动回填 fallback，
        // 避免后续 App 签名变化或授权被拒时上传空 key。
        let openAI = resolvedAPIKey(
            account: KeychainHelper.Account.openAIKey,
            userDefaultsKey: "qieman.trend.openai.key"
        )
        let alpha = resolvedAPIKey(
            account: KeychainHelper.Account.alphaVantageKey,
            userDefaultsKey: "qieman.trend.alphavantage.key"
        )
        if let key = openAI, !key.isEmpty { settings.provider.apiKey = key }
        if let key = alpha, !key.isEmpty { settings.alphaVantage.apiKey = key }
        removeLegacyTavilyKey()
    }

    /// Tavily 联网搜索已下线（2026-08-28）：清理用户 Keychain/UserDefaults 里的孤儿密钥。
    /// 直接删除，不做「先读再删」——读取旧签名创建的 Keychain 项会触发系统授权弹窗，
    /// 用户一旦点「拒绝」，删除永远不执行，弹窗每次加载设置都重现（2026-08-31 实证）。
    /// 删除操作本身不弹窗。
    private func removeLegacyTavilyKey() {
        KeychainHelper.delete(account: KeychainHelper.Account.tavilyKey)
        userDefaults.removeObject(forKey: "qieman.trend.tavily.key")
    }

    private func resolvedAPIKey(account: String, userDefaultsKey: String) -> String? {
        if let key = readSecret(account), !key.isEmpty {
            userDefaults.set(key, forKey: userDefaultsKey)
            return key
        }
        if let key = userDefaults.string(forKey: userDefaultsKey), !key.isEmpty {
            return key
        }
        return nil
    }

    /// 迁移:若 Keychain 无值但 settings 里仍有明文 key(旧版本遗留),存进 Keychain。
    private func migrateAPIKeysIfNeeded(into settings: inout TrendAnalysisSettings) {
        if readSecret(KeychainHelper.Account.openAIKey) == nil,
           !settings.provider.apiKey.isEmpty {
            writeSecret(settings.provider.apiKey, KeychainHelper.Account.openAIKey)
        }
        if readSecret(KeychainHelper.Account.alphaVantageKey) == nil,
           !settings.alphaVantage.apiKey.isEmpty {
            writeSecret(settings.alphaVantage.apiKey, KeychainHelper.Account.alphaVantageKey)
        }
    }

    /// 把 settings 的 API Key 存进 Keychain。
    private func saveAPIKeysToKeychain(_ settings: TrendAnalysisSettings) {
        if !settings.provider.apiKey.isEmpty {
            writeSecret(settings.provider.apiKey, KeychainHelper.Account.openAIKey)
            userDefaults.set(settings.provider.apiKey, forKey: "qieman.trend.openai.key")
        }
        if !settings.alphaVantage.apiKey.isEmpty {
            writeSecret(settings.alphaVantage.apiKey, KeychainHelper.Account.alphaVantageKey)
            userDefaults.set(settings.alphaVantage.apiKey, forKey: "qieman.trend.alphavantage.key")
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
