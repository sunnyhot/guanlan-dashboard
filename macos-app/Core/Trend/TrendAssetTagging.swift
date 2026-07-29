import Foundation

enum TrendAssetTagTone: String, Hashable {
    case brand
    case positive
    case info
    case warning
    case danger
    case muted
}

struct TrendAssetInlineTag: Identifiable, Hashable {
    let id: String
    let dimension: String
    let text: String
    let tone: TrendAssetTagTone
}

struct TrendAssetTradePlan: Identifiable, Hashable {
    let id: String
    let label: String
    let method: String
    let detail: String
    let source: String
    let triggerConditions: [String]
    let invalidatingConditions: [String]
    let tone: TrendAssetTagTone
}

struct TrendAssetTagSummary: Identifiable, Hashable {
    let id: String
    let assetName: String
    let code: String?
    let sector: String
    let impactText: String
    let rationale: String
    let generatedAt: String
    let dataAsOf: String
    let primaryDirection: TrendDirection?
    let primaryConfidence: TrendConfidence
    let horizons: [TrendHorizonView]
    let counterSignals: [String]
    let relatedActions: [TrendActionCandidate]
    let tradePlan: TrendAssetTradePlan
    let tags: [TrendAssetInlineTag]
}

struct TrendAssetTagIndex: Hashable {
    private let report: TrendAnalysisReport?
    private let summaries: [TrendAssetTagSummary]
    private let summariesByCode: [String: TrendAssetTagSummary]
    private let summariesByName: [String: TrendAssetTagSummary]
    private let sectors: [TrendSectorView]

    var isEmpty: Bool {
        report == nil
    }

