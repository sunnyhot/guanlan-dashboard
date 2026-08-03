import Foundation

// MARK: - SyncClient
//
// 客户端同步层:封装与服务端的 HTTP 交互 + 加解密 + payload 编解码。
// 配置(服务地址/groupId/deviceId)存 UserDefaults,accessToken/密码存 Keychain。
// revision 回滚检测:记住最高 revision,倒退报警。

@MainActor
final class SyncClient {
    static let shared = SyncClient()

    // MARK: - 配置(UserDefaults,非敏感)

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "qieman.sync.serverURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "qieman.sync.serverURL") }
    }

    var groupId: String? {
        get { UserDefaults.standard.string(forKey: "qieman.sync.groupId") }
        set { UserDefaults.standard.set(newValue, forKey: "qieman.sync.groupId") }
    }

    var deviceId: String? {
        get { UserDefaults.standard.string(forKey: "qieman.sync.deviceId") }
        set { UserDefaults.standard.set(newValue, forKey: "qieman.sync.deviceId") }
    }

    var lastKnownRevision: Int {
        get { UserDefaults.standard.integer(forKey: "qieman.sync.lastRevision") }
        set { UserDefaults.standard.set(newValue, forKey: "qieman.sync.lastRevision") }
    }

    var lastSyncTime: Date? {
        get { UserDefaults.standard.object(forKey: "qieman.sync.lastTime") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "qieman.sync.lastTime") }
    }

    // MARK: - Keychain 敏感配置

    var accessToken: String? {
        get { KeychainHelper.get(account: KeychainHelper.Account.syncAccessToken) }
    }

    var syncPassword: String? {
        get { KeychainHelper.get(account: KeychainHelper.Account.syncPassword) }
        set {
            if let pw = newValue, !pw.isEmpty {
                KeychainHelper.set(pw, account: KeychainHelper.Account.syncPassword)
            } else {
                KeychainHelper.delete(account: KeychainHelper.Account.syncPassword)
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
            throw statusError(http.statusCode, data)
        }

        let result = try JSONDecoder().decode(RegisterResponse.self, from: data)
        groupId = result.groupId
        deviceId = result.deviceId
        KeychainHelper.set(result.accessToken, account: KeychainHelper.Account.syncAccessToken)
        syncPassword = password
        lastKnownRevision = 0
    }

    // MARK: - 上传(推送)

    /// 加密当前数据并推送到服务端。
    func push(payload: SyncPayload, deviceName: String) async throws {
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
            throw statusError(http.statusCode, data)
        }

        let result = try JSONDecoder().decode(PushResponse.self, from: data)
        lastKnownRevision = result.revision
        lastSyncTime = Date()
    }

    // MARK: - 下载(拉取)

    /// 从服务端拉取并解密。返回 payload + 预览信息。
    /// 不修改本地状态(调用方负责 applySyncPayload)。
    func pull() async throws -> (payload: SyncPayload, preview: SyncImportPreview) {
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
            throw statusError(http.statusCode, data)
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

        return (payload, preview)
    }

    /// 确认下载后更新 revision 记录。
    func didDownload(revision: Int) {
        lastKnownRevision = revision
        lastSyncTime = Date()
    }

    // MARK: - 辅助

    private func makeURL(path: String) throws -> URL {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw SyncError.networkError("未配置同步服务地址") }

        // HTTPS 校验(Debug 允许 localhost HTTP)
        let isLocalhost = base.contains("localhost") || base.contains("127.0.0.1")
        #if DEBUG
        // Debug 允许 localhost HTTP
        if !base.lowercased().hasPrefix("https://") && !isLocalhost {
            throw SyncError.networkError("同步服务地址必须是 HTTPS")
        }
        #else
        if !base.lowercased().hasPrefix("https://") {
            throw SyncError.networkError("同步服务地址必须是 HTTPS")
        }
        #endif

        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw SyncError.networkError("同步服务地址格式无效")
        }
        return url
    }

    private func performRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
    }

    private func statusError(_ code: Int, _ data: Data) -> SyncError {
        switch code {
        case 401: return .authFailed
        case 404: return .groupNotFound
        case 413: return .payloadTooLarge
        default: return .serverError(code)
        }
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
