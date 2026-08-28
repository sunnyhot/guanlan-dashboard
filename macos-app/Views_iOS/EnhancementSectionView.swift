#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判页
//
// W7.1:与 macOS 同一信息架构的纵向单页——今日研判摘要(含 hero 一句话)
// → 研判基础 → 今日收盘复盘 → AI 眼中的组合 → 判断与复盘。
// 旧「观点/组合/决策/记录」四段与趋势跟踪兼容路径保留给 flag 关闭时。

struct EnhancementSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: ResearchSegment = .report
    @State private var selectedCase: DecisionCase?
    @State private var reviewCase: DecisionCase?
    @State private var isShowingProfile = false
    @State private var isShowingGlossary = false

    // 旧分段(InvestmentIntelligence 关闭时的兼容路径)
    private enum ResearchSegment: String, CaseIterable, Identifiable {
        case report = "研判"
        case tracking = "跟踪"
        case evidence = "证据"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if InvestmentIntelligence.enabled {
                    HStack(spacing: IOSDesign.spaceS) {
                        Text("AI 研判")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(IOSDesign.ink)
                        Spacer(minLength: IOSDesign.spaceS)
                        Button {
                            isShowingProfile = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(IOSDesign.accent)
                        }
                        .accessibilityLabel("投资偏好")
                        Button {
                            isShowingGlossary = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(IOSDesign.accent)
                        }
                        .accessibilityLabel("怎么读这份研判")
                    }

                    // W7.1:今日研判摘要(hero + 四链路各一行)
                    iosTodaySummarySection
                    // 研判基础:读结论前先看判断基础
                    iosCredibilitySection
                    // 今日收盘复盘
                    intelligenceViewpointContent
                    // AI 眼中的组合
                    intelligencePortfolioContent
                    // 判断与复盘:活跃事项 + 待复盘 + 历史
                    iosJudgementSection
                } else {
                    // 旧分段(兼容)
                    Picker("", selection: $segment) {
                        ForEach(ResearchSegment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 2)

                    switch segment {
                    case .report:  reportContent
                    case .tracking: trackingContent
                    case .evidence: evidenceContent
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            try? await model.refreshLatest(updateNotice: false)
        }
        .onChange(of: model.pendingInvestmentSectionAnchor) { _, target in
            // W7.2:通知深链落到 AI 页即可;iOS 无区段锚点系统,消费后清空。
            guard target != nil else { return }
            model.pendingInvestmentSectionAnchor = nil
        }
        .sheet(item: $selectedCase) { decisionCase in
            IOSDecisionCaseDetailView(caseID: decisionCase.id, onReview: { reviewCase = decisionCase })
                .environmentObject(model)
        }
        .sheet(item: $reviewCase) { decisionCase in
            IOSDecisionReviewView(caseID: decisionCase.id)
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingProfile) {
            NavigationStack {
                ScrollView { IOSUserDecisionProfileEditor().padding(16) }
                    .navigationTitle("投资偏好")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $isShowingGlossary) {
            NavigationStack {
                IOSResearchTermGlossaryView()
            }
        }
    }

    // MARK: 投资智能 - 观点

    @ViewBuilder
    // MARK: W7.1 今日研判摘要(与 macOS 同一信息架构)

    /// W2.3 同款 hero 装配。
    private var iosTodayVerdictText: String? {
        let topSignal = model.marketOpportunities.flatMap {
            InvestmentTodayResearchSummary.topSignal($0)
        }
        return TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(
                intradayPosture: model.nextHourGuidanceReport?.posture,
                topRadarSignalName: topSignal?.name,
                topRadarRecommendation: topSignal?.recommendation,
                mediumDirection: model.trendReport?.horizons.first { $0.horizon == .medium }?.direction
            )
        )
    }

    /// 与 macOS `InvestmentTodayResearchRow.Kind.iconName` 同款映射
    /// (那个扩展在 Views_macOS,iOS target 不可见,故本地维护一份)。
    private static func iosRowIcon(_ kind: InvestmentTodayResearchRow.Kind) -> String {
        switch kind {
        case .closeReview: return "sunset.fill"
        case .intraday: return "clock.arrow.circlepath"
        case .marketRadar: return "scope"
        case .longTerm: return "briefcase.fill"
        }
    }

    private var iosTodaySummarySection: some View {
        let summary = model.investmentTodayResearchSummary
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            if !model.trendSettings.provider.isConfigured {
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    Label("AI 研判尚未配置", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.bold))
                    Text("配置模型后可生成盘中指引、收盘复盘、长期研判与全市场雷达。")
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                    Button("开始配置模型") {
                        model.selectedSection = .settings
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if summary.hasAnyContent {
                Text("今日研判")
                    .font(.headline)
                    .foregroundStyle(IOSDesign.ink)
                if let verdict = iosTodayVerdictText {
                    HStack(spacing: IOSDesign.spaceS) {
                        Image(systemName: "quote.opening")
                            .foregroundStyle(IOSDesign.accent)
                        Text("今天:\(verdict)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(IOSDesign.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(IOSDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(summary.rows) { row in
                    HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                        Image(systemName: Self.iosRowIcon(row.kind))
                            .foregroundStyle(IOSDesign.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.caption)
                                .foregroundStyle(IOSDesign.muted)
                            Text(row.headline)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(IOSDesign.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: IOSDesign.spaceS)
                        Text(row.footnote)
                            .font(.caption2)
                            .foregroundStyle(IOSDesign.muted)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    Text("还没有任何研判")
                        .font(.subheadline.weight(.bold))
                    Text("生成第一份研判后,这里会出现今日摘要。")
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                    Button("生成第一份研判") {
                        model.startTrendAnalysisFromUser(withExpectation: .full)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// W7.1 研判基础:读结论前先看「基于多少穿透数据」。
    private var iosCredibilitySection: some View {
        let pct = model.portfolioLookThroughSnapshot?.disclosedSecurityCoveragePct
        let low = pct.map { $0 < 70 } ?? true
        let text: String
        if let pct {
            text = "基于\(Int(pct))%穿透数据" + (low ? " · 判断基础有限" : "")
        } else {
            text = "穿透数据未就绪 · 判断基础有限"
        }
        return HStack(spacing: IOSDesign.spaceS) {
            Image(systemName: low ? "exclamationmark.triangle.fill" : "shield.checkered")
                .foregroundStyle(low ? Color.orange : IOSDesign.muted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(IOSDesign.muted)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// W7.1 判断与复盘:活跃事项 + 待复盘 + 历史,与 macOS 同名同义。
    private var iosJudgementSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            Text("判断与复盘")
                .font(.title2.weight(.bold))
                .foregroundStyle(IOSDesign.ink)
            Text("当时的判断和后来的结果,方便回头看")
                .font(.subheadline)
                .foregroundStyle(IOSDesign.muted)
            intelligenceCasesContent
            intelligenceRecordsContent
        }
    }

    private var intelligenceViewpointContent: some View {
        let review = model.marketCloseReview
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            Text(model.marketCloseReviewTitle)
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(IOSDesign.accent)

            Text(review.headline)
                .font(.title2.weight(.bold))
                .foregroundStyle(IOSDesign.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(review.summary)
                .font(.subheadline)
                .foregroundStyle(IOSDesign.muted)
                .fixedSize(horizontal: false, vertical: true)

            if review.state == .scanning {
                HStack(spacing: IOSDesign.spaceS) {
                    ProgressView()
                    Text(model.trendProgressLogs.last?.message ?? "正在扫描市场…")
                        .font(.subheadline)
                        .foregroundStyle(IOSDesign.muted)
                }
            }

            Divider()
            Text("今日得失")
                .font(.headline)
                .foregroundStyle(IOSDesign.ink)

            if let portfolio = review.portfolioReview {
                HStack(spacing: IOSDesign.spaceM) {
                    VStack(alignment: .leading, spacing: IOSDesign.spaceXS) {
                        Text(portfolio.changeTitle)
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                        Text(dailyChangeCurrencyText(portfolio.dailyChangeAmount))
                            .font(.headline)
                            .foregroundStyle(AppPalette.marketTint(
                                for: portfolio.dailyChangeAmount ?? portfolio.dailyChangePct
                            ))
                        Text(dailyChangePercentText(portfolio.dailyChangePct))
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: IOSDesign.spaceXS) {
                        Text("涨跌覆盖")
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                        Text("\(portfolio.coveredHoldingCount)/\(portfolio.holdingCount)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(IOSDesign.ink)
                        Text("组合市值 \(currencyText(portfolio.totalMarketValue))")
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                    }
                }

                if !portfolio.holdingImpacts.isEmpty {
                    Text("组合影响")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSDesign.ink)
                    ForEach(portfolio.holdingImpacts.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: IOSDesign.spaceXS) {
                            HStack {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(IOSDesign.ink)
                                Spacer()
                                Text(dailyChangeCurrencyText(item.changeAmount, market: item.market))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(AppPalette.marketTint(
                                        for: item.changeAmount ?? item.changePct
                                    ))
                            }
                            Text("\(item.code) · \(dailyChangePercentText(item.changePct))")
                                .font(.caption)
                                .foregroundStyle(IOSDesign.muted)
                            if let analysis = item.analysis {
                                Text(analysis)
                                    .font(.caption)
                                    .foregroundStyle(IOSDesign.muted)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "暂无持仓复盘",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("刷新个人持仓后显示组合涨跌和主要持仓影响。")
                )
            }

            if !review.tomorrowWatch.isEmpty {
                Divider()
                Text("明日关注").font(.headline).foregroundStyle(IOSDesign.ink)
                ForEach(Array(review.tomorrowWatch.prefix(3).enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: IOSDesign.spaceS) {
                        Text("\(offset + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(IOSDesign.accent)
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(IOSDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DisclosureGroup("展开复盘详情") {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    if let portfolio = review.portfolioReview {
                        Text("组合明细")
                            .font(.headline)
                            .foregroundStyle(IOSDesign.ink)
                        Text("市值 \(currencyText(portfolio.totalMarketValue)) · 更新于 \(String(portfolio.refreshedAt.prefix(16)))")
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)

                        ForEach(portfolio.holdingImpacts) { item in
                            VStack(alignment: .leading, spacing: IOSDesign.spaceXS) {
                                HStack {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(IOSDesign.ink)
                                    Spacer()
                                    Text(dailyChangeCurrencyText(item.changeAmount, market: item.market))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(AppPalette.marketTint(
                                            for: item.changeAmount ?? item.changePct
                                        ))
                                }
                                if let watchText = item.watchText {
                                    Text("次日验证：\(watchText)")
                                        .font(.caption)
                                        .foregroundStyle(IOSDesign.muted)
                                }
                            }
                        }
                    }

                    if !review.marketPulse.isEmpty {
                        Divider()
                        Text("市场温度").font(.headline).foregroundStyle(IOSDesign.ink)
                        ForEach(review.marketPulse) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(item.direction.dashboardText) · \(item.confidenceText)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(iosCloseReviewTint(item.direction))
                                }
                                Text(item.rationale)
                                    .font(.caption)
                                    .foregroundStyle(IOSDesign.muted)
                                    .lineLimit(3)
                            }
                        }
                    }

                    if !review.strongThemes.isEmpty || !review.weakThemes.isEmpty {
                        Divider()
                        Text("主线与风险").font(.headline).foregroundStyle(IOSDesign.ink)
                        ForEach(review.strongThemes) { item in
                            Label {
                                Text("\(item.name) · \(item.rationale)")
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "arrow.up.right.circle.fill")
                                    .foregroundStyle(AppPalette.positive)
                            }
                        }
                        ForEach(review.weakThemes) { item in
                            Label {
                                Text("\(item.name) · \(item.rationale)")
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(AppPalette.warning)
                            }
                        }
                    }

                    Label(review.dataBoundary, systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(IOSDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup("研究依据") {
                        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                            reportContent
                            if let evidence = model.trendReport?.evidence, !evidence.isEmpty {
                                IOSTrendEvidenceListView(evidence: evidence)
                            }
                        }
                        .padding(.top, IOSDesign.spaceS)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(IOSDesign.accent)
                }
                .padding(.top, IOSDesign.spaceS)
            }
            .font(.subheadline.weight(.semibold))
            .tint(IOSDesign.accent)
        }
    }

    private func iosCloseReviewTint(_ direction: TrendDirection) -> Color {
        switch direction {
        case .bullish, .neutralPositive:
            return AppPalette.positive
        case .neutral:
            return IOSDesign.accent
        case .neutralNegative, .bearish:
            return AppPalette.warning
        case .uncertain:
            return IOSDesign.muted
        }
    }

    // MARK: 投资智能 - 我的组合

    private var intelligencePortfolioContent: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            Text("AI 眼中的组合")
                .font(.title2.weight(.bold))
                .foregroundStyle(IOSDesign.ink)
            Text("先看资金暴露，再决定需要研究什么。")
                .font(.subheadline)
                .foregroundStyle(IOSDesign.muted)

            iosPortfolioMetric("第一大持仓", model.investmentIntelligenceSummary.topDirectHoldingText ?? "待计算")
            Divider()
            iosPortfolioMetric("第一大行业", model.investmentIntelligenceSummary.topSectorText ?? "待穿透")
            Divider()
            iosPortfolioMetric("基金穿透覆盖", model.investmentIntelligenceSummary.lookThroughCoverageText ?? "数据未就绪")

            if !model.activeDecisionCases.isEmpty {
                Text("当前结构问题")
                    .font(.headline)
                    .padding(.top, IOSDesign.spaceS)
                ForEach(model.activeDecisionCases.prefix(6)) { decisionCase in
                    Button { selectedCase = decisionCase } label: {
                        HStack {
                            Circle().fill(iosDecisionTint(decisionCase.decisionState)).frame(width: 7, height: 7)
                            Text(decisionCase.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(IOSDesign.ink)
                            Spacer()
                            Text(decisionCase.metricLabel)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(IOSDesign.muted)
                        }
                        .padding(.vertical, IOSDesign.spaceS)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }

            Button("编辑投资偏好") { isShowingProfile = true }
                .buttonStyle(.bordered)
        }
    }

    // MARK: 投资智能 - 事项(M4)

    @ViewBuilder
    private var intelligenceCasesContent: some View {
        if model.activeDecisionCases.isEmpty {
            Text("当前无活跃决策事项")
                .font(.system(size: 14))
                .foregroundColor(IOSDesign.muted)
                .padding()
        } else {
            ForEach(model.activeDecisionCases) { cs in
                IOSDecisionCaseCard(
                    decisionCase: cs,
                    isResearching: model.researchingDecisionCaseID == cs.id,
                    researchReport: model.lastDecisionCaseResearchReports[cs.id],
                    onOpen: { selectedCase = cs },
                    onAcknowledge: { model.acknowledgeDecisionCase(cs.id) },
                    onResolve: { model.resolveDecisionCase(cs.id) },
                    onClose: { model.closeDecisionCase(cs.id) },
                    onResearch: { Task { await model.researchDecisionCase(cs.id) } }
                )
            }
        }
    }

    // MARK: 投资智能 - 决策记录

    @ViewBuilder
    private var intelligenceRecordsContent: some View {
        let reviewDue = model.reviewDueDecisionCases
        let history = model.historicalDecisionCases

        if reviewDue.isEmpty && history.isEmpty {
            Text("暂无复盘记录")
                .font(.system(size: 14))
                .foregroundColor(IOSDesign.muted)
                .padding()
        } else {
            if !reviewDue.isEmpty {
                Text("待复盘 (\(reviewDue.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(IOSDesign.ink)
                ForEach(reviewDue) { cs in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cs.title).font(.subheadline.weight(.medium))
                            if let due = cs.reviewDueAt {
                                Text("到期：\(due.prefix(10))").font(.caption).foregroundStyle(IOSDesign.muted)
                            }
                        }
                        Spacer()
                        Button("复盘") { reviewCase = cs }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(IOSDesign.spaceS)
                    .background(IOSDesign.paper, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
                }
            }

            if !history.isEmpty {
                Text("历史 (\(history.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(IOSDesign.ink)
                    .padding(.top)
                ForEach(history.prefix(10)) { cs in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cs.title).font(.system(size: 13, weight: .medium))
                        Text("关闭:\(String(cs.resolvedAt ?? cs.updatedAt).prefix(10))")
                            .font(.system(size: 11)).foregroundColor(IOSDesign.muted)
                    }
                    .padding(IOSDesign.spaceS)
                    .background(IOSDesign.paper, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
                }
            }

            DisclosureGroup("旧趋势跟踪清单") {
                trackingContent.padding(.top, IOSDesign.spaceS)
            }
            .font(.subheadline.weight(.semibold))
            .tint(IOSDesign.muted)
        }
    }

    private func iosPortfolioMetric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(IOSDesign.muted)
            Spacer()
            Text(value).font(.headline).foregroundStyle(IOSDesign.ink)
        }
        .padding(.vertical, IOSDesign.spaceS)
    }

    // MARK: 研判(旧,降级为"依据")

    @ViewBuilder
    private var reportContent: some View {
        let summary = model.trendDashboardSummary
        statusCard(summary)
        if !summary.horizons.isEmpty {
            horizonsCard(summary)
        }
        if !summary.sectors.isEmpty {
            sectorsCard(summary)
        }
    }

    // MARK: 跟踪

    @ViewBuilder
    private var trackingContent: some View {
        IOSTrendTrackingListView()
    }

    // MARK: 证据

    @ViewBuilder
    private var evidenceContent: some View {
        IOSTrendEvidenceListView(evidence: model.trendReport?.evidence ?? [])
    }

    // MARK: 研判卡片

    private func statusCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "AI 趋势研判", subtitle: summary.dataAsOf ?? "尚未生成", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IOSTintedBadge(text: summary.stateText, tone: .neutral)
                    if summary.riskLevel != nil, !summary.riskText.isEmpty {
                        IOSTintedBadge(text: summary.riskText, tone: trendToneToStat(summary.riskTone))
                    }
                    Spacer()
                }
                Text(summary.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let generated = summary.generatedAt {
                    Text("生成于 \(generated)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                }
                actionButtons(summary)
            }
        }
    }

    private func actionButtons(_ summary: TrendDashboardSummary) -> some View {
        VStack(spacing: 8) {
            Button {
                handleTrendAction(summary.primaryAction)
            } label: {
                Label(summary.primaryAction.title, systemImage: summary.primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(trendToneColor(summary.primaryAction.tone))
            .disabled(summary.primaryAction.isDisabled)

            if let secondary = summary.secondaryAction {
                Button {
                    handleTrendAction(secondary)
                } label: {
                    Label(secondary.title, systemImage: secondary.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(trendToneColor(secondary.tone))
                .disabled(secondary.isDisabled)
            }
        }
    }

    private func horizonsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "周期研判", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.horizons) { horizon in
                    trendRow(
                        title: horizon.title,
                        direction: horizon.directionText,
                        rationale: horizon.rationale,
                        confidence: horizon.confidence,
                        exposureText: nil,
                        tone: horizon.tone
                    )
                }
            }
        }
    }

    private func sectorsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "板块研判", icon: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.sectors) { sector in
                    trendRow(
                        title: sector.name,
                        direction: sector.directionText,
                        rationale: sector.rationale,
                        confidence: sector.confidence,
                        exposureText: sector.exposureText,
                        tone: sector.tone
                    )
                }
            }
        }
    }

    /// 周期/板块研判行：色条 + 标题 + 方向 + 暴露占比 + 把握 + 理由。
    private func trendRow(
        title: String,
        direction: String,
        rationale: String,
        confidence: TrendConfidence,
        exposureText: String?,
        tone: TrendDashboardTone
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(trendToneColor(tone))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    if let exposureText, !exposureText.isEmpty {
                        Text(exposureText)
                            .font(IOSDesign.monoNumber(10, weight: .regular))
                            .foregroundStyle(AppPalette.muted)
                    }
                    Spacer()
                    Text(direction)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trendToneColor(tone))
                }
                confidenceMeter(confidence)
                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 把握度细条：左标题右分数 + 进度胶囊（档位与 macOS 同源 ConfidenceGrade）。
    private func confidenceMeter(_ confidence: TrendConfidence) -> some View {
        HStack(spacing: IOSDesign.spaceS) {
            Text("把握 \(ConfidenceGrade(score: confidence.normalizedScore).gradeText)")
                .font(IOSDesign.sansBody(10))
                .foregroundStyle(AppPalette.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSDesign.ink.opacity(0.08))
                    Capsule()
                        .fill(trendToneColor(.info))
                        .frame(width: geo.size.width * CGFloat(max(0, min(confidence.score, 100))) / 100)
                }
            }
            .frame(height: 3)
            Text("\(confidence.score)")
                .font(IOSDesign.monoNumber(10, weight: .medium))
                .foregroundStyle(AppPalette.muted)
        }
    }

    private func handleTrendAction(_ action: TrendDashboardAction) {
        guard !action.isDisabled else { return }
        switch action.kind {
        case .configure:
            model.selectedSection = .settings
        case .generate, .refresh:
            model.startTrendAnalysis(userInitiated: true)
        case .openReport, .wait:
            break
        }
    }
}

// MARK: - TrendDashboardTone → 颜色(iOS 版)

func trendToneColor(_ tone: TrendDashboardTone) -> Color {
    switch tone {
    case .brand: return AppPalette.brand
    case .positive: return AppPalette.marketGain
    case .info: return AppPalette.info
    case .warning: return AppPalette.warning
    case .danger: return AppPalette.marketLoss
    case .muted: return AppPalette.muted
    }
}

func trendToneToStat(_ tone: TrendDashboardTone) -> IOSStatTile.StatTone {
    switch tone {
    case .positive: return .positive
    case .danger: return .negative
    default: return .neutral
    }
}
#endif
