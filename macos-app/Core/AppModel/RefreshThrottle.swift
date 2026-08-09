import Foundation

// MARK: - Refresh Throttle

/// Actor-based throttle for refresh operations.
/// Prevents the same operation (identified by key) from executing more than once
/// within a configurable time interval.
actor RefreshThrottle {
    /// Default throttle interval (5 seconds).
    static let defaultInterval: TimeInterval = 5.0

    private var lastExecutionTimes: [String: Date] = [:]

    /// Executes the given action only if enough time has elapsed since the last
    /// execution with the same key. Returns `true` if the action was executed.
    @discardableResult
    func throttle(key: String, interval: TimeInterval = defaultInterval, action: @Sendable () async -> Void) async -> Bool {
        let now = Date()
        if let lastTime = lastExecutionTimes[key], now.timeIntervalSince(lastTime) < interval {
            return false
        }
        lastExecutionTimes[key] = now
        await action()
        return true
    }
}
