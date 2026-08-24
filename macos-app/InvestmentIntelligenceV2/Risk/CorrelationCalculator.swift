import Foundation

// MARK: - CorrelationCalculator（RISK-2，Epic 8）
//
// 穿透后标的两两 Pearson 相关。铁律：历史序列不足 → unknown（不猜）。
// 不足的形态全部显式：样本数低于阈值 / 无重叠交易日 / 零方差（恒定序列，
// 数学无定义）——pearson 为 nil 且给出原因，绝不以 0 或均值填充。

/// 单对相关性结果。
struct CorrelationPair: Sendable, Codable, Hashable {
    let listingA: ListingID
    let listingB: ListingID
    /// Pearson r（−1..1）。nil = unknown（不猜，见 insufficiency）
    let pearson: Ratio?
    /// 实际参与计算的配对收益率样本数
    let sampleCount: Int
    /// pearson == nil 时的原因；非 nil 时为 nil
    let insufficiency: Insufficiency?

    struct Insufficiency: Sendable, Codable, Hashable {
        let reason: Reason
        /// 样本阈值（zeroVariance / noOverlap 时为 nil）
        let requiredSamples: Int?

        enum Reason: String, Sendable, Codable, Hashable {
            case insufficientSamples = "INSUFFICIENT_SAMPLES"
            case noOverlappingDates = "NO_OVERLAPPING_DATES"
            case zeroVariance = "ZERO_VARIANCE"
        }
    }
}

/// 相关性计算器（RISK-2，纯函数）。
struct CorrelationCalculator: Sendable {
    /// 计算参数（versioned：阈值变更走参数 + 重算）。
    struct Parameters: Sendable, Codable, Hashable {
        /// 尾部参与计算的收益率数（窗口上限）
        let windowReturns: Int
        /// 低于此样本数 → unknown（不猜）
        let minSampleCount: Int

        init(windowReturns: Int = 60, minSampleCount: Int = 30) {
            self.windowReturns = windowReturns
            self.minSampleCount = minSampleCount
        }
    }

    let parameters: Parameters

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 计算指定标的对的相关性。
    ///
    /// - series：各标的的复权收盘序列（已按 KnowledgeContext 过滤）。
    ///   **按 effectiveAt 严格配对**（同日 bar 才成对）——相关性是逐日配对
    ///   统计，跨市场日历缺口自然减少样本，不足即 unknown。
    /// - pairs：要计算的标的对（顺序保持输出）。
    func compute(
        series: [ListingID: [AdjustedClosePoint]],
        pairs: [(ListingID, ListingID)]
    ) -> [CorrelationPair] {
        // 预转各标的的日收益率（按日期索引）
        var returnsByListing: [ListingID: [Date: Decimal]] = [:]
        for (listing, points) in series {
            returnsByListing[listing] = Self.dailyReturns(points)
        }

        return pairs.map { a, b in
            computePair(
                a: a, b: b,
                returnsA: returnsByListing[a] ?? [:],
                returnsB: returnsByListing[b] ?? [:]
            )
        }
    }

    // MARK: - 单对计算

    private func computePair(
        a: ListingID, b: ListingID,
        returnsA: [Date: Decimal], returnsB: [Date: Decimal]
    ) -> CorrelationPair {
        // 严格同日配对，窗口截断（尾部 windowReturns 个）
        let commonDates = Set(returnsA.keys).intersection(returnsB.keys).sorted()
        let windowed = commonDates.suffix(parameters.windowReturns)
        let paired = windowed.map { ($0, returnsA[$0]!, returnsB[$0]!) }

        guard !paired.isEmpty else {
            return CorrelationPair(
                listingA: a, listingB: b, pearson: nil, sampleCount: 0,
                insufficiency: .init(reason: .noOverlappingDates, requiredSamples: nil)
            )
        }
        guard paired.count >= parameters.minSampleCount else {
            return CorrelationPair(
                listingA: a, listingB: b, pearson: nil, sampleCount: paired.count,
                insufficiency: .init(reason: .insufficientSamples, requiredSamples: parameters.minSampleCount)
            )
        }

        let xs = paired.map(\.1)
        let ys = paired.map(\.2)
        let n = Decimal(paired.count)
        let meanX = xs.reduce(Decimal.zero, +) / n
        let meanY = ys.reduce(Decimal.zero, +) / n
        var sumXY: Decimal = .zero
        var sumXX: Decimal = .zero
        var sumYY: Decimal = .zero
        for (x, y) in zip(xs, ys) {
            let dx = x - meanX
            let dy = y - meanY
            sumXY += dx * dy
            sumXX += dx * dx
            sumYY += dy * dy
        }

        // 零方差（任一侧恒定）→ 数学无定义，不猜
        guard sumXX > 0, sumYY > 0 else {
            return CorrelationPair(
                listingA: a, listingB: b, pearson: nil, sampleCount: paired.count,
                insufficiency: .init(reason: .zeroVariance, requiredSamples: nil)
            )
        }

        let denominator = (sumXX * sumYY).decimalSquareRoot()
        let r = (sumXY / denominator).rounded(toScale: FactorMetric.metricScale)
        return CorrelationPair(
            listingA: a, listingB: b, pearson: Ratio(value: r),
            sampleCount: paired.count, insufficiency: nil
        )
    }

    /// 序列 → 日收益率（按 effectiveAt 索引；相邻 bar 间隔无要求，收益率
    /// 只对「序列内相邻两根」定义——序列已按 PIT 语义每日一条）。
    private static func dailyReturns(_ points: [AdjustedClosePoint]) -> [Date: Decimal] {
        let sorted = points.sorted { $0.effectiveAt < $1.effectiveAt }
        var result: [Date: Decimal] = [:]
        for i in 1..<sorted.count {
            let older = sorted[i - 1].adjustedClose
            let newer = sorted[i].adjustedClose
            guard older != 0 else { continue }
            result[sorted[i].effectiveAt] = newer / older - 1
        }
        return result
    }
}
