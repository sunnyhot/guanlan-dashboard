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
