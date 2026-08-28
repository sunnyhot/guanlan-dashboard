import Foundation

/// 胜率记忆：结算样本分桶统计 + 置信度校准。
///
/// 口径（对拍 DSA memory.py + 校准扩展）：
/// - 胜率 = settledWin / (settledWin + settledLoss)；expiredUnresolved 只计入样本数不计入胜率（防幸存者偏差的反向：观望类不全算输）；
/// - 桶 ≥30 个可结算样本才启用校准（不足返回 1.0 不干预）；
/// - 校准系数 = clamp(桶胜率, 0.3, 1.2)；历史胜率 <30% 把置信度打到 3 折以下，>80% 允许小幅上浮；
/// - 样本窗口默认近 180 天（按结算时间）。
struct SignalAccuracyMemory: Codable, Hashable, Sendable {
    struct Bucket: Codable, Hashable, Sendable {
        var wins: Int = 0
        var losses: Int = 0
        var unresolved: Int = 0
        var invalidated: Int = 0

        var decideableCount: Int { wins + losses }

        var winRate: Double? {
            decideableCount > 0 ? Double(wins) / Double(decideableCount) : nil
        }

        var sampleCount: Int { wins + losses + unresolved + invalidated }
    }

    static let minimumSamples = 30
    static let sampleWindowDays = 180

    var global: Bucket = Bucket()
    var byDirection: [String: Bucket] = [:]
    var bySubject: [String: Bucket] = [:]
    var bySource: [String: Bucket] = [:]
    var computedAt: String = ""

    // MARK: - 构建

    static func build(from signals: [MarketDecisionSignal], asOf: String, now: Date = Date()) -> SignalAccuracyMemory {
        var memory = SignalAccuracyMemory()
        memory.computedAt = asOf
        let cutoff = now.addingTimeInterval(-Double(sampleWindowDays) * 86_400)

        for signal in signals {
            guard let settlement = signal.settlement else { continue }
            guard let settledDate = parseDate(settlement.settledAt) ?? parseDate(signal.reviewDueAt), settledDate >= cutoff else {
                continue
            }
            let outcome: BucketOutcome
            switch signal.status {
            case .settledWin: outcome = .win
            case .settledLoss: outcome = .loss
            case .expiredUnresolved, .insufficientData: outcome = .unresolved
            case .invalidated: outcome = .invalidated
            case .active: continue
            }

            apply(&memory.global, outcome: outcome)
            apply(&memory.byDirection[signal.direction.rawValue, default: Bucket()], outcome: outcome)
            if let code = signal.subjectCode {
                apply(&memory.bySubject["\(signal.direction.rawValue)|\(code)", default: Bucket()], outcome: outcome)
            }
            apply(&memory.bySource["\(signal.direction.rawValue)|\(signal.sourceKind.rawValue)", default: Bucket()], outcome: outcome)
        }
        return memory
    }

    private enum BucketOutcome {
        case win, loss, unresolved, invalidated
    }

    private static func apply(_ bucket: inout Bucket, outcome: BucketOutcome) {
        switch outcome {
        case .win: bucket.wins += 1
        case .loss: bucket.losses += 1
        case .unresolved: bucket.unresolved += 1
        case .invalidated: bucket.invalidated += 1
        }
    }

    // MARK: - 校准

    /// 最匹配的桶（标的 > 来源 > 方向 > 全局），样本不足自动向粗粒度回退。
    func bestBucket(direction: CanonicalDecisionType, subjectCode: String?, sourceKind: SignalSourceKind) -> Bucket? {
        if let code = subjectCode, let bucket = bySubject["\(direction.rawValue)|\(code)"], bucket.decideableCount >= Self.minimumSamples {
            return bucket
        }
        if let bucket = bySource["\(direction.rawValue)|\(sourceKind.rawValue)"], bucket.decideableCount >= Self.minimumSamples {
            return bucket
        }
        if let bucket = byDirection[direction.rawValue], bucket.decideableCount >= Self.minimumSamples {
            return bucket
        }
        if global.decideableCount >= Self.minimumSamples {
            return global
        }
        return nil
    }

    /// 校准系数：无可信桶返回 1.0（不干预）。
    /// 以 70% 胜率为中性锚：>70% 上浮（封顶 1.2）、<70% 下调（下限 0.3）；
    /// 即 factor = clamp(1 + (winRate − 0.7), 0.3, 1.2)。
    func calibrationFactor(direction: CanonicalDecisionType, subjectCode: String?, sourceKind: SignalSourceKind) -> Double {
        guard let bucket = bestBucket(direction: direction, subjectCode: subjectCode, sourceKind: sourceKind),
              let winRate = bucket.winRate
        else { return 1.0 }
        return min(max(1.0 + (winRate - 0.7), 0.3), 1.2)
    }

    /// 应用校准：raw × factor，上限 1.0。
    func calibratedConfidence(raw: Double, direction: CanonicalDecisionType, subjectCode: String?, sourceKind: SignalSourceKind) -> Double {
        let factor = calibrationFactor(direction: direction, subjectCode: subjectCode, sourceKind: sourceKind)
        return min(raw * factor, 1.0)
    }

    /// 展示口径：「历史同类胜率 62%（45 样本）」。
    func calibrationSummary(direction: CanonicalDecisionType, subjectCode: String?, sourceKind: SignalSourceKind) -> String? {
        guard let bucket = bestBucket(direction: direction, subjectCode: subjectCode, sourceKind: sourceKind),
              let winRate = bucket.winRate
        else { return nil }
        let percent = Int((winRate * 100).rounded())
        return "历史同类胜率 \(percent)%（\(bucket.decideableCount) 个可结算样本）"
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}
