import Foundation

// MARK: - AKShare 本地 Collector 对接（PROV-3a，ADR-DATA007 进程外隔离）
//
// Python Collector（../Collector/akshare_collector.py）在 macOS App 进程外独立运行，
// 产 ProviderRecord JSONL staging（PROV-1 schema）+ manifest.json。本文件是 Swift 侧
// 的三块对接能力：
//
// 1. `AKShareStagingManifest` —— manifest.json 模型（Codable，与 Python 侧字段对齐）
// 2. `AKShareStagingIngestor` —— 读 manifest → 按 dataset 读 JSONL → SchemaValidator
//    分桶 → 追加到 App 侧 ProviderStaging spool。单 dataset 失败（文件缺 / sha256
//    不符 / 行损坏 / 全部非法）只标记该 dataset 状态，不影响其他 dataset（DATA007
//    失败隔离）。**不写 Canonical**—— Canonical 化由 commit pipeline（GRDB-8）完成。
// 3. `AKShareLocalCollectorLauncher` —— 仅 macOS（`#if os(macOS)`）：进程外运行
//    Python collector（可选安装），带 watchdog 超时。iOS 编译期排除（DATA007 不进 iOS）。
//
// DATA007 §Compliance：主进程不 import Python、不内嵌 Python runtime；Collector
// 崩溃 / 超时只丢本轮 staging。akshare ProviderID 已在 CanonicalIDs.swift 登记。

// MARK: - manifest 模型（与 akshare_collector.py write_json_atomic 输出对齐）

/// Collector 一次运行的 manifest.json。
struct AKShareStagingManifest: Sendable, Codable, Hashable {
    /// Collector 版本（可审计，DATA007 §Decision 4）
    let collectorVersion: String
    /// staging 产出时刻（ISO8601 UTC）
    let generatedAt: Date
    /// "collect"（真实抓取）或 "selftest"（离线自检）
    let mode: String
    /// 每 dataset 的独立状态（DATA007 §Decision 5：独立 staging 文件 + 独立异常处理）
    let datasets: [String: DatasetStatus]

    struct DatasetStatus: Sendable, Codable, Hashable {
        /// "ok" / "error"
        let status: String
        let recordCount: Int
        /// 解析中按原因分桶的丢弃计数（如 {"malformed_row": 2}）
        let droppedMalformed: [String: Int]
        /// 失败分类：environment / network / not_found / schema / internal
        let errorCategory: String?
        /// 失败原始信息（可诊断输出，含上游异常文本）
        let errorMessage: String?
        /// staging 文件名（相对 manifest 所在目录）；失败为 nil
        let file: String?
        /// 文件 sha256（完整性核对；失败为 nil）
        let sha256: String?

        var isOK: Bool { status == "ok" }
    }

    var okDatasetCount: Int { datasets.values.filter(\.isOK).count }
    var failedDatasetCount: Int { datasets.count - okDatasetCount }
}

// MARK: - 单 dataset 摄取结果（失败隔离的可诊断出口）

/// 一个 dataset 的摄取结果（成功或带分类的失败）。
struct AKShareDatasetIngestResult: Sendable, Equatable {
    let dataset: AKShareDataset
    /// 通过 SchemaValidator 并写入 spool 的记录数（失败时 0）
    let stagedCount: Int
    /// 被SchemaValidator 拒收的记录数（非法行不污染 spool，DATA003 Pipeline）
    let rejectedCount: Int
    /// 摄取失败分类（文件缺 / sha256 不符 / 损坏行 / manifest 报错）
    let failure: AKShareIngestFailure?

    var isSuccess: Bool { failure == nil }
}

/// dataset 标识（rawValue 与 Python 侧 dataset 名对齐）。
enum AKShareDataset: String, Sendable, Codable, Hashable, CaseIterable {
    /// A 股个股日线（stock_zh_a_hist）→ DAILY_BAR
    case stockDaily = "stock_daily"
    /// 指数日线（index_zh_a_hist）→ DAILY_BAR
    case indexDaily = "index_daily"
    /// 场外基金净值（fund_open_fund_info_em）→ NAV_OBSERVATION
    case fundNAV = "fund_nav"
    /// 基金季度持仓（fund_portfolio_hold_em）→ FUND_HOLDING_SNAPSHOT
    case fundHoldings = "fund_holdings"
    /// 中国宏观序列（macro_china_*）→ MACRO_OBSERVATION
    case macroChina = "macro_china"

