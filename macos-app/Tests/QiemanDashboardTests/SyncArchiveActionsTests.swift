import XCTest
@testable import QiemanDashboard

@MainActor
final class SyncArchiveActionsTests: XCTestCase {
    func testSyncPayloadIncludesAllInMemoryAPIKeys() {
        let model = AppModel()
        model.trendSettings = syncedTrendSettings()

        let payload = model.makeSyncPayload(sourceDeviceName: "Test Mac")

        XCTAssertEqual(payload.trendSettings.provider.apiKey, "sk-sync-test")
        XCTAssertEqual(payload.trendSettings.webSearch.apiKey, "tvly-sync-test")
        XCTAssertEqual(payload.trendSettings.alphaVantage.apiKey, "alpha-sync-test")
    }

    func testApplyingSyncedTrendSettingsKeepsAPIKeysInRuntimeState() {
        var current = TrendAnalysisSettings.default
        current.officialSources = OfficialSourceSettings(
            enabled: true,
            secContactEmail: "research@example.com"
        )
        current.defaultPrivacyMode = .fullDetail

        let synced = TrendSettingsSyncDTO(from: syncedTrendSettings())
        let applied = AppModel.trendSettingsByApplyingSync(synced, to: current)

        XCTAssertTrue(applied.provider.isConfigured)
        XCTAssertEqual(applied.provider.apiKey, "sk-sync-test")
        XCTAssertEqual(applied.webSearch.apiKey, "tvly-sync-test")
        XCTAssertEqual(applied.alphaVantage.apiKey, "alpha-sync-test")
        XCTAssertEqual(applied.officialSources.secContactEmail, "research@example.com")
        XCTAssertEqual(applied.defaultPrivacyMode, .fullDetail)
    }

    func testResetConfigurationClearsKeychainAndFallbackValues() throws {
        let suiteName = "sync-reset-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var secrets = [
            KeychainHelper.Account.syncAccessToken: "token-secret",
            KeychainHelper.Account.syncPassword: "password-secret",
        ]
        let client = SyncClient(
            userDefaults: defaults,
            readSecret: { secrets[$0] },
            writeSecret: { value, account in secrets[account] = value },
            deleteSecret: { secrets.removeValue(forKey: $0) }
        )
        client.serverURL = "https://sync.example.com"
        client.groupId = "group-1"
        client.deviceId = "device-1"
        client.lastKnownRevision = 42
        client.lastSyncTime = Date(timeIntervalSince1970: 1_000)
        defaults.set("token-fallback", forKey: "qieman.sync.accessToken")
        defaults.set("password-fallback", forKey: "qieman.sync.password")

        client.resetConfiguration()

        XCTAssertEqual(client.serverURL, "https://sync.example.com")
        XCTAssertNil(client.groupId)
        XCTAssertNil(client.deviceId)
        XCTAssertEqual(client.lastKnownRevision, 0)
        XCTAssertNil(client.lastSyncTime)
        XCTAssertNil(client.accessToken)
        XCTAssertNil(client.syncPassword)
        XCTAssertTrue(secrets.isEmpty)
    }

    func testSyncImportPreviewOwnsSharedConfirmationCopy() {
        let preview = SyncImportPreview(
            exportedAt: Date(timeIntervalSince1970: 1_000),
            sourceDeviceName: "测试设备",
            schemaVersion: 1,
            holdingsCount: 2,
            pendingTradesCount: 3,
            plansCount: 4,
            watchlistCount: 5,
            alfaCount: 6,
            hasTrendConfig: true
        )

        XCTAssertTrue(preview.confirmationText.contains("来源设备：测试设备"))
        XCTAssertTrue(preview.confirmationText.contains("持仓 2 · 待确认 3 · 计划 4 · 关注 5 · 投顾 6"))
        XCTAssertTrue(preview.confirmationText.contains("含 AI 模型配置"))
        XCTAssertTrue(preview.confirmationText.contains("撤销上次下载"))
    }

    private func syncedTrendSettings() -> TrendAnalysisSettings {
        TrendAnalysisSettings(
            provider: TrendAIProviderSettings(
                providerName: "OpenAI",
                baseURL: "https://api.openai.com/v1",
                model: "gpt-test",
                apiKey: "sk-sync-test",
                timeoutSeconds: 300
            ),
            webSearch: TavilySearchSettings(apiKey: "tvly-sync-test"),
            alphaVantage: AlphaVantageSettings(
                enabled: true,
                apiKey: "alpha-sync-test",
                dailyRequestLimit: 25
            ),
            defaultPrivacyMode: .sanitized,
            dailyAutoAnalysisEnabled: false
        )
    }
}
