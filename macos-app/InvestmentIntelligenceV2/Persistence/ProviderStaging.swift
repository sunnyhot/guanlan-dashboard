import Foundation

// MARK: - ProviderStaging（PROV-1，ADR-DATA003 §Decision 3 Pipeline 第 1 步）
//
// Provider Adapter 产 ProviderRecord 后，先落地为 JSONL spool（一对象一行），
// 再由 Data Pipeline（GRDB-8）读取 → IdentityResolver → TemporalNormalizer →
// SchemaValidator → DataValidator → Canonical Commit。
//
// 为什么 JSONL 而非单 JSON 数组：spool 是 append-only 的，每次抓取追加一批；
// JSONL 支持 O(1) 追加、按行容错（单行损坏不影响其他行）、流式读取。
// 目录级编排（按 provider/日期分文件）留 Epic 6 Sync；PROV-1 定义格式 + 单文件读写。
//
// ProviderRecord 本身 Codable（默认 camelCase），staging 直接序列化。本格式是
// 内部 spool（不跨系统交换），无需 snake_case 迁移契约。

/// ProviderStaging 读写错误。
enum ProviderStagingError: Error, Equatable, Sendable {
    /// 写入失败（IO / 编码）
    case writeFailed(detail: String)
    /// 读取失败（文件不存在 / IO）
    case readFailed(detail: String)
    /// 某行不是合法的 ProviderRecord JSON。记录行号便于排查 spool 损坏。
    case malformedLine(lineNumber: Int, detail: String)
}

/// ProviderStaging 写入器：把 [ProviderRecord] 序列化为 JSONL。
///
/// 两种模式：
/// - `write`：覆盖写（整批落盘，适合一次性导出 / 测试）
/// - `append`：追加写（每次抓取追加一批，适合生产 spool）
struct ProviderStagingWriter: Sendable {
    private let encoder: JSONEncoder

    init(encoder: JSONEncoder = ProviderStaging.defaultEncoder) {
        self.encoder = encoder
    }

    /// 覆盖写：把 records 写成 JSONL（每行一条），覆盖已有文件。
    @discardableResult
    func write(_ records: [ProviderRecord], to url: URL) throws -> Self {
        let lines = try records.map { record in
            do { return try encoder.encode(record) }
            catch { throw ProviderStagingError.writeFailed(detail: "encode failed: \(error)") }
        }
        let data = Data(lines.flatMap { Array($0) + [0x0A] })   // 每条后加换行
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProviderStagingError.writeFailed(detail: "\(error)")
        }
        return self
    }

    /// 追加写：把 records 追加到已有 spool 末尾（文件不存在则创建）。
    @discardableResult
    func append(_ records: [ProviderRecord], to url: URL) throws -> Self {
        let chunk = try records.map { record -> Data in
            do { return try encoder.encode(record) }
            catch { throw ProviderStagingError.writeFailed(detail: "encode failed: \(error)") }
        }
        let data = Data(chunk.flatMap { Array($0) + [0x0A] })
        do {
            // .atomic 与追加语义冲突；追加用尾部写入
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 文件不存在时 FileHandle(forWritingTo:) 抛错 → 先创建再追加
            if FileManager.default.fileExists(atPath: url.path) == false {
                try write(records, to: url)
                return self
            }
            throw ProviderStagingError.writeFailed(detail: "\(error)")
        }
        return self
    }
}

/// ProviderStaging 读取器：从 JSONL spool 读出 [ProviderRecord]。
///
/// 容错策略：空行跳过；单行损坏默认抛 malformedLine（不静默吞，与
/// EastmoneyResponseParser 的 schema 漂移策略一致）。调用方可按需决定降级。
struct ProviderStagingReader: Sendable {
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = ProviderStaging.defaultDecoder) {
        self.decoder = decoder
    }

    /// 读取整个 spool。空行跳过；损坏行抛 malformedLine（带行号）。
    func read(from url: URL) throws -> [ProviderRecord] {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ProviderStagingError.readFailed(detail: "\(error)")
        }
        var records: [ProviderRecord] = []
        let lines = content.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }   // 空行跳过（含文件末尾换行产生的空行）
            guard let data = trimmed.data(using: .utf8) else {
                throw ProviderStagingError.malformedLine(lineNumber: idx + 1, detail: "not utf8")
            }
            do {
                records.append(try decoder.decode(ProviderRecord.self, from: data))
            } catch {
                throw ProviderStagingError.malformedLine(lineNumber: idx + 1, detail: "\(error)")
            }
        }
        return records
    }
}

// MARK: - 默认编解码器（共享，避免重复构造 + 保证读写对称）

extension ProviderStaging {
    /// 默认 encoder：dateStrategy = .iso8601（可读，spool 是人可排查的中间产物）。
    static let defaultEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()

    /// 默认 decoder：dateStrategy = .iso8601（与 encoder 对称）。
    static let defaultDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}

/// 命名空间占位（defaultEncoder/Decoder 的宿主）。
enum ProviderStaging {}
