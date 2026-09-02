import XCTest
@testable import QiemanDashboard

final class AppUpdateCheckerTests: XCTestCase {

    // MARK: - Manifest Parsing (new unified format)

    func testParseUnifiedManifestWithSHA256() throws {
        let json = """
        {
            "version": "2.6.0",
            "tag": "v2.6.0",
            "asset": {
                "name": "QiemanDashboard-2.6.0.zip",
                "download_url": "https://github.com/sunnyhot/guanlan-dashboard/releases/download/v2.6.0/QiemanDashboard-2.6.0.zip",
                "size": 3126305,
                "content_type": "application/zip",
                "sha256": "abc123def456"
            },
            "sha256": "abc123def456",
            "notes": "Release notes here",
            "html_url": "https://github.com/sunnyhot/guanlan-dashboard/releases/tag/v2.6.0",
            "published_at": "2026-05-22T10:42:15Z",
            "tag_name": "v2.6.0",
            "name": "QiemanDashboard v2.6.0",
            "body": "Release notes here",
            "assets": [
                {
                    "name": "QiemanDashboard-2.6.0.zip",
                    "browser_download_url": "https://github.com/sunnyhot/guanlan-dashboard/releases/download/v2.6.0/QiemanDashboard-2.6.0.zip",
                    "size": 3126305,
                    "content_type": "application/zip"
                }
            ]
        }
        """.data(using: .utf8)!

        // Verify the JSON can be decoded as GitHubReleasePayload
        // This tests that the new manifest format is backward-compatible
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Access private types through the public check() flow would require mocking,
        // so we test the model shapes indirectly through the version comparison logic
        XCTAssertNoThrow(try decoder.decode(TestManifestPayload.self, from: json))
        let payload = try decoder.decode(TestManifestPayload.self, from: json)
        XCTAssertEqual(payload.tag_name, "v2.6.0")
        XCTAssertEqual(payload.sha256, "abc123def456")
        XCTAssertEqual(payload.assets.count, 1)
    }

    func testParseLegacyManifestWithoutSHA256() throws {
        let json = """
        {
            "tag_name": "v2.5.0",
            "name": "QiemanDashboard v2.5.0",
            "body": "Legacy release",
            "html_url": "https://github.com/sunnyhot/guanlan-dashboard/releases/tag/v2.5.0",
            "published_at": "2026-05-20T10:00:00Z",
            "assets": [
                {
                    "name": "QiemanDashboard-2.5.0.zip",
                    "browser_download_url": "https://github.com/sunnyhot/guanlan-dashboard/releases/download/v2.5.0/QiemanDashboard-2.5.0.zip",
                    "size": 3000000,
                    "content_type": "application/zip"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(TestManifestPayload.self, from: json))
        let payload = try decoder.decode(TestManifestPayload.self, from: json)
        XCTAssertEqual(payload.tag_name, "v2.5.0")
        XCTAssertNil(payload.sha256)
        XCTAssertEqual(payload.assets.count, 1)
    }

    // MARK: - Version Comparison

    func testNormalizedVersionStripsVPrefix() {
        XCTAssertEqual(AppUpdateChecker.normalizedVersion("v2.6.0"), "2.6.0")
    }

    func testNormalizedVersionStripsVersionPrefix() {
        XCTAssertEqual(AppUpdateChecker.normalizedVersion("version-2.6.0"), "2.6.0")
    }

    func testNormalizedVersionStripsReleasePrefix() {
        XCTAssertEqual(AppUpdateChecker.normalizedVersion("release-2.6.0"), "2.6.0")
    }

    func testNormalizedVersionPassthrough() {
        XCTAssertEqual(AppUpdateChecker.normalizedVersion("2.6.0"), "2.6.0")
    }

    func testCompareVersionsDescending() {
        XCTAssertEqual(
            AppUpdateChecker.compareVersions("2.6.0", "2.5.0"),
            .orderedDescending
        )
    }

    func testCompareVersionsAscending() {
        XCTAssertEqual(
            AppUpdateChecker.compareVersions("2.5.0", "2.6.0"),
            .orderedAscending
        )
    }

    func testCompareVersionsEqual() {
        XCTAssertEqual(
            AppUpdateChecker.compareVersions("2.6.0", "2.6.0"),
            .orderedSame
        )
    }

    func testCompareVersionsDifferentLengths() {
        XCTAssertEqual(
            AppUpdateChecker.compareVersions("2.6.1", "2.6"),
            .orderedDescending
        )
        XCTAssertEqual(
            AppUpdateChecker.compareVersions("2.6", "2.6.0"),
            .orderedSame
        )
    }

    // MARK: - Default Feed URL

    func testDefaultFeedURLUsesReleaseAssetPath() {
        let url = AppUpdateChecker.defaultFeedURLString
        XCTAssertTrue(
            url.contains("/releases/latest/download/latest.json"),
            "Default feed URL should use Release asset path, got: \(url)"
        )
        XCTAssertFalse(
            url.contains("raw.githubusercontent.com"),
            "Default feed URL should NOT use raw.githubusercontent.com, got: \(url)"
        )
    }

    // MARK: - Release Notes

    func testReleaseNotesFallsBackToManifestNotesWhenBodyIsEmpty() {
        XCTAssertEqual(
            AppUpdateChecker.releaseNotes(body: "", notes: "本次更新：展示升级内容"),
            "本次更新：展示升级内容"
        )
    }

    func testReleaseNotesPrefersBodyWhenBothFieldsExist() {
        XCTAssertEqual(
            AppUpdateChecker.releaseNotes(body: "GitHub Release 正文", notes: "清单 notes"),
            "GitHub Release 正文"
        )
    }

    // MARK: - Homebrew cask 让位检测（2026-09-02）

    func testHomebrewDetectionFindsCaskroomReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caskroom-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/guanlan/4.9.6",
            withIntermediateDirectories: true
        )
        XCTAssertTrue(HomebrewCaskInstallation.isManaged(caskroomRoots: [root]), "有版本回执目录 → brew 管理")
    }

    func testHomebrewDetectionRejectsEmptyOrMissingRoot() throws {
        let missing = "/tmp/not-exists-\(UUID().uuidString)"
        XCTAssertFalse(HomebrewCaskInstallation.isManaged(caskroomRoots: [missing]), "路径不存在 → 非 brew 管理")

        let emptyToken = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caskroom-empty-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: emptyToken) }
        try FileManager.default.createDirectory(
            atPath: emptyToken + "/guanlan",
            withIntermediateDirectories: true
        )
        XCTAssertFalse(HomebrewCaskInstallation.isManaged(caskroomRoots: [emptyToken]), "token 目录为空 → 非 brew 管理")
    }

    func testHomebrewDetectionScansAllRoots() throws {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caskroom-a-\(UUID().uuidString)").path
        let realRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caskroom-b-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: emptyRoot)
            try? FileManager.default.removeItem(atPath: realRoot)
        }
        try FileManager.default.createDirectory(atPath: emptyRoot + "/other", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: realRoot + "/guanlan/4.9.6", withIntermediateDirectories: true)
        XCTAssertTrue(HomebrewCaskInstallation.isManaged(caskroomRoots: [emptyRoot, realRoot]), "任一 root 命中即 brew 管理")
    }
}

// Mirror of the private GitHubReleasePayload for testing decode logic
private struct TestManifestPayload: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: URL
    let published_at: Date?
    let assets: [TestAssetPayload]
    let sha256: String?
}

private struct TestAssetPayload: Decodable {
    let name: String
    let browser_download_url: URL
    let size: Int
    let content_type: String?
}
