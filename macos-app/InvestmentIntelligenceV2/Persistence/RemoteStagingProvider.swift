import Foundation
import CryptoKit

// MARK: - RemoteStagingProvider（PROV-3b 客户端侧，ADR-DATA010）
//
// 远程 VPS collector（Python + nginx）产出 ProviderRecord JSONL（PROV-1 schema，
// 字节对齐 Swift Codable）+ manifest（每文件 sha256 + 可选 Ed25519 签名）。
// 本类型是 App 端接收面：拉 manifest → 比对本地 state 增量下载 → sha256 验完整
// → （可选）Ed25519 验签 → ProviderStagingReader 解析 → SchemaValidator 分桶
// → 合法记录 append 进本地 spool（复用 PROV-1 Reader/Writer/Validator，接收侧零特殊代码）。
//
// **降级铁律**（DATA010 §3）：本通道是 primary 增强，失败绝不阻塞——断路器打开期间
// sync 直接 .skipped；任何 .failed 由调用方降级到原生 provider（②），不重试硬冲。
// 签名/哈希失败 = 拒收对应内容（防注入），不污染本地 spool。
//
// **凭证边界**（DATA010 §4/Compliance）：只拉公开市场数据；X-Collector-Key 是
// 反白嫖 key，不是用户凭证；任何用户私有数据（且慢 cookie）不进本通道。
//
// VPS 部署（collector 定时任务 + nginx + Cloudflare）不在本文件范围——本文件 +
// 契约测试离线先行，服务端连通后端到端验收。

// MARK: - Manifest（服务端 manifest.json 契约，与 Python collector 对齐）

/// 远程 staging 清单（wire 格式：camelCase、ISO8601 UTC，与 PROV-3a 契约一致）。
struct RemoteStagingManifest: Sendable, Codable, Hashable {
    /// 清单格式版本（当前 1）
    let version: Int
    /// collector 版本（诊断 / schema 漂移排查）
    let collectorVersion: String
    /// 本批数据产出时间（新鲜度监控锚点）
    let generatedAt: Date
    let files: [File]

    struct File: Sendable, Codable, Hashable {
        /// 相对 base URL 的文件名（如 "stock_daily.jsonl"）
        let name: String
        /// 文件内容 sha256（小写 hex）
        let sha256: String
        let byteSize: Int
    }

    func file(named name: String) -> File? {
        files.first { $0.name == name }
    }
}

/// 本地已同步状态（name → sha256），持久化在 spool 目录旁，增量下载依据。
struct RemoteStagingLocalState: Sendable, Codable, Hashable {
    var fileHashes: [String: String] = [:]
    var lastSyncedAt: Date?

    init(fileHashes: [String: String] = [:], lastSyncedAt: Date? = nil) {
        self.fileHashes = fileHashes
        self.lastSyncedAt = lastSyncedAt
    }
}

/// 追加 journal（WAL 式两阶段提交，审查 P1：checkpoint 失败/崩溃后不得重复追加）。
///
/// 每次向 spool append **之前**原子写一条 journal（记录 append 前的 spool 字节
/// 偏移）；append → state checkpoint 成功后才清除。下次 sync 启动时先做恢复：
/// - state 已含该文件（checkpoint 成功但 journal 未清）→ 只清 journal；
/// - state 未含（append 后 checkpoint 失败/中途崩溃）→ 把 spool **截断回偏移**，
///   丢弃这次未提交的追加，再清 journal——重试后 spool 仍只有一份。
struct RemoteStagingJournal: Sendable, Codable, Hashable {
    let fileName: String
    let fileSha256: String
    /// append 前 spool 的字节偏移（恢复时截断到此）
    let spoolOffsetBefore: Int
}

// MARK: - Fetcher（生产 HTTP / 测试注入）

