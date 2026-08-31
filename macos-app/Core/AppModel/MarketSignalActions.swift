import Foundation

// MARK: - L6 市场信号闭环 App 集成（2026-08-31）
//
// 接线内容（docs/ai-pipeline-baseline.md 第 10.3/10.6 节）：
// - 趋势报告落盘后自动 ingest（抽取→去重→反向失效→胜率校准）
// - 每日盘后（15:35 起，每天一次）settleDueSignals：触价/到期结算 + 失效
// - 信号只做标的级市场判定与胜率记忆；不自动建 DecisionCase、不自动交易
//
// 调度入口：NextHourGuidanceController.restartNextHourGuidanceSchedulerLoop
// 的 60s 轮询（与链路 A/B 同一 loop，天然避开盘中生成高峰）。

extension AppModel {

    // MARK: - 服务装配

    /// 信号服务（懒加载单例）。Store 在 investment-intelligence/market-signals/，
    /// 结算数据源用独立 MarketDataEngine（actor，独立缓存，低频调用）。
    func makeMarketSignalService() -> MarketSignalService? {
        if let cached = marketSignalServiceCache { return cached }
        guard let base = investmentIntelligenceDirectoryURL else { return nil }
        let service = MarketSignalService(
            store: MarketSignalStore(
                baseDirectory: base.appendingPathComponent("market-signals", isDirectory: true)
            ),
            engine: MarketDataEngine()
        )
        marketSignalServiceCache = service
        return service
    }

    /// 加载信号到 UI 状态（loadEnhancementState / ingest / settle 后调用）。
    func loadMarketSignals() {
        guard InvestmentIntelligence.enabled else { return }
        guard let service = makeMarketSignalService() else { return }
        Task { @MainActor in
            let all = await service.allSignals()
            marketSignals = all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - 报告 → 信号

    /// 趋势报告落盘后的信号抽取入库（saveTrendAnalysisReport 调用）。
    /// 先按胜率记忆校准置信度再入库；失败不影响报告保存本身。
    func ingestMarketSignalsFromReport(_ report: TrendAnalysisReport) {
        guard InvestmentIntelligence.enabled else { return }
        guard let service = makeMarketSignalService() else { return }
        Task { @MainActor in
            let candidates = MarketSignalExtractor.extract(from: report, now: Date())
            guard !candidates.isEmpty else { return }
            let calibrated = await withTaskGroup(of: MarketDecisionSignal.self) { group in
                for candidate in candidates {
                    group.addTask { await service.calibratedSignal(candidate) }
                }
                var results: [MarketDecisionSignal] = []
                for await signal in group { results.append(signal) }
                return results
            }
            do {
                let summary = try await service.ingest(signals: calibrated)
                await AIAgentDiagnosticLog.record(
                    "market_signals_ingested",
                    payload: [
                        "created": summary.created,
                        "duplicates": summary.duplicates,
                        "invalidatedOpposites": summary.invalidatedOpposites,
                    ] as [String: Int]
                )
            } catch {
                lastMarketSignalSettleSummary = "信号入库失败：\(error.localizedDescription)"
            }
            let all = await service.allSignals()
            marketSignals = all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - 每日盘后结算调度

    /// 盘后结算守门（纯函数，便于测试）：交易日 15:35 之后、当天未结算过才执行。
    enum MarketSignalSettlementScheduler {
        static let settleHour = 15
        static let settleMinute = 35
        static let lastSettleDayKey = "qieman.marketSignals.lastSettleDay"

        static func settleDayString(for date: Date, calendar: Calendar = settleCalendar) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        static var settleCalendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = MarketPhase.timeZone
            return calendar
        }

        /// 是否应当结算：已过 15:35（东八区）且当日未结算。
        static func shouldSettle(
            now: Date,
            lastSettleDay: String?
        ) -> Bool {
            let calendar = settleCalendar
            let components = calendar.dateComponents([.hour, .minute], from: now)
            guard let hour = components.hour, let minute = components.minute else { return false }
            let minutesOfDay = hour * 60 + minute
            guard minutesOfDay >= settleHour * 60 + settleMinute else { return false }
            return lastSettleDay != settleDayString(for: now, calendar: calendar)
        }
    }

    /// 60s 轮询调用：每日盘后一次，结算到期/触价信号并刷新 UI。
    func runMarketSignalSettlementIfNeeded() async {
        guard InvestmentIntelligence.enabled else { return }
        let lastSettleDay = UserDefaults.standard.string(
            forKey: MarketSignalSettlementScheduler.lastSettleDayKey
        )
        guard MarketSignalSettlementScheduler.shouldSettle(
            now: Date(), lastSettleDay: lastSettleDay
        ) else { return }
        guard let service = makeMarketSignalService() else { return }

        do {
            let summary = try await service.settleDueSignals()
            UserDefaults.standard.set(
                MarketSignalSettlementScheduler.settleDayString(for: Date()),
                forKey: MarketSignalSettlementScheduler.lastSettleDayKey
            )
            let totalSettled = summary.settledWin + summary.settledLoss + summary.expired
            if totalSettled > 0 || !lastMarketSignalSettleSummary.isEmpty {
                lastMarketSignalSettleSummary = Self.marketSignalSettleSummaryText(summary)
            }
            let all = await service.allSignals()
            marketSignals = all.sorted { $0.createdAt > $1.createdAt }
        } catch {
            // 结算失败不阻断调度；标记留空明天重试
            lastMarketSignalSettleSummary = "盘后结算失败：\(error.localizedDescription)"
        }
    }

    static func marketSignalSettleSummaryText(
        _ summary: MarketSignalService.SettleSummary
    ) -> String {
        var parts: [String] = []
        if summary.settledWin > 0 { parts.append("兑现 \(summary.settledWin)") }
        if summary.settledLoss > 0 { parts.append("止损 \(summary.settledLoss)") }
        if summary.expired > 0 { parts.append("到期未触发 \(summary.expired)") }
        if parts.isEmpty { parts.append("无到期信号") }
        parts.append("活跃 \(summary.stillActive)")
        return "上次盘后结算：" + parts.joined(separator: " · ")
    }

    // MARK: - UI 派生数据

    /// 活跃信号（按创建时间倒序）。
    var activeMarketSignals: [MarketDecisionSignal] {
        marketSignals.filter { $0.status == .active }
    }

    /// 已结算信号（最近 10 条）。
    var settledMarketSignals: [MarketDecisionSignal] {
        marketSignals
            .filter { $0.status != .active }
            .prefix(10)
            .map { $0 }
    }

    /// 全局胜率记忆摘要（≥30 可结算样本才给出胜率，与校准门槛一致）。
    var marketSignalAccuracyText: String? {
        let all = marketSignals
        let wins = all.filter { $0.settlement?.outcome == .hitTarget }.count
        let losses = all.filter { $0.settlement?.outcome == .hitStop }.count
        let active = all.filter { $0.status == .active }.count
        let decided = wins + losses
        guard decided > 0 || active > 0 else { return nil }
        var text = "可结算样本 \(decided)"
        if decided >= SignalAccuracyMemory.minimumSamples, decided > 0 {
            let rate = Double(wins) / Double(decided) * 100
            text += String(format: " · 历史胜率 %.0f%%", rate)
        } else {
            text += "（累计 \(SignalAccuracyMemory.minimumSamples) 个后开始校准置信度）"
        }
        text += " · 活跃 \(active)"
        return text
    }
}
