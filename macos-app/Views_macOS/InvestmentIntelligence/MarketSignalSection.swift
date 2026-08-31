import SwiftUI

// MARK: - L6/L7/L8 面板：市场信号 + 多 Agent 研究 + 策略回测（2026-08-31 App 集成）
//
// 对应 docs/ai-pipeline-baseline.md 10.6：
// - L6 信号闭环：趋势报告落盘自动入库、每日盘后自动结算、胜率记忆展示
// - L7 研究流水线：四档多 Agent 研究单一标的，护栏链结果 + 分歧展示
// - L8 回测：策略技能规则级历史求值，回答「这个技能历史上靠不靠谱」
//
// 颜色遵守中国股市惯例（红涨绿跌，AppPalette.marketGain/marketLoss）。

struct MarketSignalSection: View {
    @EnvironmentObject private var model: AppModel

    // L7 输入
    @State private var researchSubjectCode = ""
    @State private var researchSubjectName = ""
    @State private var researchMode: MarketResearchPipelineMode = .standard
    // L8 输入
    @State private var backtestSkillID = StrategySkillLibrary.all.first?.id ?? ""
    @State private var backtestSubjectCode = ""

    var body: some View {
        SectionCard(
            title: "市场信号与研究",
            subtitle: model.marketSignalAccuracyText
                ?? "AI 判断的自动对账：信号落库、每日盘后结算、胜率校准",
            icon: "dot.radiowaves.left.and.right"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                if !model.lastMarketSignalSettleSummary.isEmpty {
                    Text(model.lastMarketSignalSettleSummary)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                activeSignalList
                settledSignalList
                researchRunner
                if let result = model.latestMarketResearchResult {
                    researchResultView(result)
                }
                backtestRunner
                if let report = model.latestBacktestReport {
                    backtestResultView(report)
                }
            }
        }
    }

    // MARK: - L6 活跃信号