/// 远程 staging 拉取器。
protocol RemoteStagingFetcher: Sendable {
    /// 拉取 manifest.json 原始字节（验签需要原始字节，不在本层解码）。
    func fetchManifest() async throws -> Data
    /// 拉取 manifest.sig（Ed25519 签名，raw 64 字节）。未配置验签的部署不会被调用。
    func fetchManifestSignature() async throws -> Data
    /// 拉取 staging 文件原始字节。
    func fetchFile(_ name: String) async throws -> Data
}

enum RemoteStagingError: Error, Equatable, Hashable, Sendable {
    /// 配置错误（如 Ed25519 公钥字节非法）。**初始化即抛**，不静默降级为
    /// 「未启用验签」——验签开关是部署方显式声明的安全决策（审查 P1）
    case invalidConfiguration(detail: String)
    /// manifest 解析失败（schema 漂移——服务端 collector 版本与客户端不匹配）
    case malformedManifest(detail: String)
    /// Ed25519 验签失败（manifest 或签名被篡改——按被攻陷处理，拒收整批）
    case signatureVerificationFailed
    /// 文件 sha256 与 manifest 不符（拒收该文件）
    case integrityMismatch(file: String)
    /// 服务端鉴权/限流（403 无 key / 429 超限）——调用方降级，不重试硬冲
    case rejectedByServer(statusCode: Int)
    /// 网络 / 服务端不可用
    case unavailable(detail: String)
}

/// URLSession 拉取器（生产）。manifest / 文件 / 签名都在同一 base URL 下。
struct URLSessionRemoteStagingFetcher: RemoteStagingFetcher {
    private let baseURL: URL
    private let collectorKey: String?
    private let session: URLSession

    init(
        baseURL: URL,
        collectorKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.collectorKey = collectorKey
        self.session = session
    }

    func fetchManifest() async throws -> Data {
        try await get(baseURL.appendingPathComponent("manifest.json"))
    }

    func fetchManifestSignature() async throws -> Data {
        try await get(baseURL.appendingPathComponent("manifest.sig"))
    }

