import XCTest
@testable import QiemanDashboard

/// M2MarketEvidenceSource 的失败分类与 key 发现逻辑（离线单元测试）。
/// live 抓取本身由 M2LiveAcceptanceTests 覆盖（真 gate 不在此重复打网络）。
final class M2MarketEvidenceSourceTests: XCTestCase {

    func testClassify_mapsProviderErrorsToTaxonomy() {
        // challenge / 429 / 网络错误 → transportUnavailable
        XCTAssertEqual(
            M2MarketEvidenceSource.classify(
                ProviderError.unavailable(providerID: .stooq, underlying: "anti-bot challenge")
            ),
            "transportUnavailable(anti-bot challenge)"
        )
        // Alpha Vantage 额度 → quotaExhausted
        XCTAssertEqual(
            M2MarketEvidenceSource.classify(ProviderError.quotaExhausted(providerID: .alphaVantage)),
            "quotaExhausted(alpha-vantage daily budget)"
        )
        // schema 漂移 → semanticMismatch
        XCTAssertEqual(
            M2MarketEvidenceSource.classify(
                ProviderError.schemaMismatch(providerID: .stooq, detail: "bad header")
            ),
            "semanticMismatch(bad header)"
        )
        // M2 自身错误类型
        XCTAssertEqual(
            M2MarketEvidenceSource.classify(
                M2MarketEvidenceError.keyMissing(detail: "no apikey")
            ),
            "keyMissing(no apikey)"
        )
        // 兜底
        struct Dummy: Error {}
        XCTAssertEqual(
            M2MarketEvidenceSource.classify(Dummy()),
            "unclassified(Dummy())"
        )
    }

    func testAlphaVantageKeyDiscovery_noKeyConfigured() {
        // 本机未配置时返回 nil（demo key 不能用；live gate 会明确报告 keyMissing）
        // 若环境里配了 key 则跳过本断言（CI 可注入环境变量）。
        let envConfigured = ProcessInfo.processInfo.environment.keys.contains {
            $0 == "ALPHAVANTAGE_API_KEY" || $0 == "ALPHA_VANTAGE_API_KEY"
        }
        let keychainConfigured = KeychainHelper.get(
            account: KeychainHelper.Account.alphaVantageKey
        ) != nil
        if envConfigured || keychainConfigured { return }
        XCTAssertNil(M2MarketEvidenceSource.alphaVantageAPIKey())
    }

    func testSHA256ManifestEntry() {
        let sha = M2EvidenceEntry.sha256Hex("abc")
        XCTAssertEqual(
            sha,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testM2DatesAreShanghaiStartOfDay() {
        let d = M2Dates.date(2024, 7, 18)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: d)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 18)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(M2Dates.dateText(d), "2024-07-18")
    }
}
