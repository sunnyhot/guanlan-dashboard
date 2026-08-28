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
            } radarContent: {
                marketOpportunitySection
                    .investmentSectionAnchor(.marketRadar)
            } longTermContent: {
                portfolioLongTermSection
                    .investmentSectionAnchor(.longTerm)
            }
        }
    }

    // MARK: - ① 盘中实时指引

    var intradaySection: some View {
        SectionCard(
            title: "盘中实时指引",
            subtitle: model.nextHourGuidanceFreshnessText,
            icon: "clock.arrow.circlepath",
            trailing: {
                Spacer()
                Button {
                    model.startNextHourGuidanceFromUser()
                } label: {
                    Label(
                        model.nextHourGuidanceGenerationState == .generating ? "研判中…" : "更新盘中研判",
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
                // W5.3:昨日关注回指做成盘中区段第一条可见内容——
                // 「昨晚说今天要盯的事」是打开盘中最先该核对的。
                if let report = model.nextHourGuidanceReport, !report.followupReviews.isEmpty {
                    NextHourGuidanceFollowupReviewsView(reviews: report.followupReviews)
                }

                if model.trendSettings.provider.isConfigured {
                    Label(
                        "联网搜索已下线：风控规则只允许输出持有建议",
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
            subtitle: moduleFreshnessText(.marketRadar, cadence: "每日 09:00 自动")
                ?? "市场强弱主线、触发条件与失效信号",
            icon: "scope",
            trailing: {
                Spacer()
                Button {
                    model.startTrendAnalysisFromUser(withExpectation: .marketRadar)
                } label: {
                    Label(
                        marketRadarButtonTitle,
                        systemImage: "globe.asia.australia"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                // 进度统一在页面顶部的 TrendLiveLogPanel 展示（唯一进度区）。

                InvestmentDirectionView(
                    analysis: opportunities,
                    hasTrendReport: model.trendReport != nil,
                    isProviderConfigured: model.trendSettings.provider.isConfigured
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
                    model.startTrendAnalysisFromUser(withExpectation: .longTerm)
                } label: {
                    Label(longTermButtonTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(!model.trendSettings.provider.isConfigured)
            }
        ) {
            // 进度统一在页面顶部的 TrendLiveLogPanel 展示（唯一进度区）；
            // 更新期间旧报告保留在下方。
            if let report = model.trendReport {
                portfolioLongTermReportView(report)
            } else if model.trendSettings.provider.isConfigured {
                trendEmptyState("等待生成", detail: "组合研判只展示持仓方向、周期判断、重点风险和行动候选。")
            } else {
                trendEmptyState("未配置模型", detail: "在「设置」里配置 AI 模型后即可生成趋势研判。")
            }
        }
    }

    private var portfolioLongTermSubtitle: String {
        // W3.4:优先「上次生成时间 + 更新节奏」;从未生成过时退回内容说明。
        if let freshness = moduleFreshnessText(.longTerm, cadence: "每周日 20:00 自动") {
            return freshness
        }
        if let generated = model.trendReport?.generatedAt {
            return "生成于 \(String(generated.prefix(16)))"
        }
        return "持仓方向、组合风险、行动候选"
    }

    /// W3.4:模块「上次 X 生成 · 更新节奏」副标题;今天只显示时分,更早带上日期。
    private func moduleFreshnessText(
        _ scope: TrendResearchRunScope,
        cadence: String
    ) -> String? {
        guard let generated = model.trendSettings.moduleGeneratedAt(scope) else { return nil }
        let day = String(generated.prefix(10))
        let time = String(generated.dropFirst(11).prefix(5))
        let today = Self.todayDateString()
        let when = day == today ? time : "\(day) \(time)"
        let auto = model.trendSettings.dailyAutoAnalysisEnabled ? cadence : "手动更新"
        return "上次 \(when) 生成 · \(auto)"
    }

    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// 全市场机会雷达生成中：marketRadar 或 full scope 在跑。
    private var isGeneratingMarketRadar: Bool {
        guard model.trendGenerationState == .generating else { return false }
        let scope = model.trendResearchScope
        return scope == .marketRadar || scope == .full
    }

    /// W3.7:雷达按钮三态——运行中 / 已排队 / 空闲。
    private var marketRadarButtonTitle: String {
        if isGeneratingMarketRadar { return "扫描中…" }
        if model.queuedUserRequestedScope == .marketRadar { return "已排队" }
        return "更新市场雷达"
    }

    /// W3.7:长期研判按钮三态。
    private var longTermButtonTitle: String {
        if model.trendGenerationState == .generating { return "更新中…" }
        if model.queuedUserRequestedScope == .longTerm { return "已排队" }
        return "更新长期研判"
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

    // 行动候选:默认收起为 3 条,「还有 N 条」展开;原因/触发/失效/置信度 + 加入跟踪
    func todayActionCandidates(_ report: TrendAnalysisReport) -> some View {
        let actions = showsAllActionCandidates
            ? report.actions
            : Array(report.actions.prefix(3))
        let hiddenCount = report.actions.count - actions.count
        return VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("行动候选", icon: "checklist")
            if report.actions.isEmpty {
                trendEmptyState("暂无行动候选", detail: "当前报告没有建议新增观察、调仓复核或计划调整动作。")
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(actions) { action in
                        todayActionCard(action, report: report)
                    }
                    // W5.1:不再静默截断——收起时给出「还有 N 条」的显式入口。
                    if hiddenCount > 0 {
                        Button {
                            withAnimation(AppPalette.motionStandard) {
                                showsAllActionCandidates = true
                            }
                        } label: {
                            Label("还有 \(hiddenCount) 条,查看全部行动候选", systemImage: "chevron.down")
                                .font(AppPalette.appFont(.footnote, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.appSecondary)
                    } else if report.actions.count > 3 {
                        Button {
                            withAnimation(AppPalette.motionStandard) {
                                showsAllActionCandidates = false
                            }
                        } label: {
                            Label("收起,只看前 3 条", systemImage: "chevron.up")
                                .font(AppPalette.appFont(.footnote, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.appSecondary)
                    }
                }
            }
        }
        .onDisappear {
            // 切换报告区段时复位收起态,避免旧展开状态影响新报告的默认体验。
            if showsAllActionCandidates { showsAllActionCandidates = false }
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

            // W5.1:关注后当场可设复查时间,消除「关注后再去别处设时间」的断点。
            if tracked, let caseItem = model.decisionCase(for: action, report: report) {
                reviewDueRow(caseItem, tint: tint)
            }

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
        // W2.4(缩窄版):简洁模式默认隐藏完整证据账本与风险边界,
        // 「怎么读」旁的眼睛开关切换并全局记忆;证据入口仍可经结论卡查看。
        if showsResearchDetailMode, !report.portfolioEvidence.isEmpty || !report.warnings.isEmpty {
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

    /// W5.1:已关注行动的复查时间行——默认建议 7 天,当场可选/可改/可清除。
    @ViewBuilder
    private func reviewDueRow(_ caseItem: DecisionCase, tint: Color) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: "calendar.badge.clock")
                .font(AppPalette.appFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
            if let due = caseItem.reviewDueAt {
                Text("复查时间:\(String(due.prefix(10)))")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
            } else {
                Text("已加入判断与复盘 · 建议 7 天后复查")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: AppPalette.spaceS)
            Menu {
                ForEach([3, 7, 14, 30], id: \.self) { days in
                    Button("\(days) 天后复查\(days == 7 ? "(建议)" : "")") {
                        model.setDecisionCaseReviewDue(caseID: caseItem.id, daysFromNow: days)
                    }
                }
                if caseItem.reviewDueAt != nil {
                    Divider()
                    Button("暂不提醒") {
                        model.setDecisionCaseReviewDue(caseID: caseItem.id, daysFromNow: nil)
                    }
                }
            } label: {
                Label(caseItem.reviewDueAt == nil ? "设复查时间" : "调整", systemImage: "calendar")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
            }
            .controlSize(.small)
            .menuIndicator(.visible)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
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