    func fetchFile(_ name: String) async throws -> Data {
        // 文件名来自 manifest（已验签/已拉取的白名单），仍拒绝路径穿越
        guard !name.contains("/"), !name.contains("..") else {
            throw RemoteStagingError.malformedManifest(detail: "illegal file name \(name)")
        }
        return try await get(baseURL.appendingPathComponent(name))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let collectorKey, !collectorKey.isEmpty {
            request.setValue(collectorKey, forHTTPHeaderField: "X-Collector-Key")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteStagingError.unavailable(detail: "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStagingError.unavailable(detail: "non-HTTP response")
        }
        // 403（无 key/错 key）、429（超限流）→ 明确降级语义（DATA010 §4）
        if http.statusCode == 403 || http.statusCode == 429 {
            throw RemoteStagingError.rejectedByServer(statusCode: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteStagingError.unavailable(detail: "http \(http.statusCode)")
        }
        return data
    }
}

// MARK: - 同步结果

/// 单次 sync 的结果摘要。
struct RemoteStagingSyncSummary: Sendable, Hashable {
    let manifestGeneratedAt: Date
    let collectorVersion: String
    let filesDownloaded: Int
    let filesUnchanged: Int
    /// sha256 不符被拒收的文件数（防注入；内容未进 spool）
    let filesRejectedTampered: Int
    /// 追加进本地 spool 的合法记录数
    let recordsAppended: Int
    /// SchemaValidator 拒收的记录数（结构非法，未进 spool）
    let recordsRejectedInvalidSchema: Int
    let syncedAt: Date
}

enum RemoteStagingSyncOutcome: Sendable, Hashable {
    /// manifest 处理完成（可能 0 文件变化 / 部分文件被拒收——看 summary）
    case synced(RemoteStagingSyncSummary)
    /// 断路器打开（前次失败退避中）——调用方直接走原生 provider，不重试
    case skipped(openUntil: Date)
    case failed(RemoteStagingError)
}

// MARK: - RemoteStagingProvider

/// 远程 staging 接收器（PROV-3b 客户端侧，ADR-DATA010 §1/§3/§5）。
///
/// sync 流程：
/// 1. 断路器检查（退避期内直接 .skipped，避免疯狂重试触发更严风控）
/// 2. 拉 manifest（原始字节）→（可选）Ed25519 验签 → 解码
/// 3. 比对本地 state：sha256 相同的文件跳过（增量，DATA010 §5）
/// 4. 下载变化文件 → sha256 校验（不符拒收该文件并计数）
/// 5. Reader 解析 JSONL → SchemaValidator 分桶 → 合法记录 append 本地 spool
/// 6. 持久化 state；成功重置断路器，失败累计并指数退避
actor RemoteStagingProvider {

    /// 断路器配置（DATA010 §3：连续失败指数退避）。
    struct CircuitBreakerConfig: Sendable, Hashable {
        /// 基础退避（首次失败后）
        let baseBackoff: TimeInterval
        /// 退避上限
        let maxBackoff: TimeInterval

        static let standard = CircuitBreakerConfig(baseBackoff: 60, maxBackoff: 15 * 60)

        func backoff(afterConsecutiveFailures failures: Int) -> TimeInterval {
            let exponent = max(0, failures - 1)
            let scaled = baseBackoff * pow(2, Double(exponent))
            return min(maxBackoff, scaled)
        }
    }

    private let fetcher: any RemoteStagingFetcher
    /// Ed25519 验签公钥（rawRepresentation 字节）。nil = 部署未启用签名（仅 sha256 完整性）
    private let signaturePublicKey: Curve25519.Signing.PublicKey?
    private let breakerConfig: CircuitBreakerConfig
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let now: @Sendable () -> Date

    private var consecutiveFailures = 0
    private var openUntil: Date?

    /// - Throws: `RemoteStagingError.invalidConfiguration`——公钥字节非法时抛错，
    ///   **不静默回退为「未启用验签」**（那是安全降级，必须让配置错误在启动时暴露，
    ///   审查 P1）。不想验签就显式传 nil。
    init(
        fetcher: any RemoteStagingFetcher,
        signaturePublicKey: Data? = nil,
        breakerConfig: CircuitBreakerConfig = .standard,
        now: @escaping @Sendable () -> Date = { .now }
    ) throws {
        self.fetcher = fetcher
        if let signaturePublicKey {
            guard let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signaturePublicKey
            ) else {
                throw RemoteStagingError.invalidConfiguration(
                    detail: "Ed25519 公钥字节非法（期望 32 字节 rawRepresentation）"
                )
            }
            self.signaturePublicKey = key
        } else {
            self.signaturePublicKey = nil
        }
        self.breakerConfig = breakerConfig
        self.now = now
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// 同步一轮远程 staging 到本地 spool。
    ///
    /// - Parameters:
    ///   - spoolURL: 本地 spool JSONL（合法记录 append 到此，复用 PROV-1 Writer）
    ///   - stateURL: 本地增量 state JSON（name → sha256 + lastSyncedAt）；
    ///     journal 固定存放在 `stateURL.appendingPathExtension("journal")`
    func sync(
        to spoolURL: URL,
        state stateURL: URL,
        validator: ProviderRecordSchemaValidator = ProviderRecordSchemaValidator(),
        writer: ProviderStagingWriter = ProviderStagingWriter()
    ) async -> RemoteStagingSyncOutcome {
        // 1. 恢复未提交 journal（审查 P1：必须在断路器判断**之前**——checkpoint
        // 失败会立即打开断路器，若恢复放在其后，退避期内的 sync 直接 .skipped，
        // journal 与未提交 spool 尾巴永远不会被清理。恢复是纯本地操作，不触网络）
        do {
            try Self.recoverPendingJournal(
                journalURL: Self.journalURL(for: stateURL),
                spoolURL: spoolURL,
                stateURL: stateURL,
                decoder: decoder
            )
        } catch {
            recordFailure()
            return .failed(.unavailable(detail: "journal recovery failed: \(error)"))
        }

        // 2. 断路器
        if let openUntil, now() < openUntil {
            return .skipped(openUntil: openUntil)
        }

        do {
            // state 读取/解码失败终止本轮（loadState 抛错，不当空 state——审查 P1：
            // 增基线错误会导致重复下载并再次追加）
            var state = try Self.loadState(from: stateURL, decoder: decoder)
            // 2. manifest：原始字节 →（可选）验签 → 解码
            let manifestData = try await fetcher.fetchManifest()
            if let key = signaturePublicKey {
                let signature = try await fetcher.fetchManifestSignature()
                guard key.isValidSignature(signature, for: manifestData) else {
                    // 验签失败按被攻陷处理：拒收整批 + 打开断路器（DATA010 §5）
                    recordFailure()
                    return .failed(.signatureVerificationFailed)
                }
            }
            let manifest: RemoteStagingManifest
            do {
                manifest = try decoder.decode(RemoteStagingManifest.self, from: manifestData)
            } catch {
                throw RemoteStagingError.malformedManifest(detail: "\(error)")
            }

            // 3-5. 增量下载 + 完整性 + 解析入库
            var downloaded = 0
            var unchanged = 0
            var tampered = 0
            var appended = 0
            var invalidSchema = 0

            for file in manifest.files {
                if state.fileHashes[file.name] == file.sha256 {
                    unchanged += 1
                    continue
                }
                let data = try await fetcher.fetchFile(file.name)
                guard Self.sha256Hex(data) == file.sha256.lowercased() else {
                    tampered += 1   // 拒收该文件，其余继续（内容未触碰 spool）
                    continue
                }
                let records: [ProviderRecord]
                do {
                    records = try ProviderStagingReader().decodeLines(from: data)
                } catch {
                    throw RemoteStagingError.malformedManifest(
                        detail: "\(file.name) not valid JSONL: \(error)"
                    )
                }
                let partition = validator.partition(records)
                if !partition.valid.isEmpty {
                    // 两阶段提交（审查 P1）：journal（记录 append 前偏移）→ append
                    // → checkpoint → 清 journal。checkpoint 失败时 journal 保留，
                    // 下轮恢复把 spool 截断回偏移——不依赖 Pipeline upsert 去重。
                    let offset = try Self.spoolSize(spoolURL)
                    try Self.writeJournal(
                        RemoteStagingJournal(
                            fileName: file.name,
                            fileSha256: file.sha256,
                            spoolOffsetBefore: offset
                        ),
                        to: Self.journalURL(for: stateURL),
                        encoder: encoder
                    )
                    try writer.append(partition.valid, to: spoolURL)
                    appended += partition.valid.count
                }
                invalidSchema += partition.invalid.count
                state.fileHashes[file.name] = file.sha256
                downloaded += 1
                // 逐文件 checkpoint：写入失败上抛为 .failed（journal 尚在，下轮恢复
                // 截断重试），绝不虚报 .synced
                try Self.saveState(state, to: stateURL, encoder: encoder)
                Self.clearJournal(Self.journalURL(for: stateURL))
            }

            // 6. 成功：记录 lastSyncedAt + 重置断路器
            state.lastSyncedAt = now()
            try Self.saveState(state, to: stateURL, encoder: encoder)
            consecutiveFailures = 0
            openUntil = nil

            return .synced(RemoteStagingSyncSummary(
                manifestGeneratedAt: manifest.generatedAt,
                collectorVersion: manifest.collectorVersion,
                filesDownloaded: downloaded,
                filesUnchanged: unchanged,
                filesRejectedTampered: tampered,
                recordsAppended: appended,
                recordsRejectedInvalidSchema: invalidSchema,
                syncedAt: now()
            ))
        } catch let e as RemoteStagingError {
            recordFailure()
            return .failed(e)
        } catch {
            recordFailure()
            return .failed(.unavailable(detail: "\(error)"))
        }
    }

    /// 断路器当前状态（诊断 / UI「远程增强暂不可用」提示用）。
    func breakerStatus() -> (consecutiveFailures: Int, openUntil: Date?) {
        (consecutiveFailures, openUntil)
    }

    // MARK: - Helpers

    private func recordFailure() {
        consecutiveFailures += 1
        openUntil = now().addingTimeInterval(
            breakerConfig.backoff(afterConsecutiveFailures: consecutiveFailures)
        )
    }

    /// journal 固定与 state 同目录同名 + `.journal` 后缀。
    private static func journalURL(for stateURL: URL) -> URL {
        stateURL.appendingPathExtension("journal")
    }

    /// 读取 state。**只有明确的 no-such-file 错误**才返回空 state（首次运行）；
    /// 其它任何读取/解码失败必须抛错（审查 P1：fileExists 前置不可靠——路径因
    /// 权限/I/O 错误无法检查时它也返回 false，会被误当首次运行；把读失败的
    /// state 当空 state，恢复逻辑会误判「未提交」并截断已提交的 spool——静默
    /// 数据丢失；同步主流程也会因增基线错误而重复下载追加）。
    private static func loadState(
        from url: URL, decoder: JSONDecoder
    ) throws -> RemoteStagingLocalState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return RemoteStagingLocalState()
        } catch {
            throw RemoteStagingError.unavailable(detail: "state read failed: \(error)")
        }
        do {
            return try decoder.decode(RemoteStagingLocalState.self, from: data)
        } catch {
            throw RemoteStagingError.unavailable(detail: "state decode failed: \(error)")
        }
    }