    /// staging 文件名（与 Python 侧约定一致）。
    var fileName: String { "\(rawValue).jsonl" }
}

/// 单 dataset 摄取失败分类（可诊断输出）。
enum AKShareIngestFailure: Sendable, Equatable, Error {
    /// manifest 里该 dataset 是 error（Python 侧已分类）
    case collectorReported(category: String, message: String)
    /// manifest 标 ok 但文件缺失
    case fileMissing(fileName: String)
    /// 文件内容 sha256 与 manifest 不符（部分写入 / 外部篡改）
    case checksumMismatch(fileName: String)
    /// JSONL 有损坏行（带行号；已读到的合法行仍摄取，坏行计数）
    case malformedLine(lineNumber: Int, detail: String)
    /// 全部行都无法通过 SchemaValidator（schema 漂移信号）
    case allRecordsRejected(total: Int, detail: String)
}

// MARK: - Staging 摄取器（失败隔离：单 dataset 失败不影响其他）

/// 读 collector staging 目录 → 验证 → 追加到 App 侧 ProviderStaging spool。
///
/// 与 `ProviderAdapter.fetchAndStage` 的分工：那是「Swift Adapter 抓 HTTP → 落盘」；
/// 本类是「进程外 Python collector 已产 staging → 校验搬运」。两者都只到 staging，
/// 都过 SchemaValidator，Canonical 化统一走 commit pipeline。
struct AKShareStagingIngestor: Sendable {
    private let reader: ProviderStagingReader
    private let writer: ProviderStagingWriter
    private let validator: ProviderRecordSchemaValidator
    private let verifyChecksums: Bool

    init(
        reader: ProviderStagingReader = ProviderStagingReader(),
        writer: ProviderStagingWriter = ProviderStagingWriter(),
        validator: ProviderRecordSchemaValidator = ProviderRecordSchemaValidator(),
        verifyChecksums: Bool = true
    ) {
        self.reader = reader
        self.writer = writer
        self.validator = validator
        self.verifyChecksums = verifyChecksums
    }

    /// 摄取整个 staging 目录（manifest 列出的全部 dataset）。
    ///
    /// 逐 dataset 独立处理：任何失败（含抛错）都收敛进该 dataset 的
    /// `AKShareIngestResult.failure`，循环继续（DATA007 失败隔离）。
    /// manifest 本身读不了才整目录失败。
    func ingest(
        from stagingDirectory: URL,
        toSpool spoolURL: URL
    ) throws -> (manifest: AKShareStagingManifest, results: [AKShareDatasetIngestResult]) {
        let manifestURL = stagingDirectory.appendingPathComponent("manifest.json")
        let manifest: AKShareStagingManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try ProviderStaging.defaultDecoder.decode(AKShareStagingManifest.self, from: data)
        } catch {
            throw ProviderStagingError.readFailed(detail: "manifest.json: \(error)")
        }

