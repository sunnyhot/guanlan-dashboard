import Foundation

// MARK: - V2 归因桥接（ATTR-5，Epic 9 首次 App 层引用 V2，双轨期开始）
//
// B.3 集成时点：Epic 9 起 App 层引用 V2，与旧 marketCloseReview 双轨展示，
// 旧代码 Epic 12 才删。本文件是唯一的 App→V2 桥：
// - 旧链路（MarketCloseReviewSnapshot）完全不动；
// - V2 归因只消费 userPortfolioSnapshot 的冻结数字（确定性，无 LLM）。

/// 从用户组合快照供 V2 归因输入（DailyAttributionInputProvider 实现）。
///
/// 语义对齐旧链路的数据基础：
/// - 权重 = marketValue / ΣmarketValue（无市值的行无法加权，不进 positions——
///   归因需要权重基础，缺权重不猜）；
/// - 成分收益 = estimateChangePct（nil = 涨跌未公布，进 coverage 缺口）；
/// - 组合实际收益 = dailyChangeSummary.pct（缺失时 residual 不产）。
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
        snapshot.dailyChangeSummary.pct.map { Ratio(value: Self.decimal($0 / 100)) }
    }

    /// Double → Decimal（经字符串舍入到 10 位，避免二进制浮点尾噪进入 artifact）。
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.10f", value)) ?? Decimal.zero
    }
}

// MARK: - AppModel 派生入口

extension AppModel {
    /// V2 双轨归因 outcome（ATTR-5）。纯计算，每次访问重跑（几十行循环，
    /// 成本可忽略）；与 marketCloseReview 并存展示，互不影响。
    ///
    /// nil = 无持仓快照（面板显示待刷新态）。
    var dailyAttributionV2: DailyAttributionWorkflow.RunOutcome? {
        guard let snapshot = userPortfolioSnapshot, !snapshot.rows.isEmpty else { return nil }
        let workflow = DailyAttributionWorkflow(provider: UserPortfolioAttributionProvider(snapshot: snapshot))
        // 归因日 = 涨跌数据实际所属交易日（无任何涨跌数据时退回今天）
        let attributionDate = Self.attributionV2Date(latestChangeDate: snapshot.latestChangeDate)
        return workflow.run(portfolioKey: "app:userPortfolio", on: attributionDate, now: Date())
    }

    /// 「yyyy-MM-dd」→ 当地（Asia/Shanghai）日界；解析失败 / nil 用今天。
    private static func attributionV2Date(latestChangeDate: String?) -> Date {
        guard let latestChangeDate else { return Date() }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: String(latestChangeDate.prefix(10))) else { return Date() }
        return parsed
    }
}
