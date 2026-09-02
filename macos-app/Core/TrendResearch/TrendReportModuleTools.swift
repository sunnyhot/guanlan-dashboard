import Foundation

// 最终趋势报告采用分模块提交，避免模型一次生成包含全部资产、证据和行动的超大
// tool_call。各模块只暂存在本次运行内；全部收齐后仍复用 SubmitTrendReportTool
// 完成证据归一化、来源状态计算和完整 Validator 校验。

enum TrendReportModuleToolName {
    static let overview = "submit_trend_overview_module"
    static let market = "submit_trend_market_module"
    static let assetBatch = "submit_trend_asset_batch"
    static let actions = "submit_trend_actions_module"

    static let all: Set<String> = [overview, market, assetBatch, actions]
}

struct TrendReportOverviewModule: Codable {
    let portfolio: TrendPortfolioSummary
    let horizons: [TrendHorizonView]
}

struct TrendReportMarketModule: Codable {
    let marketOutlook: [TrendMarketOutlook]
    let sectors: [TrendSectorView]
    let opportunities: [TrendOpportunity]
}

struct TrendReportAssetBatchModule: Codable {
    let assetTrends: [TrendAssetView]
}

struct TrendReportActionsModule: Codable {
    let keyAssets: [TrendAssetView]
    let actions: [TrendActionCandidate]
    let warnings: [TrendWarning]
    let disclaimer: String
}

struct TrendReportDraftProgress: Sendable {
    let nextToolName: String?
    let completedSections: Int
    let totalSections: Int
    let remainingFundCodes: [String]

    var isComplete: Bool {
        nextToolName == nil
    }
}

enum TrendReportDraftError: LocalizedError {
    case invalidModule(String)

    var errorDescription: String? {
        switch self {
        case .invalidModule(let message):
            return message
        }
    }
}

