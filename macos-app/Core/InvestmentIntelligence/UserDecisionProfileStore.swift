import Foundation

// UserDecisionProfile 持久化 Store。
//
// 单文件 JSON,存一个 UserDecisionProfile(不是数组)。
// 单例配置对象,原子写 + 0o600。

struct UserDecisionProfileStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load(from fileURL: URL) throws -> UserDecisionProfile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(UserDecisionProfile.self, from: data)
    }

    func save(_ profile: UserDecisionProfile, to fileURL: URL) throws {
        let data = try encoder.encode(profile)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
