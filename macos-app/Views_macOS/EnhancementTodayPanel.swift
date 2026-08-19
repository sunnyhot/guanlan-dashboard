import SwiftUI

extension EnhancementCenterView {
    /// AI 投资指引单页：围绕用户决策链路按紧迫度排列。
    /// 盘中实时 → 全市场机会 → 我的组合长期研判 → 判断与复盘。
    /// (旧趋势跟踪清单已 sunset:行动候选直接入决策案例,历史项由启动迁移承接。)
    var investmentDashboardContent: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            InvestmentIntelligenceDashboardView {
                intradaySection
                    .investmentSectionAnchor(.intraday)
                marketOpportunitySection
                    .investmentSectionAnchor(.marketRadar)
            } trendContent: {
                portfolioLongTermSection
                    .investmentSectionAnchor(.longTerm)
            }
        }
    }

    // MARK: - ① 盘中实时指引

    var intradaySection: some View {
        SectionCard(
            title: "盘中实时指引",
            subtitle: model.nextHourGuidanceScheduleText,
            icon: "clock.arrow.circlepath",
            trailing: {
                Spacer()
                Button {
                    model.startNextHourGuidance()
                } label: {
                    Label(
                        model.nextHourGuidanceGenerationState == .generating ? "研判中…" : "立即研判",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || model.nextHourGuidanceGenerationState == .generating
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                if model.trendSettings.provider.isConfigured,
                   !model.trendSettings.webSearch.isConfigured {
                    Label(
                        "未配置联网搜索：风控规则只允许输出持有建议",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.warning)
                }

                if model.nextHourGuidanceGenerationState == .generating {
                    NextHourGuidanceProgressView(stage: model.nextHourGuidanceProgressStage)
                }

                if let report = model.nextHourGuidanceReport {
                    NextHourGuidanceDecisionConsole(report: report)
                } else if model.nextHourGuidanceGenerationState != .generating {
                    Text(model.trendSettings.provider.isConfigured
                         ? "将在下一个交易时段自动生成，也可以手动触发。"
                         : "配置 AI 模型后自动启用。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.vertical, AppPalette.spaceS)

                    if model.trendSettings.provider.isConfigured {
                        IntradayEmptyHintView()
                    }
                }

                if !model.nextHourGuidanceError.isEmpty {
                    let explanation = TrendErrorTriage.explain(model.nextHourGuidanceError)
                    HStack(spacing: AppPalette.spaceS) {
                        Label(explanation.reasonText, systemImage: "exclamationmark.triangle.fill")
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                            .foregroundStyle(AppPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if explanation.shouldOpenSettings {
                            Button("去设置") {
                                model.selectedSection = .settings
                            }
                            .font(AppPalette.appFont(.caption, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(AppPalette.brand)
                        } else if let actionText = explanation.actionText {
                            Text(actionText)
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - ② 全市场机会雷达

    var marketOpportunitySection: some View {
        let opportunities = model.marketOpportunities

        return SectionCard(
            title: "全市场机会雷达",
            subtitle: "市场强弱主线、触发条件与失效信号",
            icon: "scope",
            trailing: {
                Spacer()
                Button {
                    model.startTrendAnalysis(userInitiated: true, scope: .marketRadar)
                } label: {
                    Label(
                        isGeneratingMarketRadar ? "扫描中…" : "扫描市场",
                        systemImage: "globe.asia.australia"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || !model.trendSettings.webSearch.isConfigured
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                if isGeneratingMarketRadar {
                    TrendResearchProgressCard(
                        message: model.trendProgressLogs.last?.message,
                        progress: model.trendResearchProgress
                    )
                }

                InvestmentDirectionView(
                    analysis: opportunities,
                    hasTrendReport: model.trendReport != nil,
                    isProviderConfigured: model.trendSettings.provider.isConfigured,
                    isWebSearchConfigured: model.trendSettings.webSearch.isConfigured
                )
            }
        }
    }

    // MARK: - ③ 我的组合长期研判

    var portfolioLongTermSection: some View {
        SectionCard(
            title: "我的组合长期研判",
            subtitle: portfolioLongTermSubtitle,
            icon: "briefcase.fill",
            trailing: {
                Spacer()
                Button {
                    model.startTrendAnalysis(userInitiated: true, scope: .longTerm)
                } label: {
                    Label(model.trendGenerationState == .generating ? "更新中…" : "更新研判", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            if let report = model.trendReport {
                portfolioLongTermReportView(report)
            } else if model.trendGenerationState == .generating {
                HStack(spacing: AppPalette.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("正在分析…")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.vertical, AppPalette.spaceS)
            } else if model.trendSettings.provider.isConfigured {
                trendEmptyState("等待生成", detail: "组合研判只展示持仓方向、周期判断、重点风险和行动候选。")
            } else {
                trendEmptyState("未配置模型", detail: "在「设置」里配置 AI 模型后即可生成趋势研判。")
            }
        }
    }

    private var portfolioLongTermSubtitle: String {
        if let generated = model.trendSettings.moduleGeneratedAt(.longTerm)
            ?? model.trendReport?.generatedAt {
            return "生成于 \(String(generated.prefix(16)))"
        }
        return "持仓方向、组合风险、行动候选"
    }

    /// 全市场机会雷达生成中：marketRadar 或 full scope 在跑。
    private var isGeneratingMarketRadar: Bool {
        guard model.trendGenerationState == .generating else { return false }
        let scope = model.trendResearchScope
        return scope == .marketRadar || scope == .full
    }

    func portfolioLongTermReportView(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            trendPortfolioHeader(report)
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                trendReportSectionTitle("组合方向", icon: "clock")
                trendHorizonGrid(report.horizons)
            }
            portfolioAssetTrendSection(report)
            todayActionCandidates(report)
            portfolioVerificationSection(report)
        }
    }

    func portfolioAssetTrendSection(_ report: TrendAnalysisReport) -> some View {
        let assets = report.assetTrends.isEmpty ? report.keyAssets : report.assetTrends
        return VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("持仓趋势与重点风险", icon: "chart.bar.doc.horizontal")
            Text("只展示当前组合内的基金与资产，不重复全市场机会卡片。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            trendAssetList(assets)
        }
    }

    // 行动候选（最多 3 条）：原因/触发/失效/置信度 + 加入跟踪
    func todayActionCandidates(_ report: TrendAnalysisReport) -> some View {
        let actions = Array(report.actions.prefix(3))
        return VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("行动候选", icon: "checklist")
            if actions.isEmpty {
                trendEmptyState("暂无行动候选", detail: "当前报告没有建议新增观察、调仓复核或计划调整动作。")
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(actions) { action in
                        todayActionCard(action, report: report)
                    }
                }
            }
        }
    }

    func todayActionCard(_ action: TrendActionCandidate, report: TrendAnalysisReport) -> some View {
        let tracked = model.hasDecisionCase(for: action, report: report)
        let tint = todayActionTint(action.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(action.title)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                TintedCapsuleBadge(
                    text: action.kind.displayText,
                    tint: tint,
                    font: AppPalette.appFont(.caption, weight: .bold),
                    horizontalPadding: 6,
                    verticalPadding: 2
                )
                trendConfidenceMeter(action.confidence)
                Spacer(minLength: 6)
                Button {
                    model.addDecisionCase(from: action, report: report)
                } label: {
                    Label(tracked ? "已关注" : "加入关注", systemImage: tracked ? "checkmark.circle.fill" : "bell.badge")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .tint(tint)
                .disabled(tracked)
            }

            Text(action.detail)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceS) {
                    todayConditionLine("触发", action.triggerConditions, tint: AppPalette.info)
                    todayConditionLine("失效", action.invalidatingConditions, tint: AppPalette.warning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    todayConditionLine("触发", action.triggerConditions, tint: AppPalette.info)
                    todayConditionLine("失效", action.invalidatingConditions, tint: AppPalette.warning)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.40
        )
    }

    @ViewBuilder
    func todayConditionLine(_ title: String, _ items: [String], tint: Color) -> some View {
        let trimmed = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                Text(trimmed.joined(separator: "；"))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
            .overlay(RoundedRectangle(cornerRadius: AppPalette.badgeRadius).stroke(tint.opacity(0.35), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func portfolioVerificationSection(_ report: TrendAnalysisReport) -> some View {
        if !report.portfolioEvidence.isEmpty || !report.warnings.isEmpty {
            DisclosureGroup("证据与风险边界") {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    trendEvidenceList(report.portfolioEvidence)
                    trendWarnings(report)
                }
                .padding(.top, 6)
            }
            .font(AppPalette.appFont(.body, weight: .semibold))
            .tint(AppPalette.info)
        }
    }

    func todayActionTint(_ kind: TrendActionKind) -> Color {
        switch kind {
        case .watch, .waitForConfirmation:
            return AppPalette.info
        case .observeInBatches, .rebalanceReview:
            return AppPalette.brand
        case .pausePlan, .considerReduce:
            return AppPalette.warning
        case .considerIncrease:
            return AppPalette.positive
        }
    }
}

/// 非交易时段空态引流:指向当前真正有内容的区段,避免空档期整页无看点。
/// 独立 struct 因为扩展里不能声明属性包装器(@Environment)。
private struct IntradayEmptyHintView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.investmentSectionAnchors) private var anchors

    private var targetKinds: [InvestmentTodayResearchRow.Kind] {
        let summary = model.investmentTodayResearchSummary
        var kinds: [InvestmentTodayResearchRow.Kind] = []
        if summary.rows.contains(where: { $0.kind == .closeReview }) {
            kinds.append(.closeReview)
        }
        if summary.rows.contains(where: { $0.kind == .longTerm }) {
            kinds.append(.longTerm)
        }
        return kinds
    }

    private func label(for kind: InvestmentTodayResearchRow.Kind) -> String {
        switch kind {
        case .closeReview: return model.marketCloseReviewTitle
        case .longTerm: return "组合中期研判"
        case .intraday, .marketRadar: return ""
        }
    }

    var body: some View {
        if !targetKinds.isEmpty {
            HStack(spacing: AppPalette.spaceS) {
                Text("现在适合看")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                ForEach(targetKinds, id: \.self) { kind in
                    Button(label(for: kind)) {
                        anchors?.scrollTo = kind
                    }
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.brand)
                }
            }
        }
    }
}
