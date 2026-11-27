import Foundation

// MARK: - 基金估值融合

/// 单个数据源给出的估值候选。
struct FundEstimateCandidate: Hashable, Sendable {
    /// 来源标识（与校准台账 `source` 对齐）。
    let source: String
    /// 来源展示名（如「东方财富盘中估值」「持仓穿透」）。
    let sourceLabel: String
    /// 估算涨幅（百分数）。
    let changePct: Double
    /// 估算净值。
    let estimatedNav: Double
    /// 估值时间（数据源给的，`yyyy-MM-dd HH:mm` 或 `yyyy-MM-dd`）。
    let estimatedAt: String
    /// 来源内在可信度 0...1（穿透引擎按覆盖率给；外部源默认 1）。
    let intrinsicConfidence: Double
    /// 穿透贡献明细（仅穿透源有）。
    let topContributors: [FundEstimateContribution]

    init(
        source: String,
        sourceLabel: String,
        changePct: Double,
        estimatedNav: Double,
        estimatedAt: String,
        intrinsicConfidence: Double = 1,
        topContributors: [FundEstimateContribution] = []
    ) {
        self.source = source
        self.sourceLabel = sourceLabel
        self.changePct = changePct
        self.estimatedNav = estimatedNav
        self.estimatedAt = estimatedAt
        self.intrinsicConfidence = intrinsicConfidence
        self.topContributors = topContributors
    }
}

/// 融合结果。
struct FundEstimateFusionResult: Hashable, Sendable {
    /// 融合后估算涨幅（百分数，已去偏）。
    let changePct: Double
    /// 融合后估算净值。
    let estimatedNav: Double
    /// 融合后估值时间（取参与融合来源中最新的）。
    let estimatedAt: String
    /// 来源展示：单一来源用其标签；多源为「A · B」。
    let sourceLabel: String
    /// 主导来源标识（校准落账用）。
    let primarySource: String
    /// 参与融合的来源数。
    let fusedSourceCount: Int
    /// 来源间最大分歧（百分点）。`nil` 表示只有一个来源。
    let maxDisagreementPct: Double?
    /// 分歧是否显著（超过 `FundEstimateFusionEngine.disagreementThresholdPct`）。
    let hasSignificantDisagreement: Bool
    /// 融合后可信度。
    let confidence: FundEstimateConfidence
    /// 误差带半宽（百分点），用于 UI 展示「±x%」。
    let errorBandPct: Double?
    /// 穿透贡献（若主导来源为穿透）。
    let topContributors: [FundEstimateContribution]
    /// 各来源及其权重，供调试/CLI。
    let weightsBySource: [String: Double]
}

/// 多源估值融合引擎：纯计算。
///
/// 规则：
/// 1. 只融合估值时间为**今天**的候选（隔天估值不参与）。
/// 2. 每个候选权重 = 校准可信度权重 × 内在可信度 × 新鲜度因子。
/// 3. 先按各来源历史 bias 去偏，再加权平均。
/// 4. 来源间最大分歧超过阈值时标记 `hasSignificantDisagreement`，UI 提示。
/// 5. 没有任何已校准来源时，退化为「新鲜度优先 + 内在可信度」。
enum FundEstimateFusionEngine {
    /// 分歧阈值（百分点）。两只来源差超过此值视为显著分歧。
    static let disagreementThresholdPct = 0.30
    /// 新鲜度衰减半衰期（分钟）：估值时间距今超过该值，权重减半。
    static let freshnessHalfLifeMinutes = 20.0
    /// 新鲜度最低因子，避免极端陈旧的来源被完全忽略。
    static let minimumFreshnessFactor = 0.15
    /// 超过该分钟数视为隔天/失效（不参与融合）。
    static let maximumAgeMinutes = 6 * 60

