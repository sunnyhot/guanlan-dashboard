import Foundation

// MARK: - AppModel 投资智能自动调度循环（审计 B1/C5）
//
// 60 秒轮询（复用 AppModel 既有 Task+sleep 模式）：到期判定（纯函数）→
// **先落盘标记再启动**（V1 语义：同一窗口至多自动尝试一次，失败不跨窗
// 口补跑、可手动）→ 触发对应 runXxx()。盘中/发现/复盘是纯本地快动作；
// 组合研究需 Provider 配置（未配置时跳过本轮且不消耗尝试标记——用户
// 配好后的下一个窗口仍会触发）。

extension AppModel {

    /// 60 秒一轮的调度 tick（循环体，可单测注入 now）。
    @MainActor
    func runIntelligenceAutomationTick(now: Date = Date()) {
        guard intelligenceRuntime != nil else { return }
        guard let dataDirectory = dataDirectoryURL else { return }

        var settings = intelligenceScheduleSettings
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let isTradingDay = HolidayTableTradingCalendar.bundled
            .isTradingDay(now, jurisdiction: .chinaMainland)
        let isSunday = calendar.component(.weekday, from: now) == 1

        let evaluation = IntelligenceScheduleEvaluator.evaluate(
            settings: settings, now: now, isTradingDay: isTradingDay, isSunday: isSunday)
        guard !evaluation.slots.isEmpty else { return }

        // 研究未配置 Provider：本轮跳过且不消耗标记
        var effectiveKeys = evaluation.keys
        if evaluation.slots.portfolioResearch,
           !IntelligenceV2ProviderSettings.isConfigured {
            effectiveKeys.portfolioResearch = nil
        }
        guard effectiveKeys.marketDiscovery != nil
            || effectiveKeys.intraday != nil
            || effectiveKeys.closeReview != nil
            || effectiveKeys.portfolioResearch != nil
        else { return }

        // 标记先行落盘（同窗口至多一次自动尝试）
        if let key = effectiveKeys.marketDiscovery {
            settings.lastAttemptedKeys["marketDiscovery"] = key
        }
        if let key = effectiveKeys.intraday {
            settings.lastAttemptedKeys["intraday"] = key
        }
        if let key = effectiveKeys.closeReview {
            settings.lastAttemptedKeys["closeReview"] = key
        }
        if let key = effectiveKeys.portfolioResearch {
            settings.lastAttemptedKeys["portfolioResearch"] = key
        }
        intelligenceScheduleSettings = settings
        settings.save(dataDirectory: dataDirectory)

        if effectiveKeys.marketDiscovery != nil {
            runMarketDiscovery()
        }
        if effectiveKeys.intraday != nil {
            runIntradayDecision()
        }
        if effectiveKeys.closeReview != nil {
            runMarketCloseReview(manual: false)
        }
        if effectiveKeys.portfolioResearch != nil {
            runPortfolioResearch()
        }
    }

    /// 后台循环（start() 启动，deinit/重启 cancel）。
    func restartIntelligenceAutomationLoop() {
        intelligenceAutomationTask?.cancel()
        intelligenceAutomationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runIntelligenceAutomationTick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// 更新调度设置（设置面板入口；持久化 + 发布）。
    @MainActor
    func updateIntelligenceSchedule(
        _ transform: (inout IntelligenceScheduleSettings) -> Void
    ) {
        guard let dataDirectory = dataDirectoryURL else { return }
        var settings = intelligenceScheduleSettings
        transform(&settings)
        intelligenceScheduleSettings = settings
        settings.save(dataDirectory: dataDirectory)
    }
}
