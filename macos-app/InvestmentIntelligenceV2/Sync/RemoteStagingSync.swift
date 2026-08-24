import CryptoKit
import Foundation

// MARK: - RemoteStagingSync（PROV-3b App 生产接线，ADR-DATA010 接收面入口）
//
// RemoteStagingProvider（Persistence/）已具备完整接收语义（快照固定读取 / 验签 /
// sha256 / 增量 / journal 两阶段提交 / 断路器），但此前零生产调用点。本文件补
// 生产接线三件套（SYNC-2 Market Daily Sync 的入口工作）：
// 1. `RemoteStagingSyncConfig` + Store：部署配置面（baseURL / X-Collector-Key /
//    验签公钥），JSON 文件持久化在 App 数据目录，默认关闭（未配置 = 不运行）；
// 2. `RemoteStagingSyncPaths`：spool / state 的目录布局；
// 3. `RemoteStagingSyncSetup`：config → fetcher+provider 的装配结果，
//    **配置错误显式上报不静默降级**（非法公钥 → .misconfigured，绝不回退
//    「未启用验签」——与 RemoteStagingProvider.init 的 fail-loud 语义一致）。
//
// 降级铁律不变（DATA010 §3）：本通道失败绝不阻塞主流程——断路器退避期内 sync
// 返回 .skipped，任何 .failed 只记录诊断，不重试硬冲、不影响原生 provider。

// MARK: - 配置

/// 远程 staging 同步配置（用户可编辑，JSON 落盘在 App 数据目录顶层）。
///
/// 默认 `disabled`：PROV-3b 是「默认路径」但按部署 opt-in——用户部署好自己的
/// VPS collector（remote-collector/README）后填写本文件启用；未配置/未启用时
/// App 零网络行为、零后台任务。
struct RemoteStagingSyncConfig: Sendable, Codable, Hashable {
    /// 是否启用远程增强通道（默认 false）
    var enabled: Bool
    /// 发布根 URL（nginx 托管 snapshot.txt + snapshots/，如 https://vps.example.com/staging）
    var baseURL: String
    /// 反白嫖 key（X-Collector-Key；nil/空 = 服务端未开鉴权）
    var collectorKey: String?
    /// Ed25519 验签公钥（raw 32 字节的 base64——remote_publish.py --generate-key
    /// stdout 打印的形态）。nil = 该部署未启用签名（仅 sha256 完整性）。
    var signaturePublicKeyBase64: String?