    init(report: TrendAnalysisReport?) {
        guard let report else {
            self.report = nil
            summaries = []
            summariesByCode = [:]
            summariesByName = [:]
            sectors = []
            return
        }

        self.report = report
        let assets = report.assetTrends + report.keyAssets.filter { keyAsset in
            !report.assetTrends.contains { trend in
                Self.normalizedCode(trend.code) == Self.normalizedCode(keyAsset.code)
                    || Self.normalizedName(trend.name) == Self.normalizedName(keyAsset.name)
            }
        }
        let builtSummaries = assets.map { asset in
            Self.makeSummary(asset: asset, report: report)
        }
        summaries = builtSummaries
        summariesByCode = Dictionary(
            builtSummaries.flatMap { summary in
                Self.normalizedCodeAliases(summary.code).map { ($0, summary) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        summariesByName = Dictionary(
            builtSummaries.compactMap { summary in
                let name = Self.normalizedName(summary.assetName)
                guard !name.isEmpty else { return nil }
                return (name, summary)
            },
            uniquingKeysWith: { first, _ in first }
        )
        sectors = report.sectors
    }

    func summary(for row: PersonalAssetAggregateRow) -> TrendAssetTagSummary? {
        if let code = Self.normalizedCode(row.fundCode), let summary = summariesByCode[code] {
            return summary
        }

        let rowName = Self.normalizedName(row.fundName)
        if let summary = summariesByName[rowName] {
            return summary
        }

        if let fuzzy = summaries.first(where: { summary in
            let assetName = Self.normalizedName(summary.assetName)
            return !rowName.isEmpty && !assetName.isEmpty && (rowName.contains(assetName) || assetName.contains(rowName))
        }) {
            return fuzzy
        }

        guard let report else { return nil }
        return Self.makeFallbackSummary(row: row, report: report, sector: sectorSummary(for: row))
    }

    private static func makeSummary(asset: TrendAssetView, report: TrendAnalysisReport) -> TrendAssetTagSummary {
        let primaryHorizon = preferredHorizon(asset.horizons)
        let primaryConfidence = primaryHorizon?.confidence ?? TrendConfidence(score: 0, label: "低")
        let relatedActions = report.actions.filter { matches(action: $0, asset: asset) }
        let counterSignals = Array((asset.counterSignals + asset.horizons.flatMap(\.counterSignals)).filter { !$0.isEmpty })
        let tradePlan = makeTradePlan(
            action: relatedActions.first,
            direction: primaryHorizon?.direction,
            confidence: primaryConfidence,
            counterSignals: counterSignals,
            row: nil,
            sourceID: asset.id
        )

        var tags: [TrendAssetInlineTag] = []
        tags.append(TrendAssetInlineTag(
            id: "sector-\(asset.id)",
            dimension: "板块",
            text: asset.sector,
            tone: .brand
        ))
        tags.append(contentsOf: tradePlanTags(tradePlan))
        for horizon in asset.horizons.prefix(3) {
            tags.append(TrendAssetInlineTag(
                id: "\(horizon.horizon.rawValue)-\(asset.id)",
                dimension: horizon.horizon.assetTagText,
                text: horizon.direction.assetTagText,
                tone: horizon.direction.assetTagTone
            ))
        }
        if primaryHorizon != nil {
            tags.append(TrendAssetInlineTag(
                id: "confidence-\(asset.id)",
                dimension: "信心",
                text: "\(primaryConfidence.label)信心",
                tone: confidenceTone(primaryConfidence)
            ))
        }
        if !counterSignals.isEmpty {
            tags.append(TrendAssetInlineTag(
                id: "counter-\(asset.id)",
                dimension: "反证",
                text: "\(counterSignals.count) 条",
                tone: .warning
            ))
        }

        return TrendAssetTagSummary(
            id: asset.id,
            assetName: asset.name,
            code: asset.code,
            sector: asset.sector,
            impactText: asset.impactText,
            rationale: asset.rationale,
            generatedAt: report.generatedAt,
            dataAsOf: report.dataAsOf,
            primaryDirection: primaryHorizon?.direction,
            primaryConfidence: primaryConfidence,
            horizons: asset.horizons,
            counterSignals: counterSignals,
            relatedActions: relatedActions,
            tradePlan: tradePlan,
            tags: tags
        )
    }

    private static func preferredHorizon(_ horizons: [TrendHorizonView]) -> TrendHorizonView? {
        if let short = horizons.first(where: { $0.horizon == .short }) {
            return short
        }
        return horizons.first
    }

    private static func matches(action: TrendActionCandidate, asset: TrendAssetView) -> Bool {
        guard let targetName = action.targetName else { return false }
        let targetCodes = Set(normalizedCodeAliases(targetName))
        let assetCodes = Set(normalizedCodeAliases(asset.code))
        if !targetCodes.isEmpty, !assetCodes.isEmpty, !targetCodes.isDisjoint(with: assetCodes) {
            return true
        }

        let target = normalizedName(targetName)
        let assetName = normalizedName(asset.name)
        guard !target.isEmpty, !assetName.isEmpty else { return false }
        return target.contains(assetName) || assetName.contains(target)
    }

    private static func normalizedCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.isEmpty ? nil : code
    }

    private static func normalizedCodeAliases(_ value: String?) -> [String] {
        guard let value else { return [] }
        let whole = normalizedCode(value).map { [$0] } ?? []
        let split = value
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { normalizedCode(String($0)) }
        return Array(Set(whole + split)).sorted()
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isNewline }
    }

    private func sectorSummary(for row: PersonalAssetAggregateRow) -> TrendSectorView? {
        let rowName = Self.normalizedName(row.fundName)
        if let direct = sectors.first(where: { sector in
            let name = Self.normalizedName(sector.name)
            return !name.isEmpty && (rowName.contains(name) || name.contains(rowName))
        }) {
            return direct
        }

        let inferred = Self.inferredThemeNames(for: row)
        return sectors.first { sector in
            inferred.contains(Self.normalizedName(sector.name))
        }
    }

    private static func makeFallbackSummary(
        row: PersonalAssetAggregateRow,
        report: TrendAnalysisReport,
        sector: TrendSectorView?
    ) -> TrendAssetTagSummary {
        let relatedActions = report.actions.filter { matches(action: $0, row: row) }
        let localSector = sector?.name ?? localSectorName(for: row)
        let direction = sector?.direction ?? .uncertain
        let confidence = sector?.confidence ?? TrendConfidence(score: 0, label: "低")
        let counterSignals = sector?.counterSignals ?? []
        let rationale = sector?.rationale ?? "趋势报告未覆盖到该标的的单独判断，当前先展示本地持仓维度。"
        let impactText = sector?.rationale ?? "趋势报告未覆盖该标的，先显示本地持仓维度；重新生成趋势分析可补齐标的级标签。"
        let tradePlan = makeTradePlan(
            action: relatedActions.first,
            direction: direction,
            confidence: confidence,
            counterSignals: counterSignals,
            row: row,
            sourceID: row.id
        )

        var tags: [TrendAssetInlineTag] = []
        tags.append(TrendAssetInlineTag(
            id: "sector-\(row.id)",
            dimension: sector == nil ? "类别" : "板块",
            text: localSector,
            tone: .brand
        ))
        tags.append(contentsOf: tradePlanTags(tradePlan))
        if let sector {
            tags.append(TrendAssetInlineTag(
                id: "sector-trend-\(sector.id)-\(row.id)",
                dimension: "板块趋势",
                text: sector.direction.assetTagText,
                tone: sector.direction.assetTagTone
            ))
            tags.append(TrendAssetInlineTag(
                id: "confidence-\(row.id)",
                dimension: "信心",
                text: "\(sector.confidence.label)信心",
                tone: confidenceTone(sector.confidence)
            ))
            if !sector.counterSignals.isEmpty {
                tags.append(TrendAssetInlineTag(
                    id: "counter-\(row.id)",
                    dimension: "反证",
                    text: "\(sector.counterSignals.count) 条",
                    tone: .warning
                ))
            }
        } else {
            tags.append(TrendAssetInlineTag(
                id: "coverage-\(row.id)",
                dimension: "覆盖",
                text: "待补齐",
                tone: .muted
            ))
        }

        tags.append(contentsOf: localTags(for: row))

        return TrendAssetTagSummary(
            id: "fallback-\(row.id)",
            assetName: row.fundName,
            code: row.fundCode,
            sector: localSector,
            impactText: impactText,
            rationale: rationale,
            generatedAt: report.generatedAt,
            dataAsOf: report.dataAsOf,
            primaryDirection: direction,
            primaryConfidence: confidence,
            horizons: [],
            counterSignals: counterSignals,
            relatedActions: relatedActions,
            tradePlan: tradePlan,
            tags: tags
        )
    }

    private static func tradePlanTags(_ plan: TrendAssetTradePlan) -> [TrendAssetInlineTag] {
        [
            TrendAssetInlineTag(
                id: "trade-action-\(plan.id)",
                dimension: "动作",
                text: plan.label,
                tone: plan.tone
            ),
            TrendAssetInlineTag(
                id: "trade-method-\(plan.id)",
                dimension: "方式",
                text: plan.method,
                tone: plan.tone
            )
        ]
    }

    private static func makeTradePlan(
        action: TrendActionCandidate?,
        direction: TrendDirection?,
        confidence: TrendConfidence,
        counterSignals: [String],
        row: PersonalAssetAggregateRow?,
        sourceID: String
    ) -> TrendAssetTradePlan {
        if let action {
            return tradePlan(from: action, fallbackCounterSignals: counterSignals, sourceID: sourceID)
        }

        if row?.hasPending == true {
            return TrendAssetTradePlan(
                id: "pending-\(sourceID)",
                label: "等待确认",
                method: "先确认成交",
                detail: "该标的已有待确认交易，先确认成交、金额和持仓变化，再决定是否继续买入或卖出，避免重复下单。",
                source: "本地持仓",
                triggerConditions: ["待确认交易完成或撤销", "更新后的仓位仍符合计划"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .info
            )
        }

        switch direction ?? .uncertain {
        case .bullish, .neutralPositive:
            return TrendAssetTradePlan(
                id: "buy-\(sourceID)",
                label: "买入观察",
                method: "分批买入",
                detail: "趋势偏强时只在预算允许且未触发反证下分批买入，优先小额试探或跟随既有计划，避免一次性追高。",
                source: "趋势推导",
                triggerConditions: ["短期趋势维持偏强", "未触发反证条件", "组合仓位仍有预算空间"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .positive
            )
        case .neutral:
            return TrendAssetTradePlan(
                id: "hold-\(sourceID)",
                label: "持有观察",
                method: row?.activePlanCount ?? 0 > 0 ? "按计划定投" : "不追涨",
                detail: "趋势中性时以持有观察为主，已有计划按节奏执行；没有计划时等待更明确的方向，不因为短期波动追买追卖。",
                source: "趋势推导",
                triggerConditions: ["方向转为偏强后再考虑加仓", "方向转弱或风险暴露升高后再复核减仓"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .info
            )
        case .neutralNegative:
            if row?.activePlanCount ?? 0 > 0 {
                return TrendAssetTradePlan(
                    id: "pause-\(sourceID)",
                    label: "暂停买入",
                    method: "暂停定投",
                    detail: "短期偏弱且仍有进行中计划时，优先复核是否暂停下一期买入；等趋势企稳或反证出现后再恢复。",
                    source: "趋势推导",
                    triggerConditions: ["短期趋势维持偏弱", "计划金额会继续增加风险暴露"],
                    invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                    tone: .warning
                )
            }
            return TrendAssetTradePlan(
                id: "reduce-review-\(sourceID)",
                label: "减仓复核",
                method: "暂停追买",
                detail: "短期偏弱时先暂停新增买入，复核仓位占比和亏损承受度；若弱势扩大，再考虑分批降低敞口。",
                source: "趋势推导",
                triggerConditions: ["短期趋势维持偏弱", "仓位占比或回撤压力需要控制"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .warning
            )
        case .bearish:
            return TrendAssetTradePlan(
                id: "sell-\(sourceID)",
                label: "卖出/减仓",
                method: "分批卖出",
                detail: "趋势明显偏弱且未出现反证时，以分批卖出或降低计划买入为主；先处理高风险敞口，避免一次性情绪化清仓。",
                source: "趋势推导",
                triggerConditions: ["趋势维持偏弱或跌破关键位置", "组合风险暴露需要下降"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .danger
            )
        case .uncertain:
            return TrendAssetTradePlan(
                id: "wait-\(sourceID)",
                label: "持有观察",
                method: "等信号再动",
                detail: "标的级趋势证据不足时暂不新增交易，先等待价格信号、平台调仓信号或模型补齐分析，再决定买入、卖出或继续持有。",
                source: "本地兜底",
                triggerConditions: ["补齐标的级趋势分析", "出现明确价格或调仓信号"],
                invalidatingConditions: defaultInvalidatingConditions(counterSignals),
                tone: .muted
            )
        }
    }

    private static func tradePlan(
        from action: TrendActionCandidate,
        fallbackCounterSignals: [String],
        sourceID: String
    ) -> TrendAssetTradePlan {
        let label: String
        let method: String
        let tone: TrendAssetTagTone

        switch action.kind {
        case .watch:
            label = "持有观察"
            method = "不追涨"
            tone = .info
        case .waitForConfirmation:
            label = "等待确认"
            method = "先确认成交"
            tone = .info
        case .observeInBatches:
            label = "分批观察"
            method = "小额试探"
            tone = .brand
        case .pausePlan:
            label = "暂停买入"
            method = "暂停定投"
            tone = .warning
        case .considerIncrease:
            label = "买入/加仓"
            method = "分批买入"
            tone = .positive
        case .considerReduce:
            label = "卖出/减仓"
            method = "分批卖出"
            tone = .warning
        case .rebalanceReview:
            label = "调仓复核"
            method = "再平衡"
            tone = .brand
        }

        return TrendAssetTradePlan(
            id: "model-\(action.id)-\(sourceID)",
            label: label,
            method: method,
            detail: action.detail,
            source: "模型动作",
            triggerConditions: action.triggerConditions.isEmpty ? defaultTriggerConditions(for: action.kind) : action.triggerConditions,
            invalidatingConditions: action.invalidatingConditions.isEmpty ? defaultInvalidatingConditions(fallbackCounterSignals) : action.invalidatingConditions,
            tone: tone
        )
    }

    private static func defaultTriggerConditions(for kind: TrendActionKind) -> [String] {
        switch kind {
        case .watch:
            return ["等待新的价格、估值或平台调仓信号"]
        case .waitForConfirmation:
            return ["待确认交易完成或撤销后复核"]
        case .observeInBatches:
            return ["方向改善但仍需控制单次投入"]
        case .pausePlan:
            return ["短期偏弱且计划会继续扩大风险暴露"]
        case .considerIncrease:
            return ["趋势维持偏强且未触发反证"]
        case .considerReduce:
            return ["趋势维持偏弱或组合风险暴露过高"]
        case .rebalanceReview:
            return ["组合权重偏离目标或板块风险集中"]
        }
    }

    private static func defaultInvalidatingConditions(_ counterSignals: [String]) -> [String] {
        let cleaned = counterSignals.filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            return Array(cleaned.prefix(3))
        }
        return ["出现与当前趋势相反的量价、估值或平台调仓信号"]
    }

    private static func matches(action: TrendActionCandidate, row: PersonalAssetAggregateRow) -> Bool {
        guard let targetName = action.targetName else { return false }
        let targetCodes = Set(normalizedCodeAliases(targetName))
        let rowCodes = Set(normalizedCodeAliases(row.fundCode))
        if !targetCodes.isEmpty, !rowCodes.isEmpty, !targetCodes.isDisjoint(with: rowCodes) {
            return true
        }

        let target = normalizedName(targetName)
        let rowName = normalizedName(row.fundName)
        guard !target.isEmpty, !rowName.isEmpty else { return false }
        return target.contains(rowName) || rowName.contains(target)
    }

    private static func localTags(for row: PersonalAssetAggregateRow) -> [TrendAssetInlineTag] {
        var tags: [TrendAssetInlineTag] = [
            TrendAssetInlineTag(id: "status-\(row.id)", dimension: "状态", text: row.combinedStatusText, tone: row.hasPending ? .warning : .info)
        ]
        if row.pendingTradeCount > 0 {
            tags.append(TrendAssetInlineTag(id: "pending-\(row.id)", dimension: "待确认", text: "\(row.pendingTradeCount) 笔", tone: .warning))
        }
        if row.activePlanCount > 0 {
            tags.append(TrendAssetInlineTag(id: "plan-\(row.id)", dimension: "计划", text: "进行中 \(row.activePlanCount)", tone: .brand))
        }
        if let profitPct = row.profitPct {
            tags.append(TrendAssetInlineTag(
                id: "profit-\(row.id)",
                dimension: "收益",
                text: profitPct > 0 ? "盈利" : (profitPct < 0 ? "回撤" : "持平"),
                tone: profitPct > 0 ? .positive : (profitPct < 0 ? .warning : .muted)
            ))
        }
        if let changePct = row.estimateChangePct {
            tags.append(TrendAssetInlineTag(
                id: "today-\(row.id)",
                dimension: "今日",
                text: changePct > 0 ? "上涨" : (changePct < 0 ? "下跌" : "持平"),
                tone: changePct > 0 ? .positive : (changePct < 0 ? .warning : .muted)
            ))
        }
        return tags
    }

    private static func localSectorName(for row: PersonalAssetAggregateRow) -> String {
        if row.assetType == .stock {
            switch row.detectedMarket {
            case .us:
                return "美股"
            case .hk:
                return "港股"
            case .aShare:
                return "A股"
            case .none:
                return row.assetTypeLabel
            }
        }
        switch row.detectedFundMarket {
        case .onExchange:
            return "场内基金"
        case .offExchange:
            return "场外基金"
        case .none:
            return row.assetTypeLabel
        }
    }

    private static func inferredThemeNames(for row: PersonalAssetAggregateRow) -> Set<String> {
        let name = normalizedName(row.fundName)
        var themes = Set<String>()
        if ["qdii", "恒生", "纳斯达克", "标普", "中概", "香港", "美国", "全球", "海外"].contains(where: { name.contains(normalizedName($0)) }) {
            themes.insert(normalizedName("海外权益"))
        }
        if ["消费", "白酒", "食品", "医药"].contains(where: { name.contains(normalizedName($0)) }) {
            themes.insert(normalizedName("消费"))
        }
        if ["科技", "创新", "半导体", "互联网", "人工智能", "数字"].contains(where: { name.contains(normalizedName($0)) }) {
            themes.insert(normalizedName("科技创新"))
        }
        if ["红利", "低波", "股息"].contains(where: { name.contains(normalizedName($0)) }) {
            themes.insert(normalizedName("红利低波"))
        }
        if ["债", "货币", "现金"].contains(where: { name.contains(normalizedName($0)) }) {
            themes.insert(normalizedName("债券"))
        }
        return themes
    }

    private static func confidenceTone(_ confidence: TrendConfidence) -> TrendAssetTagTone {
        if confidence.normalizedScore >= 75 { return .positive }
        if confidence.normalizedScore >= 45 { return .info }
        return .muted
    }
}

extension TrendHorizon {
    var assetTagText: String {
        switch self {
        case .short:
            return "短期"
        case .medium:
            return "中期"
        case .long:
            return "长期"
        }
    }
}

extension TrendDirection {
    var assetTagText: String {
        switch self {
        case .bullish:
            return "偏强"
        case .neutralPositive:
            return "中性偏强"
        case .neutral:
            return "中性"
        case .neutralNegative:
            return "中性偏弱"
        case .bearish:
            return "偏弱"
        case .uncertain:
            return "不确定"
        }
    }

    var assetTagTone: TrendAssetTagTone {
        switch self {
        case .bullish, .neutralPositive:
            return .positive
        case .neutral:
            return .info
        case .neutralNegative, .bearish:
            return .warning
        case .uncertain:
            return .muted
        }
    }
}

extension TrendActionKind {
    var assetTagText: String {
        switch self {
        case .watch:
            return "观察"
        case .waitForConfirmation:
            return "等待确认"
        case .observeInBatches:
            return "分批观察"
        case .pausePlan:
            return "暂停计划"
        case .considerIncrease:
            return "考虑增加"
        case .considerReduce:
            return "考虑降低"
        case .rebalanceReview:
            return "调仓复核"
        }
    }

    var assetTagTone: TrendAssetTagTone {
        switch self {
        case .watch, .waitForConfirmation:
            return .info
        case .observeInBatches, .rebalanceReview:
            return .brand
        case .pausePlan, .considerReduce:
            return .warning
        case .considerIncrease:
            return .positive
        }
    }
}
