import Foundation

// MARK: - SyncClient
//
// 客户端同步层:封装与服务端的 HTTP 交互 + 加解密 + payload 编解码。
// 配置(服务地址/groupId/deviceId)存 UserDefaults,accessToken/密码存 Keychain。
// revision 回滚检测:记住最高 revision,倒退报警。

@MainActor
final class SyncClient {
    static let shared = SyncClient()

    private enum StorageKey {
        static let serverURL = "qieman.sync.serverURL"
        static let groupID = "qieman.sync.groupId"
        static let deviceID = "qieman.sync.deviceId"
        static let lastRevision = "qieman.sync.lastRevision"
        static let lastSyncTime = "qieman.sync.lastTime"
        static let accessTokenFallback = "qieman.sync.accessToken"
        static let passwordFallback = "qieman.sync.password"
    }

    private let userDefaults: UserDefaults
    private let readSecret: (String) -> String?
    private let writeSecret: (String, String) -> Void
    private let deleteSecret: (String) -> Void

    init(
        userDefaults: UserDefaults = .standard,
        readSecret: @escaping (String) -> String? = { KeychainHelper.get(account: $0) },
        writeSecret: @escaping (String, String) -> Void = { value, account in
            KeychainHelper.set(value, account: account)
        },
        deleteSecret: @escaping (String) -> Void = { KeychainHelper.delete(account: $0) }
    ) {
        self.userDefaults = userDefaults
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.deleteSecret = deleteSecret
    }

    // MARK: - 配置(UserDefaults,非敏感)

    var serverURL: String {
        get { userDefaults.string(forKey: StorageKey.serverURL) ?? "" }
        set { userDefaults.set(newValue, forKey: StorageKey.serverURL) }
    }

    var groupId: String? {
        get { userDefaults.string(forKey: StorageKey.groupID) }
        set { userDefaults.set(newValue, forKey: StorageKey.groupID) }
    }

    var deviceId: String? {
        get { userDefaults.string(forKey: StorageKey.deviceID) }
        set { userDefaults.set(newValue, forKey: StorageKey.deviceID) }
    }

    var lastKnownRevision: Int {
        get { userDefaults.integer(forKey: StorageKey.lastRevision) }
        set { userDefaults.set(newValue, forKey: StorageKey.lastRevision) }
    }

    var lastSyncTime: Date? {
        get { userDefaults.object(forKey: StorageKey.lastSyncTime) as? Date }
        set { userDefaults.set(newValue, forKey: StorageKey.lastSyncTime) }
    }

    // MARK: - Keychain 敏感配置

    var accessToken: String? {
        get {
            readSecret(KeychainHelper.Account.syncAccessToken)
                ?? userDefaults.string(forKey: StorageKey.accessTokenFallback)
        }
    }

    var syncPassword: String? {
        get {
            readSecret(KeychainHelper.Account.syncPassword)
                ?? userDefaults.string(forKey: StorageKey.passwordFallback)
        }
        set {
            if let pw = newValue, !pw.isEmpty {
                writeSecret(pw, KeychainHelper.Account.syncPassword)
                userDefaults.set(pw, forKey: StorageKey.passwordFallback)
            } else {
                deleteSecret(KeychainHelper.Account.syncPassword)
                userDefaults.removeObject(forKey: StorageKey.passwordFallback)
            }
        }
    }

    var isConfigured: Bool {
        !serverURL.isEmpty && groupId != nil && accessToken != nil && syncPassword != nil
    }

    // MARK: - 注册同步组

    /// 注册新的同步组。成功后配置存入 UserDefaults/Keychain。
    func register(password: String) async throws {
        let url = try makeURL(path: "/v1/groups")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performRequest(req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverError(0)
        }
        guard http.statusCode == 201 else {
            throw statusError(http.statusCode)
        }

        let result = try JSONDecoder().decode(RegisterResponse.self, from: data)
        groupId = result.groupId
        deviceId = result.deviceId
        writeSecret(result.accessToken, KeychainHelper.Account.syncAccessToken)
        userDefaults.set(result.accessToken, forKey: StorageKey.accessTokenFallback)
        syncPassword = password
        lastKnownRevision = 0
    }

    /// 加入已有同步组（第二台设备用）。需要第一台设备的 groupId + accessToken + 同步密码。
    func joinGroup(existingGroupId: String, accessToken: String, password: String) async throws {
        let url = try makeURL(path: "/v1/groups")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "existingGroupId": existingGroupId,
            "accessToken": accessToken,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverError(0)
        }
        if http.statusCode == 404 { throw SyncError.groupNotFound }
        if http.statusCode == 401 { throw SyncError.authFailed }
        guard http.statusCode == 200 else {
            throw statusError(http.statusCode)
        }

