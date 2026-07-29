import Foundation

// 阶段二：submit_trend_report 工具。
//
// 接收模型提交的完整报告，执行：解码 → 用快照覆盖 privacyMode/dataAsOf、用当前时间
// 覆盖 generatedAt → 证据归一化（只保留被引用且账本中存在的证据，用账本规范对象覆盖
// 模型填写字段）→ 调用增强后的 Validator。校验通过则返回 completion，Agent 结束；
// 校验失败则把错误回灌模型继续修正。

struct SubmitTrendReportTool: TrendResearchTool {
    let name = "submit_trend_report"
    let description = "提交最终趋势研究报告并结束本次分析。report 必须是完整的报告对象。证据只能引用工具返回的 evidence_ids，不得创造 URL 或来源标题。所有持有基金必须出现在 assetTrends。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "report": ["type": "object", "description": "完整的 TrendAnalysisReport 对象"]
        ],
        "required": ["report"],
        "additionalProperties": false
    ]

    func execute(argumentsJSON: String, context: TrendResearchToolContext) async -> TrendResearchToolResult {
        let snapshot = context.snapshot

        // 1. 取出 report 对象。
        guard let argumentsObject = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any],
              let reportValue = argumentsObject["report"] else {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "缺少 report 字段或参数不是合法 JSON"), isError: true)
        }
        let reportData: Data
        do {
            reportData = try JSONSerialization.data(withJSONObject: reportValue)
        } catch {
            return .content(TrendResearchToolEnvelope.error(code: "invalid_arguments", message: "report 对象无法序列化：\(error.localizedDescription)"), isError: true)
        }

        // 2. 解码（自定义 init(from:) 对缺失字段宽容）。
        let decoded: TrendAnalysisReport
        do {
            decoded = try JSONDecoder().decode(TrendAnalysisReport.self, from: reportData)
        } catch {
            return validationFailure(messages: ["报告解码失败：\(Self.describeDecodingError(error))"], context: context)
        }
        guard decoded.schemaVersion == TrendAnalysisReport.currentSchemaVersion else {
            return validationFailure(
                messages: [
                    "本次提交必须使用 schemaVersion=\(TrendAnalysisReport.currentSchemaVersion)，旧结构不能绕过 Claim-Evidence 安全门。"
                ],
                context: context
            )
        }

        // 3. 收集被引用的证据 ID（sectors/marketOutlook/opportunities）。
        let referencedIDs = Self.collectReferencedEvidenceIDs(decoded)

        // 4. 证据归一化：只保留被引用且账本中存在的证据，用账本规范对象覆盖模型字段。
        var canonical: [TrendEvidence] = []
        var seen = Set<String>()
        for id in referencedIDs {
            if seen.contains(id) { continue }
            guard let entry = await context.evidenceLedger.canonical(for: id) else { continue }
            seen.insert(id)
            canonical.append(entry)
        }

        // 5. 外部信号状态、数据源状态和置信度由 App 归一化，忽略模型自报值。
        let externalSignalStatus = Self.externalSignalStatus(for: canonical)
        let sourceStatuses = await Self.normalizedSourceStatuses(
            snapshot: snapshot,
            ledger: context.evidenceLedger,
            officialSourceConfigured: context.officialSourceSettings.isSECConfigured,
            alphaVantageConfigured: context.alphaVantageSettings.isConfigured,
            webSearchConfigured: context.webSearchSettings.isConfigured
        )
        let insufficientReasons = Self.insufficientEvidenceReasons(
            sourceStatuses: sourceStatuses,
            expectedFundCodes: snapshot.expectedFundCodes,
            marketQuotes: snapshot.marketQuotes
        )
        let normalizedHorizons = decoded.horizons.map {
            Self.normalized(
                $0,
                forceShortUncertainReasons: insufficientReasons
            )
        }
        var normalizedMarket = decoded.marketOutlook.map(Self.normalized)
        var normalizedSectors = decoded.sectors.map(Self.normalized)
        var normalizedOpportunities = decoded.opportunities.map(Self.normalized)

        // 非 action 研究结论（板块/大类资产/机会）若 supporting 证据与该主题无关联，
        // 降级为 uncertain 并登记 warning——不硬拒整份报告；资金动作仍由 validateAction 严卡。
        let canonicalByID = Dictionary(canonical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let claimPolicy = TrendClaimEvidencePolicy()
        var associationDowngradeWarnings: [TrendWarning] = []
        for index in normalizedSectors.indices {
            let claim = normalizedSectors[index]
            guard claim.direction != .uncertain else { continue }
            if claimPolicy.lacksAssociatedSupport(evidence: claim.claimEvidence, evidenceByID: canonicalByID, sectorKey: claim.name) {
                normalizedSectors[index].direction = .uncertain
                associationDowngradeWarnings.append(TrendWarning(id: "association-downgrade-sector-\(claim.id)", title: "证据关联降级", detail: "板块「\(claim.name)」的支持证据与该板块无明确关联，已降级为 uncertain。"))
            }
        }
        for index in normalizedMarket.indices {
            let claim = normalizedMarket[index]
            guard claim.direction != .uncertain else { continue }
            if claimPolicy.lacksAssociatedSupport(evidence: claim.claimEvidence, evidenceByID: canonicalByID, entityName: claim.name) {
                normalizedMarket[index].direction = .uncertain
                associationDowngradeWarnings.append(TrendWarning(id: "association-downgrade-market-\(claim.id)", title: "证据关联降级", detail: "大盘/大类资产「\(claim.name)」的支持证据与该主题无明确关联，已降级为 uncertain。"))
            }
        }
        for index in normalizedOpportunities.indices {
            let claim = normalizedOpportunities[index]
            guard claim.direction != .uncertain else { continue }
            if claimPolicy.lacksAssociatedSupport(evidence: claim.claimEvidence, evidenceByID: canonicalByID, entityName: claim.name) {
                normalizedOpportunities[index].direction = .uncertain
                associationDowngradeWarnings.append(TrendWarning(id: "association-downgrade-opportunity-\(claim.id)", title: "证据关联降级", detail: "机会「\(claim.name)」的支持证据与该主题无明确关联，已降级为 uncertain。"))
            }
        }
        let normalizedKeyAssets = decoded.keyAssets.map {
            Self.normalized($0, forceShortUncertainReasons: insufficientReasons)
        }
        let normalizedAssetTrends = decoded.assetTrends.map {
            Self.normalized($0, forceShortUncertainReasons: insufficientReasons)
        }
        let normalizedActions = insufficientReasons.isEmpty
            ? decoded.actions.map(Self.normalized)
            : []
        let disposition = Self.disposition(
            actions: normalizedActions,
            evidence: canonical,
            insufficientReasons: insufficientReasons
        )
        let sourceWarnings = sourceStatuses.compactMap { status -> TrendWarning? in
            guard let detail = status.warningText else { return nil }
            return TrendWarning(
                id: "source-status-\(status.source.rawValue)-\(status.status.rawValue)",
                title: "数据来源边界",
                detail: detail
            )
        }
        let insufficiencyWarnings = insufficientReasons.enumerated().map {
            TrendWarning(
                id: "insufficient-evidence-\($0.offset)",
                title: "已降级为证据不足",
                detail: $0.element
            )
        }
        let warnings = Self.uniqueWarnings(
            decoded.warnings + sourceWarnings + insufficiencyWarnings + associationDowngradeWarnings
        )

        // 6. 用快照覆盖 privacyMode（let，需重建）和 dataAsOf；用当前时间覆盖 generatedAt。
        let normalized = TrendAnalysisReport(
            id: decoded.id,
            generatedAt: Self.nowTimestamp(),
            dataAsOf: snapshot.dataAsOf,
            privacyMode: snapshot.privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: decoded.portfolio,
            horizons: normalizedHorizons,
            marketOutlook: normalizedMarket,
            sectors: normalizedSectors,
            opportunities: normalizedOpportunities,
            keyAssets: normalizedKeyAssets,
            assetTrends: normalizedAssetTrends,
            actions: normalizedActions,
            evidence: canonical,
            warnings: warnings,
            disclaimer: decoded.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: disposition,
            sourceStatuses: sourceStatuses
        )

        // 7. 业务校验。
        let result = TrendAnalysisValidator().validate(
            normalized,
            expectedFundCodes: snapshot.expectedFundCodes,
            expectedPrivacyMode: snapshot.privacyMode
        )
        guard result.isValid else {
            return validationFailure(messages: result.messages, context: context)
        }

        // 8. 校验通过，返回报告，Agent 结束。
        let successEnvelope = TrendResearchToolEnvelope.success([
            "accepted": true,
            "generatedAt": normalized.generatedAt,
            "dataAsOf": normalized.dataAsOf
        ])
        return .report(successEnvelope, isError: false, report: normalized)
    }

    private func validationFailure(messages: [String], context: TrendResearchToolContext) -> TrendResearchToolResult {
        let remaining = max(0, context.invalidSubmissionBudget - context.invalidSubmissionsUsed - 1)
        let envelope = TrendResearchToolEnvelope.submitValidationError(
            code: "report_validation_failed",
            message: "报告未通过校验，请按 errors 修正后重新提交。",
            errors: messages,
            remainingRepairAttempts: remaining
        )
        return .content(envelope, isError: true)
    }

    private static func collectReferencedEvidenceIDs(_ report: TrendAnalysisReport) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let append: (String) -> Void = { id in
            if !seen.contains(id) { seen.insert(id); ids.append(id) }
        }
        report.sectors.forEach { $0.evidenceIDs.forEach(append) }
        report.marketOutlook.forEach { $0.evidenceIDs.forEach(append) }
        report.opportunities.forEach { $0.evidenceIDs.forEach(append) }
        report.portfolio.claimEvidence.allEvidenceIDs.forEach(append)
        report.horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        report.sectors.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        report.marketOutlook.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        report.opportunities.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        (report.keyAssets + report.assetTrends).forEach { asset in
            asset.claimEvidence.allEvidenceIDs.forEach(append)
            asset.horizons.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        }
        report.actions.forEach { $0.claimEvidence.allEvidenceIDs.forEach(append) }
        return ids
    }

    private static func externalSignalStatus(for evidence: [TrendEvidence]) -> TrendExternalSignalStatus {
        if evidence.contains(where: {
            $0.metadata.sourceKind.isExternalResearch
                || $0.id.hasPrefix("official:sec:")
                || $0.id.hasPrefix("web:tavily:")
        }) {
            return .available
        }
        if evidence.contains(where: { $0.id.hasPrefix("market:") }) {
            return .partial
        }
        return .unavailable
    }

    private static func normalizedSourceStatuses(
        snapshot: TrendResearchSnapshot,
        ledger: TrendEvidenceLedger,
        officialSourceConfigured: Bool,
        alphaVantageConfigured: Bool,
        webSearchConfigured: Bool
    ) async -> [TrendSourceStatus] {
        var bySource = Dictionary(
            snapshot.sourceStatuses.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allEvidence = await ledger.allEvidence()
        let officialEvidence = allEvidence.filter {
            $0.metadata.sourceKind.isOfficialPrimary || $0.id.hasPrefix("official:sec:")
        }
        let eligibleOfficialTargets = snapshot.eligibleSECResearchTickers
        if eligibleOfficialTargets.isEmpty {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: .notRequested,
                receivedAt: snapshot.createdAt,
                detail: "当前快照没有可映射到 SEC 的美国股票代码。"
            )
        } else if officialSourceConfigured {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: officialEvidence.isEmpty ? .failed : .success,
                asOf: officialEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: officialEvidence.map(\.retrievedAt).max() ?? snapshot.createdAt,
                errorCode: officialEvidence.isEmpty ? "no_usable_official_evidence" : nil,
                itemCount: officialEvidence.count,
                detail: officialEvidence.isEmpty
                    ? "SEC 官方源已尝试，但没有形成可用、可引用的证据。"
                    : nil
            )
        } else {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: .notConfigured,
                receivedAt: snapshot.createdAt,
                detail: "SEC 官方源需要启用并填写联系邮箱。"
            )
        }
        let alphaEvidence = allEvidence.filter {
            $0.metadata.sourceKind == .licensedMarketData
                || $0.id.hasPrefix("vendor:alphavantage:")
        }
        if snapshot.eligibleAlphaVantageSymbols.isEmpty {
            bySource[.alphaVantage] = TrendSourceStatus(
                source: .alphaVantage,
                status: .notRequested,
                receivedAt: snapshot.createdAt,
                detail: "当前快照没有可映射到 Alpha Vantage 的股票或 ETF 代码。"
            )
        } else if alphaVantageConfigured {
            bySource[.alphaVantage] = TrendSourceStatus(
                source: .alphaVantage,
                status: alphaEvidence.isEmpty ? .failed : .success,
                asOf: alphaEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: alphaEvidence.map(\.retrievedAt).max() ?? snapshot.createdAt,
                errorCode: alphaEvidence.isEmpty ? "no_usable_alpha_vantage_evidence" : nil,
                itemCount: alphaEvidence.count,
                detail: alphaEvidence.isEmpty
                    ? "Alpha Vantage 已尝试，但没有形成可用、可引用的结构化证据。"
                    : nil
            )
        } else {
            bySource[.alphaVantage] = TrendSourceStatus(
                source: .alphaVantage,
                status: .notConfigured,
                receivedAt: snapshot.createdAt,
                detail: "未启用或未填写 Alpha Vantage API Key。"
            )
        }
        let webEvidence = allEvidence.filter {
            $0.metadata.sourceKind == .webSearch || $0.id.hasPrefix("web:tavily:")
        }
        if webSearchConfigured {
            bySource[.webSearch] = TrendSourceStatus(
                source: .webSearch,
                status: webEvidence.isEmpty ? .failed : .success,
                asOf: webEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: webEvidence.map(\.retrievedAt).max() ?? snapshot.createdAt,
                errorCode: webEvidence.isEmpty ? "no_usable_web_evidence" : nil,
                itemCount: webEvidence.count,
                detail: webEvidence.isEmpty
                    ? "联网搜索已尝试，但没有形成可用、可引用的新证据。"
                    : nil
            )
        } else {
            bySource[.webSearch] = TrendSourceStatus(
                source: .webSearch,
                status: .notConfigured,
                receivedAt: snapshot.createdAt,
                detail: "未配置 Tavily API Key。"
            )
        }
        for source in TrendDataSource.allCases where bySource[source] == nil {
            bySource[source] = TrendSourceStatus(
                source: source,
                status: .notRequested,
                receivedAt: snapshot.createdAt
            )
        }
        return TrendDataSource.allCases.compactMap { bySource[$0] }
    }

    private static func disposition(
        actions: [TrendActionCandidate],
        evidence: [TrendEvidence],
        insufficientReasons: [String]
    ) -> TrendReportDisposition {
        if !insufficientReasons.isEmpty {
            return .insufficientEvidence
        }
        if actions.contains(where: { $0.kind.evidencePolicyLevel == .allocationReview }) {
            return .actionable
        }
        let hasResearchEvidence = evidence.contains {
            switch $0.metadata.sourceKind {
            case .marketQuote, .fundDisclosure, .platformSignal, .managerSignal,
                 .officialFiling, .officialFinancial, .licensedMarketData, .webSearch:
                return true
            case .portfolioSnapshot, .derived, .unknown:
                return false
            }
        }
        return hasResearchEvidence ? .analysisOnly : .insufficientEvidence
    }

    private static func normalized(
        _ value: TrendHorizonView,
        forceShortUncertainReasons: [String] = []
    ) -> TrendHorizonView {
        let mustDowngrade = value.horizon == .short
            && !forceShortUncertainReasons.isEmpty
        let evidence = mustDowngrade && value.claimEvidence.supportingEvidenceIDs.isEmpty
            ? TrendClaimEvidence(
                supportingEvidenceIDs: [],
                counterEvidenceIDs: value.claimEvidence.counterEvidenceIDs,
                contextEvidenceIDs: value.claimEvidence.contextEvidenceIDs,
                exemptionReason: forceShortUncertainReasons.joined(separator: "；")
            )
            : value.claimEvidence
        return TrendHorizonView(
            horizon: value.horizon,
            direction: mustDowngrade ? .uncertain : value.direction,
            confidence: mustDowngrade
                ? TrendConfidence(score: min(35, value.confidence.score), label: "低").appNormalized
                : value.confidence.appNormalized,
            rationale: value.rationale,
            counterSignals: value.counterSignals,
            claimEvidence: evidence
        )
    }

    private static func normalized(_ value: TrendMarketOutlook) -> TrendMarketOutlook {
        TrendMarketOutlook(
            id: value.id,
            name: value.name,
            category: value.category,
            direction: value.direction,
            confidence: value.confidence.appNormalized,
            rationale: value.rationale,
            evidenceIDs: value.evidenceIDs,
            counterSignals: value.counterSignals,
            claimEvidence: effectiveClaimEvidence(
                value.claimEvidence,
                legacySupportingIDs: value.evidenceIDs
            )
        )
    }

    private static func normalized(_ value: TrendSectorView) -> TrendSectorView {
        TrendSectorView(
            id: value.id,
            name: value.name,
            exposureText: value.exposureText,
            direction: value.direction,
            confidence: value.confidence.appNormalized,
            rationale: value.rationale,
            evidenceIDs: value.evidenceIDs,
            counterSignals: value.counterSignals,
            claimEvidence: effectiveClaimEvidence(
                value.claimEvidence,
                legacySupportingIDs: value.evidenceIDs
            )
        )
    }

    private static func normalized(_ value: TrendOpportunity) -> TrendOpportunity {
        TrendOpportunity(
            id: value.id,
            name: value.name,
            category: value.category,
            direction: value.direction,
            confidence: value.confidence.appNormalized,
            rationale: value.rationale,
            triggerConditions: value.triggerConditions,
            invalidatingConditions: value.invalidatingConditions,
            evidenceIDs: value.evidenceIDs,
            counterSignals: value.counterSignals,
            claimEvidence: effectiveClaimEvidence(
                value.claimEvidence,
                legacySupportingIDs: value.evidenceIDs
            )
        )
    }

    private static func normalized(
        _ value: TrendAssetView,
        forceShortUncertainReasons: [String] = []
    ) -> TrendAssetView {
        TrendAssetView(
            id: value.id,
            name: value.name,
            code: value.code,
            sector: value.sector,
            impactText: value.impactText,
            horizons: value.horizons.map {
                normalized(
                    $0,
                    forceShortUncertainReasons: forceShortUncertainReasons
                )
            },
            rationale: value.rationale,
            counterSignals: value.counterSignals,
            claimEvidence: value.claimEvidence
        )
    }

    private static func normalized(_ value: TrendActionCandidate) -> TrendActionCandidate {
        TrendActionCandidate(
            id: value.id,
            kind: value.kind,
            title: value.title,
            detail: value.detail,
            targetName: value.targetName,
            confidence: value.confidence.appNormalized,
            triggerConditions: value.triggerConditions,
            invalidatingConditions: value.invalidatingConditions,
            claimEvidence: value.claimEvidence
        )
    }

    private static func uniqueWarnings(_ warnings: [TrendWarning]) -> [TrendWarning] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0.id).inserted }
    }

    private static func insufficientEvidenceReasons(
        sourceStatuses: [TrendSourceStatus],
        expectedFundCodes: [String],
        marketQuotes: [TrendResearchQuote]
    ) -> [String] {
        let bySource = Dictionary(
            sourceStatuses.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reasons: [String] = []
        if bySource[.portfolioQuote]?.status != .success {
            reasons.append("个人持仓报价没有形成可用成功状态，短期方向已降为 uncertain，行动已禁用。")
        }
        if bySource[.marketIndex]?.status != .success {
            reasons.append("主要指数行情没有形成可用成功状态，短期方向已降为 uncertain，行动已禁用。")
        } else {
            let chinaIndexCodes: Set<String> = [
                MarketIndexKind.sseComposite.rawValue,
                MarketIndexKind.csi300.rawValue,
                MarketIndexKind.chinext.rawValue,
            ]
            let hasUsableChinaIndex = marketQuotes.contains {
                $0.kind == "index"
                    && chinaIndexCodes.contains($0.code)
                    && [.fresh, .previousSessionClose].contains(
                        $0.assessment.freshnessStatus
                    )
            }
            if !hasUsableChinaIndex {
                reasons.append("主要指数行情时间不满足当前时段的新鲜度策略，短期方向已降为 uncertain，行动已禁用。")
            }
        }
        if bySource[.webSearch]?.status != .success {
            reasons.append("联网搜索没有形成新的可引用证据，短期方向已降为 uncertain，行动已禁用。")
        }
        let expectedFundCount = Set(expectedFundCodes).count
        if expectedFundCount > 0 {
            let disclosure = bySource[.fundDisclosure]
            if disclosure?.status != .success
                || (disclosure?.itemCount ?? 0) < expectedFundCount {
                reasons.append("持有基金的公开披露未完整形成可用快照，基金短期行动已禁用。")
            }
        }
        return reasons
    }

    private static func effectiveClaimEvidence(
        _ value: TrendClaimEvidence,
        legacySupportingIDs: [String]
    ) -> TrendClaimEvidence {
        guard value.allEvidenceIDs.isEmpty,
              !legacySupportingIDs.isEmpty else {
            return value
        }
        return TrendClaimEvidence(
            supportingEvidenceIDs: legacySupportingIDs
        )
    }

    private static func nowTimestamp() -> String {
        Self.timestampFormatter.string(from: Date())
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(key.stringValue)\(codingPathSuffix(context.codingPath))"
        case .valueNotFound(_, let context):
            return "缺少必要值\(codingPathSuffix(context.codingPath))"
        case .typeMismatch(_, let context):
            return "字段类型不匹配\(codingPathSuffix(context.codingPath))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPathSuffix(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "" }
        return "（路径：\(path.map(\.stringValue).joined(separator: "."))）"
    }
}
