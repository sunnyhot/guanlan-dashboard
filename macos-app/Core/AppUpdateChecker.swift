import Foundation

struct AppUpdateAsset: Equatable {
    let name: String
    let downloadURL: URL
    let size: Int
    let contentType: String?

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct AppUpdateRelease: Identifiable, Equatable {
    var id: String { tagName }

    let tagName: String
    let version: String
    let title: String
    let notes: String
    let htmlURL: URL
    let publishedAt: Date?
    let asset: AppUpdateAsset?
    let currentVersion: String
    let sha256: String?

    var displayTitle: String {
        title.isEmpty ? "版本 \(version)" : title
    }
}

enum AppUpdateCheckError: LocalizedError {
    case invalidFeedURL(String)
    case noGitHubRelease
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL(let value):
            return "更新源地址无效：\(value)"
        case .noGitHubRelease:
            return "GitHub 上还没有可用的更新清单或 Release。上传最新 App 压缩包和 latest.json 后，这里就能检查到。"
        case .requestFailed(let statusCode):
            return "检查更新失败，GitHub 返回 HTTP \(statusCode)。"
        case .invalidResponse:
            return "检查更新失败，GitHub 返回的数据格式不完整。"
        }
    }
}

struct AppUpdateChecker {
    private struct GitHubReleasePayload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let notes: String?
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [GitHubAssetPayload]
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case notes
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
            case sha256
        }
    }

    private struct GitHubAssetPayload: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int
        let contentType: String?
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case contentType = "content_type"
            case sha256
        }
    }

    let feedURL: URL
    let currentVersion: String

    init(
        feedURLString: String = AppUpdateChecker.defaultFeedURLString,
        currentVersion: String = AppUpdateChecker.bundleVersion
    ) throws {
        guard let url = URL(string: feedURLString) else {
            throw AppUpdateCheckError.invalidFeedURL(feedURLString)
        }
        self.feedURL = url
        self.currentVersion = currentVersion
    }

    func check() async throws -> AppUpdateRelease? {
        var request = URLRequest(url: feedURL, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QiemanDashboard/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            throw AppUpdateCheckError.noGitHubRelease
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckError.requestFailed(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubReleasePayload.self, from: data)
        let releaseVersion = Self.normalizedVersion(payload.tagName)
        guard Self.compareVersions(releaseVersion, currentVersion) == .orderedDescending else {
            return nil
        }

        // Extract sha256: prefer top-level, fall back to asset-level
        let manifestSHA256 = payload.sha256 ?? Self.sha256FromAssets(payload.assets)

        return AppUpdateRelease(
            tagName: payload.tagName,
            version: releaseVersion,
            title: payload.name ?? "",
            notes: Self.releaseNotes(body: payload.body, notes: payload.notes),
            htmlURL: payload.htmlURL,
            publishedAt: payload.publishedAt,
            asset: Self.preferredAsset(from: payload.assets),
            currentVersion: currentVersion,
            sha256: manifestSHA256
        )
    }

    static var defaultRepository: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "QiemanUpdateRepository") as? String
        return nonEmpty(value) ?? "sunnyhot/guanlan-dashboard"
    }

    static var defaultFeedURLString: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "QiemanUpdateFeedURL") as? String
        return nonEmpty(value) ?? "https://github.com/\(defaultRepository)/releases/latest/download/latest.json"
    }

    static var bundleVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return nonEmpty(value) ?? "0.0.0"
    }

    static func normalizedVersion(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("version-") {
            return String(trimmed.dropFirst("version-".count))
        }
        if trimmed.lowercased().hasPrefix("release-") {
            return String(trimmed.dropFirst("release-".count))
        }
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionParts(lhs)
        let rhsParts = versionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    static func releaseNotes(body: String?, notes: String?) -> String {
        nonEmpty(body) ?? nonEmpty(notes) ?? ""
    }

    private static func preferredAsset(from assets: [GitHubAssetPayload]) -> AppUpdateAsset? {
        let preferred = assets.first { asset in
            let name = asset.name.lowercased()
            return name.contains("qiemandashboard") && name.hasSuffix(".zip")
        } ?? assets.first { asset in
            asset.name.lowercased().hasSuffix(".zip")
        } ?? assets.first

        guard let preferred else { return nil }
        return AppUpdateAsset(
            name: preferred.name,
            downloadURL: preferred.browserDownloadURL,
            size: preferred.size,
            contentType: preferred.contentType
        )
    }

    /// Extract sha256 from the unified manifest "asset" object if embedded in assets array.
    /// The new manifest format has a top-level "sha256" field, but this serves as fallback.
    private static func sha256FromAssets(_ assets: [GitHubAssetPayload]) -> String? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }?.sha256
    }

    private static func versionParts(_ value: String) -> [Int] {
        normalizedVersion(value)
            .split { character in
                !(character.isNumber)
            }
            .map { Int($0) ?? 0 }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