actor TrendReportDraftStore {
    /// 单批基金数。线上耗时分析(2026-08-19):29 只 ÷ 5 只/批 = 6 轮生成、每轮
    /// 50-322s,提交阶段占全程 ~97%。提到 8 只/批把轮次减 1/4;单只归因生成
    /// 约 16-20s,8 只 ≈ 130-160s,依赖服务超时 ≥240s(推理模型首批更慢,首
    /// 批可能仍接近上限,超时由上层重试兜底)。
    static let assetBatchSize = 8

    static func effectiveScope(
        requestedScope: TrendResearchRunScope,
        baselineReport: TrendAnalysisReport?,
        expectedFundCodes: [String]
    ) -> TrendResearchRunScope {
        guard requestedScope != .full, let baselineReport else { return .full }
        if requestedScope == .closeReview,
           expectedFundCodes.compactMap(normalizedCode).isEmpty {
            return .full
        }
        guard requestedScope == .marketRadar else { return requestedScope }
        let baselineCodes = Set(baselineReport.assetTrends.compactMap { normalizedCode($0.code) })
        let expectedCodes = Set(expectedFundCodes.compactMap(normalizedCode))
        return baselineCodes == expectedCodes ? requestedScope : .full
    }

    private let expectedFundCodesByNormalized: [String: String]
    private let requiredModuleToolNames: [String]
    private let requiredModuleToolNameSet: Set<String>
    private var overview: TrendReportOverviewModule?
    private var market: TrendReportMarketModule?
    private var assetTrendsByCode: [String: TrendAssetView] = [:]
    private var actions: TrendReportActionsModule?

    init(
        expectedFundCodes: [String],
        scope requestedScope: TrendResearchRunScope = .full,
        baselineReport: TrendAnalysisReport? = nil
    ) {
        let expectedByNormalized = Dictionary(
            expectedFundCodes.compactMap { code -> (String, String)? in
                guard let normalized = Self.normalizedCode(code) else { return nil }
                return (normalized, code)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // 增量运行必须有上一份完整、已校验报告作为未更新模块的基线。
        // 市场雷达不重算持仓；若持仓清单已经变化，也回退为 full 以维持报告完整性。
        let effectiveScope = Self.effectiveScope(
            requestedScope: requestedScope,
            baselineReport: baselineReport,
            expectedFundCodes: expectedFundCodes
        )
        let requiredNames = effectiveScope.requiredModuleToolNames
        let requiredNameSet = effectiveScope.requiredModuleToolNameSet

        var initialOverview: TrendReportOverviewModule?
        var initialMarket: TrendReportMarketModule?
        var initialAssets: [String: TrendAssetView] = [:]
        var initialActions: TrendReportActionsModule?

        if let baselineReport {
            // W4:复用的旧基线数据由 App 补丁到满足明确性契约,避免旧报告
            // 把增量运行的新报告整份拒批(模型只提交本次开放模块)。
            initialOverview = TrendReportOverviewModule(
                portfolio: baselineReport.portfolio,
                horizons: TrendBaselineContractPatch.horizons(baselineReport.horizons)
            )
            initialMarket = TrendReportMarketModule(
                marketOutlook: TrendBaselineContractPatch.markets(baselineReport.marketOutlook),
                sectors: TrendBaselineContractPatch.sectors(baselineReport.sectors),
                opportunities: TrendBaselineContractPatch.opportunities(baselineReport.opportunities)
            )
            initialAssets = Dictionary(
                baselineReport.assetTrends.compactMap { asset -> (String, TrendAssetView)? in
                    guard let normalized = Self.normalizedCode(asset.code),
                          expectedByNormalized[normalized] != nil else { return nil }
                    return (normalized, asset)
                },
                uniquingKeysWith: { first, _ in first }
            )
            initialActions = TrendReportActionsModule(
                keyAssets: baselineReport.keyAssets,
                actions: TrendBaselineContractPatch.actions(baselineReport.actions),
                warnings: baselineReport.warnings,
                disclaimer: baselineReport.disclaimer
            )
        }

        if requiredNameSet.contains(TrendReportModuleToolName.overview) {
            initialOverview = nil
        }
        if requiredNameSet.contains(TrendReportModuleToolName.market) {
            initialMarket = nil
        }
        if requiredNameSet.contains(TrendReportModuleToolName.assetBatch) {
            initialAssets.removeAll()
        }
        if requiredNameSet.contains(TrendReportModuleToolName.actions) {
            initialActions = nil
        }

        expectedFundCodesByNormalized = expectedByNormalized
        requiredModuleToolNames = requiredNames
        requiredModuleToolNameSet = requiredNameSet
        overview = initialOverview
        market = initialMarket
        assetTrendsByCode = initialAssets
        actions = initialActions
    }

    func storeOverview(_ module: TrendReportOverviewModule) throws {
        let requiredHorizons = Set(TrendHorizon.allCases)
        let submittedHorizons = Set(module.horizons.map(\.horizon))
        guard module.horizons.count == requiredHorizons.count,
              submittedHorizons == requiredHorizons else {
            throw TrendReportDraftError.invalidModule(
                "组合模块必须完整包含 short/medium/long 三个周期且各出现一次。"
            )
        }
        guard !module.portfolio.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !module.portfolio.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrendReportDraftError.invalidModule("组合模块的 headline 和 summary 不能为空。")
        }
        // 2026-09-01 傍晚根治(runID 4B624F1C):W4 文案类缺陷(uncertain 缺「待观察信号」
        // 出口/首句缺方向词/whatWouldChange 空)入库即由 App 确定性补写——此前会沉默到
        // 整报告终审才爆,错误归属 horizons 却清空整个 overview 要求模型全量重提,
        // flash 模型整包重建易抄丢字段,修复预算白烧。修补只往文案兜底方向改,
        // 不动方向/证据语义,与 BaselineContractPatch 修基线数据同一先例。
        overview = TrendReportOverviewModule(
            portfolio: module.portfolio,
            horizons: TrendBaselineContractPatch.horizons(module.horizons)
        )
    }

    func storeMarket(_ module: TrendReportMarketModule) throws {
        guard !module.marketOutlook.isEmpty || !module.sectors.isEmpty else {
            throw TrendReportDraftError.invalidModule(
                "市场与板块模块不能为空；marketOutlook 和 sectors 至少提交一项。"
            )
        }
        let marketNames = Set(module.marketOutlook.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let sectorNames = Set(module.sectors.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        if let duplicate = marketNames.intersection(sectorNames).first(where: { !$0.isEmpty }) {
            throw TrendReportDraftError.invalidModule(
                "「\(duplicate)」不能同时出现在 marketOutlook 与 sectors。"
            )
        }
        if let invalidOpportunity = module.opportunities.first(where: { $0.scope != .marketWide }) {
            throw TrendReportDraftError.invalidModule(
                "机会「\(invalidOpportunity.name)」缺少 scope=marketWide；opportunities 只能提交独立全市场扫描结果。"
            )
        }
        // 与 storeOverview 同源:W4 文案类缺陷入库即补(见 runID 4B624F1C 注记)。
        market = TrendReportMarketModule(
            marketOutlook: TrendBaselineContractPatch.markets(module.marketOutlook),
            sectors: TrendBaselineContractPatch.sectors(module.sectors),
            opportunities: TrendBaselineContractPatch.opportunities(module.opportunities)
        )
    }

    func storeAssetBatch(_ module: TrendReportAssetBatchModule) throws {
        let remaining = remainingFundCodes
        if !remaining.isEmpty, module.assetTrends.isEmpty {
            throw TrendReportDraftError.invalidModule(
                "持仓模块不能为空；本批请提交最多 \(Self.assetBatchSize) 只尚未覆盖的基金。"
            )
        }
        // 2026-09-01 根治:超批不再拒批(2026-08-31 实证模型把 24 只塞进一批,
        // 拒批后修复轮 418s 仍失败,fanout 整段 874s 白烧)。schema 的 maxItems 仍是
        // 输出规模指导,但违反时照常逐只校验入库,remaining 自然收缩。
        // v4.6.1:「原因待确认」缺边界措辞时由 App 补写而不是拒批
        // (真实运行实证的拒批死循环修复,详见 policy 注释)。
        // 2026-08-28 死循环修复二连:①无因果证据的「涨跌归因：」先降级为「原因待确认：」
        // (首错即 throw 时期,排在 40 只行情上限外的基金必然拒批且修不完);
        // ②一批内全部基金的问题一次性返回,消灭「每轮只报一只」的打地鼠循环。
        // 2026-09-01 根治续:③无前缀/空 impactText 由 App 确定性补前缀(不再拒批);
        // ④缺 horizons 由 App 合成保守三周期(终审要求三周期齐全,推迟到终审更贵);
        // ⑤supporting 证据为空时 App 补结构性豁免并把周期降为 uncertain——终审
        //   「缺 supporting 必须 uncertain+exemptionReason」是隐形双条件,
        //   2026-08-31 fanout 修复轮正死于「资产缺 supportingEvidenceIDs」。
        let assetTrends = module.assetTrends
            .map(Self.assetWithAttributionPrefix)
            .map(Self.assetWithAttributionDowngrade)
            .map(Self.assetWithAttributionBoundary)
            .map(Self.assetWithStructuralClaimExemption)
            .map(Self.assetWithSynthesizedHorizons)
            .map(Self.assetWithCounterSignalsFallback)

        var submittedCodes = Set<String>()
        var batchErrors: [String] = []
        var acceptedAssets: [TrendAssetView] = []
        for asset in assetTrends {
            guard let normalized = Self.normalizedCode(asset.code) else {
                batchErrors.append("持仓基金「\(asset.name)」缺少有效 code。")
                continue
            }
            guard expectedFundCodesByNormalized[normalized] != nil else {
                batchErrors.append("基金 \(asset.code ?? asset.name) 不在本次待覆盖持仓中。")
                continue
            }
            // 2026-09-02 根治(runID AD2D63F9 第 15 轮):已入库或本批内重复的基金直接跳过,
            // 不再整批拒——重交已入库基金连坐同批健康基金,把最后的修复预算烧在重抄上。
            // 已暂存版本已过校验,重复提交无信息量,丢弃即可;工具结果里的
            // remaining_fund_codes 自然把模型引回未覆盖基金。与「超批不再拒批」同一先例。
            guard assetTrendsByCode[normalized] == nil, submittedCodes.insert(normalized).inserted else {
                continue
            }
            acceptedAssets.append(asset)
            if let message = TrendAssetDailyAttributionPolicy.validationMessage(for: asset) {
                batchErrors.append(message)
            }
        }
        if !batchErrors.isEmpty {
            throw TrendReportDraftError.invalidModule(
                "本批 \(batchErrors.count) 个问题（已一次性全部列出，请全部修正后整批重新提交）：\n"
                    + batchErrors.joined(separator: "\n")
            )
        }

        for asset in acceptedAssets {
            if let normalized = Self.normalizedCode(asset.code) {
                assetTrendsByCode[normalized] = asset
            }
        }
    }

    /// 2026-08-28:无因果证据的「涨跌归因：」降级为「原因待确认：」（App 兜底，不拒批）。
    private static func assetWithAttributionDowngrade(_ asset: TrendAssetView) -> TrendAssetView {
        guard let downgraded = TrendAssetDailyAttributionPolicy.downgradedAttributionText(asset) else {
            return asset
        }
        return replaceImpactText(downgraded, on: asset)
    }

    private static func assetWithAttributionBoundary(_ asset: TrendAssetView) -> TrendAssetView {
        let patched = TrendAssetDailyAttributionPolicy.appendingMissingEvidenceBoundaryIfNeeded(asset.impactText)
        guard patched != asset.impactText else { return asset }
        return replaceImpactText(patched, on: asset)
    }

    /// 2026-09-01:无前缀/空 impactText 由 App 按因果证据确定性补前缀(先于降级/边界补写,
    /// 三者用同一证据判定字段,不会互相矛盾)。
    private static func assetWithAttributionPrefix(_ asset: TrendAssetView) -> TrendAssetView {
        let prefixed = TrendAssetDailyAttributionPolicy.normalizedAttributionText(
            asset.impactText,
            hasCausalEvidence: TrendAssetDailyAttributionPolicy.containsCausalEvidence(
                asset.claimEvidence.supportingEvidenceIDs
            )
        )
        guard prefixed != asset.impactText else { return asset }
        return replaceImpactText(prefixed, on: asset)
    }

    /// 2026-09-01:缺 horizons 的条目由 App 合成保守三周期,失败不再推迟到终审。
    private static func assetWithSynthesizedHorizons(_ asset: TrendAssetView) -> TrendAssetView {
        guard asset.horizons.isEmpty else { return asset }
        return TrendAssetView(
            id: asset.id,
            name: asset.name,
            code: asset.code,
            sector: asset.sector,
            impactText: asset.impactText,
            horizons: TrendDegradedAssetFactory.synthesizedHorizons(
                reason: "模型本轮未提供周期判断"
            ),
            rationale: asset.rationale,
            counterSignals: asset.counterSignals,
            claimEvidence: asset.claimEvidence
        )
    }

    /// 2026-09-02 根治(runID AD2D63F9):终审要求每条已持有基金趋势带反证条件,
    /// 但归一化链此前无人补写资产级 counterSignals——被 prepareRepairs 清空后模型用
    /// code+name 短表单恢复覆盖,空壳条目周期可合成、反证条件缺失沉默到终审才爆,
    /// 连续两轮把降级组装也一起拖死。保守兜底,不宣称因果,与 missingRationale 同先例。
    private static func assetWithCounterSignalsFallback(_ asset: TrendAssetView) -> TrendAssetView {
        guard asset.counterSignals.isEmpty else { return asset }
        return TrendAssetView(
            id: asset.id,
            name: asset.name,
            code: asset.code,
            sector: asset.sector,
            impactText: asset.impactText,
            horizons: asset.horizons,
            rationale: asset.rationale,
            counterSignals: ["模型未提供反证条件，关键假设或行情变化后重估。"],
            claimEvidence: asset.claimEvidence
        )
    }

    /// 2026-09-01:supporting 为空时 App 补结构性豁免、周期降 uncertain——
    /// 终审规则(TrendClaimEvidencePolicy)对空 supporting 硬性要求
    /// uncertain + exemptionReason 双条件,模型只看到拒批不知道要补豁免。
    /// 与清洗器(v4.8.1 剔幻觉 ID 后的降级)同一先例:只往保守方向改写,
    /// 保留 counter/context 证据与原文。
    private static func assetWithStructuralClaimExemption(_ asset: TrendAssetView) -> TrendAssetView {
        let patchedClaim: TrendClaimEvidence
        if asset.claimEvidence.supportingEvidenceIDs.isEmpty,
           asset.claimEvidence.exemptionReason == nil {
            patchedClaim = TrendClaimEvidence(
                supportingEvidenceIDs: [],
                counterEvidenceIDs: asset.claimEvidence.counterEvidenceIDs,
                contextEvidenceIDs: asset.claimEvidence.contextEvidenceIDs,
                exemptionReason: "模型未引用支持证据，按证据不足处理。"
            )
        } else {
            patchedClaim = asset.claimEvidence
        }
        let patchedHorizons = asset.horizons.map { horizon in
            guard horizon.claimEvidence.supportingEvidenceIDs.isEmpty else { return horizon }
            guard horizon.direction != .uncertain
                || horizon.claimEvidence.exemptionReason == nil else { return horizon }
            return TrendHorizonView(
                horizon: horizon.horizon,
                direction: .uncertain,
                confidence: horizon.confidence,
                rationale: horizon.rationale,
                whatWouldChange: horizon.whatWouldChange,
                counterSignals: horizon.counterSignals,
                claimEvidence: TrendClaimEvidence(
                    supportingEvidenceIDs: [],
                    counterEvidenceIDs: horizon.claimEvidence.counterEvidenceIDs,
                    contextEvidenceIDs: horizon.claimEvidence.contextEvidenceIDs,
                    exemptionReason: horizon.claimEvidence.exemptionReason
                        ?? "周期判断未引用支持证据，按证据不足处理。"
                )
            )
        }
        guard patchedClaim != asset.claimEvidence || patchedHorizons != asset.horizons else {
            return asset
        }
        return TrendAssetView(
            id: asset.id,
            name: asset.name,
            code: asset.code,
            sector: asset.sector,
            impactText: asset.impactText,
            horizons: patchedHorizons,
            rationale: asset.rationale,
            counterSignals: asset.counterSignals,
            claimEvidence: patchedClaim
        )
    }

    private static func replaceImpactText(_ text: String, on asset: TrendAssetView) -> TrendAssetView {
        TrendAssetView(
            id: asset.id,
            name: asset.name,
            code: asset.code,
            sector: asset.sector,
            impactText: text,
            horizons: asset.horizons,
            rationale: asset.rationale,
            counterSignals: asset.counterSignals,
            claimEvidence: asset.claimEvidence
        )
    }

    func storeActions(_ module: TrendReportActionsModule) throws {
        guard module.disclaimer.contains("非投资建议") else {
            throw TrendReportDraftError.invalidModule(
                "操作与风险模块的 disclaimer 必须明确包含「非投资建议」。"
            )
        }
        guard module.keyAssets.count <= 5 else {
            throw TrendReportDraftError.invalidModule("keyAssets 最多保留 5 条。")
        }
        guard module.actions.count <= 5 else {
            throw TrendReportDraftError.invalidModule("actions 最多保留 5 条。")
        }
        // 与 storeOverview 同源:W4 文案类缺陷入库即补(见 runID 4B624F1C 注记)。
        actions = TrendReportActionsModule(
            keyAssets: module.keyAssets,
            actions: TrendBaselineContractPatch.actions(module.actions),
            warnings: module.warnings,
            disclaimer: module.disclaimer
        )
    }

    func progress() -> TrendReportDraftProgress {
        let remainingCodes = remainingFundCodes
        let assetModuleRequired = requiredModuleToolNameSet.contains(
            TrendReportModuleToolName.assetBatch
        )
        let batchCount = assetModuleRequired
            ? Int(ceil(Double(expectedFundCodesByNormalized.count) / Double(Self.assetBatchSize)))
            : 0
        let totalSections = requiredModuleToolNames.reduce(into: 0) { count, toolName in
            count += toolName == TrendReportModuleToolName.assetBatch ? batchCount : 1
        }
        let completedAssetBatches: Int
        if !assetModuleRequired || expectedFundCodesByNormalized.isEmpty {
            completedAssetBatches = 0
        } else if remainingCodes.isEmpty {
            completedAssetBatches = batchCount
        } else {
            completedAssetBatches = min(batchCount, assetTrendsByCode.count / Self.assetBatchSize)
        }
        let completedSections = requiredModuleToolNames.reduce(into: 0) { count, toolName in
            switch toolName {
            case TrendReportModuleToolName.overview:
                count += overview == nil ? 0 : 1
            case TrendReportModuleToolName.market:
                count += market == nil ? 0 : 1
            case TrendReportModuleToolName.assetBatch:
                count += completedAssetBatches
            case TrendReportModuleToolName.actions:
                count += actions == nil ? 0 : 1
            default:
                break
            }
        }

        let nextToolName: String?
        nextToolName = requiredModuleToolNames.first { toolName in
            switch toolName {
            case TrendReportModuleToolName.overview: overview == nil
            case TrendReportModuleToolName.market: market == nil
            case TrendReportModuleToolName.assetBatch: !remainingCodes.isEmpty
            case TrendReportModuleToolName.actions: actions == nil
            default: false
            }
        }
        return TrendReportDraftProgress(
            nextToolName: nextToolName,
            completedSections: completedSections,
            totalSections: totalSections,
            remainingFundCodes: remainingCodes
        )
    }

    func assembledReport(snapshot: TrendResearchSnapshot) -> TrendAnalysisReport? {
        guard let overview, let market, let actions, remainingFundCodes.isEmpty else {
            return nil
        }
        let orderedAssetTrends = expectedFundCodesByNormalized.keys.sorted().compactMap {
            assetTrendsByCode[$0]
        }
        return TrendAnalysisReport(
            id: UUID(),
            generatedAt: "",
            dataAsOf: snapshot.dataAsOf,
            privacyMode: snapshot.privacyMode,
            externalSignalStatus: .unavailable,
            portfolio: overview.portfolio,
            horizons: overview.horizons,
            marketOutlook: market.marketOutlook,
            sectors: market.sectors,
            opportunities: market.opportunities,
            keyAssets: actions.keyAssets,
            assetTrends: orderedAssetTrends,
            actions: actions.actions,
            evidence: [],
            warnings: actions.warnings,
            disclaimer: actions.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion
        )
    }

    /// 2026-09-01 根治(W5):预算终局/环节失败时用已暂存批次组装降级报告——
    /// 已覆盖基金保留真实分析,未覆盖基金由 App 合成保守条目(uncertain + 低置信 +
    /// 「原因待确认」),已暂存工作永不白烧(2026-08-31 实证:29 只覆盖 21 只时
    /// 整 run 报废,~30 分钟产出清零)。前置:四模块就绪(增量 scope 下 overview/
    /// market/actions 由 baseline 预填)且至少暂存 1 只基金;否则返回 nil,
    /// 由调用方维持现行失败契约。组装后仍走 finalizeAssembledReport 同一条
    /// 终检链,校验不过同样返回 nil——降级不绕过质量门。
    func degradedReport(
        snapshot: TrendResearchSnapshot,
        reason: String
    ) -> TrendAnalysisReport? {
        // 2026-09-01 傍晚根治(runID 4B624F1C):终局降级不再被 overview/actions 缺失挡住
        //——prepareRepairs 清空模块后预算即耗尽的运行,已暂存批次(29 只全覆盖)此前
        // 因 overview 刚被清空而整 run 报废。缺失模块保守合成;market 仍必须存在
        //(终检要求 marketOutlook/sectors 至少一项,空集合过不了终检;增量运行 market
        // 恒复用基线,实证不会缺)。
        guard let market, !assetTrendsByCode.isEmpty else {
            return nil
        }
        let overviewModule = overview ?? Self.synthesizedOverviewModule(reason: reason)
        let actionsModule = actions ?? Self.synthesizedActionsModule(reason: reason)
        var merged = assetTrendsByCode
        let assetsByNormalizedCode: [String: TrendContextAsset] = Dictionary(
            snapshot.assets.compactMap { asset in
                asset.code.map { (Self.normalizedCode($0) ?? $0, asset) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        for code in remainingFundCodes {
            let normalized = Self.normalizedCode(code) ?? code
            guard merged[normalized] == nil else { continue }
            let contextAsset = assetsByNormalizedCode[normalized]
            merged[normalized] = TrendDegradedAssetFactory.budgetExhaustedAsset(
                code: code,
                name: contextAsset?.name ?? code,
                sector: contextAsset?.sector ?? "未分类",
                reason: reason
            )
        }
        let orderedAssetTrends = expectedFundCodesByNormalized.keys.sorted().compactMap {
            merged[$0]
        }
        return TrendAnalysisReport(
            id: UUID(),
            generatedAt: "",
            dataAsOf: snapshot.dataAsOf,
            privacyMode: snapshot.privacyMode,
            externalSignalStatus: .unavailable,
            portfolio: overviewModule.portfolio,
            horizons: overviewModule.horizons,
            marketOutlook: market.marketOutlook,
            sectors: market.sectors,
            opportunities: market.opportunities,
            keyAssets: actionsModule.keyAssets,
            assetTrends: orderedAssetTrends,
            actions: actionsModule.actions,
            evidence: [],
            warnings: actionsModule.warnings,
            disclaimer: actionsModule.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion
        )
    }

    /// 降级组装时 overview 模块缺失的保守占位:组合总判断标注未完成,
    /// 三周期 uncertain(带待观察信号出口,过 W4 终检)。
    private static func synthesizedOverviewModule(reason: String) -> TrendReportOverviewModule {
        TrendReportOverviewModule(
            portfolio: TrendPortfolioSummary(
                headline: "组合研判未完成",
                riskLevel: .medium,
                summary: "原因待确认：\(reason)，本轮未完成组合总判断；已覆盖持仓的分析见下。",
                claimEvidence: TrendClaimEvidence(exemptionReason: "\(reason)，组合总判断未完成。")
            ),
            horizons: TrendDegradedAssetFactory.synthesizedHorizons(
                reason: reason,
                entityLabel: "组合"
            )
        )
    }

    /// 降级组装时 actions 模块缺失的保守占位:无行动、无警告,
    /// disclaimer 保留「非投资建议」终检措辞。
    private static func synthesizedActionsModule(reason: String) -> TrendReportActionsModule {
        TrendReportActionsModule(
            keyAssets: [],
            actions: [],
            warnings: [],
            disclaimer: "本报告为\(reason)后的降级组装结果，非投资建议。"
        )
    }

    /// 完整 Validator 仍可能发现跨模块问题。只清空涉及的模块，让模型局部修复，
    /// 不要求重新生成已经通过的其它模块。
    func prepareRepairs(for messages: [String]) {        let joined = messages.joined(separator: "\n")
        var matched = false
        if joined.contains("组合结论")
            || joined.contains("短中长期")
            || joined.contains("周期趋势") {
            if requiredModuleToolNameSet.contains(TrendReportModuleToolName.overview) {
                overview = nil
                matched = true
            }
        }
        if joined.contains("大盘")
            || joined.contains("板块")
            || joined.contains("机会")
            || joined.contains("marketOutlook")
            || joined.contains("sectors") {
            if requiredModuleToolNameSet.contains(TrendReportModuleToolName.market) {
                market = nil
                matched = true
            }
        }
        if joined.contains("已持有基金")
            || joined.contains("assetTrends")
            || joined.contains("资产「") {
            if requiredModuleToolNameSet.contains(TrendReportModuleToolName.assetBatch) {
                assetTrendsByCode.removeAll()
                matched = true
            }
        }
        if joined.contains("行动")
            || joined.contains("allocationReview")
            || joined.contains("非投资建议")
            || joined.contains("关键资产")
            || joined.contains("disclaimer") {
            if requiredModuleToolNameSet.contains(TrendReportModuleToolName.actions) {
                actions = nil
                matched = true
            }
        }
        if !matched {
            // 只重做本次运行范围内的最后一块，绝不把增量任务扩回整份报告。
            switch requiredModuleToolNames.last {
            case TrendReportModuleToolName.overview: overview = nil
            case TrendReportModuleToolName.market: market = nil
            case TrendReportModuleToolName.assetBatch: assetTrendsByCode.removeAll()
            case TrendReportModuleToolName.actions: actions = nil
            default: break
            }
        }
    }

    private var remainingFundCodes: [String] {
        expectedFundCodesByNormalized.keys
            .filter { assetTrendsByCode[$0] == nil }
            .sorted()
            .compactMap { expectedFundCodesByNormalized[$0] }
    }

    static func normalizedCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - 分模块工具

struct SubmitTrendOverviewModuleTool: TrendResearchTool {
    let name = TrendReportModuleToolName.overview
    let description = "提交报告第 1 模块：组合总判断与 short/medium/long 三个周期。只提交本模块，不得夹带市场、资产或操作字段。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "portfolio": ["type": "object"],
            "horizons": ["type": "array", "items": ["type": "object"], "minItems": 3, "maxItems": 3]
        ],
        "required": ["portfolio", "horizons"],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        await executeTrendModule(
            argumentsJSON: argumentsJSON,
            context: context,
            moduleName: "组合判断"
        ) { store, data in
            try await store.storeOverview(JSONDecoder().decode(TrendReportOverviewModule.self, from: data))
        }
    }
}

struct SubmitTrendMarketModuleTool: TrendResearchTool {
    let name = TrendReportModuleToolName.market
    let description = "提交报告第 2 模块：组合大盘/板块判断和独立全市场机会。opportunities 必须标记 scope=marketWide；指数只放 marketOutlook，行业只放 sectors；两者不能同时为空。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "marketOutlook": ["type": "array", "items": ["type": "object"]],
            "sectors": ["type": "array", "items": ["type": "object"]],
            "opportunities": ["type": "array", "items": ["type": "object"]]
        ],
        "required": ["marketOutlook", "sectors", "opportunities"],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        await executeTrendModule(
            argumentsJSON: argumentsJSON,
            context: context,
            moduleName: "市场与板块"
        ) { store, data in
            try await store.storeMarket(JSONDecoder().decode(TrendReportMarketModule.self, from: data))
        }
    }
}

struct SubmitTrendAssetBatchTool: TrendResearchTool {
    let name = TrendReportModuleToolName.assetBatch
    let description = "分批提交已持有基金趋势。每次最多 \(TrendReportDraftStore.assetBatchSize) 只，只提交 remaining_fund_codes。impactText 必须提供有行情证据的「涨跌归因：」，或在证据不足时明确写「原因待确认：」；静态持仓结构不能冒充涨跌原因。前缀缺失、超批、字段缺失或重复提交已入库基金时 App 会保守兜底/忽略而不拒批，但归因质量取决于你引用的证据。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "assetTrends": [
                "type": "array",
                "items": ["type": "object"],
                "minItems": 1,
                "maxItems": .number(Double(TrendReportDraftStore.assetBatchSize))
            ]
        ],
        "required": ["assetTrends"],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        await executeTrendModule(
            argumentsJSON: argumentsJSON,
            context: context,
            moduleName: "持仓基金分批"
        ) { store, data in
            var module = try JSONDecoder().decode(TrendReportAssetBatchModule.self, from: data)
            // 2026-09-01 傍晚根治(runID 4B624F1C):模型常写 name 漏 code(当天 4 批全因
            // 「缺少有效 code」各烧一轮修复预算)。name 与冻结快照精确匹配时 App
            // 确定性补写,不再拒批;匹配不到维持原错误。
            let (resolvedModule, resolvedNames) = Self.resolveMissingCodes(module, snapshot: context.snapshot)
            if !resolvedNames.isEmpty {
                module = resolvedModule
                await AIAgentDiagnosticLog.record(
                    "asset_codes_resolved",
                    message: "按名称补写 \(resolvedNames.count) 只基金的缺失 code（App 兜底，不拒批）"
                )
            }
            let evidence = await context.evidenceLedger.allEvidence()
            let (sanitized, removedIDs) = TrendReportEvidenceSanitizer.sanitizedAssetBatch(module, evidence: evidence)
            module = sanitized
            if !removedIDs.isEmpty {
                await AIAgentDiagnosticLog.record(
                    "evidence_ids_sanitized",
                    message: "持仓批次剔除 \(removedIDs.count) 个账本不存在的证据 ID（App 兜底，不拒批）"
                )
            }
            try await store.storeAssetBatch(module)
        }
    }

    /// name 与冻结快照精确匹配(trim 后全等;不做模糊匹配避免错配)时补写缺失
    /// code,其余条目原样返回。返回补写成功的基金名列表供诊断。
    static func resolveMissingCodes(
        _ module: TrendReportAssetBatchModule,
        snapshot: TrendResearchSnapshot
    ) -> (module: TrendReportAssetBatchModule, resolvedNames: [String]) {
        let codeByTrimmedName: [String: String] = Dictionary(
            snapshot.assets.compactMap { asset -> (String, String)? in
                guard let code = asset.code else { return nil }
                let assetName = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !assetName.isEmpty else { return nil }
                return (assetName, code)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !codeByTrimmedName.isEmpty else { return (module, []) }

        var resolvedNames: [String] = []
        let assets = module.assetTrends.map { asset -> TrendAssetView in
            guard TrendReportDraftStore.normalizedCode(asset.code) == nil else { return asset }
            let trimmedName = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let code = codeByTrimmedName[trimmedName] else { return asset }
            resolvedNames.append(asset.name)
            return TrendAssetView(
                id: asset.id,
                name: asset.name,
                code: code,
                sector: asset.sector,
                impactText: asset.impactText,
                horizons: asset.horizons,
                rationale: asset.rationale,
                counterSignals: asset.counterSignals,
                claimEvidence: asset.claimEvidence
            )
        }
        guard !resolvedNames.isEmpty else { return (module, []) }
        return (TrendReportAssetBatchModule(assetTrends: assets), resolvedNames)
    }
}

struct SubmitTrendActionsModuleTool: TrendResearchTool {
    let name = TrendReportModuleToolName.actions
    let description = "提交最后模块：最多 5 条关键资产、最多 5 条操作候选、风险警告和非投资建议声明。提交后 App 自动组装并校验整份报告。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "keyAssets": ["type": "array", "items": ["type": "object"], "maxItems": 5],
            "actions": ["type": "array", "items": ["type": "object"], "maxItems": 5],
            "warnings": ["type": "array", "items": ["type": "object"]],
            "disclaimer": ["type": "string"]
        ],
        "required": ["keyAssets", "actions", "warnings", "disclaimer"],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        await executeTrendModule(
            argumentsJSON: argumentsJSON,
            context: context,
            moduleName: "操作与风险"
        ) { store, data in
            var module = try JSONDecoder().decode(TrendReportActionsModule.self, from: data)
            let evidence = await context.evidenceLedger.allEvidence()
            let (sanitized, droppedActions, removedIDs) = TrendReportEvidenceSanitizer.sanitizedActions(module, evidence: evidence)
            module = sanitized
            if !droppedActions.isEmpty || !removedIDs.isEmpty {
                await AIAgentDiagnosticLog.record(
                    "actions_sanitized",
                    message: "剔除 \(droppedActions.count) 条无本地事实证据的行动、\(removedIDs.count) 个幻觉证据 ID"
                )
            }
            try await store.storeActions(module)
        }
    }
}

