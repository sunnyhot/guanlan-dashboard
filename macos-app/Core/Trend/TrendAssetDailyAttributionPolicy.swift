import Foundation

/// 约束基金当日涨跌说明必须是可验证归因，而不是市值、累计盈亏或持仓名单的复述。
enum TrendAssetDailyAttributionPolicy {
    static let attributionPrefix = "涨跌归因："
    static let unavailablePrefix = "原因待确认："
    static let maxUnderlyingQuoteCount = 40

    // 联网搜索（web:tavily:）已下线；因果归因只能由底层证券行情或结构化行情证据支撑。
    private static let causalEvidencePrefixes = [
        "market:stock:",
        "vendor:alphavantage:",
    ]
    private static let unavailableBoundaryTerms = [
        "缺少", "未取得", "未提供", "无法", "不足", "没有",
    ]

    static func displayText(
        from rawValue: String?,
        hasDailyChange: Bool
    ) -> String? {
        guard hasDailyChange else { return nil }
        guard let value = normalized(rawValue),
              value.hasPrefix(attributionPrefix) || value.hasPrefix(unavailablePrefix) else {
            return unavailablePrefix
                + "旧报告只记录了持仓结构与净值结果，没有提供可验证的当日涨跌归因；请重新运行 AI 分析。"
        }
        return value
    }

    /// 2026-09-01 根治:无前缀/空的 impactText 不再拒批,由 App 确定性补前缀。
    /// 规则与 validationMessage 的证据检查同源:causal 证据在 supportingEvidenceIDs
    /// 里 → 补「涨跌归因：」(证据支撑归因声明);否则 → 补「原因待确认：」(保守降级)。
    /// 判定是纯字符串前缀匹配——模型写不写前缀、写哪种前缀,都不再影响运行存活。
    /// 2026-08-31 实证:glm-5.3-flash 对同一批 8 只无行情基金连续 4 轮不写前缀,
    /// 修复预算被格式问题耗尽后撞 1800 秒墙,整 run 报废。
    static func normalizedAttributionText(
        _ impactText: String,
        hasCausalEvidence: Bool
    ) -> String {
        if let value = normalized(impactText) {
            guard value.hasPrefix(attributionPrefix) || value.hasPrefix(unavailablePrefix) else {
                return (hasCausalEvidence ? attributionPrefix : unavailablePrefix) + value
            }
            return value
        }
        return unavailablePrefix + TrendDegradedAssetFactory.missingImpactText
    }

    /// supporting 证据里是否含因果归因来源(底层证券行情 / AlphaVantage)。
    static func containsCausalEvidence(_ evidenceIDs: [String]) -> Bool {
        evidenceIDs.contains(where: isCausalEvidenceID)
    }

    static func validationMessage(for asset: TrendAssetView) -> String? {
        guard let value = normalized(asset.impactText) else {
            return "基金 \(asset.code ?? asset.name) 的 impactText 不能为空。"
        }
        if value.hasPrefix(unavailablePrefix) {
            guard unavailableBoundaryTerms.contains(where: value.contains) else {
                return "基金 \(asset.code ?? asset.name) 使用「原因待确认：」时，必须说明缺少哪类行情或证据，不能继续复述静态持仓数据。"
            }
            return nil
        }
        guard value.hasPrefix(attributionPrefix) else {
            return "基金 \(asset.code ?? asset.name) 的 impactText 必须以「涨跌归因：」或「原因待确认：」开头；不得用市值、累计盈亏、持仓名单或净值涨跌本身代替原因。"
        }

        let supportingIDs = asset.claimEvidence.supportingEvidenceIDs
        guard supportingIDs.contains(where: isCausalEvidenceID) else {
            return "基金 \(asset.code ?? asset.name) 声称完成涨跌归因，但没有引用底层证券行情或外部研究证据；证据不足时请改为「原因待确认：」。"
        }
        return nil
    }

