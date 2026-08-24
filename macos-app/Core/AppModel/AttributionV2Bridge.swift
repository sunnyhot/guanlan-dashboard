import Foundation

// MARK: - V2 归因桥接（ATTR-5，Epic 9 首次 App 层引用 V2，双轨期开始）
//
// B.3 集成时点：Epic 9 起 App 层引用 V2，与旧 marketCloseReview 双轨展示，
// 旧代码 Epic 12 才删。本文件是唯一的 App→V2 桥：
// - 旧链路（MarketCloseReviewSnapshot）完全不动；
// - V2 归因只消费 userPortfolioSnapshot 的冻结数字（确定性，无 LLM）。
//
// 审查 P1-8 修复：估值 / 涨跌覆盖不完整时**不提供组合实际收益**（residual
// 的分母必须是全组合口径，dailyChangeSummary 只聚合已知行——子集收益当
// 全组合 residual 基准会系统性偏差）；覆盖状态随结果透出供 UI 降级表述。

/// 从用户组合快照供 V2 归因输入（DailyAttributionInputProvider 实现）。
///
/// 语义对齐旧链路的数据基础：
/// - 权重 = marketValue / ΣmarketValue（无市值的行无法加权，不进 positions——
///   归因需要权重基础，缺权重不猜）；
/// - 成分收益 = estimateChangePct（nil = 涨跌未公布，进 coverage 缺口）；
/// - 组合实际收益 = dailyChangeSummary.pct，**仅在估值与涨跌双全覆盖时
///   提供**（否则 residual 不产——审查 P1-8）。
struct UserPortfolioAttributionProvider: DailyAttributionInputProvider {
    let snapshot: UserPortfolioSnapshot

    init(snapshot: UserPortfolioSnapshot) {
        self.snapshot = snapshot
    }

    func positions(portfolioKey: String, on date: Date) throws -> [AttributionPositionInput] {
        snapshot.rows.compactMap { row in
            guard let marketValue = row.marketValue, marketValue > 0 else { return nil }
            // App 侧 code 直接作 subject 键（fundCode 对基金/股票通用）；
            // 接 Canonical Identity 后替换为登记 ID（双轨期渐进）
            let subject: AttributionSubject = row.holding.assetType == .stock
                ? .listing(ListingID(rawValue: row.holding.fundCode))
                : .fund(FundProductID(rawValue: row.holding.fundCode))
            let periodReturn = row.estimateChangePct.map {
                Ratio(value: Self.decimal($0 / 100))
            }
            return AttributionPositionInput(
                subject: subject,
                weight: Ratio(value: Self.decimal(marketValue)),
                periodReturn: periodReturn
            )
        }
    }

    func portfolioReturn(portfolioKey: String, on date: Date) throws -> Ratio? {
        // residual 基准要求全组合口径：任一行缺估值或缺涨跌 → 不提供
        // （dailyChangeSummary 只是已知行子集的加权，当作全组合实际收益
        // 会产生系统性偏差的 residual——审查 P1-8）
        guard snapshot.dailyChangeCoverageCount == snapshot.rows.count,
              !snapshot.hasIncompleteValuationCoverage
        else { return nil }
        return snapshot.dailyChangeSummary.pct.map { Ratio(value: Self.decimal($0 / 100)) }
    }

    /// Double → Decimal（经字符串舍入到 10 位，避免二进制浮点尾噪进入 artifact）。
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.10f", value)) ?? Decimal.zero
    }
}

// MARK: - 覆盖状态（审查 P1-8：随 outcome 透出，UI 据此降级表述）

/// 组合快照的数据覆盖状态（估值 / 涨跌两层）。
struct AttributionDataCoverage: Hashable {
    let holdingCount: Int
    /// 有市值的行数（权重基础）
    let valuedCount: Int
    /// 有涨跌的行数（收益已知）
    let changeCount: Int

    var hasFullValuation: Bool { valuedCount == holdingCount && holdingCount > 0 }
    var hasFullChange: Bool { changeCount == holdingCount && holdingCount > 0 }
    /// residual 口径完备（估值 + 涨跌双全）
    var supportsResidual: Bool { hasFullValuation && hasFullChange }

    var summaryText: String {
        "估值覆盖 \(valuedCount)/\(holdingCount) · 涨跌覆盖 \(changeCount)/\(holdingCount)"
    }
}

// MARK: - AppModel 派生入口

extension AppModel {
    /// V2 双轨归因（ATTR-5）。纯计算；与 marketCloseReview 并存展示。
    ///
    /// nil = 无持仓快照（面板显示待刷新态）。
    var dailyAttributionV2: DailyAttributionWorkflow.RunOutcome? {
        guard let snapshot = userPortfolioSnapshot, !snapshot.rows.isEmpty else { return nil }
        let workflow = DailyAttributionWorkflow(provider: UserPortfolioAttributionProvider(snapshot: snapshot))
        // 归因日 = 涨跌数据实际所属交易日；缺失时用上海时区当日零点
        // （固定日界——审查 P2-9：同一天内 ID 稳定）
        let attributionDate = Self.attributionV2Date(latestChangeDate: snapshot.latestChangeDate)
        return workflow.run(portfolioKey: "app:userPortfolio", on: attributionDate, now: Date())
    }

    /// 数据覆盖状态（审查 P1-8：UI 降级表述的依据）。
    var attributionV2Coverage: AttributionDataCoverage? {
        guard let snapshot = userPortfolioSnapshot, !snapshot.rows.isEmpty else { return nil }
        return AttributionDataCoverage(
            holdingCount: snapshot.rows.count,
            valuedCount: snapshot.rows.filter { ($0.marketValue ?? 0) > 0 }.count,
            changeCount: snapshot.dailyChangeCoverageCount
        )
    }

    /// 「yyyy-MM-dd」→ 上海时区日界；解析失败 / nil 用上海时区**当日零点**
    /// （固定日界，同一天内不随访问时刻漂移——审查 P2-9）。
    private static func attributionV2Date(latestChangeDate: String?) -> Date {
        let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let fallback = cal.startOfDay(for: Date())

        guard let latestChangeDate else { return fallback }
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: String(latestChangeDate.prefix(10))) else { return fallback }
        return parsed
    }
}
