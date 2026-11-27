import Foundation

// MARK: - 基金估值校准（估算 vs 事后真实净值）

/// 单条校准记录：某基金某交易日，收盘时的估算涨幅与事后公布的真实涨幅。
///
/// 生命周期：`pending`（已记录收盘估算，等待净值）→ `settled`（净值公布，算出误差）。
struct FundEstimateCalibrationRecord: Codable, Hashable, Sendable {
    /// 基金代码（去空格）。
    let fundCode: String
    /// 交易日 `yyyy-MM-dd`（Asia/Shanghai）。
    let tradeDate: String
    /// 收盘时采用的估算涨幅（百分数）。
    let estimatedChangePct: Double
    /// 产生该估算的来源标识（如 `eastmoney_legacy_estimate`、`holdings_lookthrough`）。
    let source: String
    /// 估算对应的时间戳（数据源给的估值时间）。
    let estimatedAt: String
    /// 官方净值公布后的真实涨幅（百分数）。nil 表示尚未结算。
    var actualChangePct: Double?
    /// 结算时间戳。
    var settledAt: String?

    var isSettled: Bool { actualChangePct != nil }

    /// 真实 − 估算。正值表示估算偏低（实际涨得更多）。
    var errorPct: Double? {
        guard let actualChangePct else { return nil }
        return actualChangePct - estimatedChangePct
    }

    init(
        fundCode: String,
        tradeDate: String,
        estimatedChangePct: Double,
        source: String,
        estimatedAt: String,
        actualChangePct: Double? = nil,
        settledAt: String? = nil
    ) {
        self.fundCode = fundCode
        self.tradeDate = tradeDate
        self.estimatedChangePct = estimatedChangePct
        self.source = source
        self.estimatedAt = estimatedAt
        self.actualChangePct = actualChangePct
        self.settledAt = settledAt
    }
}

/// 估值可信度等级。按滚动 RMSE 分档，供 UI 与融合权重使用。
enum FundEstimateConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    /// 样本不足（< 3 条已结算记录），尚不能判断。
    case unknown
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .unknown: return "待校准"
        case .high: return "高可信"
        case .medium: return "中可信"
        case .low: return "低可信"
        }
    }

    /// 融合时的权重基数。`unknown` 给中性偏低权重，避免未校准来源压过已证明准确的来源；
    /// `low` 压得很低——已被证明不准的来源只应提供方向性参考，不应明显拉低融合结果的可信度。
    var fusionWeight: Double {
        switch self {
        case .unknown: return 0.5
        case .high: return 1.0
        case .medium: return 0.6
        case .low: return 0.1
        }
    }

    /// RMSE 分档阈值（百分数）。
    static func from(rmse: Double?, sampleCount: Int) -> FundEstimateConfidence {
        guard let rmse, sampleCount >= 3 else { return .unknown }
        if rmse <= 0.15 { return .high }
        if rmse <= 0.40 { return .medium }
        return .low
    }
}

/// 单只基金（或单一来源）的滚动误差统计。
struct FundEstimateAccuracyStats: Codable, Hashable, Sendable {
    /// 系统偏差：mean(真实 − 估算)。估算值**加上**它即可去偏（估算长期偏低 → bias 为正 → 上调）。
    let biasPct: Double
    /// 均方根误差。
    let rmsePct: Double
    /// 平均绝对误差。
    let maePct: Double
    /// 已结算样本数。
    let sampleCount: Int
    /// 最近一次结算的交易日。
    let latestTradeDate: String?

    static let empty = FundEstimateAccuracyStats(biasPct: 0, rmsePct: 0, maePct: 0, sampleCount: 0, latestTradeDate: nil)

    var confidence: FundEstimateConfidence {
        FundEstimateConfidence.from(rmse: rmsePct, sampleCount: sampleCount)
    }

    /// 置信区间半宽（±），按误差近似正态用 1.96σ 估算，σ 用 RMSE 近似。
    var errorBandPct: Double? {
        guard sampleCount >= 3, rmsePct.isFinite, rmsePct >= 0 else { return nil }
        return min(3.0, 1.96 * rmsePct)
    }

    static func compute(errors: [Double], tradeDates: [String]) -> FundEstimateAccuracyStats {
        let valid = errors.filter { $0.isFinite }
        guard !valid.isEmpty else { return .empty }
        let n = Double(valid.count)
        let mean = valid.reduce(0, +) / n
        let mse = valid.reduce(0) { $0 + $1 * $1 } / n
        let mae = valid.reduce(0) { $0 + abs($1) } / n
        return FundEstimateAccuracyStats(
            biasPct: mean,
            rmsePct: mse.squareRoot(),
            maePct: mae,
            sampleCount: valid.count,
            latestTradeDate: tradeDates.max()
        )
    }
}