private func executeTrendModule(
    argumentsJSON: String,
    context: TrendResearchToolContext,
    moduleName: String,
    store: @Sendable (TrendReportDraftStore, Data) async throws -> Void
) async -> TrendResearchToolResult {
    guard let draftStore = context.reportDraftStore else {
        return .content(
            TrendResearchToolEnvelope.error(
                code: "report_draft_unavailable",
                message: "报告分模块暂存器未初始化。"
            ),
            isError: true
        )
    }
    do {
        // 模型输出规整:字符串数组字段的元素类型收敛,单字段毛刺不再否决整个模块。
        try await store(draftStore, ModelOutputCoercion.normalizedJSON(Data(argumentsJSON.utf8)))
    } catch {
        return moduleValidationFailure(
            messages: ["\(moduleName)模块提交失败：\(describeModuleError(error))"],
            context: context
        )
    }

    if let assembled = await draftStore.assembledReport(snapshot: context.snapshot) {
        let result = await finalizeAssembledReport(assembled, context: context)
        if result.isError {
            let messages = moduleValidationMessages(from: result.contentJSON)
            await draftStore.prepareRepairs(for: messages)
        }
        return result
    }

    let progress = await draftStore.progress()
    return .content(
        TrendResearchToolEnvelope.success([
            "accepted": true,
            "module": moduleName,
            "completed_sections": progress.completedSections,
            "total_sections": progress.totalSections,
            "next_tool": progress.nextToolName ?? "",
            "remaining_fund_codes": progress.remainingFundCodes
        ])
    )
}

