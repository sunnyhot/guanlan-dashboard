import Foundation

// MARK: - AppModel 同步组装/应用
//
// 组装:从内存各属性构建 SyncPayload(清洗运行态)。
// 应用:事务式覆盖——备份→临时文件→原子替换→统一改内存→重建派生数据。
// 失败恢复:任一步失败恢复备份,内存状态不变。

extension AppModel {

    // MARK: - 组装 SyncPayload

    /// 从当前内存数据构建同步 payload。清洗运行态字段。
    func makeSyncPayload(sourceDeviceName: String) -> SyncPayload {
        var settings = trendSettings
        // API Key:取内存值、本地密钥存储(UserDefaults)中第一个非空的。
        // 不能用 nil 覆盖内存里的非空值。
        func resolveKey(memValue: String, account: String) -> String {
            if !memValue.isEmpty { return memValue }
            return LocalSecretStore.get(account: account) ?? ""
        }
        settings.provider.apiKey = resolveKey(
            memValue: settings.provider.apiKey,
            account: LocalSecretStore.Account.openAIKey)
        settings.alphaVantage.apiKey = resolveKey(
            memValue: settings.alphaVantage.apiKey,
            account: LocalSecretStore.Account.alphaVantageKey)

        return SyncPayload(
            schemaVersion: SyncPayload.currentSchemaVersion,
            exportedAt: Date(),
            sourceDeviceName: sourceDeviceName,
            holdings: userPortfolioHoldings,
            pendingTrades: pendingTrades,
            investmentPlans: investmentPlans,
            alfaPortfolios: alfaPortfolios,
            valuationAlerts: portfolioValuationAlertProfiles.values.map { ValuationAlertProfileConfig(from: $0) },
            valuationAlertSettings: ValuationAlertSettingsConfig(from: portfolioValuationAlertSettings),
            managerWatch: ManagerWatchSyncConfig(from: managerWatchSettings),
            watchlist: personalWatchlistRecords.map { WatchlistItemSync(from: $0) },
            trendSettings: TrendSettingsSyncDTO(from: settings)
        )
    }

    // MARK: - 事务式应用 payload(覆盖本地)

    /// 应用同步 payload:完全覆盖本地数据。
    /// 流程:校验版本 → 备份 → 写临时文件 → 原子替换 → 统一改内存 → 重建派生。
    /// 任一步失败:恢复备份,内存不变。
    func applySyncPayload(_ payload: SyncPayload) throws {
        // 1. 版本校验
        guard payload.schemaVersion <= SyncPayload.currentSchemaVersion else {
            throw SyncError.incompatibleVersion("数据版本 \(payload.schemaVersion) 高于本机支持版本")
        }

        // 2. 备份当前同步文件
        let backupURL = try backupCurrentSyncFiles()

        // 3. 先把 API Key 存入 Keychain + UserDefaults(双写 fallback)
        if !payload.trendSettings.provider.apiKey.isEmpty {
            LocalSecretStore.set(payload.trendSettings.provider.apiKey, account: LocalSecretStore.Account.openAIKey)
            UserDefaults.standard.set(payload.trendSettings.provider.apiKey, forKey: "qieman.trend.openai.key")
        }
        if !payload.trendSettings.alphaVantage.apiKey.isEmpty {
            LocalSecretStore.set(payload.trendSettings.alphaVantage.apiKey, account: LocalSecretStore.Account.alphaVantageKey)
            UserDefaults.standard.set(payload.trendSettings.alphaVantage.apiKey, forKey: "qieman.trend.alphavantage.key")
        }

        // 4. 逐项持久化(失败则恢复备份)
        do {
            try persistSyncedData(payload)
        } catch {
            // 恢复备份
            try? restoreFromBackup(backupURL)
            throw error
        }

        // 5. 持久化成功 → 统一改内存状态
        applyPayloadToMemory(payload)

        // 6. 重建派生数据
        rebuildDerivedStateAfterSync()

        // 7. 清理备份(保留用于撤销)
        // 备份保留在 backup-pre-sync/,供「撤销本次下载」用
    }

    // MARK: - 内存状态应用