/// 估值校准台账：纯函数式核心，AppModel 负责持久化与调用时机。
///
/// 两个职责：
/// 1. **去偏**：按基金 × 来源维护滚动 bias，实时估算加上 bias 即修正值。
/// 2. **评分**：按基金 × 来源维护滚动 RMSE，映射为可信度并作为多源融合权重。
struct FundEstimateCalibrationLedger: Codable, Hashable, Sendable {
    /// 每只基金最多保留的已结算记录数（滚动窗口）。
    static let maximumRecordsPerFund = 60
    /// 参与统计的最近 N 条记录。
    static let statisticsWindow = 20

    /// fundCode → 已结算记录（按交易日升序）。
    private(set) var settledByFund: [String: [FundEstimateCalibrationRecord]]
    /// fundCode → 等待净值的记录。
    private(set) var pendingByFund: [String: FundEstimateCalibrationRecord]

    init(
        settledByFund: [String: [FundEstimateCalibrationRecord]] = [:],
        pendingByFund: [String: FundEstimateCalibrationRecord] = [:]
    ) {
        self.settledByFund = settledByFund
        self.pendingByFund = pendingByFund
    }

    // MARK: 写入

    /// 记录收盘估算。同一基金同一交易日重复记录时保留时间更晚的一条（更接近收盘）。
    /// 返回是否发生了写入。
    @discardableResult
    mutating func recordEstimate(_ record: FundEstimateCalibrationRecord) -> Bool {
        guard record.estimatedChangePct.isFinite else { return false }
        let code = record.fundCode
        if let existing = pendingByFund[code], existing.tradeDate == record.tradeDate {
            guard record.estimatedAt > existing.estimatedAt else { return false }
        }
        // 若该日已结算（净值先到、估算后到的异常顺序），不覆盖已结算记录。
        if let settled = settledByFund[code], settled.contains(where: { $0.tradeDate == record.tradeDate }) {
            return false
        }
        pendingByFund[code] = record
        return true
    }

    /// 用官方净值结算等待中的记录。`actualChangePctByDate` 为该基金近期「交易日 → 真实涨幅」。
    /// 返回本次结算的记录数。
    @discardableResult
    mutating func settle(
        fundCode: String,
        actualChangePctByDate: [String: Double],
        settledAt: String
    ) -> Int {
        guard let pending = pendingByFund[fundCode],
              let actual = actualChangePctByDate[pending.tradeDate],
              actual.isFinite else {
            return 0
        }
        var settledRecord = pending
        settledRecord.actualChangePct = actual
        settledRecord.settledAt = settledAt
        pendingByFund[fundCode] = nil
        var list = settledByFund[fundCode] ?? []
        list.append(settledRecord)
        list.sort { $0.tradeDate < $1.tradeDate }
        if list.count > Self.maximumRecordsPerFund {
            list.removeFirst(list.count - Self.maximumRecordsPerFund)
        }
        settledByFund[fundCode] = list
        return 1
    }

    /// 丢弃超过 `maxAgeDays` 天仍未结算的 pending（如基金清盘、长期停牌）。
    mutating func pruneStalePending(olderThanDays maxAgeDays: Int, now: Date = Date()) {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -maxAgeDays, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffText = formatter.string(from: cutoff)
        pendingByFund = pendingByFund.filter { $0.value.tradeDate >= cutoffText }
    }

    // MARK: 读取

    /// 该基金该来源的滚动统计（只用最近 `statisticsWindow` 条该来源记录）。
    func stats(fundCode: String, source: String?) -> FundEstimateAccuracyStats {
        guard let list = settledByFund[fundCode] else { return .empty }
        let scoped = source.map { scopedSource -> [FundEstimateCalibrationRecord] in
            list.filter { $0.source == scopedSource }
        } ?? list
        let filtered = scoped
            .suffix(Self.statisticsWindow)
        guard !filtered.isEmpty else { return .empty }
        let errors = filtered.compactMap(\.errorPct)
        return FundEstimateAccuracyStats.compute(
            errors: errors,
            tradeDates: filtered.map(\.tradeDate)
        )
    }

    /// 该基金所有来源合并的统计（用于整体可信度展示）。
    func overallStats(fundCode: String) -> FundEstimateAccuracyStats {
        stats(fundCode: fundCode, source: nil)
    }

    /// 对实时估算去偏：`修正值 = 原始 + bias`（bias = 真实 − 估算）。样本不足时原样返回。
    func debiasedChangePct(_ rawChangePct: Double, fundCode: String, source: String) -> Double {
        let s = stats(fundCode: fundCode, source: source)
        guard s.sampleCount >= 3, s.biasPct.isFinite else { return rawChangePct }
        // 偏差极小不修正，避免无意义抖动。
        guard abs(s.biasPct) >= 0.01 else { return rawChangePct }
        return rawChangePct + s.biasPct
    }

    /// 全部已结算记录（按基金、日期升序），供调试与 CLI 输出。
    var allSettledRecords: [FundEstimateCalibrationRecord] {
        settledByFund.keys.sorted().flatMap { settledByFund[$0] ?? [] }
    }

    var pendingCount: Int {
        pendingByFund.count
    }

    var settledCount: Int {
        settledByFund.values.reduce(0) { $0 + $1.count }
    }
}