/// internal:fan-out 路径与交互路径共用同一终检链。
func finalizeAssembledReport(
    _ report: TrendAnalysisReport,
    context: TrendResearchToolContext
) async -> TrendResearchToolResult {
    do {
        let encoded = try JSONEncoder().encode(report)
        let reportObject = try JSONSerialization.jsonObject(with: encoded)
        let arguments = try JSONSerialization.data(withJSONObject: ["report": reportObject])
        guard let argumentsJSON = String(data: arguments, encoding: .utf8) else {
            throw TrendReportDraftError.invalidModule("无法编码组装后的完整报告。")
        }
        return await SubmitTrendReportTool().execute(
            argumentsJSON: argumentsJSON,
            context: context
        )
    } catch {
        return moduleValidationFailure(
            messages: ["组装完整报告失败：\(describeModuleError(error))"],
            context: context
        )
    }
}

private func moduleValidationFailure(
    messages: [String],
    context: TrendResearchToolContext
) -> TrendResearchToolResult {
    let remaining = max(
        0,
        context.invalidSubmissionBudget - context.invalidSubmissionsUsed - 1
    )
    return .content(
        TrendResearchToolEnvelope.submitValidationError(
            code: "report_module_validation_failed",
            message: "报告模块未通过校验，请只修正当前模块。",
            errors: messages,
            remainingRepairAttempts: remaining
        ),
        isError: true
    )
}