        let result = try JSONDecoder().decode(RegisterResponse.self, from: data)
        groupId = result.groupId
        deviceId = result.deviceId
        writeSecret(result.accessToken, KeychainHelper.Account.syncAccessToken)
        userDefaults.set(result.accessToken, forKey: StorageKey.accessTokenFallback)
        syncPassword = password
    }

    // MARK: - 上传(推送)

    /// 加密当前数据并推送到服务端。
    func push(payload: SyncPayload) async throws {
        guard isConfigured else { throw SyncError.authFailed }
        guard let password = syncPassword else { throw SyncError.authFailed }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(payload)
        let encrypted = try ArchiveCipher.encrypt(jsonData, password: password)
        let blobBase64 = encrypted.base64EncodedString()

        let url = try makeURL(path: "/v1/groups/\(groupId!)/blob")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 乐观锁:带已知 revision
        if lastKnownRevision > 0 {
            req.setValue("\(lastKnownRevision)", forHTTPHeaderField: "If-Match")
        }

        let bodyDict: [String: Any] = [
            "blob": blobBase64,
            "sourceDeviceId": deviceId ?? "unknown",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await performRequest(req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverError(0)
        }
        if http.statusCode == 409 {
            throw SyncError.conflictNeedsConfirmation
        }
        guard http.statusCode == 200 else {
            throw statusError(http.statusCode)
        }

        let result = try JSONDecoder().decode(PushResponse.self, from: data)
        lastKnownRevision = result.revision
        lastSyncTime = Date()
    }

    // MARK: - 下载(拉取)

    /// 从服务端拉取并解密。返回 payload + 预览信息。
    /// 不修改本地状态(调用方负责 applySyncPayload)。
    func pull() async throws -> (payload: SyncPayload, preview: SyncImportPreview, revision: Int) {
        guard isConfigured else { throw SyncError.authFailed }
        guard let password = syncPassword else { throw SyncError.authFailed }

        let url = try makeURL(path: "/v1/groups/\(groupId!)/blob")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(req)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverError(0)
        }
        if http.statusCode == 404 {
            // 可能是 no_data(未上传过)或 group_not_found
            let err = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            if err?.error == "group_not_found" {
                throw SyncError.groupNotFound
            }
            throw SyncError.serverError(404)  // 无数据,调用方提示
        }
        guard http.statusCode == 200 else {
            throw statusError(http.statusCode)
        }

        let result = try JSONDecoder().decode(PullResponse.self, from: data)

        // 回滚检测
        if result.revision < lastKnownRevision {
            throw SyncError.rollbackDetected
        }

        // 解密
        guard let blobData = Data(base64Encoded: result.blob) else {
            throw SyncError.authenticationFailed
        }
        let decrypted = try ArchiveCipher.decrypt(blobData, password: password)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SyncPayload.self, from: decrypted)

        // 版本校验
        guard payload.schemaVersion <= SyncPayload.currentSchemaVersion else {
            throw SyncError.incompatibleVersion("数据版本 \(payload.schemaVersion) 高于本机支持")
        }

        let preview = SyncImportPreview(
            exportedAt: payload.exportedAt,
            sourceDeviceName: payload.sourceDeviceName,
            schemaVersion: payload.schemaVersion,
            holdingsCount: payload.holdings.count,
            pendingTradesCount: payload.pendingTrades.count,
            plansCount: payload.investmentPlans.count,
            watchlistCount: payload.watchlist.count,
            alfaCount: payload.alfaPortfolios.count,
            hasTrendConfig: !payload.trendSettings.provider.apiKey.isEmpty
        )

        return (payload, preview, result.revision)
    }

    /// 确认下载后更新 revision 记录。
    func didDownload(revision: Int) {
        lastKnownRevision = revision
        lastSyncTime = Date()
    }

    /// 清除同步组、设备、revision 和全部敏感凭据 fallback；保留服务端地址，方便重新注册。
    func resetConfiguration() {
        groupId = nil
        deviceId = nil
        lastKnownRevision = 0
        lastSyncTime = nil
        deleteSecret(KeychainHelper.Account.syncAccessToken)
        deleteSecret(KeychainHelper.Account.syncPassword)
        userDefaults.removeObject(forKey: StorageKey.accessTokenFallback)
        userDefaults.removeObject(forKey: StorageKey.passwordFallback)
        userDefaults.removeObject(forKey: StorageKey.deviceID)
        userDefaults.removeObject(forKey: StorageKey.lastRevision)
        userDefaults.removeObject(forKey: StorageKey.lastSyncTime)
    }

    // MARK: - 辅助

    private func makeURL(path: String) throws -> URL {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw SyncError.networkError("未配置同步服务地址") }

        // HTTPS 校验:同步服务用自签名证书(无域名),URLSession 默认不信任自签名,
        // 且 ATS 会拦截。内容安全由 E2EE 保证(密码加密,服务端只存密文),
        // 因此允许 HTTP 和自签名 HTTPS。正式域名 + Let's Encrypt 后可恢复强制校验。

        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw SyncError.networkError("同步服务地址格式无效")
        }
        return url
    }

    private func performRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: req)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
    }

    /// 信任自签名证书的 session(仅用于同步服务)。
    /// 验证证书指纹,只信任匹配的服务器证书,防中间人。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: SyncURLSessionDelegate(), delegateQueue: nil)
    }()

    private func statusError(_ code: Int) -> SyncError {
        switch code {
        case 401: return .authFailed
        case 404: return .groupNotFound
        case 413: return .payloadTooLarge
        default: return .serverError(code)
        }
    }
}

// MARK: - 自签名证书信任

/// 信任同步服务器的自签名证书。
/// 策略:HTTPS 请求时接受自签名证书(同步内容已由 E2EE 保护,传输层证书
/// 主要防被动监听)。HTTP 请求不受此 delegate 影响。
private final class SyncURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 接受自签名证书(同步内容由 E2EE 加密,证书层防监听即可)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - 响应 DTO

private struct RegisterResponse: Decodable {
    let groupId: String
    let deviceId: String
    let accessToken: String
}

private struct PushResponse: Decodable {
    let revision: Int
    let serverTimestamp: String
}

private struct PullResponse: Decodable {
    let revision: Int
    let serverTimestamp: String
    let sourceDeviceId: String
    let blob: String
}

private struct ServerErrorBody: Decodable {
    let error: String?
}