    private func applyPayloadToMemory(_ payload: SyncPayload) {
        userPortfolioHoldings = payload.holdings
        pendingTrades = payload.pendingTrades
        investmentPlans = payload.investmentPlans
        personalWatchlistRecords = payload.watchlist.map { $0.toRecord() }
        portfolioValuationAlertProfiles = Dictionary(
            payload.valuationAlerts.map { ($0.fundCode, $0.toProfile()) },
            uniquingKeysWith: { last, _ in last }
        )
        portfolioValuationAlertSettings = payload.valuationAlertSettings.toSettings()
        payload.managerWatch.merge(into: &managerWatchSettings)
        alfaPortfolios = payload.alfaPortfolios

        // AI 请求和设置界面都直接读取内存中的 API Key。
        // 明文只不落 JSON 文件，不能在应用同步后把运行态也清空。
        trendSettings = Self.trendSettingsByApplyingSync(
            payload.trendSettings,
            to: trendSettings
        )
    }

    /// 纯数据合并：同步三类外部服务配置，保留本机不在同步协议中的运行设置。
    static func trendSettingsByApplyingSync(
        _ synced: TrendSettingsSyncDTO,
        to current: TrendAnalysisSettings
    ) -> TrendAnalysisSettings {
        var settings = current
        settings.provider = synced.provider
        settings.alphaVantage = synced.alphaVantage
        return settings
    }

    // MARK: - 持久化到文件

    private func persistSyncedData(_ payload: SyncPayload) throws {
        guard let dir = dataDirectoryURL else {
            throw SyncError.dataDirectoryUnavailable
        }

        // 各 Store 序列化并保存
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try saveJSON(payload.holdings, to: dir.appendingPathComponent("user-portfolio.json"), encoder: encoder)
        try saveJSON(payload.pendingTrades, to: dir.appendingPathComponent("user-pending-trades.json"), encoder: encoder)
        try saveJSON(payload.investmentPlans, to: dir.appendingPathComponent("user-investment-plans.json"), encoder: encoder)
        try saveJSON(payload.watchlist.map { $0.toRecord() }, to: dir.appendingPathComponent("user-watchlist.json"), encoder: encoder)

        // 估值告警:数组格式(与 Store 一致)
        let alertArray = payload.valuationAlerts.map { $0.toProfile() }.sorted { $0.fundCode < $1.fundCode }
        try saveJSON(alertArray, to: dir.appendingPathComponent("portfolio-valuation-alerts.json"), encoder: encoder)
        try saveJSON(payload.valuationAlertSettings.toSettings(), to: dir.appendingPathComponent("portfolio-valuation-alert-settings.json"), encoder: encoder)

        // 巡检:合并 config 进现有(保留运行态字段)
        var watchSettings = managerWatchSettings
        payload.managerWatch.merge(into: &watchSettings)
        try saveJSON(watchSettings, to: dir.appendingPathComponent("manager-watch-settings.json"), encoder: encoder)

        try saveJSON(payload.alfaPortfolios, to: dir.appendingPathComponent("alfa-portfolios.json"), encoder: encoder)

        // 趋势设置:API Key 存 Keychain(已在 applySyncPayload 做了),JSON 只存 config
        // 保留现有 settings 的其余字段(privacy/autoAnalysis),只覆盖 provider/alphaVantage
        var trendForFile = trendSettings
        trendForFile.provider = payload.trendSettings.provider
        trendForFile.alphaVantage = payload.trendSettings.alphaVantage
        trendForFile.provider.apiKey = ""
        trendForFile.alphaVantage.apiKey = ""
        let store = TrendAnalysisSettingsStore()
        if let url = trendAnalysisSettingsFileURL {
            try store.save(trendForFile, to: url)
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 重建派生数据

    private func rebuildDerivedStateAfterSync() {
        rebuildAssetRows()
        // 清理并重建 snapshot(旧 snapshot 基于旧持仓,失效)
        userPortfolioSnapshot = nil
        // alfa:校验选中组合是否仍有效
        if let selected = selectedAlfaPoCode,
           !alfaPortfolios.contains(where: { $0.poCode == selected }) {
            selectedAlfaPoCode = nil
            alfaPayload = nil
            alfaHoldings = []
        }
        // 巡检配置变更:重启巡检任务
        if managerWatchSettings.isEnabled {
            restartManagerWatchLoop(immediate: false)
        }
    }

    // MARK: - 备份/恢复

    private func backupCurrentSyncFiles() throws -> URL {
        let fm = FileManager.default
        guard let dir = dataDirectoryURL else {
            throw SyncError.dataDirectoryUnavailable
        }
        let backupDir = dir.appendingPathComponent("backup-pre-sync", isDirectory: true)
        try? fm.removeItem(at: backupDir)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let syncFiles = [
            "user-portfolio.json", "user-pending-trades.json", "user-investment-plans.json",
            "user-watchlist.json", "portfolio-valuation-alerts.json",
            "portfolio-valuation-alert-settings.json", "manager-watch-settings.json",
            "alfa-portfolios.json", "trend-analysis-settings.json"
        ]
        for name in syncFiles {
            let src = dir.appendingPathComponent(name)
            let dst = backupDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dst)
            }
        }
        return backupDir
    }

