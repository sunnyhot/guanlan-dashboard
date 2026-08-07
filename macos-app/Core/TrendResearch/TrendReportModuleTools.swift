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
    static let assetBatchSize = 5

    private let expectedFundCodesByNormalized: [String: String]
    private var overview: TrendReportOverviewModule?
    private var market: TrendReportMarketModule?
    private var assetTrendsByCode: [String: TrendAssetView] = [:]
    private var actions: TrendReportActionsModule?

    init(expectedFundCodes: [String]) {
        expectedFundCodesByNormalized = Dictionary(
            expectedFundCodes.compactMap { code -> (String, String)? in
                guard let normalized = Self.normalizedCode(code) else { return nil }
                return (normalized, code)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
        overview = module
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
        market = module
    }

    func storeAssetBatch(_ module: TrendReportAssetBatchModule) throws {
        let remaining = remainingFundCodes
        if !remaining.isEmpty, module.assetTrends.isEmpty {
            throw TrendReportDraftError.invalidModule(
                "持仓模块不能为空；本批请提交最多 \(Self.assetBatchSize) 只尚未覆盖的基金。"
            )
        }
        guard module.assetTrends.count <= Self.assetBatchSize else {
            throw TrendReportDraftError.invalidModule(
                "单批最多提交 \(Self.assetBatchSize) 只基金，当前提交了 \(module.assetTrends.count) 只。"
            )
        }

        var submittedCodes = Set<String>()
        for asset in module.assetTrends {
            guard let normalized = Self.normalizedCode(asset.code) else {
                throw TrendReportDraftError.invalidModule(
                    "持仓基金「\(asset.name)」缺少有效 code。"
                )
            }
            guard expectedFundCodesByNormalized[normalized] != nil else {
                throw TrendReportDraftError.invalidModule(
                    "基金 \(asset.code ?? asset.name) 不在本次待覆盖持仓中。"
                )
            }
            guard assetTrendsByCode[normalized] == nil, submittedCodes.insert(normalized).inserted else {
                throw TrendReportDraftError.invalidModule(
                    "基金 \(asset.code ?? asset.name) 已提交，请只提交 remaining_fund_codes 中的基金。"
                )
            }
        }

        for asset in module.assetTrends {
            if let normalized = Self.normalizedCode(asset.code) {
                assetTrendsByCode[normalized] = asset
            }
        }
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
        actions = module
    }

    func progress() -> TrendReportDraftProgress {
        let remainingCodes = remainingFundCodes
        let batchCount = Int(
            ceil(Double(expectedFundCodesByNormalized.count) / Double(Self.assetBatchSize))
        )
        let totalSections = 3 + batchCount
        let completedAssetBatches: Int
        if expectedFundCodesByNormalized.isEmpty {
            completedAssetBatches = 0
        } else if remainingCodes.isEmpty {
            completedAssetBatches = batchCount
        } else {
            completedAssetBatches = min(batchCount, assetTrendsByCode.count / Self.assetBatchSize)
        }
        let completedSections = (overview == nil ? 0 : 1)
            + (market == nil ? 0 : 1)
            + completedAssetBatches
            + (actions == nil ? 0 : 1)

        let nextToolName: String?
        if overview == nil {
            nextToolName = TrendReportModuleToolName.overview
        } else if market == nil {
            nextToolName = TrendReportModuleToolName.market
        } else if !remainingCodes.isEmpty {
            nextToolName = TrendReportModuleToolName.assetBatch
        } else if actions == nil {
            nextToolName = TrendReportModuleToolName.actions
        } else {
            nextToolName = nil
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

    /// 完整 Validator 仍可能发现跨模块问题。只清空涉及的模块，让模型局部修复，
    /// 不要求重新生成已经通过的其它模块。
    func prepareRepairs(for messages: [String]) {
        let joined = messages.joined(separator: "\n")
        var matched = false
        if joined.contains("组合结论")
            || joined.contains("短中长期")
            || joined.contains("周期趋势") {
            overview = nil
            matched = true
        }
        if joined.contains("大盘")
            || joined.contains("板块")
            || joined.contains("机会")
            || joined.contains("marketOutlook")
            || joined.contains("sectors") {
            market = nil
            matched = true
        }
        if joined.contains("已持有基金")
            || joined.contains("assetTrends")
            || joined.contains("资产「") {
            assetTrendsByCode.removeAll()
            matched = true
        }
        if joined.contains("行动")
            || joined.contains("allocationReview")
            || joined.contains("非投资建议")
            || joined.contains("关键资产")
            || joined.contains("disclaimer") {
            actions = nil
            matched = true
        }
        if !matched {
            // 无法可靠归类的跨模块错误优先重做最后一块，避免推翻全部研究。
            actions = nil
        }
    }

    private var remainingFundCodes: [String] {
        expectedFundCodesByNormalized.keys
            .filter { assetTrendsByCode[$0] == nil }
            .sorted()
            .compactMap { expectedFundCodesByNormalized[$0] }
    }

    private static func normalizedCode(_ value: String?) -> String? {
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
    let description = "分批提交已持有基金趋势。每次最多 5 只，只提交工具结果 remaining_fund_codes 中尚未覆盖的基金；直到全部覆盖。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "assetTrends": [
                "type": "array",
                "items": ["type": "object"],
                "minItems": 1,
                "maxItems": 5
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
            try await store.storeAssetBatch(JSONDecoder().decode(TrendReportAssetBatchModule.self, from: data))
        }
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
            try await store.storeActions(JSONDecoder().decode(TrendReportActionsModule.self, from: data))
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
        try await store(draftStore, Data(argumentsJSON.utf8))
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

private func finalizeAssembledReport(
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
    if let decodingError = error as? DecodingError {
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(key.stringValue)（\(context.codingPath.map(\.stringValue).joined(separator: "."))）。"
        case .valueNotFound(_, let context):
            return "字段缺少必要值（\(context.codingPath.map(\.stringValue).joined(separator: "."))）。"
        case .typeMismatch(_, let context):
            return "字段类型不匹配（\(context.codingPath.map(\.stringValue).joined(separator: "."))）。"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return decodingError.localizedDescription
        }
    }
    return error.localizedDescription
}
