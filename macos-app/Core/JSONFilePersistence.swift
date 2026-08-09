import Foundation

/// JSON 文件 Store 共用的底层读写能力。
///
/// 领域 Store 仍负责默认值、迁移和排序等业务规则；这里仅统一目录创建、
/// pretty/sorted 编码、原子写入、文件权限和缺文件处理。
enum JSONFilePersistence {
    static func load<Value: Decodable>(
        _ type: Value.Type,
        from fileURL: URL,
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default
    ) throws -> Value? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(type, from: data)
    }

    static func load<Value: Decodable>(
        _ type: Value.Type,
        from fileURL: URL,
        defaultValue: @autoclosure () -> Value,
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default
    ) throws -> Value {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return defaultValue()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(type, from: data)
    }

    static func save<Value: Encodable>(
        _ value: Value,
        to fileURL: URL,
        encoder: JSONEncoder? = nil,
        filePermissions: Int? = 0o600,
        fileManager: FileManager = .default
    ) throws {
        let resolvedEncoder = encoder ?? prettyPrintedEncoder()
        let data = try resolvedEncoder.encode(value)
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if filePermissions != nil {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        }
        try data.write(to: fileURL, options: .atomic)
        if let filePermissions {
            try? fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: fileURL.path
            )
        }
    }

    static func delete(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    static func prettyPrintedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