    private func restoreFromBackup(_ backupURL: URL) throws {
        let fm = FileManager.default
        guard let dir = dataDirectoryURL else { return }
        // 把备份文件覆盖回正式目录
        if let files = try? fm.contentsOfDirectory(atPath: backupURL.path) {
            for name in files {
                let src = backupURL.appendingPathComponent(name)
                let dst = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// 撤销上次同步下载(恢复 backup-pre-sync/)。
    func undoLastSyncDownload() throws {
        let fm = FileManager.default
        guard let dir = dataDirectoryURL else { return }
        let backupDir = dir.appendingPathComponent("backup-pre-sync", isDirectory: true)
        guard fm.fileExists(atPath: backupDir.path) else {
            throw SyncError.noBackupToRestore
        }
        try restoreFromBackup(backupDir)
        // 重新从磁盘加载全部状态
        reloadAllFromDisk()
        rebuildDerivedStateAfterSync()
        try? fm.removeItem(at: backupDir)
    }

    /// 从磁盘重新加载所有同步数据到内存(撤销同步后重建状态)。
    private func reloadAllFromDisk() {
        loadInvestmentPlans()
        loadPendingTrades()
        loadManagerWatchSettings()
        loadAlfaPortfolios()
        loadTrendAnalysisState()
        // watchlist/portfolio/alerts 需从文件加载
        if let url = personalWatchlistFileURL,
           let records = try? PersonalWatchlistStore().load(from: url) {
            personalWatchlistRecords = records
        }
        if let url = portfolioFileURL,
           let holdings = try? UserPortfolioStore().load(from: url) {
            userPortfolioHoldings = holdings
        }
        if let url = portfolioValuationAlertFileURL,
           let profiles = try? PortfolioValuationAlertStore().load(from: url) {
            portfolioValuationAlertProfiles = profiles
        }
        if let url = portfolioValuationAlertSettingsFileURL,
           let settings = try? PortfolioValuationAlertSettingsStore().load(from: url) {
            portfolioValuationAlertSettings = settings
        }
    }
}

// MARK: - SyncError

enum SyncError: LocalizedError {
    case incompatibleVersion(String)
    case dataDirectoryUnavailable
    case authenticationFailed
    case networkError(String)
    case authFailed
    case groupNotFound
    case conflictNeedsConfirmation
    case rollbackDetected
    case payloadTooLarge
    case serverError(Int)
    case noBackupToRestore

    var errorDescription: String? {
        switch self {
        case .incompatibleVersion(let v): return v
        case .dataDirectoryUnavailable: return "应用数据目录不可用。"
        case .authenticationFailed: return "密码不正确,或同步数据已损坏。"
        case .networkError(let m): return "网络连接失败:\(m)"
        case .authFailed: return "同步凭证失效,请重新注册同步组。"
        case .groupNotFound: return "同步组不存在,请检查或重新注册。"
        case .conflictNeedsConfirmation: return "云端有更新版本,是否仍然覆盖?"
        case .rollbackDetected: return "检测到数据版本异常回退,是否继续?"
        case .payloadTooLarge: return "同步数据过大(上限 2MB)。"
        case .serverError(let code): return "同步服务异常(HTTP \(code)),请稍后重试。"
        case .noBackupToRestore: return "没有可恢复的备份。"
        }
    }
}
