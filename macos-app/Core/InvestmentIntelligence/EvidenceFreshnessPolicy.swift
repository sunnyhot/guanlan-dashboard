import Foundation

// Evidence 时效引擎(Slice 4)。
//
// TrendSourceFreshnessPolicy 只覆盖 quote 类(行情/净值)的时效。
// 本引擎覆盖事件类证据(webSearch/officialFiling/officialFinancial/fundDisclosure)的衰减,
// 按来源使用不同策略:
// - webSearch:按 publishedAt 距今的天数衰减(7 天内 fresh,30 天内 previousSessionClose,超 stale)
// - officialFiling/officialFinancial:按 publishedAt,90 天内 fresh(官方文件有效期长)
// - fundDisclosure:按报告期(季报 120 天内有效)
// - 其余:用 metadata.freshnessStatus 兜底,无则 unknown
//
// 见 docs/ai-pipeline-baseline.md 第 9.2 节(需新建:时效评分)。

enum EvidenceFreshnessPolicy {

    /// 中国时区(与 TrendSourceFreshnessPolicy 一致)。
    private static let timezone = TimeZone(identifier: "Asia/Shanghai")!

    // 衰减阈值(天)
    private static let webFreshDays: Double = 7
    private static let webStaleDays: Double = 30
    private static let filingFreshDays: Double = 90
    private static let filingStaleDays: Double = 365
    private static let disclosureFreshDays: Double = 120
    private static let disclosureStaleDays: Double = 365

    /// 评估单条证据的时效状态。
    static func assess(_ evidence: TrendEvidence, asOf referenceDate: Date = Date()) -> TrendFreshnessStatus {
        let kind = evidence.metadata.sourceKind

        // quote 类委托给现有 policy(如果有 freshnessStatus 就用它)
        if kind == .marketQuote || kind == .portfolioSnapshot || kind == .platformSignal || kind == .managerSignal {
            return evidence.metadata.freshnessStatus ?? .unknown
        }

        // 事件类:按 publishedAt 衰减
        guard let publishedAt = evidence.publishedAt.flatMap({ parse($0) }) else {
            // 无 publishedAt,尝试 retrievedAt(retrievedAt 是非 optional String)
            if parse(evidence.retrievedAt) != nil {
                return .previousSessionClose  // 有 retrievedAt 但无 publishedAt → 视为可引用但非最新
            }
            return .unknown
        }

        let ageDays = referenceDate.timeIntervalSince(publishedAt) / 86400

        switch kind {
        case .webSearch:
            return ageThreshold(ageDays, fresh: webFreshDays, stale: webStaleDays)
        case .officialFiling, .officialFinancial:
            return ageThreshold(ageDays, fresh: filingFreshDays, stale: filingStaleDays)
        case .fundDisclosure:
            return ageThreshold(ageDays, fresh: disclosureFreshDays, stale: disclosureStaleDays)
        case .licensedMarketData:
            return ageThreshold(ageDays, fresh: webFreshDays, stale: webStaleDays)
        case .derived, .unknown:
            return evidence.metadata.freshnessStatus ?? .unknown
        case .marketQuote, .portfolioSnapshot, .platformSignal, .managerSignal:
            return evidence.metadata.freshnessStatus ?? .unknown
        }
    }

    /// 批量评估,返回每条证据的时效 + 统计。
    static func assessBatch(_ evidence: [TrendEvidence], asOf referenceDate: Date = Date()) -> EvidenceFreshnessSummary {
        var statuses: [(TrendEvidence, TrendFreshnessStatus)] = []
        for e in evidence {
            statuses.append((e, assess(e, asOf: referenceDate)))
        }
        let freshCount = statuses.filter { $0.1 == .fresh }.count
        let previousCloseCount = statuses.filter { $0.1 == .previousSessionClose }.count
        let staleCount = statuses.filter { $0.1 == .stale }.count
        return EvidenceFreshnessSummary(
            perEvidence: statuses,
            freshCount: freshCount,
            usableCount: freshCount + previousCloseCount,  // fresh + previousSessionClose 可用
            staleCount: staleCount
        )
    }

    // MARK: - 内部

    private static func ageThreshold(_ ageDays: Double, fresh: Double, stale: Double) -> TrendFreshnessStatus {
        if ageDays < 0 { return .unknown }  // 未来日期(数据错误)
        if ageDays <= fresh { return .fresh }
        if ageDays <= stale { return .previousSessionClose }
        return .stale
    }

    private static func parse(_ value: String) -> Date? {
        // 尝试多种格式(与 TrendSourceFreshnessPolicy.parse 兼容)
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        // ISO8601 兜底
        return ISO8601DateFormatter().date(from: value)
    }
}

/// 时效评估汇总。
struct EvidenceFreshnessSummary {
    let perEvidence: [(TrendEvidence, TrendFreshnessStatus)]
    let freshCount: Int
    let usableCount: Int     // fresh + previousSessionClose
    let staleCount: Int
}