    /// v4.6.1:「原因待确认:」已声明边界语义但措辞没命中六词硬词表时,
    /// 由 App 追加缺失证据说明而不是拒批(2026-08-28 真实运行实证:
    /// 模型写「超额收益具体来源原因待确认」被词表拒掉,修复预算耗尽致整次失败)。
    /// 前缀仍是 unavailablePrefix,不宣称因果,安全方向不变——与 W4 的
    /// 「App 强制降级自动补写待观察信号」同一先例。
    static func appendingMissingEvidenceBoundaryIfNeeded(_ impactText: String) -> String {
        guard let value = normalized(impactText),
              value.hasPrefix(unavailablePrefix),
              !unavailableBoundaryTerms.contains(where: value.contains) else {
            return impactText
        }
        return value + "(缺少可佐证的底层证券当日行情或外部研究证据。)"
    }

    /// 2026-08-28 死循环修复（v4.7.0 实证）：模型写了「涨跌归因：」但 supporting 证据里没有
    /// 任何因果证据（market:stock:/vendor:alphavantage:）时，由 App 降级为「原因待确认：」
    /// 而不是拒批——联网搜索下线后 40 只行情上限外的基金零路径通关，结构性拒批必然复发。
    /// 与 v4.6.1 appendingMissingEvidenceBoundaryIfNeeded 同一先例：只往保守方向改写，原文保留为线索。
    /// 2026-08-28 修复方向3：提交前算出「本轮没有因果行情路径的基金」清单，由 prompt upfront 告知
    /// 模型直接写「原因待确认：」——40 只行情上限或抓取失败之外的基金物理上拿不到
    /// market:stock: 证据；美股底层证券在 Alpha Vantage 已配置时有 vendor: 路径，排除。
    static func fundCodesLackingCausalEvidence(
        expectedFundCodes: [String],
        lookThrough: PortfolioLookThroughSnapshot?,
        quotedStockCodes: Set<String>,
        alphaVantageConfigured: Bool
    ) -> [String] {
        guard !expectedFundCodes.isEmpty else { return [] }
        var lacking: [String] = []
        for fundCode in expectedFundCodes {
            guard let disclosure = lookThrough?.disclosures[fundCode] else {
                lacking.append(fundCode)  // 无披露 → 无因果路径
                continue
            }
            let topStocks = disclosure.holdings
                .filter { $0.kind == .stock }
                .sorted { $0.weightPct > $1.weightPct }
                .prefix(3)
            guard !topStocks.isEmpty else {
                lacking.append(fundCode)  // 无股票底层（纯债/货基）→ 无因果路径
                continue
            }
            let hasQuoted = topStocks.contains { quotedStockCodes.contains($0.code) }
            if hasQuoted { continue }
            let hasAVPath = alphaVantageConfigured
                && topStocks.contains { UserPortfolioHolding.detectStockMarket(from: $0.code) == .us }
            if !hasAVPath {
                lacking.append(fundCode)
            }
        }
        return lacking
    }

    static func downgradedAttributionText(_ asset: TrendAssetView) -> String? {
        guard let value = normalized(asset.impactText),
              value.hasPrefix(attributionPrefix) else { return nil }
        let hasCausal = asset.claimEvidence.supportingEvidenceIDs.contains(where: isCausalEvidenceID)
        guard !hasCausal else { return nil }
        let original = String(value.dropFirst(attributionPrefix.count))
        return unavailablePrefix
            + "(缺少可佐证的底层证券当日行情或外部研究证据。原描述：\(original))"
    }

    static func underlyingQuoteCodes(
        in snapshot: PortfolioLookThroughSnapshot
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for fundCode in snapshot.disclosures.keys.sorted() {
            guard let disclosure = snapshot.disclosures[fundCode] else { continue }
            let topStocks = disclosure.holdings
                .filter { $0.kind == .stock }
                .sorted { $0.weightPct > $1.weightPct }
                .prefix(3)
            for holding in topStocks {
                let code = holding.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty, seen.insert(code).inserted else { continue }
                result.append(code)
                if result.count == maxUnderlyingQuoteCount {
                    return result
                }
            }
        }
        return result
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isCausalEvidenceID(_ evidenceID: String) -> Bool {
        causalEvidencePrefixes.contains { evidenceID.hasPrefix($0) }
    }
}