    /// 持久化 state。写入失败**上抛**（审查 P1：吞掉会让调用方误以为本轮已提交，
    /// 下次重下同一批文件造成 spool 重复追加）。
    private static func saveState(
        _ state: RemoteStagingLocalState, to url: URL, encoder: JSONEncoder
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw RemoteStagingError.unavailable(detail: "state encode failed: \(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw RemoteStagingError.unavailable(detail: "state write failed: \(error)")
        }
    }

    // MARK: Journal（WAL 式两阶段提交）

    private static func writeJournal(
        _ journal: RemoteStagingJournal, to url: URL, encoder: JSONEncoder
    ) throws {
        do {
            try encoder.encode(journal).write(to: url, options: .atomic)
        } catch {
            throw RemoteStagingError.unavailable(detail: "journal write failed: \(error)")
        }
    }

    /// 清 journal。失败可容忍：恢复逻辑幂等（state 已含该文件 → 只清不截断），
    /// 下轮 sync 会再清一次。
    private static func clearJournal(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// spool 当前字节大小。**只有明确的 no-such-file 错误**返回 0（首次 append
    /// 的合法场景，不用 fileExists 前置——它无法区分「不存在」与「查不了」）；
    /// 其它读不出大小的情况必须抛错（审查 P1：静默返回 0 会让 journal 记下错误
    /// 偏移，一旦 checkpoint 失败，恢复会把已提交的历史 spool 整体截断到 0）。
    private static func spoolSize(_ url: URL) throws -> Int {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return 0
        } catch {
            throw RemoteStagingError.unavailable(detail: "spool size unreadable: \(error)")
        }
        guard let size = (attrs[.size] as? NSNumber)?.intValue else {
            throw RemoteStagingError.unavailable(detail: "spool size missing from attributes")
        }
        return size
    }

