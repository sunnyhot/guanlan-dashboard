import Foundation

// UserDecisionProfile 持久化 Store。
//
// 单文件 JSON,存一个 UserDecisionProfile(不是数组)。
// 单例配置对象,原子写 + 0o600。

struct UserDecisionProfileStore {
    func load(from fileURL: URL) throws -> UserDecisionProfile {
        try JSONFilePersistence.load(
            UserDecisionProfile.self,
            from: fileURL,
            defaultValue: .default
        )
    }

    func save(_ profile: UserDecisionProfile, to fileURL: URL) throws {
        try JSONFilePersistence.save(profile, to: fileURL)
    }
}