        // 按 AKShareDataset 声明序处理；manifest 里的未知 dataset key（未来 collector
        // 新增）跳过不摄取——旧 App 对新 collector 前向兼容。
        var results: [AKShareDatasetIngestResult] = []
        for dataset in AKShareDataset.allCases {
            guard let status = manifest.datasets[dataset.rawValue] else { continue }
            results.append(ingestDataset(status, dataset: dataset, directory: stagingDirectory, spoolURL: spoolURL))
        }
        return (manifest, results)
    }

    /// 摄取单个 dataset（独立异常处理单位，DATA007 §Decision 5）。
    private func ingestDataset(
        _ status: AKShareStagingManifest.DatasetStatus,
        dataset: AKShareDataset,
        directory: URL,
        spoolURL: URL
    ) -> AKShareDatasetIngestResult {
        // 1. Python 侧已报错 → 直接透传分类（不碰文件）
        guard status.isOK else {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: 0,
                failure: .collectorReported(
                    category: status.errorCategory ?? "unknown",
                    message: status.errorMessage ?? "collector reported error without message"
                )
            )
        }
        // 2. 文件必须存在
        guard let fileName = status.file else {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: 0,
                failure: .fileMissing(fileName: dataset.fileName)
            )
        }
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: 0,
                failure: .fileMissing(fileName: fileName)
            )
        }
        // 3. sha256 完整性（DATA010 §5 的完整性思路在本地目录同样适用）
        if verifyChecksums, let expected = status.sha256 {
            let actual = Self.sha256Hex(ofFile: fileURL)
            guard actual == expected.lowercased() else {
                return AKShareDatasetIngestResult(
                    dataset: dataset, stagedCount: 0, rejectedCount: 0,
                    failure: .checksumMismatch(fileName: fileName)
                )
            }
        }
        // 4. 读 JSONL（坏行让整文件失败——追加语义下部分摄取会破坏行完整性审计；
        //    Python 侧原子写保证正常路径不会出现半行，损坏行意味着外部干扰）
        let records: [ProviderRecord]
        do {
            records = try reader.read(from: fileURL)
        } catch let e as ProviderStagingError {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: 0,
                failure: Self.failure(for: e, fileName: fileName)
            )
        } catch {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: 0,
                failure: .malformedLine(lineNumber: 0, detail: "\(error)")
            )
        }
        // 5. SchemaValidator 分桶：非法记录不污染 spool（DATA003 Pipeline 第 4 步）
        let (valid, invalid) = validator.partition(records)
        if valid.isEmpty {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: invalid.count,
                failure: .allRecordsRejected(
                    total: records.count,
                    detail: invalid.first.map { "\($0.error)" } ?? "zero records"
                )
            )
        }
        // 6. 追加到 App spool（append：每轮抓取追加一批，生产 spool 语义）
        do {
            try writer.append(valid, to: spoolURL)
        } catch {
            return AKShareDatasetIngestResult(
                dataset: dataset, stagedCount: 0, rejectedCount: invalid.count,
                failure: .malformedLine(lineNumber: 0, detail: "spool append failed: \(error)")
            )
        }
        return AKShareDatasetIngestResult(
            dataset: dataset, stagedCount: valid.count, rejectedCount: invalid.count, failure: nil
        )
    }

    private static func failure(
        for error: ProviderStagingError, fileName: String
    ) -> AKShareIngestFailure {
        switch error {
        case .malformedLine(let line, let detail):
            return .malformedLine(lineNumber: line, detail: detail)
        case .readFailed(let detail):
            return .malformedLine(lineNumber: 0, detail: "\(fileName): \(detail)")
        case .writeFailed(let detail):
            return .malformedLine(lineNumber: 0, detail: "\(fileName): \(detail)")
        }
    }

    private static func sha256Hex(ofFile url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit

#if os(macOS)

// MARK: - 进程外 Launcher（仅 macOS；iOS 编译期排除，DATA007 §Decision 2）

/// AKShare Collector 运行错误。
enum AKShareCollectorError: Error, Equatable, Sendable {
    /// Python 解释器不存在（可选组件未安装）
    case pythonNotFound(detail: String)
    /// Collector 脚本不存在（App 内资源缺失）
    case scriptNotFound(path: String)
    /// 进程启动失败
    case launchFailed(detail: String)
    /// watchdog 超时（DATA007 §Decision 3：卡死由主进程杀掉，不影响 UI）
    case timedOut(seconds: TimeInterval)
    /// 退出码非 0（部分 dataset 失败 exit 1 / 环境 error exit 2）
    case nonzeroExit(code: Int32, stderrTail: String)
}

/// 进程外运行 Python AKShare Collector（macOS only）。
///
/// DATA007 合规：Process 子进程独立崩溃 / 独立超时（watchdog 杀进程而非等待）；
/// 主进程只读它落盘的 staging。iOS 无此类型（`#if os(macOS)`）。
///
/// 测试注入点：`processFactory` 允许注入替身 Process（不真正跑 Python），
/// 真实联调（本机装有 akshare）走默认 factory。
struct AKShareLocalCollectorLauncher: Sendable {
    /// Python 解释器候选（可选安装：用户可能用 brew / 系统 python3）
    var pythonCandidates: [String] = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]
    /// watchdog：超时杀进程（默认 5 分钟，历史回填足够；intraday 不在此场景）
    var timeoutSeconds: TimeInterval = 300
    /// 单独可注入的时钟 / 进程工厂（测试不真跑 Python）
    private let processFactory: @Sendable () -> CollectorProcess

    init(processFactory: @escaping @Sendable () -> CollectorProcess = { RealCollectorProcess() }) {
        self.processFactory = processFactory
    }

    /// 运行 collector 一次。
    ///
    /// - Parameters:
    ///   - scriptURL: akshare_collector.py 位置
    ///   - outDir: staging 输出目录（manifest.json + {dataset}.jsonl）
    ///   - configURL: 可选 --config
    ///   - datasets: 只跑指定 dataset（nil = 全部）
    ///   - selftest: 离线自检模式（不联网；跨语言契约测试用）
    ///   - extraArguments: 额外透传参数（如 --hang-ms，watchdog 测试用）
    func run(
        scriptURL: URL,
        outDir: URL,
        configURL: URL? = nil,
        datasets: [AKShareDataset]? = nil,
        selftest: Bool = false,
        extraArguments: [String] = []
    ) async throws {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw AKShareCollectorError.scriptNotFound(path: scriptURL.path)
        }
        // 十一轮 P3:pythonCandidates 可注入空数组(测试/配置构造)——
        // fallback 缺失时抛 pythonNotFound(可恢复的数据校验错误),
        // 不崩进程(原 pythonCandidates.last! 强解包)
        guard let fallback = pythonCandidates.last else {
            throw AKShareCollectorError.pythonNotFound(
                detail: "pythonCandidates 为空——没有可用的 Python 解释器候选")
        }
        let python = pythonCandidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? fallback

        var arguments = [scriptURL.path, "--out-dir", outDir.path]
        if let configURL { arguments += ["--config", configURL.path] }
        if let datasets, !datasets.isEmpty {
            arguments += ["--dataset", datasets.map(\.rawValue).joined(separator: ",")]
        }
        if selftest { arguments += ["--selftest"] }
        arguments += extraArguments

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let process = processFactory()
        let stderrTail = StderrTail(capacity: 4000)
        do {
            try process.launch(pythonPath: python, arguments: arguments, stderrSink: stderrTail.append)
        } catch {
            throw AKShareCollectorError.launchFailed(detail: "\(error)")
        }

        // watchdog：超时先杀进程再抛（不 await 已死进程）
        let exitCode: Int32 = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await process.waitUntilExit() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                process.terminate()
                throw AKShareCollectorError.timedOut(seconds: self.timeoutSeconds)
            }
            let first = try await group.next() ?? -1
            group.cancelAll()
            return first
        }

        guard exitCode == 0 else {
            throw AKShareCollectorError.nonzeroExit(code: exitCode, stderrTail: stderrTail.text)
        }
    }
}

