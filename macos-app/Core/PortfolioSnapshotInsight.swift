import Foundation

struct PortfolioInsightSnapshot: Codable, Hashable, Identifiable {
    var id: String { createdAt }

    let createdAt: String
    let totalExposure: Double
    let totalMarketValue: Double
    let pendingAmount: Double
    let nextPlanAmount: Double
    let topHoldingName: String?
    let topHoldingWeightPct: Double
    let holdingCount: Int

    static func make(rows: [PersonalAssetAggregateRow], createdAt: String) -> PortfolioInsightSnapshot {
        let totalExposure = rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        let totalMarketValue = rows.reduce(0) { $0 + ($1.marketValue ?? 0) }
        let pendingAmount = rows.reduce(0) { $0 + $1.pendingCashAmount }
        let nextPlanAmount = rows.reduce(0) { $0 + $1.estimatedNextPlanAmount }
        let top = rows.max { $0.effectiveHoldingAmount < $1.effectiveHoldingAmount }
        let topWeight = totalExposure > 0 ? (top?.effectiveHoldingAmount ?? 0) / totalExposure * 100 : 0

        return PortfolioInsightSnapshot(
            createdAt: createdAt,
            totalExposure: totalExposure,
            totalMarketValue: totalMarketValue,
            pendingAmount: pendingAmount,
            nextPlanAmount: nextPlanAmount,
            topHoldingName: top?.fundName,
            topHoldingWeightPct: topWeight,
            holdingCount: rows.filter(\.hasHolding).count
        )
    }
}

enum PortfolioSnapshotInsightKind: String, Codable, CaseIterable, Hashable {
    case assetChange
    case concentrationDrift
    case pendingImpact
    case planImpact
    case coverage
}

enum PortfolioSnapshotInsightTone: String, Codable, Hashable {
    case gain
    case loss
    case warning
    case info
    case neutral
}

struct PortfolioSnapshotInsightCard: Identifiable, Codable, Hashable {
    let kind: PortfolioSnapshotInsightKind
    let title: String
    let metric: String
    let detail: String
    let tone: PortfolioSnapshotInsightTone

    var id: PortfolioSnapshotInsightKind { kind }
}

struct PortfolioSnapshotInsightSummary: Codable, Hashable {
    let headline: String
    let hasEnoughHistory: Bool
    let cards: [PortfolioSnapshotInsightCard]

    static func make(
        snapshots: [PortfolioInsightSnapshot],
        currentRows: [PersonalAssetAggregateRow]
    ) -> PortfolioSnapshotInsightSummary {
        let sorted = snapshots.sorted { $0.createdAt < $1.createdAt }
        let pendingAmount = currentRows.reduce(0) { $0 + $1.pendingCashAmount }
        let nextPlanAmount = currentRows.reduce(0) { $0 + $1.estimatedNextPlanAmount }

        guard sorted.count >= 2, let previous = sorted.dropLast().last, let latest = sorted.last else {
            return PortfolioSnapshotInsightSummary(
                headline: "等待组合快照",
                hasEnoughHistory: false,
                cards: [
                    PortfolioSnapshotInsightCard(
                        kind: .coverage,
                        title: "数据覆盖",
                        metric: "\(sorted.count) / 2",
                        detail: "至少需要两次组合快照才能生成变化洞察",
                        tone: .info
                    )
                ]
            )
        }

        let exposureDelta = latest.totalExposure - previous.totalExposure
        let topWeightDelta = latest.topHoldingWeightPct - previous.topHoldingWeightPct
        let headlineVerb = exposureDelta >= 0 ? "增加" : "减少"
        let headline = "组合占用\(headlineVerb) \(currencyText(abs(exposureDelta)))"
        let driftMetric = String(format: "%+.2f pct", topWeightDelta)

        return PortfolioSnapshotInsightSummary(
            headline: headline,
            hasEnoughHistory: true,
            cards: [
                PortfolioSnapshotInsightCard(
                    kind: .assetChange,
                    title: "资产变化",
                    metric: signedCurrencyText(exposureDelta),
                    detail: "\(previous.createdAt) 到 \(latest.createdAt)",
                    tone: exposureDelta > 0 ? .gain : (exposureDelta < 0 ? .loss : .neutral)
                ),
                PortfolioSnapshotInsightCard(
                    kind: .concentrationDrift,
                    title: "集中度漂移",
                    metric: driftMetric,
                    detail: latest.topHoldingName.map { "第一大标的：\($0)" } ?? "暂无第一大标的",
                    tone: abs(topWeightDelta) >= 10 ? .warning : .info
                ),
                PortfolioSnapshotInsightCard(
                    kind: .pendingImpact,
                    title: "待确认影响",
                    metric: currencyText(pendingAmount),
                    detail: pendingAmount > 0 ? "买入中或转换记录会影响实际敞口" : "暂无待确认交易影响",
                    tone: pendingAmount > 0 ? .warning : .neutral
                ),
                PortfolioSnapshotInsightCard(
                    kind: .planImpact,
                    title: "计划影响",
                    metric: currencyText(nextPlanAmount),
                    detail: nextPlanAmount > 0 ? "下一次计划投入估算" : "暂无进行中计划投入",
                    tone: nextPlanAmount > 0 ? .info : .neutral
                ),
                PortfolioSnapshotInsightCard(
                    kind: .coverage,
                    title: "快照覆盖",
                    metric: "\(sorted.count) 次",
                    detail: "最近快照：\(latest.createdAt)",
                    tone: .info
                )
            ]
        )
    }
}

struct PortfolioSnapshotInsightStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let maxCount: Int

    init(maxCount: Int = 30) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.maxCount = maxCount
    }

    func load(from fileURL: URL) throws -> [PortfolioInsightSnapshot] {
        try JSONFilePersistence.load(
            [PortfolioInsightSnapshot].self,
            from: fileURL,
            defaultValue: [],
            decoder: decoder
        )
            .sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ snapshots: [PortfolioInsightSnapshot], to fileURL: URL) throws {
        let pruned = Array(snapshots.sorted { $0.createdAt < $1.createdAt }.suffix(maxCount))
        try JSONFilePersistence.save(pruned, to: fileURL, encoder: encoder)
    }

    func append(_ snapshot: PortfolioInsightSnapshot, to fileURL: URL) throws {
        let existing = try load(from: fileURL)
        var withoutSameTimestamp = existing.filter { $0.createdAt != snapshot.createdAt }
        withoutSameTimestamp.append(snapshot)
        try save(withoutSameTimestamp, to: fileURL)
    }
}
