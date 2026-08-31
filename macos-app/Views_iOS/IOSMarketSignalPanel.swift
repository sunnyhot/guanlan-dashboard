import SwiftUI

// MARK: - iOS 市场信号与研究面板（2026-08-31，对齐 macOS MarketSignalSection）
//
// L6 信号闭环（自动入库/盘后结算/胜率校准）的移动端只读视图 +
// L7 四档研究流水线 / L8 策略回测的手动入口。Core 逻辑双端共用（AppModel），
// 本文件只做展示；方向与结算颜色红涨绿跌（AppPalette.marketGain/marketLoss）。

struct IOSMarketSignalPanel: View {
    @EnvironmentObject private var model: AppModel

    @State private var researchSubjectCode = ""
    @State private var researchSubjectName = ""
    @State private var researchMode: MarketResearchPipelineMode = .standard
    @State private var backtestSkillID = StrategySkillLibrary.all.first?.id ?? ""
    @State private var backtestSubjectCode = ""

    var body: some View {
        IOSSectionCard(
            title: "市场信号与研究",
            subtitle: model.marketSignalAccuracyText ?? "AI 判断的自动对账：信号落库、盘后结算、胜率校准",
            icon: "dot.radiowaves.left.and.right"
        ) {
            VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                if !model.lastMarketSignalSettleSummary.isEmpty {
                    Text(model.lastMarketSignalSettleSummary)
                        .font(IOSDesign.sansBody(12))
                        .foregroundStyle(IOSDesign.muted)
                }
                activeSignals
                settledSignals
                researchRunner
                if let result = model.latestMarketResearchResult {
                    researchResult(result)
                }
                backtestRunner
                if let report = model.latestBacktestReport {
                    backtestResult(report)
                }
            }
        }
    }

    // MARK: - L6 信号

    @ViewBuilder
    private var activeSignals: some View {
        let active = model.activeMarketSignals
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text("活跃信号 \(active.count)")
                .font(IOSDesign.sansBody(14, weight: .semibold))
                .foregroundStyle(IOSDesign.ink)
            if active.isEmpty {
                Text("暂无活跃信号。趋势研判报告落盘后，行动候选会自动转成可结算信号。")
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
            } else {
                ForEach(active.prefix(5)) { signal in
                    signalRow(signal)
                }
            }
        }
    }

    @ViewBuilder
    private var settledSignals: some View {
        let settled = model.settledMarketSignals
        if !settled.isEmpty {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                Text("最近结算")
                    .font(IOSDesign.sansBody(14, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                ForEach(settled.prefix(3)) { signal in
                    signalRow(signal)
                }
            }
        }
    }

    private func signalRow(_ signal: MarketDecisionSignal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(signal.direction.displayName)
                    .font(IOSDesign.sansBody(11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(directionColor(signal.direction), in: Capsule())
                Text(signal.subjectCode ?? "组合级")
                    .font(IOSDesign.monoNumber(13))
                    .foregroundStyle(IOSDesign.ink)
                Text(signal.subjectName)
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if signal.status == .active {
                    Text("复查 \(String(signal.reviewDueAt.prefix(10)))")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                } else if let settlement = signal.settlement {
                    Text(outcomeText(settlement.outcome))
                        .font(IOSDesign.sansBody(11, weight: .semibold))
                        .foregroundStyle(outcomeColor(settlement.outcome))
                }
            }
            Text(signal.reason)
                .font(IOSDesign.sansBody(12))
                .foregroundStyle(IOSDesign.muted)
                .lineLimit(2)
        }
        .padding(IOSDesign.spaceS)
        .background(IOSDesign.card.opacity(0.6), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: - L7 研究流水线

    private var researchRunner: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text("多 Agent 市场研究")
                .font(IOSDesign.sansBody(14, weight: .semibold))
                .foregroundStyle(IOSDesign.ink)
            Text("四档深度（1-4 次 LLM 调用），护栏链保证结论自洽；结论信号自动进入闭环。")
                .font(IOSDesign.sansBody(12))
                .foregroundStyle(IOSDesign.muted)
            HStack(spacing: IOSDesign.spaceS) {
                TextField("代码 600519", text: $researchSubjectCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("名称(选填)", text: $researchSubjectName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: IOSDesign.spaceS) {
                Picker("深度", selection: $researchMode) {
                    Text("快速").tag(MarketResearchPipelineMode.quick)
                    Text("标准").tag(MarketResearchPipelineMode.standard)
                    Text("完整").tag(MarketResearchPipelineMode.full)
                    Text("专家").tag(MarketResearchPipelineMode.specialist)
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await model.runMarketResearch(
                        subjectCode: researchSubjectCode,
                        subjectName: researchSubjectName,
                        mode: researchMode
                    ) }
                } label: {
                    if model.marketResearchState == .generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("研究")
                    }
                }
                .buttonStyle(.borderedProminent)
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
                    .font(IOSDesign.sansBody(12, weight: .medium))
                    .foregroundStyle(AppPalette.danger)
            }
        }
    }

    private func researchResult(_ result: MarketResearchPipelineResult) -> some View {
        let dashboard = result.dashboard
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(spacing: 6) {
                Text("\(dashboard.score)分 · \(CanonicalScoreBand.band(forScore: dashboard.score).displayName)")
                    .font(IOSDesign.sansBody(13, weight: .bold))
                    .foregroundStyle(scoreColor(dashboard.score))
                Text(dashboard.action.displayName)
                    .font(IOSDesign.sansBody(12, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(actionColor(dashboard.action).opacity(0.15), in: Capsule())
                    .foregroundStyle(actionColor(dashboard.action))
                if dashboard.isDegradedFallback {
                    Text("降级产出")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(AppPalette.warning)
                }
                Spacer()
            }
            Text(dashboard.coreConclusion)
                .font(IOSDesign.sansBody(13))
                .foregroundStyle(IOSDesign.ink)
            if let phase = dashboard.phaseDecision {
                infoLine("当下动作", "\(phase.immediateAction)（\(phase.actionWindow)）")
            }
            let sniper = dashboard.sniperPoints
            let sniperTexts = sniperPointTexts(sniper)
            if !sniperTexts.isEmpty {
                infoLine("关键点位", sniperTexts.joined(separator: "；"))
            }
            if !dashboard.riskAlerts.isEmpty {
                infoLine("风险", dashboard.riskAlerts.joined(separator: "；"))
            }
            if result.disagreement.isSplit {
                infoLine("Agent 分歧", "看多:\(result.disagreement.bullishAgents.joined(separator: "、")) 看空:\(result.disagreement.bearishAgents.joined(separator: "、"))")
            }
        }
        .padding(IOSDesign.spaceS)
        .background(IOSDesign.card.opacity(0.6), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: - L8 回测

    private var backtestRunner: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text("策略技能回测")
                .font(IOSDesign.sansBody(14, weight: .semibold))
                .foregroundStyle(IOSDesign.ink)
            Menu {
                ForEach(StrategySkillLibrary.all) { skill in
                    Button(skill.displayName) { backtestSkillID = skill.id }
                }
            } label: {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(StrategySkillLibrary.skill(id: backtestSkillID)?.displayName ?? "选择技能")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(IOSDesign.sansBody(13))
            }
            HStack(spacing: IOSDesign.spaceS) {
                TextField("代码 600519", text: $backtestSubjectCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button {
                    Task { await model.runStrategyBacktest(
                        skillID: backtestSkillID,
                        subjectCode: backtestSubjectCode
                    ) }
                } label: {
                    if model.isRunningBacktest {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("回测")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    backtestSubjectCode.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.isRunningBacktest
                )
            }
        }
    }

    private func backtestResult(_ report: BacktestReport) -> some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text("回测 · \(StrategySkillLibrary.skill(id: report.skillID)?.displayName ?? report.skillID)")
                    .font(IOSDesign.sansBody(13, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                Spacer()
                Text(report.isSampleSufficient ? "样本充分" : "样本不足")
                    .font(IOSDesign.sansBody(11, weight: .semibold))
                    .foregroundStyle(report.isSampleSufficient ? AppPalette.positive : AppPalette.warning)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: IOSDesign.spaceS) {
                    IOSStatTile(title: "样本", value: "\(report.sampleCount)")
                    IOSStatTile(title: "交易", value: "\(report.trades.count)")
                    if let winRate = report.winRate {
                        IOSStatTile(title: "胜率", value: String(format: "%.0f%%", winRate * 100))
                    }
                    if let profitFactor = report.profitFactor {
                        IOSStatTile(title: "盈亏比", value: String(format: "%.2f", profitFactor))
                    }
                    if let avg = report.avgReturnPct {
                        IOSStatTile(title: "均笔", value: String(format: "%+.2f%%", avg))
                    }
                    if let drawdown = report.maxDrawdownPct {
                        IOSStatTile(title: "最大回撤", value: String(format: "%.1f%%", drawdown))
                    }
                }
            }
            if !report.dataBoundary.isEmpty {
                Text(report.dataBoundary)
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
            }
        }
        .padding(IOSDesign.spaceS)
        .background(IOSDesign.card.opacity(0.6), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: - 辅助

    private func sniperPointTexts(_ sniper: MarketDecisionDashboard.SniperPoints) -> [String] {
        var texts: [String] = []
        if let ideal = sniper.idealBuy {
            texts.append(String(format: "理想买点 %.2f", ideal))
        }
        if let stop = sniper.stopLoss {
            texts.append(String(format: "止损 %.2f", stop))
        }
        if let target = sniper.takeProfit {
            texts.append(String(format: "目标 %.2f", target))
        }
        return texts
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(IOSDesign.sansBody(11, weight: .semibold))
                .foregroundStyle(IOSDesign.muted)
            Text(value)
                .font(IOSDesign.sansBody(12))
                .foregroundStyle(IOSDesign.ink)
        }
    }

    private func directionColor(_ direction: CanonicalDecisionType) -> Color {
        switch direction {
        case .buy: return AppPalette.marketGain
        case .sell: return AppPalette.marketLoss
        case .hold: return IOSDesign.muted
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch CanonicalScoreBand.band(forScore: score).decisionType {
        case .buy: return AppPalette.marketGain
        case .sell: return AppPalette.marketLoss
        case .hold: return IOSDesign.accent
        }
    }

    private func actionColor(_ action: CanonicalAction) -> Color {
        switch action {
        case .buy, .add: return AppPalette.marketGain
        case .sell, .reduce, .avoid: return AppPalette.marketLoss
        case .hold, .watch, .alert: return IOSDesign.accent
        }
    }

    private func outcomeText(_ outcome: SignalSettlement.Outcome) -> String {
        switch outcome {
        case .hitTarget: return "兑现"
        case .hitStop: return "止损"
        case .expiredUnresolved: return "到期未触发"
        case .superseded: return "反向取代"
        case .insufficientData: return "数据不足"
        }
    }

    private func outcomeColor(_ outcome: SignalSettlement.Outcome) -> Color {
        switch outcome {
        case .hitTarget: return AppPalette.marketGain
        case .hitStop: return AppPalette.marketLoss
        case .expiredUnresolved, .superseded, .insufficientData: return IOSDesign.muted
        }
    }
}