    @ViewBuilder
    private var activeSignalList: some View {
        let active = model.activeMarketSignals
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            sectionLabel("活跃信号", count: active.count)
            if active.isEmpty {
                emptyHint("暂无活跃信号。趋势研判报告落盘后，其中的行动候选会自动转成可结算信号。")
            } else {
                ForEach(active.prefix(6)) { signal in
                    signalRow(signal)
                }
                if active.count > 6 {
                    Text("还有 \(active.count - 6) 条活跃信号，盘后结算时统一对账。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }
        }
    }

    // MARK: - L6 已结算

    @ViewBuilder
    private var settledSignalList: some View {
        let settled = model.settledMarketSignals
        if !settled.isEmpty {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                sectionLabel("最近结算", count: settled.count)
                ForEach(settled.prefix(5)) { signal in
                    signalRow(signal)
                }
            }
        }
    }

    private func signalRow(_ signal: MarketDecisionSignal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TintedCapsuleBadge(
                    text: signal.direction.displayName,
                    tint: directionTint(signal.direction),
                    font: AppPalette.appFont(.caption, weight: .bold),
                    horizontalPadding: 6,
                    verticalPadding: 2
                )
                Text(signal.subjectCode ?? "组合级")
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text(signal.subjectName)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if signal.status == .active {
                    Text("复查 \(String(signal.reviewDueAt.prefix(10)))")
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                } else if let settlement = signal.settlement {
                    TintedCapsuleBadge(
                        text: settlementOutcomeText(settlement.outcome),
                        tint: settlementOutcomeTint(settlement.outcome),
                        font: AppPalette.appFont(.caption2, weight: .semibold),
                        horizontalPadding: 5,
                        verticalPadding: 1
                    )
                }
            }
            Text(signal.reason)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(2)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: directionTint(signal.direction),
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.14,
            activeStrokeOpacity: 0.30
        )
    }

    // MARK: - L7 研究流水线入口

    private var researchRunner: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            sectionLabel("多 Agent 市场研究", count: nil)
            Text("四档深度（quick 1 次 / standard 2 次 / full 3 次 / specialist 4 次 LLM 调用），护栏链保证输出与分数带自洽；结论信号自动进入上面的闭环。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            HStack(spacing: AppPalette.spaceS) {
                TextField("代码，如 600519 / 00700", text: $researchSubjectCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField("名称（可选）", text: $researchSubjectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Picker("深度", selection: $researchMode) {
                    ForEach(MarketResearchPipelineMode.allCases, id: \.self) { mode in
                        Text(researchModeLabel(mode)).tag(mode)
                    }
                }
                .frame(width: 130)
                Button {
                    Task { await model.runMarketResearch(
                        subjectCode: researchSubjectCode,
                        subjectName: researchSubjectName,
                        mode: researchMode
                    ) }
                } label: {
                    Label(
                        model.marketResearchState == .generating ? "研究中…" : "开始研究",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    researchSubjectCode.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.marketResearchState == .generating
                        || !model.trendSettings.provider.isConfigured
                        || model.trendGenerationState == .generating
                        || model.nextHourGuidanceGenerationState == .generating
                        || model.decisionCaseResearchState == .generating
                )
            }
            if !model.lastMarketResearchError.isEmpty {
                Text(model.lastMarketResearchError)
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.danger)
            }
        }
    }

    @ViewBuilder
    private func researchResultView(_ result: MarketResearchPipelineResult) -> some View {
        let dashboard = result.dashboard
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            sectionLabel("研究结论 · \(dashboard.subjectCode) \(dashboard.subjectName)", count: nil)
            HStack(spacing: AppPalette.spaceS) {
                TintedCapsuleBadge(
                    text: "\(dashboard.score) 分 · \(CanonicalScoreBand.band(forScore: dashboard.score).displayName)",
                    tint: scoreTint(dashboard.score),
                    font: AppPalette.appFont(.footnote, weight: .bold),
                    horizontalPadding: 8,
                    verticalPadding: 3
                )
                TintedCapsuleBadge(
                    text: dashboard.action.displayName,
                    tint: actionTint(dashboard.action),
                    font: AppPalette.appFont(.footnote, weight: .bold),
                    horizontalPadding: 8,
                    verticalPadding: 3
                )
                TintedCapsuleBadge(
                    text: dashboard.confidence.displayName,
                    tint: AppPalette.info,
                    font: AppPalette.appFont(.caption, weight: .semibold),
                    horizontalPadding: 6,
                    verticalPadding: 2
                )
                if dashboard.isDegradedFallback {
                    TintedCapsuleBadge(
                        text: "降级产出",
                        tint: AppPalette.warning,
                        font: AppPalette.appFont(.caption2, weight: .semibold),
                        horizontalPadding: 5,
                        verticalPadding: 1
                    )
                }
                Spacer()
            }
            Text(dashboard.coreConclusion)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(3)

            if let phase = dashboard.phaseDecision {
                conditionLine("当下动作", [phase.immediateAction + "（" + phase.actionWindow + "）"], tint: AppPalette.brand)
            }
            if !dashboard.noPositionAdvice.isEmpty {
                conditionLine("未持仓", [dashboard.noPositionAdvice], tint: AppPalette.muted)
            }
            if !dashboard.hasPositionAdvice.isEmpty {
                conditionLine("已持仓", [dashboard.hasPositionAdvice], tint: AppPalette.muted)
            }
            let sniperTexts = sniperPointTexts(dashboard.sniperPoints)
            if !sniperTexts.isEmpty {
                conditionLine("关键点位", sniperTexts, tint: AppPalette.accentWarm)
            }
            if !dashboard.riskAlerts.isEmpty {
                conditionLine("风险", dashboard.riskAlerts, tint: AppPalette.danger)
            }
            if result.disagreement.isSplit {
                conditionLine(
                    "Agent 分歧",
                    ["看多：\(result.disagreement.bullishAgents.joined(separator: "、"))｜看空：\(result.disagreement.bearishAgents.joined(separator: "、"))"],
                    tint: AppPalette.warning
                )
            }
            if !result.degradedStages.isEmpty {
                conditionLine("降级阶段", result.degradedStages, tint: AppPalette.warning)
            }
            if !dashboard.guardrailNotes.isEmpty {
                conditionLine("护栏修正", dashboard.guardrailNotes, tint: AppPalette.info)
            }
            if let attribution = dashboard.signalAttribution {
                Text("归因：技术面 \(attribution.technicalIndicators)% · 消息面 \(attribution.newsSentiment)% · 基本面 \(attribution.fundamentals)% · 市场环境 \(attribution.marketConditions)%")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: scoreTint(dashboard.score),
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.16,
            activeStrokeOpacity: 0.34
        )
    }

    // MARK: - L8 策略回测入口

    private var backtestRunner: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            sectionLabel("策略技能回测", count: nil)
            Text("纯本地规则回测（约一年日 K）：技能量化条件历史求值，次日开盘入场、同根先止损；样本不足时结论仅供参考。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            HStack(spacing: AppPalette.spaceS) {
                Picker("技能", selection: $backtestSkillID) {
                    ForEach(StrategySkillLibrary.all) { skill in
                        Text(skill.displayName).tag(skill.id)
                    }
                }
                .frame(maxWidth: 260)
                TextField("代码，如 600519", text: $backtestSubjectCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button {
                    Task { await model.runStrategyBacktest(
                        skillID: backtestSkillID,
                        subjectCode: backtestSubjectCode
                    ) }
                } label: {
                    Label(
                        model.isRunningBacktest ? "回测中…" : "运行回测",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    backtestSubjectCode.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.isRunningBacktest
                )
            }
        }
    }

    @ViewBuilder
    private func backtestResultView(_ report: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                sectionLabel(
                    "回测 · \(StrategySkillLibrary.skill(id: report.skillID)?.displayName ?? report.skillID) · \(report.subjectCode.isEmpty ? backtestSubjectCode : report.subjectCode)",
                    count: nil
                )
                Spacer()
                TintedCapsuleBadge(
                    text: report.isSampleSufficient ? "样本充分" : "样本不足",
                    tint: report.isSampleSufficient ? AppPalette.positive : AppPalette.warning,
                    font: AppPalette.appFont(.caption2, weight: .semibold),
                    horizontalPadding: 5,
                    verticalPadding: 1
                )
            }
            HStack(spacing: AppPalette.spaceXL) {
                backtestMetric("样本", "\(report.sampleCount) 根 K 线")
                backtestMetric("交易", "\(report.trades.count) 笔")
                if let winRate = report.winRate {
                    backtestMetric("胜率", String(format: "%.0f%%", winRate * 100))
                }
                if let profitFactor = report.profitFactor {
                    backtestMetric("盈亏比", String(format: "%.2f", profitFactor))
                }
                if let avg = report.avgReturnPct {
                    backtestMetric("均笔", String(format: "%+.2f%%", avg))
                }
                if let drawdown = report.maxDrawdownPct {
                    backtestMetric("最大回撤", String(format: "%.1f%%", drawdown))
                }
            }
            if !report.dataBoundary.isEmpty {
                Text(report.dataBoundary)
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: AppPalette.info,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.14,
            activeStrokeOpacity: 0.30
        )
    }

    // MARK: - 小组件

    private func sniperPointTexts(_ sniper: MarketDecisionDashboard.SniperPoints) -> [String] {
        var texts: [String] = []
        if let ideal = sniper.idealBuy {
            texts.append(String(format: "理想买点 %.2f", ideal))
        }
        if let secondary = sniper.secondaryBuy {
            texts.append(String(format: "次级买点 %.2f", secondary))
        }
        if let stop = sniper.stopLoss {
            texts.append(String(format: "止损 %.2f", stop))
        }
        if let target = sniper.takeProfit {
            texts.append(String(format: "目标 %.2f", target))
        }
        return texts
    }

    private func sectionLabel(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            if let count {
                Text("\(count)")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)
            .padding(.vertical, AppPalette.spaceS)
    }

    @ViewBuilder
    private func conditionLine(_ title: String, _ items: [String], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                Text(items.joined(separator: "；"))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
            .overlay(RoundedRectangle(cornerRadius: AppPalette.badgeRadius).stroke(tint.opacity(0.35), lineWidth: 1))
        }
    }

    private func backtestMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.footnote, weight: .bold))
                .foregroundStyle(AppPalette.ink)
        }
    }

    // MARK: - 颜色（红涨绿跌）

    private func directionTint(_ direction: CanonicalDecisionType) -> Color {
        switch direction {
        case .buy: return AppPalette.marketGain
        case .sell: return AppPalette.marketLoss
        case .hold: return AppPalette.muted
        }
    }

    private func scoreTint(_ score: Int) -> Color {
        switch CanonicalScoreBand.band(forScore: score).decisionType {
        case .buy: return AppPalette.marketGain
        case .sell: return AppPalette.marketLoss
        case .hold: return AppPalette.info
        }
    }

    private func actionTint(_ action: CanonicalAction) -> Color {
        switch action {
        case .buy, .add: return AppPalette.marketGain
        case .sell, .reduce, .avoid: return AppPalette.marketLoss
        case .hold, .watch, .alert: return AppPalette.info
        }
    }

    private func settlementOutcomeText(_ outcome: SignalSettlement.Outcome) -> String {
        switch outcome {
        case .hitTarget: return "兑现"
        case .hitStop: return "止损"
        case .expiredUnresolved: return "到期未触发"
        case .superseded: return "反向取代"
        case .insufficientData: return "数据不足"
        }
    }

    private func settlementOutcomeTint(_ outcome: SignalSettlement.Outcome) -> Color {
        switch outcome {
        case .hitTarget: return AppPalette.marketGain
        case .hitStop: return AppPalette.marketLoss
        case .expiredUnresolved, .superseded, .insufficientData: return AppPalette.muted
        }
    }

    private func researchModeLabel(_ mode: MarketResearchPipelineMode) -> String {
        switch mode {
        case .quick: return "快速"
        case .standard: return "标准"
        case .full: return "完整"
        case .specialist: return "专家"
        }
    }
}