    static func fuse(
        candidates: [FundEstimateCandidate],
        fundCode: String,
        officialNav: Double,
        ledger: FundEstimateCalibrationLedger,
        now: Date = Date()
    ) -> FundEstimateFusionResult? {
        let valid = candidates.filter {
            $0.changePct.isFinite
                && $0.estimatedNav.isFinite
                && $0.estimatedNav > 0
                && abs($0.changePct) <= 50
                && isToday($0.estimatedAt, now: now)
        }
        guard !valid.isEmpty else { return nil }

        // 单一来源：直接去偏返回，不触发分歧判断。
        if valid.count == 1, let only = valid.first {
            let debiased = ledger.debiasedChangePct(only.changePct, fundCode: fundCode, source: only.source)
            let stats = ledger.stats(fundCode: fundCode, source: only.source)
            // 未去偏时直接沿用来源自己算的净值（来源内部用未舍入净值计算，比我们用涨幅反算更准）；
            // 去偏后只能用涨幅反算。
            let nav = debiased == only.changePct
                ? only.estimatedNav
                : (officialNav > 0 ? officialNav * (1 + debiased / 100) : only.estimatedNav)
            return FundEstimateFusionResult(
                changePct: debiased,
                estimatedNav: nav,
                estimatedAt: only.estimatedAt,
                sourceLabel: only.sourceLabel,
                primarySource: only.source,
                fusedSourceCount: 1,
                maxDisagreementPct: nil,
                hasSignificantDisagreement: false,
                confidence: stats.confidence,
                errorBandPct: stats.errorBandPct,
                topContributors: only.topContributors,
                weightsBySource: [only.source: 1]
            )
        }

        let hasCalibration = valid.contains { ledger.stats(fundCode: fundCode, source: $0.source).sampleCount >= 3 }

        // 指数基金若存在跟踪指数候选，它就是权威（跟踪误差通常 <0.1%），
        // 其它来源（第三方估值/穿透）只作方向性参考，权重打折——避免新浪等对指数基金的高估把结果带偏。
        let hasTrackingIndex = valid.contains { $0.source == FundEstimateSource.trackingIndex.rawValue }

        var weights: [String: Double] = [:]
        var debiasedBySource: [String: Double] = [:]
        var statsBySource: [String: FundEstimateAccuracyStats] = [:]
        var totalWeight = 0.0
        for candidate in valid {
            let stats = ledger.stats(fundCode: fundCode, source: candidate.source)
            statsBySource[candidate.source] = stats
            let calibrationWeight = stats.confidence.fusionWeight
            let freshness = freshnessFactor(estimatedAt: candidate.estimatedAt, now: now)
            var weight = calibrationWeight * max(0.05, candidate.intrinsicConfidence) * freshness
            if !hasCalibration {
                // 未校准：RMSE 倒数不可得，退化为「内在可信度 × 新鲜度」。
                weight = max(0.05, candidate.intrinsicConfidence) * freshness
            }
            if hasTrackingIndex, candidate.source != FundEstimateSource.trackingIndex.rawValue {
                weight *= 0.3
            }
            weight = max(weight, 0.01)
            weights[candidate.source] = weight
            debiasedBySource[candidate.source] = ledger.debiasedChangePct(
                candidate.changePct, fundCode: fundCode, source: candidate.source
            )
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }

        var fused = 0.0
        for candidate in valid {
            let w = (weights[candidate.source] ?? 0) / totalWeight
            fused += (debiasedBySource[candidate.source] ?? candidate.changePct) * w
        }

        let sortedByTime = valid.sorted { $0.estimatedAt > $1.estimatedAt }
        let latest = sortedByTime.first!
        let primary = valid.max { (weights[$0.source] ?? 0) < (weights[$1.source] ?? 0) } ?? latest
        let changes = valid.map { debiasedBySource[$0.source] ?? $0.changePct }
        let disagreement = (changes.max() ?? 0) - (changes.min() ?? 0)

        // 融合后可信度 = 各源 RMSE 按权重加权后的等效 RMSE（而非把所有源误差混在一起算，
        // 否则一个不可信的次要点源会把整体拉成 low，与融合结果的真实精度不符）。
        var weightedRMSE = 0.0
        var weightedCount = 0.0
        for candidate in valid {
            let s = statsBySource[candidate.source] ?? .empty
            guard s.sampleCount >= 3 else { continue }
            let w = (weights[candidate.source] ?? 0) / totalWeight
            weightedRMSE += s.rmsePct * w
            weightedCount += w
        }
        // 未校准来源按「中等」先验 0.3% 计入，避免完全忽略。
        if weightedCount < 1 {
            weightedRMSE += 0.3 * (1 - weightedCount)
            weightedCount = 1
        }
        let confidence = hasCalibration
            ? FundEstimateConfidence.from(rmse: weightedRMSE, sampleCount: 3)
            : FundEstimateConfidence.unknown

        let labels = sortedByTime.map(\.sourceLabel).reduce(into: [String]()) { acc, label in
            if !acc.contains(label) { acc.append(label) }
        }

        return FundEstimateFusionResult(
            changePct: fused,
            estimatedNav: officialNav > 0 ? officialNav * (1 + fused / 100) : latest.estimatedNav,
            estimatedAt: latest.estimatedAt,
            sourceLabel: labels.joined(separator: " · "),
            primarySource: primary.source,
            fusedSourceCount: valid.count,
            maxDisagreementPct: disagreement,
            hasSignificantDisagreement: disagreement > disagreementThresholdPct,
            confidence: confidence,
            errorBandPct: hasCalibration && weightedCount > 0 ? min(3.0, 1.96 * weightedRMSE) : nil,
            topContributors: primary.topContributors,
            weightsBySource: weights
        )
    }

