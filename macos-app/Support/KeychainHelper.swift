import Foundation
import Security

// MARK: - KeychainHelper
//
// 跨平台(macOS/iOS)Keychain 存取,用于保存敏感数据:
// - 趋势分析 API Key(OpenAI/AlphaVantage):从明文 JSON 迁移到 Keychain
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
        // v4.4.2 根因修复：此前用 SecAccessControlCreateWithFlags 产
        // kSecAttrAccessControl——该属性需要 keychain entitlement，本 App
        // 走 GitHub Actions ad-hoc 签名（无 entitlement），SecItemAdd 恒返
        // errSecMissingEntitlement(-34018)，**macOS 上 Key 从未写入成功过**
        // （旧版静默吞掉 =「AI 模型配置不生效」）。
        // 正确组合（双 binary 实验验证）：legacy keychain + kSecAttrAccessible
        // ——无 ACL 绑定，ad-hoc 重签（自动更新）后写入可用。
        // 但 2026-08-31 实证：ad-hoc 身份每次构建都变，读取旧签名创建的项
        // 仍会触发授权弹窗；根治靠稳定签名身份（见
        // scripts/create_signing_identity.sh 与 build_macos_app.sh）。
        // 显式不设 kSecUseDataProtectionKeychain（同样缺 entitlement 会 -34018）。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
        /// 已废弃：Tavily 联网搜索 2026-08-28 下线，仅保留给遗留密钥清理用。
        static let tavilyKey = "trend.tavily.apiKey"
        static let alphaVantageKey = "trend.alphaVantage.apiKey"
        static let syncPassword = "sync.password"
        static let syncAccessToken = "sync.accessToken"
    }
}
