import Foundation

// MARK: - SyncKit（SYNC-2..5 共享的直接抓取 sync 基础设施）
//
// 直接 Provider（eastmoney / FRED / SEC，区别于 RemoteStagingProvider 远程通道）
// 的 sync 循环共享三件套：
// 1. `DirectSyncPaths`：spool / state 的目录布局（与 remote-staging 同住
//    V2 工作目录，ADR-DATA004——spool 是事实源、库是派生物，删库重放走 spool）；
// 2. `SyncStateStore`：增量游标状态的原子持久化（tmp+rename）；
//    读取 fail-closed——解码失败抛错不静默当空状态（对齐 RemoteStagingSync
//    的 state 语义：只有明确的「文件不存在」才算首轮）；
// 3. `SyncStateError`：state 持久化错误类型。
//
// 各 sync 引擎（FundNAVSync / FundHoldingSync / MacroSync）自带语义，
// 只复用这三个纯基础设施，不共享循环骨架（垂直切片，等三条链稳定再抽）。

// MARK: - 目录布局

/// 直接 Provider sync 的 spool / state 目录布局（App 数据目录内）。
///
/// ```
/// <AppData>/
/// └─ investment-intelligence-v2/
///    ├─ canonical.sqlite3                  ← CanonicalStorePaths
///    ├─ remote-staging/                    ← RemoteStagingSyncPaths（远程通道）
///    ├─ sync-spool/<name>.jsonl            ← 本类型：直接抓取 spool（append-only）
///    └─ sync-state/<name>.json             ← 本类型：增量游标状态（原子写）
/// ```
enum DirectSyncPaths {

    static func spoolURL(name: String, in dataDirectory: URL) -> URL {
        CanonicalStorePaths.workDirectory(in: dataDirectory)
            .appendingPathComponent("sync-spool", isDirectory: true)
            .appendingPathComponent("\(name).jsonl", isDirectory: false)
    }

    static func stateURL(name: String, in dataDirectory: URL) -> URL {
        CanonicalStorePaths.workDirectory(in: dataDirectory)
            .appendingPathComponent("sync-state", isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
    }

    /// spool 追加前保证父目录存在（幂等；state 写入同理）。
    static func ensureDirectories(in dataDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: CanonicalStorePaths.workDirectory(in: dataDirectory)
                .appendingPathComponent("sync-spool", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: CanonicalStorePaths.workDirectory(in: dataDirectory)
                .appendingPathComponent("sync-state", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - 状态持久化

/// sync 状态持久化错误（fail-closed：坏状态不静默当空）。
enum SyncStateError: Error, Equatable, Sendable {
    /// 状态文件存在但读不出（权限 / IO——区别于「不存在」）
    case unreadable(underlying: String)
    /// 状态文件内容损坏或与声明版本不匹配（解不出目标类型）
    case corrupt(detail: String)
    /// 原子写失败（tmp 写入或 rename 阶段）
    case writeFailed(underlying: String)
}

/// 非泛型命名空间：泛型类型不支持 static stored property，codec 放这里
///（JSONEncoder/JSONDecoder 线程安全，静态实例免每轮重建）。
private enum SyncStateCodec {
    /// ISO8601 毫秒（与 CanonicalColumnCodec 时间戳约定一致，人可读可排序）。
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(CanonicalColumnCodec.encodeTimestamp(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let raw = try c.decode(String.self)
            do {
                return try CanonicalColumnCodec.decodeTimestamp(raw)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "非法时间戳 \(raw)"
                )
            }
        }
        return d
    }()
}

/// 增量游标状态的 JSON 原子持久化（tmp + rename，同一份语义供 SYNC-3/4/5 复用）。
struct SyncStateStore<State: Codable & Sendable>: Sendable {

    init() {}

    /// 读取状态。文件不存在 → nil（首轮）；存在但读不出/解不出 → 抛错
    /// （fail-closed：坏状态当空状态会把游标归零、重复抓取甚至误判进度）。
    func load(from url: URL) throws -> State? {
        do {
            let data = try Data(contentsOf: url)
            return try SyncStateCodec.decoder.decode(State.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as DecodingError {
            throw SyncStateError.corrupt(detail: "\(error)")
        } catch {
            throw SyncStateError.unreadable(underlying: "\(error)")
        }
    }

    /// 原子写（tmp + rename）：读到一半的旧文件或写一半的新文件都不会出现。
    func save(_ state: State, to url: URL) throws {
        let data: Data
        do {
            data = try SyncStateCodec.encoder.encode(state)
        } catch {
            throw SyncStateError.corrupt(detail: "编码失败：\(error)")
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: tmp, options: [.atomic])
            // replaceItemAt 走安全替换（目标存在时原子覆盖；moveItem 会撞已存在）
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SyncStateError.writeFailed(underlying: "\(error)")
        }
    }
}
