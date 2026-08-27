import Foundation

// MARK: - IntelligencePresentationFormatter（稳定文案层，产品重构方案 §5.2）
//
// Dashboard DTO 的全部用户可见文案在此程序化生成（同输入同文案）：
// - View 不拼业务文案，只做布局
// - 内部术语（Artifact ID / universe 版本 / provenance raw value / 文件名）
//   不进入摘要层文案；技术 ID 只允许出现在详情层的技术信息折叠区
// - 日期按用户 Locale；不引入 LLM

enum IntelligencePresentationFormatter {

    // MARK: - 资产类

    static func assetClassName(_ assetClass: AssetClass) -> String {
        switch assetClass {
        case .equity: return "股票"
        case .fixedIncome: return "固收"
        case .commodity: return "商品"
        case .cash: return "现金"
        case .alternative: return "另类"
        }
    }

    // MARK: - 百分比

    /// Decimal（0...1）→ 百分比文案（一位小数，0 显示 0%）。
    static func percentText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let percent = value * 100
        var rounded = percent.rounded(toScale: 1)
        if rounded == rounded.rounded(toScale: 0) {
            rounded = rounded.rounded(toScale: 0)
        }
        return "\(rounded)%"
    }

    /// 偏差文案（带符号；±带内视为 0 显示）。
    static func deviationText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let percent = value * 100
        let rounded = percent.rounded(toScale: 1)
        if rounded == 0 { return "0%" }
        return (rounded > 0 ? "+" : "") + "\(rounded)%"
    }

    // MARK: - 日期

    static func dateTimeText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - 今日结论

    static func headlineStatusLabel(
        _ status: InvestmentIntelligenceDashboardSnapshot.Headline.Status
    ) -> String {
        switch status {
        case .rebalanceSuggested: return "建议再平衡"
        case .holdConfigured: return "维持配置"
        case .undecidable: return "暂不可判断"
        case .notReady: return "尚未准备"
        }
    }

    /// 一句话主因（投影时生成——同快照同文案，双端一致）。
    static func headlineReason(
        status: InvestmentIntelligenceDashboardSnapshot.Headline.Status,
        blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker?,
        intraday: InvestmentIntelligenceDashboardSnapshot.IntradaySummary?,
        maxDeviation: String
    ) -> String {
        switch status {
        case .rebalanceSuggested:
            if intraday?.decision == .executeRebalance, intraday?.moves.isEmpty == false {
                return "当前配置与战略目标的最大偏差已达 \(maxDeviation)，建议按目标调整"
            }
            return "存在超出容忍带的配置偏差"
        case .holdConfigured:
            if let intraday, intraday.decision == .hold, !intraday.holdReasons.isEmpty {
                return intraday.holdReasons[0]
            }
            return "当前配置与战略目标差异均在容忍带内"
        case .undecidable:
            if let intraday, intraday.validity == .expired {
                return "最近一次评估已过期，请重新评估"
            }
            return "暂无有效评估结论，可运行盘中评估"
        case .notReady:
            switch blocker {
            case .missingTarget:
                return "先设定战略配置目标，系统才能给出偏差结论"
            case .unclassifiedHoldings(let subjects):
                return "\(subjects.count) 项持仓待归类，归类完成前不生成结论"
            case .staleValuation(let latest):
                return "持仓估值已过期（最新 \(dateText(latest))），请更新持仓数据"
            case nil:
                return "完成准备工作后开始"
            }
        }
    }

    /// 配置卡最大偏差文案（展示「最大偏差」用）。
    static func maxDeviationText(
        _ allocation: InvestmentIntelligenceDashboardSnapshot.AllocationSummary
    ) -> String {
        let deviations = allocation.rows.compactMap(\.deviation).map { abs($0) }
        guard let maxDeviation = deviations.max() else { return "—" }
        return percentText(maxDeviation)
    }

    // MARK: - 盘中执行

    static func intradayDecisionLabel(
        _ decision: InvestmentIntelligenceDashboardSnapshot.IntradaySummary.Decision
    ) -> String {
        switch decision {
        case .executeRebalance: return "建议调整"
        case .hold: return "持有不动"
        }
    }

    static func intradayValidityLabel(
        _ validity: InvestmentIntelligenceDashboardSnapshot.IntradaySummary.Validity
    ) -> String {
        switch validity {
        case .current: return "本时段有效"
        case .expired: return "已过期"
        }
    }

    /// Δw provenance 的人话来源（D001 三类；不透出 enum raw value）。
    static func provenanceText(
        _ kind: InvestmentIntelligenceDashboardSnapshot.IntradaySummary.PlannedMove.ProvenanceKind
    ) -> String {
        switch kind {
        case .targetFollow: return "跟随战略目标"
        case .remediation: return "修复状态约束"
        case .userDirective: return "用户指令"
        }
    }

    static func plannedMoveText(
        _ move: InvestmentIntelligenceDashboardSnapshot.IntradaySummary.PlannedMove
    ) -> String {
        plannedMoveText(
            subjectKey: move.subjectKey,
            directionUp: move.direction == .increase,
            weightChange: move.weightChange,
            provenanceKind: move.provenanceKind)
    }

    /// 参数化版本（行动候选等非 PlannedMove 形态复用同一文案）。
    static func plannedMoveText(
        subjectKey: String,
        directionUp: Bool,
        weightChange: Decimal,
        provenanceKind: InvestmentIntelligenceDashboardSnapshot.IntradaySummary.PlannedMove.ProvenanceKind
    ) -> String {
        let direction = directionUp ? "增持" : "减持"
        return "\(direction) \(subjectKey) · \(percentText(abs(weightChange)))（\(provenanceText(provenanceKind))）"
    }

    // MARK: - 市场机会

    static func discoveryStateLabel(
        _ state: InvestmentIntelligenceDashboardSnapshot.DiscoverySummary.State
    ) -> String {
        switch state {
        case .hasCandidates: return "已筛出候选"
        case .noCandidates: return "本期无候选"
        case .insufficientData: return "市场数据准备中"
        }
    }

    static func coverageText(
        _ coverage: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.MarketCoverage
    ) -> String {
        "市场数据 \(coverage.covered)/\(coverage.total)"
    }

    // MARK: - 研究与历史

    static func historyKindLabel(
        _ kind: InvestmentIntelligenceDashboardSnapshot.HistoryItem.Kind
    ) -> String {
        switch kind {
        case .intraday: return "盘中评估"
        case .decision: return "组合决策"
        case .discovery: return "市场发现"
        case .closeReview: return "收盘复盘"
        }
    }

    static func historyValidityLabel(_ isValid: Bool) -> String {
        isValid ? "有效" : "已过期"
    }

    // MARK: - 收盘复盘（审计 A1）

    static func closeReviewStateLabel(
        _ state: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary.State
    ) -> String {
        switch state {
        case .todayDone: return "今日已复盘"
        case .awaitingTonight: return "今晚 21:00 生成"
        case .overdue: return "今日复盘待补做"
        case .neverGenerated: return "尚未生成"
        }
    }

    /// 状态徽章色性（View 据此映射 AppPalette，不在 Formatter 引色）。
    enum CloseReviewBadgeTone {
        case positive
        case warning
        case muted
    }

    static func closeReviewStateBadgeTone(
        _ state: InvestmentIntelligenceDashboardSnapshot.CloseReviewSummary.State
    ) -> CloseReviewBadgeTone {
        switch state {
        case .todayDone: return .positive
        case .awaitingTonight, .neverGenerated: return .muted
        case .overdue: return .warning
        }
    }

    static func narrativeSourceLabel(_ source: CloseReviewNarrativeSource) -> String {
        switch source {
        case .llm: return "AI 叙述"
        case .localFactors: return "本地因子"
        }
    }

    static func pulseDirectionLabel(_ direction: MarketPulseDirection) -> String {
        switch direction {
        case .up: return "偏强"
        case .down: return "偏弱"
        case .flat: return "震荡"
        }
    }

    static func themeDirectionLabel(_ direction: MarketThemeDirection) -> String {
        switch direction {
        case .strong: return "强势"
        case .weak: return "弱势"
        }
    }
}