// MARK: - 进程抽象（测试可注入）

/// Launcher 依赖的最小进程接口（真实实现包 Process；测试用替身）。
protocol CollectorProcess: Sendable {
    func launch(pythonPath: String, arguments: [String], stderrSink: @escaping @Sendable (String) -> Void) throws
    func waitUntilExit() async throws -> Int32
    func terminate()
}

/// 真实 Process 实现（class：Process 状态跨 launch/wait 调用可变）。
private final class RealCollectorProcess: CollectorProcess, @unchecked Sendable {
    private let process = Process()
    private nonisolated(unsafe) var stderrPipe: Pipe?

    func launch(pythonPath: String, arguments: [String], stderrSink: @escaping @Sendable (String) -> Void) throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        process.standardError = pipe
        process.standardOutput = pipe   // collector 的进度行也进 stderr 汇总
        process.environment = ProcessInfo.processInfo.environment
        stderrPipe = pipe
        // 读端持续转发到 sink（后台线程；文件句柄生命周期随进程）
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: chunk, encoding: .utf8) {
                stderrSink(text)
            }
        }
        do {
            try process.run()
        } catch {
            // 启动失败（python 路径无效等）：区分「解释器不存在」
            if !FileManager.default.fileExists(atPath: pythonPath) {
                throw AKShareCollectorError.pythonNotFound(detail: pythonPath)
            }
            throw error
        }
    }

    func waitUntilExit() async throws -> Int32 {
        // Process 没有原生 async 等待；轮询 + Task.yield（子进程独立运行，不阻塞线程）
        while process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// stderr / stdout 尾部环形缓冲（错误上报带最后 N 字符，可诊断输出）。
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: Data = Data()
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var append: @Sendable (String) -> Void {
        // @Sendable 入口（readabilityHandler 线程调用；NSLock 串行化 buffer 访问）
        { [weak self] text in
            guard let self else { return }
            let data = text.data(using: .utf8) ?? Data()
            self.lock.lock()
            self.buffer.append(data)
            if self.buffer.count > self.capacity {
                self.buffer = self.buffer.suffix(self.capacity)
            }
            self.lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}

#endif
