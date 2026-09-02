import Foundation
import Security

// MARK: - 本地密钥存储（2026-09-02 起，替代 Keychain）
//
// 弃用 Keychain 的根因：旧签名身份创建的钥匙串条目，新身份（发版证书更换/本地
// 开发构建）读取会触发系统授权弹窗，用户点「拒绝」后每次加载设置都重现
// （2026-08-31 实证）；即使稳定签名身份落地，本地开发版与 CI 版混用仍会弹。
// API Key / 同步凭证改存 UserDefaults（沙盒内、单用户权限保护），与
// qieman.cookie 本地受权限保护文件同一安全模型。
//
// 迁移策略（零弹框优先）：
// 1. UserDefaults 已有值（旧版 fallback 通道每次成功读 Keychain 都会回填，
//    存量用户大概率已有）→ 直接使用，不碰 Keychain；
// 2. 无值时尝试读一次旧 Keychain 条目（此时可能弹最后一框，点「拒绝」则标记
//    不再尝试，用户重填即可），读到后写入 UserDefaults；
// 3. 迁移完成后 delete 旧 Keychain 条目——删除操作本身不弹窗（实证），
//    彻底断掉后续任何弹窗可能。

enum LocalSecretStore {
    /// account 名沿用旧版 UserDefaults fallback key，存量数据无缝衔接。
    enum Account {
        static let openAIKey = "qieman.trend.openai.key"
        static let alphaVantageKey = "qieman.trend.alphavantage.key"
        static let syncPassword = "qieman.sync.password"
        static let syncAccessToken = "qieman.sync.accessToken"
    }

    /// 一次性迁移标记：读取旧 Keychain 的尝试至多发生一次（无论成败），
    /// 防止被拒后每次启动都弹。
    private static let migrationAttemptedKey = "qieman.keychain.migration.attempted"

    // 旧 Keychain account 名（仅迁移与清理用）。
    private enum LegacyKeychainAccount {
        static let openAIKey = "trend.openai.apiKey"
        static let alphaVantageKey = "trend.alphaVantage.apiKey"
        static let tavilyKey = "trend.tavily.apiKey"
        static let syncPassword = "sync.password"
        static let syncAccessToken = "sync.accessToken"
    }

    static func get(account: String) -> String? {
        migrateFromKeychainIfNeeded()
        let value = UserDefaults.standard.string(forKey: account)
        return (value?.isEmpty == false) ? value : nil
    }

    static func set(_ value: String, account: String) {
        UserDefaults.standard.set(value, forKey: account)
    }

    static func delete(account: String) {
        UserDefaults.standard.removeObject(forKey: account)
    }

    /// 无 UserDefaults 值时尝试从旧 Keychain 迁移一次；随后清理全部旧条目
    /// （delete 不弹窗）。用户本机存量数据通常已回填，直接零弹框跳过。
    static func migrateFromKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationAttemptedKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationAttemptedKey)

        let legacyPairs: [(keychain: String, local: String)] = [
            (LegacyKeychainAccount.openAIKey, Account.openAIKey),
            (LegacyKeychainAccount.alphaVantageKey, Account.alphaVantageKey),
            (LegacyKeychainAccount.syncPassword, Account.syncPassword),
            (LegacyKeychainAccount.syncAccessToken, Account.syncAccessToken),
        ]
        for pair in legacyPairs where UserDefaults.standard.string(forKey: pair.local)?.isEmpty != false {
            if let legacy = KeychainReader.get(account: pair.keychain), !legacy.isEmpty {
                UserDefaults.standard.set(legacy, forKey: pair.local)
            }
        }
        // 旧条目清理（含已下线 Tavily 的孤儿密钥）：delete 不触发授权弹窗。
        for pair in legacyPairs {
            KeychainReader.delete(account: pair.keychain)
        }
        KeychainReader.delete(account: LegacyKeychainAccount.tavilyKey)
    }
}

/// 迁移专用的最小 Keychain 读写（自 KeychainHelper 退役后内联至此）。
private enum KeychainReader {
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sunnyhot.qieman.dashboard",  // 与旧 KeychainHelper 一致,迁移才能读到旧条目
        ]
    }

    static func get(account: String) -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        SecItemDelete(query as CFDictionary)
    }
}