private func moduleValidationMessages(from contentJSON: String) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(
        with: Data(contentJSON.utf8)
    ) as? [String: Any] else {
        return ["完整报告校验失败。"]
    }
    return object["errors"] as? [String] ?? ["完整报告校验失败。"]
}

private func describeModuleError(_ error: Error) -> String {
    AgentDecodingErrorFormatter.describe(error, trailingPeriod: true)
}

// MARK: - 2026-08-31 终审爆量修复：模块入库级证据清洗（App 兜底，不拒批）

/// 三个根因的对策（v4.8.0 后首个真实运行实证）：
/// ① 模型幻觉证据 ID（上下文压缩后凭记忆重建，前缀对但账本里没有）；
/// ② 模块验收只查前缀、终审才查存在性/关联性 → 错误沉默累积到预算耗尽时爆出；
/// ③ 琐碎 schema 错耗尽共享修复预算。
/// 清洗发生在模块入库前：幻觉 ID 剔除 → 周期降 uncertain → 行动剔除，终审规则前置完成。
enum TrendReportEvidenceSanitizer {
    static func cleanedClaim(
        _ claim: TrendClaimEvidence,
        validIDs: Set<String>
    ) -> (claim: TrendClaimEvidence, removed: [String]) {
        let supporting = claim.supportingEvidenceIDs.filter { validIDs.contains($0) }
        let counter = claim.counterEvidenceIDs.filter { validIDs.contains($0) }
        let context = claim.contextEvidenceIDs.filter { validIDs.contains($0) }
        let removedSupporting = claim.supportingEvidenceIDs.filter { !validIDs.contains($0) }
        let removedCounter = claim.counterEvidenceIDs.filter { !validIDs.contains($0) }
        let removedContext = claim.contextEvidenceIDs.filter { !validIDs.contains($0) }
        let removed = (removedSupporting + removedCounter + removedContext).deduplicatedPreservingOrder()
        guard !removed.isEmpty else { return (claim, []) }
        let cleaned = TrendClaimEvidence(
            supportingEvidenceIDs: supporting,
            counterEvidenceIDs: counter,
            contextEvidenceIDs: context,
            exemptionReason: claim.exemptionReason
        )
        return (cleaned, removed)
    }