    /// 恢复未提交 journal：
    /// - state 已含该文件（append → checkpoint 已成功，仅 journal 未清）→ 清 journal；
    /// - state 未含（checkpoint 失败/崩溃，spool 里是未提交的追加）→ 截断 spool
    ///   回 `spoolOffsetBefore` 再清 journal——重试后 spool 仍只有一份。
    /// 恢复自身失败（journal/state 读不了、解码不了、截断不了）**上抛终止本轮**
    /// （审查 P1：journal 存在但读取失败时若静默跳过恢复，spool 里的未提交追加
    /// 会留到后续轮次被重复下载再次追加；state 读取失败时若当空 state 处理，
    /// 已提交的 spool 会被误截断）。现场保留待重试或人工排查。
    private static func recoverPendingJournal(
        journalURL: URL,
        spoolURL: URL,
        stateURL: URL,
        decoder: JSONDecoder
    ) throws {
        let journalData: Data
        do {
            journalData = try Data(contentsOf: journalURL)
        } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return   // 明确没有 journal：无恢复工作（不用 fileExists——它无法区分
                     // 「不存在」与「因权限/IO 查不了」，审查 P1）
        } catch {
            throw RemoteStagingError.unavailable(detail: "journal read failed: \(error)")
        }
        let journal: RemoteStagingJournal
        do {
            journal = try decoder.decode(RemoteStagingJournal.self, from: journalData)
        } catch {
            // journal 本身损坏（半写不可能：.atomic；更可能是外部改动）——截断到
            // journal 里读不出偏移，保守拒绝本轮 sync
            throw RemoteStagingError.unavailable(detail: "journal decode failed: \(error)")
        }
        // state 判断穿透抛错：读不出/解不出的 state 不得当成空 state（否则把
        // 已提交文件误判为未提交 → 截断已提交 spool）
        let committed = try loadState(from: stateURL, decoder: decoder)
            .fileHashes[journal.fileName] == journal.fileSha256
        if !committed {
            try truncateSpool(spoolURL, toOffset: journal.spoolOffsetBefore)
        }
        clearJournal(journalURL)
    }

    /// 把 spool 截断到指定字节偏移（丢弃未提交的尾部追加）。
    ///
    /// 一致性防线（审查 P1）：
    /// - **负偏移拒绝**：合法 JSON 可解码出 `spoolOffsetBefore < 0`（语义损坏），
    ///   `max(0, offset)` 静默转 0 会清空整个 spool——先强制 `offset >= 0`；
    /// - 偏移**大于**当前大小时拒绝（spool 被外部缩短/替换过的现场，按 offset
    ///   截断等于误删，宁可失败上报）；
    /// - spool 缺失（明确的 no-such-file → size 0）只允许 `offset == 0`，
    ///   由上一条上界检查自然覆盖。
    private static func truncateSpool(_ url: URL, toOffset offset: Int) throws {
        guard offset >= 0 else {
            throw RemoteStagingError.unavailable(
                detail: "journal offset \(offset) is negative"
            )
        }
        let currentSize = try spoolSize(url)
        guard offset <= currentSize else {
            throw RemoteStagingError.unavailable(
                detail: "journal offset \(offset) > spool size \(currentSize)"
            )
        }
        if offset == currentSize {
            return   // 无尾可截（含 spool 缺失且 offset==0，或尾部本就为空）
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
        } catch {
            throw RemoteStagingError.unavailable(detail: "spool truncate failed: \(error)")
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ProviderStagingReader：内存字节解析（远程文件先验完整再落盘，不经本地中转文件）

extension ProviderStagingReader {
    /// 从内存 Data 解析 JSONL（与 read(from:) 相同容错：空行跳过，损坏行抛错）。
    /// 日期策略与 ProviderStaging.defaultDecoder 对齐（iso8601）。
    func decodeLines(from data: Data) throws -> [ProviderRecord] {
        guard let content = String(data: data, encoding: .utf8) else {
            throw ProviderStagingError.readFailed(detail: "not utf8")
        }
        let decoder = ProviderStaging.defaultDecoder
        var records: [ProviderRecord] = []
        let lines = content.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else {
                throw ProviderStagingError.malformedLine(lineNumber: idx + 1, detail: "not utf8")
            }
            do {
                records.append(try decoder.decode(ProviderRecord.self, from: lineData))
            } catch {
                throw ProviderStagingError.malformedLine(lineNumber: idx + 1, detail: "\(error)")
            }
        }
        return records
    }
}
