import Foundation

/// 信号服务（actor）：抽取入库（去重/反向失效）→ 到期结算 → 胜率校准查询。
///
/// 与 DecisionCase 的关系：正交互补，数据不互写——信号不自动建 Case，Case 不产信号。
/// 结算数据源：MarketDataEngine 日 K（仅 marketSettleable 的信号）。
actor MarketSignalService {
    private let store: MarketSignalStore
    private let engine: MarketDataEngine?
    private let now: () -> Date

    init(
        store: MarketSignalStore,
        engine: MarketDataEngine? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.engine = engine
        self.now = now
    }

    // MARK: - 抽取入库

    struct IngestSummary {
        var created = 0
        var duplicates = 0
        var invalidatedOpposites = 0
    }

    /// 从趋势报告抽取并入库。同 dedupKey 且 7 天内已存在 → 跳过；
    /// 同标的出现反向 active 信号 → 旧信号 invalidated(superseded)。
    func ingest(report: TrendAnalysisReport) throws -> IngestSummary {
        let candidates = MarketSignalExtractor.extract(from: report, now: now())
        return try ingest(signals: candidates)
    }

    func ingest(signals: [MarketDecisionSignal]) throws -> IngestSummary {
        var summary = IngestSummary()
        guard !signals.isEmpty else { return summary }
        var existing = store.loadAll()

        for signal in signals {
            // 去重：同 dedupKey 7 天内已存在
            let cutoff = signal.createdAt
            if let duplicate = existing.first(where: { existingSignal in
                existingSignal.dedupKey == signal.dedupKey
                    && existingSignal.status != .invalidated
                    && daysBetween(existingSignal.createdAt, cutoff) < 7
            }) {
                _ = duplicate
                summary.duplicates += 1
                continue
            }

            // 反向失效：同标的（代码或名称）反方向 active 信号作废
            if signal.direction != .hold, let subjectCode = signal.subjectCode {
                for index in existing.indices
                where existing[index].status == .active
                    && existing[index].direction != .hold
                    && existing[index].direction != signal.direction
                    && existing[index].subjectCode == subjectCode {
                    existing[index].status = .invalidated
                    existing[index].settlement = SignalSettlement(
                        settledAt: signal.createdAt,
                        outcome: .superseded,
                        settlePrice: nil,
                        settleDate: nil,
                        maxFavorablePct: nil,
                        maxAdversePct: nil,
                        note: "同标的出现反向信号「\(signal.reason.prefix(40))」，旧判断作废"
                    )
                    existing[index].events.append(
                        SignalEvent(at: signal.createdAt, type: .superseded, reason: "被反向信号取代（\(signal.direction.displayName)）")
                    )
                    summary.invalidatedOpposites += 1
                }
            }

            existing.append(signal)
            summary.created += 1
        }

        try store.saveAll(existing)
        return summary
    }

    // MARK: - 结算

    struct SettleSummary {
        var settledWin = 0
        var settledLoss = 0
        var expired = 0
        var insufficientData = 0
        var stillActive = 0
    }

    /// 结算所有到期/触价的 active 信号。每日盘后调用一次。
    func settleDueSignals(asOf: String? = nil) async throws -> SettleSummary {
        var summary = SettleSummary()
        let all = store.loadAll()
        let asOfText = asOf ?? timestamp(now())
        var changed: [MarketDecisionSignal] = []

        for var signal in all where signal.status == .active {
            // 无可结算条件的信号：到期直接 expiredUnresolved
            if !signal.marketSettleable || !signal.priceConditions.isSettleable {
                if MarketSignalSettler.isPastDue(signal: signal, asOf: asOfText, now: now()) {
                    signal.status = .expiredUnresolved
                    signal.settlement = SignalSettlement(
                        settledAt: asOfText,
                        outcome: .expiredUnresolved,
                        settlePrice: nil,
                        settleDate: nil,
                        maxFavorablePct: nil,
                        maxAdversePct: nil,
                        note: signal.marketSettleable
                            ? "价格条件不可自动求值（自然语言条件），到期未触发"
                            : "无可市价结算标的（组合级/场外标的），到期未触发；计入样本不计入胜率分子"
                    )
                    signal.events.append(SignalEvent(at: asOfText, type: .expired, reason: "复查期到"))
                    summary.expired += 1
                    changed.append(signal)
                } else {
                    summary.stillActive += 1
                }
                continue
            }

            guard let engine, let code = signal.subjectCode else {
                summary.stillActive += 1
                continue
            }
            let bars = (try? await engine.dailyBars(code: code, days: 20)) ?? []
            let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: asOfText, now: now())
            switch result.status {
            case .settledWin:
                summary.settledWin += 1
            case .settledLoss:
                summary.settledLoss += 1
            case .expiredUnresolved:
                summary.expired += 1
            case .insufficientData:
                summary.insufficientData += 1
            case .active:
                summary.stillActive += 1
                continue // 无变化不落盘
            case .invalidated:
                continue
            }
            signal.status = result.status
            signal.settlement = result.settlement
            if let event = result.event {
                signal.events.append(event)
            }
            changed.append(signal)
        }

        if !changed.isEmpty {
            try store.saveAll(changed)
        }
        return summary
    }

    // MARK: - 校准

    private var cachedMemory: SignalAccuracyMemory?

    /// 胜率记忆（懒加载 + 失效）。
    func accuracyMemory() -> SignalAccuracyMemory {
        if let cachedMemory { return cachedMemory }
        let memory = SignalAccuracyMemory.build(from: store.loadAll(), asOf: timestamp(now()), now: now())
        cachedMemory = memory
        return memory
    }

    /// 入库时对新信号应用校准（覆盖 calibratedConfidence）。
    func calibratedSignal(_ signal: MarketDecisionSignal) -> MarketDecisionSignal {
        var calibrated = signal
        let memory = accuracyMemory()
        calibrated.calibratedConfidence = memory.calibratedConfidence(
            raw: signal.rawConfidence,
            direction: signal.direction,
            subjectCode: signal.subjectCode,
            sourceKind: signal.sourceKind
        )
        return calibrated
    }

    func calibrationSummary(direction: CanonicalDecisionType, subjectCode: String?) -> String? {
        accuracyMemory().calibrationSummary(
            direction: direction,
            subjectCode: subjectCode,
            sourceKind: .trendReport
        )
    }

    func invalidateMemoryCache() {
        cachedMemory = nil
    }

    // MARK: - 查询

    func allSignals() -> [MarketDecisionSignal] {
        store.loadAll()
    }

    func activeSignals() -> [MarketDecisionSignal] {
        store.loadAll().filter { $0.status == .active }
    }

    // MARK: - 内部

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func daysBetween(_ lhs: String, _ rhs: String) -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let left = formatter.date(from: lhs), let right = formatter.date(from: rhs) else { return .max }
        return Int(abs(right.timeIntervalSince(left)) / 86_400)
    }
}