// MARK: - IntelligenceUserFacingError（错误映射，产品重构方案 §7.2）

/// 用户可见错误（title/message/recovery + 诊断码）。主页面不得直接显示
/// `error.localizedDescription`；diagnosticCode 可在详情中复制用于排查。
struct IntelligenceUserFacingError: Error, Equatable, Sendable {
    /// 恢复动作（UI 据此渲染主动作按钮）。
    enum Recovery: Equatable, Sendable {
        /// 前往 AI 设置
        case goToSettings
        /// 设置战略目标
        case configureTarget
        /// 完善持仓分类
        case classifyHoldings
        /// 更新持仓 / 市场数据
        case refreshData
        /// 重试上一次操作
        case retry
        /// 打开诊断日志（数据目录）
        case openDiagnostics
    }

    let title: String
    let message: String
    let recovery: Recovery
    let diagnosticCode: String

    // MARK: 工厂（覆盖方案 §7.2 的七类映射）

    static func providerNotConfigured() -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "研究功能尚未配置",
            message: "开始组合研究前，需要先在设置中配置 AI 模型。",
            recovery: .goToSettings,
            diagnosticCode: "INTL-PROVIDER-MISSING")
    }

    static func providerAuthFailed() -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "模型调用未通过鉴权",
            message: "API Key 可能已失效，请检查后重新保存。",
            recovery: .goToSettings,
            diagnosticCode: "INTL-PROVIDER-AUTH")
    }

    static func marketDataInsufficient() -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "市场数据不足",
            message: "本轮筛选缺少多数标的的行情数据，结果可能不完整。可先更新数据再扫描。",
            recovery: .refreshData,
            diagnosticCode: "INTL-MARKET-DATA")
    }

    static func targetMissing() -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "尚未设定战略配置",
            message: "先设定五类资产的目标占比，系统才能评估偏差并给出建议。",
            recovery: .configureTarget,
            diagnosticCode: "INTL-TARGET-MISSING")
    }

    static func holdingsUnclassified(_ subjects: [String]) -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "\(subjects.count) 项持仓待归类",
            message: "归类完成前不会生成执行计划——不会用默认分类兜底。",
            recovery: .classifyHoldings,
            diagnosticCode: "INTL-HOLDINGS-UNCLASSIFIED")
    }

    static func runtimeFailure(_ underlying: Error) -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "投资智能运行失败",
            message: "本地运行时或数据库初始化遇到问题。可重试；若持续失败请查看诊断日志。",
            recovery: .retry,
            diagnosticCode: "INTL-RUNTIME-\(Self.shortCode(underlying))")
    }

    static func networkOrRateLimited() -> IntelligenceUserFacingError {
        IntelligenceUserFacingError(
            title: "网络受限",
            message: "请求未能完成（网络波动或触发了限流）。本地结果已保留，可稍后重试。",
            recovery: .retry,
            diagnosticCode: "INTL-NETWORK")
    }

    static func from(_ inputError: IntelligenceInputError) -> IntelligenceUserFacingError {
        switch inputError {
        case .missingTarget:
            return .targetMissing()
        case .unclassifiedHoldings(let subjects):
            return .holdingsUnclassified(subjects)
        case .staleValuation:
            return IntelligenceUserFacingError(
                title: "持仓数据已过期",
                message: "估值数据过旧会影响结论可信度。请先更新持仓数据再评估。",
                recovery: .refreshData,
                diagnosticCode: "INTL-VALUATION-STALE")
        case .emptyPortfolio:
            return IntelligenceUserFacingError(
                title: "暂无有效持仓",
                message: "添加持仓后即可使用投资智能。",
                recovery: .refreshData,
                diagnosticCode: "INTL-PORTFOLIO-EMPTY")
        }
    }

    /// 从底层 Error 做启发式映射（LLM/网络等）；未识别走 runtimeFailure。
    static func from(_ error: Error) -> IntelligenceUserFacingError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkOrRateLimited()
        }
        if nsError.code == 401 || nsError.code == 403 {
            return .providerAuthFailed()
        }
        return .runtimeFailure(error)
    }

    private static func shortCode(_ error: Error) -> String {
        let nsError = error as NSError
        let raw = "\(nsError.domain)-\(nsError.code)"
        return raw.unicodeScalars.map { scalar in
            scalar.isASCII && scalar.isAlphanumericallySafe ? Character(scalar) : "-"
        }.prefix(32).reduce(into: "") { $0.append($1) }
    }
}

private extension Unicode.Scalar {
    var isAlphanumericallySafe: Bool {
        (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122)
    }
}
