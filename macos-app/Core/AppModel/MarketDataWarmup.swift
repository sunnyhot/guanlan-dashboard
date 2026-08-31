import Foundation

// MARK: - L1 广度预暖（2026-08-31，baseline 10.6 收尾）
//
// 全市场广度首算约 15-30s（抓全市场快照）。Agent 的 get_market_breadth
// 工具直接调 MarketDataEngine.shared——盘内每分钟预暖（TTL 10 分钟内直接
// 命中缓存），Agent 工具调用从「首算半分钟」降到「秒回」。
//
// 挂在 60s 调度循环（restartNextHourGuidanceSchedulerLoop）里，
// 与下一小时研判/趋势研究/信号结算同一循环，顺序无竞争。

extension AppModel {

    /// 是否处于广度预暖窗口：周一~周五 09:00–15:30（东八区）。
    /// 节假日引擎拉不到数据会走降级路径，不影响正确性。
    nonisolated static func isMarketBreadthPrewarmWindow(now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketPhase.timeZone
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = components.weekday, let hour = components.hour else { return false }
        guard weekday >= 2, weekday <= 6 else { return false }
        let minutesOfDay = hour * 60 + (components.minute ?? 0)
        return minutesOfDay >= 9 * 60 && minutesOfDay <= 15 * 60 + 30
    }

    /// 盘内预暖共享引擎的广度缓存；冷算耗时较长，fire-and-forget 不阻塞调度循环。
    func prewarmMarketBreadthIfNeeded() {
        guard InvestmentIntelligence.enabled else { return }
        guard Self.isMarketBreadthPrewarmWindow(now: Date()) else { return }
        guard !isPrewarmingMarketBreadth else { return }
        isPrewarmingMarketBreadth = true
        Task { [weak self] in
            defer { self?.isPrewarmingMarketBreadth = false }
            _ = try? await MarketDataEngine.shared.marketBreadth()
        }
    }
}
