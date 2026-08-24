import Foundation

// MARK: - CanonicalColumnCodec（GRDB-2..6 共享的列编解码约定）
//
// Canonical Store 各表的非原生列（Date / Decimal / JSON 数组）统一在此编解码，
// 保证跨表一致：
//
// - **时间戳**：ISO8601 UTC + 毫秒小数秒（`2026-08-24T09:30:00.000Z`）。
//   该格式**字典序 = 时间序**，PIT 查询（`availableAt <= asOf` 类）可以在 SQL 里
//   直接做字符串比较，不需要把整列读回 Swift 再比。毫秒精度覆盖 ingestedAt
//   的排序需求（更细粒度对 Canonical 语义无意义）。
// - **Decimal**：TEXT 存储（`NSDecimalNumber` description），十进制精度无损，
//   不走 Double（浮点误差会污染 Factor / 费率语义）。
// - **JSON 子文档**（regulatoryIDs / feeStructure 等）：TEXT 存 JSON 编码，
//   由各表 row codec 自行定义 Codable 类型后借用这里的 encoder/decoder。

/// Canonical Store 列编解码（纯函数命名空间）。
enum CanonicalColumnCodec {

    // MARK: - 时间戳（ISO8601 UTC 毫秒）

    /// 线程安全：`ISO8601DateFormatter` 文档明确线程安全（与 NSDateFormatter 不同），
    /// 静态实例避免每次编码重建（GRDB-3 行情批量入库时是热路径）。
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Date → ISO8601 UTC 毫秒字符串（落库形态）。
    static func encodeTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// ISO8601 UTC 毫秒字符串 → Date。非法格式抛错（fail-closed，不静默回落
    /// 秒级解析——库里的列由本 codec 写入，读不回来说明库被外部改过）。
    static func decodeTimestamp(_ raw: String) throws -> Date {
        guard let date = timestampFormatter.date(from: raw) else {
            throw CanonicalColumnCodecError.malformedTimestamp(raw)
        }
        return date
    }

    // MARK: - Decimal（TEXT 保精度）

    static func encodeDecimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description
    }

    /// TEXT → Decimal。非法格式抛错（不静默 0）。
    static func decodeDecimal(_ raw: String) throws -> Decimal {
        guard let value = Decimal(string: raw) else {
            throw CanonicalColumnCodecError.malformedDecimal(raw)
        }
        return value
    }

    // MARK: - JSON 子文档

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // 确定性输出：同值同字节，便于对账
        return e
    }()

    private static let jsonDecoder: JSONDecoder = JSONDecoder()

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(data: try jsonEncoder.encode(value), encoding: .utf8) ?? ""
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw CanonicalColumnCodecError.malformedJSON(raw)
        }
        return try jsonDecoder.decode(type, from: data)
    }
}

/// 列编解码失败（库内容与 codec 约定不符——理论上只有外部改库才会触发）。
enum CanonicalColumnCodecError: Error, Equatable, CustomStringConvertible {
    case malformedTimestamp(String)
    case malformedDecimal(String)
    case malformedJSON(String)

    var description: String {
        switch self {
        case .malformedTimestamp(let raw): return "CanonicalColumnCodec: 非法时间戳列值 \(raw)"
        case .malformedDecimal(let raw): return "CanonicalColumnCodec: 非法 Decimal 列值 \(raw)"
        case .malformedJSON(let raw): return "CanonicalColumnCodec: 非法 JSON 列值 \(raw)"
        }
    }
}