    static let disabled = RemoteStagingSyncConfig(
        enabled: false, baseURL: "", collectorKey: nil, signaturePublicKeyBase64: nil
    )

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCollectorKey: String? {
        guard let key = collectorKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    var trimmedSignaturePublicKeyBase64: String? {
        guard let key = signaturePublicKeyBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// base URL 合法性：必须是可以构造 http(s) URL 且带 host 的绝对地址
    /// （作为 URLSession 请求根，路径穿越类风险由 fetcher 侧白名单兜底）。
    var normalizedBaseURL: URL? {
        guard let url = URL(string: trimmedBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 配置是否足以启动 sync 循环（enabled + 合法 baseURL）。
    var isRunnable: Bool {
        enabled && normalizedBaseURL != nil
    }
}

/// 配置读写错误。
enum RemoteStagingSyncConfigError: Error, Equatable, Sendable {
    /// 文件存在但读不出（权限 / IO）——fail-closed 上报，不当「未配置」
    case unreadable(String)
    /// JSON / 字段非法
    case malformed(String)
    case writeFailed(String)
}

/// 配置文件读写（纯函数，无状态；模式同 AlfaPortfolioStore）。
enum RemoteStagingSyncConfigStore {

    /// 读取配置。文件不存在返回 nil（首次运行 = 默认关闭，合法状态）；
    /// 其它读取/解码失败**抛错**（沿用 RemoteStagingProvider 的 no-such-file
    /// 区分原则：读不出 ≠ 不存在，静默当未配置会让用户以为开着实际没开）。
    static func load(from url: URL) throws -> RemoteStagingSyncConfig? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw RemoteStagingSyncConfigError.unreadable("\(error)")
        }
        do {
            return try JSONDecoder().decode(RemoteStagingSyncConfig.self, from: data)
        } catch {
            throw RemoteStagingSyncConfigError.malformed("\(error)")
        }
    }

    /// 写入配置（原子写；用户手工编辑同义）。
    static func save(_ config: RemoteStagingSyncConfig, to url: URL) throws {
        do {
            try JSONEncoder().encode(config).write(to: url, options: .atomic)
        } catch {
            throw RemoteStagingSyncConfigError.writeFailed("\(error)")
        }
    }
}

// MARK: - 生产路径布局

/// spool / state / config 的目录布局（App 数据目录内）。
///
/// - 配置：数据目录顶层 `remote-staging-sync.json`（与 user-portfolio.json 等
///   其它用户可见文件同级，方便部署方直接编辑）；
/// - spool / state：`investment-intelligence-v2/remote-staging/` 子目录（内部
///   工件；journal 由 RemoteStagingProvider 固定放 state 旁 `.journal` 后缀）。
enum RemoteStagingSyncPaths {
    static let configFileName = "remote-staging-sync.json"

    static func configURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(configFileName, isDirectory: false)
    }

    static func workDirectory(in dataDirectory: URL) -> URL {
        dataDirectory
            .appendingPathComponent("investment-intelligence-v2", isDirectory: true)
            .appendingPathComponent("remote-staging", isDirectory: true)
    }

    /// 本地 spool（合法记录 append；复用 PROV-1 JSONL 语义，含远程与本地 collector 摄取）
    static func spoolURL(in dataDirectory: URL) -> URL {
        workDirectory(in: dataDirectory)
            .appendingPathComponent("spool.jsonl", isDirectory: false)
    }

    /// 增量同步 state（name → sha256 + lastSyncedAt）
    static func stateURL(in dataDirectory: URL) -> URL {
        workDirectory(in: dataDirectory)
            .appendingPathComponent("state.json", isDirectory: false)
    }
}

// MARK: - 装配（config → fetcher + provider）

/// sync 循环的装配结果。misconfigured 与 notConfigured 分开：前者是**错误**
///（部署方以为开着实际配错——必须显式暴露），后者是合法的未启用/未配置。
enum RemoteStagingSyncSetup {
    case notConfigured(reason: String)
    case misconfigured(String)
    case ready(provider: RemoteStagingProvider)

    /// 由配置装配 provider。默认经 `URLSessionRemoteStagingFetcher` 走生产
    /// HTTP；测试注入 `fetcher`（连同 session 参数一并被忽略）做离线验证。
    ///
    /// 分档契约（审查 P2 修正）：`enabled=false` 才是 notConfigured（合法的
    /// 未启用）；**enabled=true 但配置非法（URL 缺失/非 http(s)、公钥字节
    /// 非法）一律 misconfigured**——部署方以为开着实际配错，必须显式暴露。
    ///
    /// 验签开关语义（DATA010 §5 + RemoteStagingProvider.init 的 fail-loud）：
    /// 配了公钥但字节非法 → `.misconfigured`，**不**回退未验签模式。
    static func make(
        config: RemoteStagingSyncConfig,
        fetcher: (any RemoteStagingFetcher)? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) -> RemoteStagingSyncSetup {
        guard config.enabled else {
            return .notConfigured(reason: "未启用（enabled=false）")
        }
        guard let baseURL = config.normalizedBaseURL else {
            return .misconfigured(
                "baseURL 缺失或非法（需要 http/https 绝对地址，当前：\"\(config.trimmedBaseURL)\"）"
            )
        }
        // 公钥配置存在但 base64 解不出 → 显式配置错误（不静默忽略）
        if let keyText = config.trimmedSignaturePublicKeyBase64,
           Data(base64Encoded: keyText) == nil {
            return .misconfigured(
                "signaturePublicKeyBase64 不是合法 base64（期望 remote_publish.py --generate-key stdout 的 32 字节公钥 base64）"
            )
        }
        let publicKey = config.trimmedSignaturePublicKeyBase64
            .flatMap { Data(base64Encoded: $0) }
        let resolvedFetcher: any RemoteStagingFetcher = fetcher
            ?? URLSessionRemoteStagingFetcher(
                baseURL: baseURL,
                collectorKey: config.trimmedCollectorKey
            )
        do {
            let provider = try RemoteStagingProvider(
                fetcher: resolvedFetcher,
                signaturePublicKey: publicKey,
                now: now
            )
            return .ready(provider: provider)
        } catch RemoteStagingError.invalidConfiguration(let detail) {
            return .misconfigured(detail)
        } catch {
            return .misconfigured("RemoteStagingProvider 构造失败：\(error)")
        }
    }
}