    /// 周期级兜底：清完 ID 后 supporting 为空、或无一与该基金关联、且方向不是 uncertain
    /// → 降 uncertain + exemptionReason + rationale 补「待观察信号」+ whatWouldChange 兜底。
    static func sanitizedHorizon(
        _ horizon: TrendHorizonView,
        fundCode: String?,
        fundName: String,
        evidenceByID: [String: TrendEvidence]
    ) -> (horizon: TrendHorizonView, removed: [String]) {
        let validIDs = Set(evidenceByID.keys)
        let (cleanedClaim, removed) = cleanedClaim(horizon.claimEvidence, validIDs: validIDs)
        guard horizon.direction != .uncertain else {
            return (rebuild(horizon, claim: filledExemption(cleanedClaim), forceDowngrade: false), removed)
        }
        let supportingEvidence = cleanedClaim.supportingEvidenceIDs.compactMap { evidenceByID[$0] }
        let hasAssociated = supportingEvidence.contains { evidence in
            evidence.metadata.isAssociated(entityCode: fundCode, entityName: fundName)
        }
        if hasAssociated, removed.isEmpty {
            return (horizon, [])  // 完全健康，原样返回
        }
        if hasAssociated {
            return (rebuild(horizon, claim: cleanedClaim, forceDowngrade: false), removed)
        }
        // 降级路径
        var claim = cleanedClaim
        claim = filledExemption(claim)
        return (rebuild(horizon, claim: claim, forceDowngrade: true), removed)
    }

