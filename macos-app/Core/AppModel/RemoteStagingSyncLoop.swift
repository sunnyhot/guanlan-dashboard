import Foundation

// MARK: - RemoteStagingSync 接线（PROV-3b 客户端生产入口，SYNC-2 前置）
//
// V2 远程增强通道（ADR-DATA010）的 App 侧唯一调用点：启动时读配置
//（`remote-staging-sync.json`，默认不存在 = 默认关闭），配置齐备才启动
// sync 循环（立即一轮 + 每 6 小时一轮；服务端日级发布，增量拉取开销极小）。
//
// 降级铁律：任何失败只更新诊断状态，不弹错误、不重试硬冲（断路器在
// RemoteStagingProvider 内部指数退避）、绝不影响原生 provider 路径。
// 状态暴露给未来的「远程增强」设置页/诊断面板，本 Story 不做 UI（B.3）。

/// 远程增强通道的运行状态（诊断用；未来 UI「远程增强暂不可用」的数据源）。
enum RemoteStagingSyncStatus: Equatable {
    case notConfigured(String)
    case misconfigured(String)
    case idle
    /// 一轮 sync 完成。**拒收计数必须保留**（审查 P1）：sha256 不符 /
    /// schema 非法的文件被 Provider 拒收时 sync 仍算完成（其余文件照常入库），
    /// 但诊断面不能因此显示「干净成功」——非零 tampered 是完整性事件
    ///（DATA010 防注入信号），非零 invalidSchema 是服务端版本漂移信号。
    case synced(
        filesDownloaded: Int,
        recordsAppended: Int,
        filesRejectedTampered: Int,
        recordsRejectedInvalidSchema: Int,
        at: Date
    )
    case skippedUntil(Date)
    case failed(String)

    /// Provider outcome → 诊断状态的唯一映射（纯函数，测试直接覆盖）。
    static func make(from outcome: RemoteStagingSyncOutcome) -> RemoteStagingSyncStatus {
        switch outcome {
        case .synced(let summary):
            return .synced(
                filesDownloaded: summary.filesDownloaded,
                recordsAppended: summary.recordsAppended,
                filesRejectedTampered: summary.filesRejectedTampered,
                recordsRejectedInvalidSchema: summary.recordsRejectedInvalidSchema,
                at: summary.syncedAt
            )
        case .skipped(let openUntil):
            return .skippedUntil(openUntil)
        case .failed(let error):
            return .failed("\(error)")
        }
    }
}

extension AppModel {

    /// sync 周期：服务端日级发布（收盘后 cron），6 小时一轮在当天内必命中新快照，
    /// 增量比对下未变化轮次退化为一次 manifest 拉取。
    static let remoteStagingSyncInterval: TimeInterval = 6 * 60 * 60

    /// 启动远程增强 sync 循环（幂等；未配置 / 未启用 / 配置错误均不启动任务）。
    @MainActor
    func startRemoteStagingSyncLoopIfNeeded() {
        guard remoteStagingSyncTask == nil else { return }
        guard let dataDirectory = dataDirectoryURL else {
            remoteStagingSyncStatus = .notConfigured("数据目录未就绪")
            return
        }
        let configURL = RemoteStagingSyncPaths.configURL(in: dataDirectory)
        let config: RemoteStagingSyncConfig
        do {
            guard let loaded = try RemoteStagingSyncConfigStore.load(from: configURL) else {
                remoteStagingSyncStatus = .notConfigured("未配置远程增强（默认关闭）")
                return
            }
            config = loaded
        } catch {
            remoteStagingSyncStatus = .misconfigured("配置读取失败：\(error)")
            return
        }
        switch RemoteStagingSyncSetup.make(config: config) {
        case .notConfigured(let reason):
            remoteStagingSyncStatus = .notConfigured(reason)
        case .misconfigured(let detail):
            remoteStagingSyncStatus = .misconfigured(detail)
        case .ready(let provider):
            remoteStagingSyncStatus = .idle
            remoteStagingSyncTask = Task { [weak self] in
                await self?.runRemoteStagingSyncLoop(
                    provider: provider,
                    spoolURL: RemoteStagingSyncPaths.spoolURL(in: dataDirectory),
                    stateURL: RemoteStagingSyncPaths.stateURL(in: dataDirectory)
                )
            }
        }
    }

    @MainActor
    private func runRemoteStagingSyncLoop(
        provider: RemoteStagingProvider,
        spoolURL: URL,
        stateURL: URL
    ) async {
        let interval = UInt64(Self.remoteStagingSyncInterval * 1_000_000_000)
        while !Task.isCancelled {
            // spool 目录可能尚不存在（首次启用）；RemoteStagingProvider 的 append
            // 路径只保证文件级创建，目录由这里负责
            try? FileManager.default.createDirectory(
                at: spoolURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let outcome = await provider.sync(to: spoolURL, state: stateURL)
            if Task.isCancelled { return }
            remoteStagingSyncStatus = RemoteStagingSyncStatus.make(from: outcome)
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                return   // 任务被取消
            }
        }
    }
}
