import Foundation

/// 按 `(provider, capability)` 维度的熔断器：连续 N 次失败进入熔断，冷却期后半开单次探测。
///
/// 口径参考 daily_stock_analysis（MIT）`realtime_types.py`：3 次失败 / 300s 冷却 / 半开 1 次。
/// 半开语义说明：探测请求进行中若并发到来，`canAttempt` 仍返回 true（顺序调用场景无影响），
/// 探测结果出来后按 success/failure 归位。
actor MarketDataCircuitBreaker {
    enum State: Equatable, Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    struct Counter: Sendable {
        var consecutiveFailures: Int = 0
        var state: State = .closed
    }

    private var counters: [String: Counter] = [:]
    private let failureThreshold: Int
    private let cooldownSeconds: TimeInterval
    private let now: () -> Date

    init(
        failureThreshold: Int = 3,
        cooldownSeconds: TimeInterval = 300,
        now: @escaping () -> Date = { Date() }
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.now = now
    }

    /// 当前是否允许发起请求。熔断冷却期内返回 false。
    func canAttempt(_ key: String) -> Bool {
        refresh(key: key)
        switch counters[key]?.state ?? .closed {
        case .closed, .halfOpen:
            return true
        case .open:
            return false
        }
    }

    /// 当前状态（诊断用）。
    func state(_ key: String) -> State {
        refresh(key: key)
        return counters[key]?.state ?? .closed
    }

    func recordSuccess(_ key: String) {
        counters[key] = Counter()
    }

    func recordFailure(_ key: String) {
        var counter = counters[key] ?? Counter()
        counter.consecutiveFailures += 1
        if case .halfOpen = counter.state {
            // 半开探测失败：重新熔断
            counter.state = .open(until: now().addingTimeInterval(cooldownSeconds))
        } else if counter.consecutiveFailures >= failureThreshold {
            counter.state = .open(until: now().addingTimeInterval(cooldownSeconds))
        }
        counters[key] = counter
    }

    /// 冷却期结束则转半开。
    private func refresh(key: String) {
        guard var counter = counters[key] else { return }
        if case .open(let until) = counter.state, now() >= until {
            counter.state = .halfOpen
            counters[key] = counter
        }
    }
}