    private static func filledExemption(_ claim: TrendClaimEvidence) -> TrendClaimEvidence {
        let reason = (claim.exemptionReason ?? "").isEmpty
            ? "App 降级：缺少与该标的关联的可引用支持证据"
            : claim.exemptionReason!
        return TrendClaimEvidence(
            supportingEvidenceIDs: claim.supportingEvidenceIDs,
            counterEvidenceIDs: claim.counterEvidenceIDs,
            contextEvidenceIDs: claim.contextEvidenceIDs,
            exemptionReason: reason
        )
    }

    private static func rebuild(
        _ horizon: TrendHorizonView,
        claim: TrendClaimEvidence,
        forceDowngrade: Bool
    ) -> TrendHorizonView {
        var direction = horizon.direction
        var rationale = horizon.rationale
        var whatWouldChange = horizon.whatWouldChange
        var counterSignals = horizon.counterSignals
        if forceDowngrade {
            direction = .uncertain
        }
        // 2026-09-01 傍晚根治:补出口条件从「降级为 uncertain」扩到「本来就是 uncertain」
        //——模型自报 uncertain 且 rationale 无出口时此前原样放行,终审 W4 契约必拒
        //(runID 4B624F1C:同一错误 16 轮重发仍复现,修不掉)。
        if direction == .uncertain, !rationale.contains("待观察信号") {
            rationale = rationale + " 待观察信号：出现可关联的行情或研究证据后重估方向。"
        }
        if whatWouldChange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whatWouldChange = "取到可关联证据后升级方向判断。"
        }
        if counterSignals.isEmpty {
            counterSignals = ["证据不足，当前方向判断不成立。"]
        }
        return TrendHorizonView(
            horizon: horizon.horizon,
            direction: direction,
            confidence: horizon.confidence,
            rationale: rationale,
            whatWouldChange: whatWouldChange,
            counterSignals: counterSignals,
            claimEvidence: claim
        )
    }

    /// 持仓批次清洗：资产级 claim + 逐 horizon + impactText 归因前缀证据核对。
    static func sanitizedAssetBatch(
        _ module: TrendReportAssetBatchModule,
        evidence: [TrendEvidence]
    ) -> (module: TrendReportAssetBatchModule, removedIDs: [String]) {
        let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        let validIDs = Set(evidenceByID.keys)
        var removed: [String] = []
        var assets: [TrendAssetView] = []
        for asset in module.assetTrends {
            let (assetClaim, assetRemoved) = cleanedClaim(asset.claimEvidence, validIDs: validIDs)
            removed += assetRemoved
            var horizons: [TrendHorizonView] = []
            for source in asset.horizons {
                let (sanitizedHorizonResult, horizonRemoved) = sanitizedHorizon(
                    source, fundCode: asset.code, fundName: asset.name, evidenceByID: evidenceByID
                )
                horizons.append(sanitizedHorizonResult)
                removed += horizonRemoved
            }
            // 归因证据前缀里引用的幻觉 ID：TrendAssetDailyAttributionPolicy 只查前缀；
            // 这里顺带把 impactText 归因但 supporting 全幻觉的情况交给既有降级（v4.8.0 修复 2）。
            var rebuilt = asset
            rebuilt = TrendAssetView(
                id: asset.id, name: asset.name, code: asset.code, sector: asset.sector,
                impactText: asset.impactText, horizons: horizons,
                rationale: asset.rationale, counterSignals: asset.counterSignals,
                claimEvidence: assetClaim
            )
            assets.append(rebuilt)
        }
        return (TrendReportAssetBatchModule(assetTrends: assets), removed.deduplicatedPreservingOrder())
    }

    /// 操作与风险模块清洗：ID 剔除 → 无本地事实证据的行动整条剔除；
    /// keyAssets 补 counterSignals；disclaimer 补「非投资建议」。
    static func sanitizedActions(
        _ module: TrendReportActionsModule,
        evidence: [TrendEvidence]
    ) -> (module: TrendReportActionsModule, droppedActions: [String], removedIDs: [String]) {
        let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        let validIDs = Set(evidenceByID.keys)
        var removed: [String] = []
        var dropped: [String] = []

        var keptActions: [TrendActionCandidate] = []
        for action in module.actions {
            let (claim, actionRemoved) = cleanedClaim(action.claimEvidence, validIDs: validIDs)
            removed += actionRemoved
            let hasLocalFact = claim.supportingEvidenceIDs.contains { id in
                guard let evidence = evidenceByID[id] else { return false }
                let isLocal = evidence.metadata.sourceKind == .portfolioSnapshot
                    || evidence.metadata.sourceKind == .marketQuote
                return isLocal && evidence.metadata.isAssociated(
                    entityCode: nil,
                    entityName: action.targetName
                )
            }
            if !hasLocalFact {
                dropped.append(action.title)
                continue
            }
            var rebuilt = action
            rebuilt = TrendActionCandidate(
                id: action.id, kind: action.kind, title: action.title, detail: action.detail,
                targetName: action.targetName, confidence: action.confidence,
                whatWouldChange: action.whatWouldChange,
                triggerConditions: action.triggerConditions,
                invalidatingConditions: action.invalidatingConditions,
                claimEvidence: claim
            )
            keptActions.append(rebuilt)
        }

        let keyAssets = module.keyAssets.map { asset -> TrendAssetView in
            let (claim, keyRemoved) = cleanedClaim(asset.claimEvidence, validIDs: validIDs)
            removed += keyRemoved
            var counters = asset.counterSignals
            if counters.isEmpty { counters = ["关键假设变化需重新评估。"] }
            // 2026-09-02 根治(runID AD2D63F9):终审对 keyAssets 与 assetTrends 走同一条
            // 周期校验,但此处此前只清幻觉 ID 不做关联降级——keyAsset 周期引底仓股票/
            // 组合级证据(与该基金无关联)时入库沉默,终审必拒;错误文案含「资产「」又触发
            // prepareRepairs 清空全部已暂存批次,健康运行与 W5 降级组装双双死于此。
            // 与 assetTrends 同一条 sanitizedHorizon 清洗链(未关联 supporting → uncertain)。
            var horizons: [TrendHorizonView] = []
            for source in asset.horizons {
                let (sanitizedHorizonResult, horizonRemoved) = sanitizedHorizon(
                    source, fundCode: asset.code, fundName: asset.name, evidenceByID: evidenceByID
                )
                horizons.append(sanitizedHorizonResult)
                removed += horizonRemoved
            }
            return TrendAssetView(
                id: asset.id, name: asset.name, code: asset.code, sector: asset.sector,
                impactText: asset.impactText, horizons: horizons,
                rationale: asset.rationale, counterSignals: counters, claimEvidence: claim
            )
        }

        var disclaimer = module.disclaimer
        if !disclaimer.contains("非投资建议") {
            disclaimer = disclaimer + " 本内容为 AI 研判参考，非投资建议。"
        }

        let cleaned = TrendReportActionsModule(
            keyAssets: keyAssets,
            actions: keptActions,
            warnings: module.warnings,
            disclaimer: disclaimer
        )
        return (cleaned, dropped, removed.deduplicatedPreservingOrder())
    }
}

extension Array where Element == String {
    /// 保序去重。
    fileprivate func deduplicatedPreservingOrder() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - get_evidence_index（修复 4：治幻觉源头——随时可查真实证据 ID）

struct EvidenceIndexTool: TrendResearchTool {
    static let maxEntries = 200

    let name = "get_evidence_index"
    let description = "列出本次运行证据账本里的全部真实 evidence_id（含标题与来源）。提交任何模块前如果不确定证据 ID，先查本工具；引用不存在的 ID 会被 App 剔除并降级对应结论。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let all = await context.evidenceLedger.allEvidence()
        let entries = all.prefix(Self.maxEntries)
        let rows: [[String: Any]] = entries.map { evidence in
            [
                "evidence_id": evidence.id,
                "title": String(evidence.title.prefix(30)),
                "source": evidence.sourceName,
            ]
        }
        let data: [String: Any] = [
            "count": entries.count,
            "total": all.count,
            "entries": rows,
            "note": "提交模块引用证据时必须从这里或工具返回的 evidence_ids 取值，不要凭记忆拼写"
        ]
        return .content(TrendResearchToolEnvelope.success(data))
    }
}
