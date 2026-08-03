import Foundation
import Security

// MARK: - KeychainHelper
//
// 跨平台(macOS/iOS)Keychain 存取,用于保存敏感数据:
// - 趋势分析 API Key(OpenAI/Tavily/AlphaVantage):从明文 JSON 迁移到 Keychain
// - 同步密码、accessToken(同步功能用)
//
// 零依赖,纯 Security 框架。service 固定为 bundleId 前缀,account 区分用途。

enum KeychainHelper {
    private static let service = "com.sunnyhot.qieman.dashboard"

    // MARK: - 存

    /// 存字符串到 Keychain。已有同 account 的项会被覆盖。
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return set(data, account: account)
    }

    /// 存 Data 到 Keychain。
    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先删旧值
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        #if os(macOS)
        // macOS 非沙盒 app:用 SecAccessControl 设置「不弹窗」的访问策略。
        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlock,
            [],
            nil
        )
        if let access {
            attributes[kSecAttrAccessControl as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        #else
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - 取

    /// 取字符串。不存在返回 nil。
    static func get(account: String) -> String? {
        guard let data = getData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 取 Data。
    static func getData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - 删

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - API Key 专用 account 常量

    /// 趋势分析 API Key 的 Keychain account 名。
    enum Account {
        static let openAIKey = "trend.openai.apiKey"
        static let tavilyKey = "trend.tavily.apiKey"
        static let alphaVantageKey = "trend.alphaVantage.apiKey"
        static let syncPassword = "sync.password"
        static let syncAccessToken = "sync.accessToken"
    }
}