    /// 新鲜度因子：指数衰减，半衰期 `freshnessHalfLifeMinutes`，下限 `minimumFreshnessFactor`。
    static func freshnessFactor(estimatedAt: String, now: Date) -> Double {
        guard let age = ageMinutes(of: estimatedAt, now: now) else {
            return minimumFreshnessFactor
        }
        guard age >= 0 else { return 1 }
        let factor = pow(0.5, age / freshnessHalfLifeMinutes)
        return max(minimumFreshnessFactor, min(1, factor))
    }

    /// 估值时间距今的分钟数。无法解析返回 nil。
    static func ageMinutes(of estimatedAt: String, now: Date) -> Double? {
        guard let date = parseEstimateTime(estimatedAt) else { return nil }
        return now.timeIntervalSince(date) / 60
    }

    /// 解析估值时间：支持 `yyyy-MM-dd HH:mm:ss`、`yyyy-MM-dd HH:mm`、`yyyy-MM-dd`（按 15:00 收盘）。
    static func parseEstimateTime(_ text: String) -> Date? {
        // 腾讯港股行情时间形如 "2026/11/27 15:48:28"，统一斜杠为短横线。
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard trimmed.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let day = String(trimmed.prefix(10))
        let rest = trimmed.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: " T"))
        if rest.isEmpty {
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: day) else { return nil }
            return formatter.calendar.date(byAdding: .hour, value: 15, to: date) ?? date
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        // 「yyyy-MM-dd HH:mm」只有 16 位时补 :00
        if rest.count == 5, let date = formatter.date(from: day + " " + rest + ":00") {
            return date
        }
        return nil
    }

    static func isToday(_ estimatedAt: String, now: Date) -> Bool {
        guard let date = parseEstimateTime(estimatedAt) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.isDate(date, inSameDayAs: now)
    }
}

/// 估值来源标识（与校准台账 `source` 字段对齐，不要随意改动 rawValue）。
enum FundEstimateSource: String, Codable, Hashable, Sendable {
    /// 东方财富 `fundgz` 盘中估值。
    case eastmoneyLegacyEstimate = "eastmoney_legacy_estimate"
    /// 新浪 `fu_` 盘中估值。
    case sinaEstimate = "sina_estimate"
    /// 持仓穿透自算。
    case holdingsLookThrough = "holdings_lookthrough"
    /// 跟踪指数/ETF 直接代理。
    case trackingIndex = "tracking_index"
    /// 旧版按基金名猜代理。
    case marketProxyEstimate = "market_proxy_estimate"

    var displayName: String {
        switch self {
        case .eastmoneyLegacyEstimate: return "东方财富盘中估值"
        case .sinaEstimate: return "新浪盘中估值"
        case .holdingsLookThrough: return "持仓穿透"
        case .trackingIndex: return "跟踪指数"
        case .marketProxyEstimate: return "代理估算"
        }
    }
}
