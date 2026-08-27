import Foundation

// MARK: - EastmoneyHoldingRecordBuilder（REPO-7 持仓 → ProviderRecord）
//
// FundLookThroughClient 已经负责天天基金 fundf10 的请求、重试、缓存与 HTML/JSON
// 解析。本边界只消费它的 typed disclosure，把 Provider 视角的持仓字段封装成
// FundHoldingPayload；不修改现有 client，也不把 Core 的披露模型泄漏到 Pipeline。

/// 将现有天天基金持仓披露转换成一个 FundHolding ProviderRecord。
///
/// 天天基金当前披露的持仓只有 weightPct。shares / marketValue 没有可靠来源时
/// 明确留 nil，不能用 0 或权重反推，以免下游把缺口当成真实数据。
struct EastmoneyHoldingRecordBuilder: Sendable {

    /// 一份披露对应一个 snapshot record。无可用报告日期时返回 nil，避免制造
    /// 没有 PIT 时间锚点的 ProviderRecord。
    static func makeRecord(
        from disclosure: FundLookThroughDisclosure,
        reliabilityClass: ProviderReliabilityClass,
        jurisdiction: Jurisdiction,
        ingestedAt: Date
    ) -> ProviderRecord? {
        guard let effectiveAt = disclosureDate(for: disclosure) else { return nil }

        let positions = disclosure.holdings.compactMap { holding -> FundHoldingPayload.Position? in
            let code = holding.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty,
                  holding.weightPct.isFinite,
                  holding.weightPct > 0,
                  holding.weightPct <= 100,
                  let weight = Decimal(string: String(holding.weightPct / 100))
            else {
                return nil
            }

            return FundHoldingPayload.Position(
                providerID: .eastmoney,
                providerCode: ProviderCode(
                    scheme: providerScheme(for: holding.kind),
                    value: code
                ),
                weight: Ratio(value: weight),
                shares: nil,
                marketValue: nil,
                isDisclosed: true
            )
        }

        let disclosedWeightTotal = min(
            Decimal(1),
            positions.reduce(Decimal.zero) { $0 + $1.weight.value }
        )
        let payload = FundHoldingPayload(
            reportPeriod: reportPeriod(for: effectiveAt),
            positions: positions,
            disclosedWeightTotal: Ratio(value: disclosedWeightTotal)
        )
        guard let rawPayload = try? JSONEncoder().encode(payload) else { return nil }

        // FundLookThroughDisclosure exposes the report cutoff date, not the separate
        // announcement date. Preserve the source timestamp rather than inventing one;
        // a later source revision can add a real publishedAt without changing payload.
        return ProviderRecord(
            providerID: .eastmoney,
            providerCode: ProviderCode(scheme: "fund_code", value: disclosure.fundCode),
            effectiveAt: effectiveAt,
            publishedAt: effectiveAt,
            ingestedAt: ingestedAt,
            kind: .fundHoldingSnapshot,
            rawPayload: rawPayload,
            reliabilityClass: reliabilityClass,
            jurisdiction: jurisdiction
        )
    }

    private static func providerScheme(for kind: FundUnderlyingAssetKind) -> String {
        switch kind {
        case .stock: return "stock_symbol"
        case .bond: return "bond_symbol"
        }
    }

    private static func disclosureDate(for disclosure: FundLookThroughDisclosure) -> Date? {
        parseShanghaiDay(disclosure.asOf)
            ?? disclosure.holdings
                .compactMap { parseShanghaiDay($0.disclosureDate) }
                .max()
    }

    private static func parseShanghaiDay(_ rawValue: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(rawValue.prefix(10))) else { return nil }
        return formatter.calendar.startOfDay(for: date)
    }

    private static func reportPeriod(for date: Date) -> FundHoldingSnapshot.ReportPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        switch calendar.component(.month, from: date) {
        case 1...3: return .q1
        case 4...6: return .q2
        case 7...9: return .q3
        default: return .q4
        }
    }
}
