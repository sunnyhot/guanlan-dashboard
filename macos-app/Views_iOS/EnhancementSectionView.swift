#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判页
//
// 投资智能主路径：AI 观点 / 我的组合 / 决策中心 / 决策记录。
// 原趋势研判、跟踪和证据保留为按需展开的研究依据。

struct EnhancementSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: ResearchSegment = .report
    @State private var intelligenceSegment: IntelligenceSegment = .viewpoint
    @State private var selectedCase: DecisionCase?
    @State private var reviewCase: DecisionCase?
    @State private var isShowingProfile = false
    @State private var isShowingGlossary = false

    // 旧分段(投资智能未启用时)
    private enum ResearchSegment: String, CaseIterable, Identifiable {
        case report = "研判"
        case tracking = "跟踪"
        case evidence = "证据"
        var id: String { rawValue }
    }

    // 新分段与 macOS 保持同一产品语言。
    private enum IntelligenceSegment: String, CaseIterable, Identifiable {
        case viewpoint = "观点"
        case portfolio = "组合"
        case decisions = "决策"
        case records = "记录"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if InvestmentIntelligence.enabled {
                    HStack(spacing: IOSDesign.spaceS) {
                        Picker("", selection: $intelligenceSegment) {
                            ForEach(IntelligenceSegment.allCases) { seg in
                                Text(seg.rawValue).tag(seg)
                            }
                        }
                        .pickerStyle(.segmented)

                        Button {
                            isShowingGlossary = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(IOSDesign.accent)
                        }
                        .accessibilityLabel("怎么读这份研判")
                    }
                    .padding(.bottom, 2)

                    switch intelligenceSegment {
                    case .viewpoint: intelligenceViewpointContent
                    case .portfolio: intelligencePortfolioContent
                    case .decisions: intelligenceCasesContent
                    case .records: intelligenceRecordsContent
                    }
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

            // V2 双轨归因（ATTR-5）：确定性引擎，与上方 LLM 复盘对照
            Divider()
            Text("当日归因 · V2 引擎")
                .font(.headline)
                .foregroundStyle(IOSDesign.ink)
            // 五轮 P2-6:与 macOS AttributionV2Section 同口径——coverage 徽标
            // (V2 纯 formatter)/贡献行/残差说明/数据基础/失败态逐一同步
            switch model.dailyAttributionV2 {
            case .some(let outcome) where outcome.job.state == .failed:
                Label(
                    outcome.errorDetail ?? "归因计算失败",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
            case .some(let outcome):
                if let rendered = outcome.rendered {
                    // badge 文案走 V2 纯 formatter(与 macOS 同一实现)
                    let coverage = model.attributionV2Coverage
                    let engineComplete = (outcome.artifact?.result.coverage.value ?? 0) == 1
                    let badge = rendered.grade.badgeLabel(
                        engineCoverageComplete: engineComplete,
                        valuationComplete: coverage?.hasFullValuation ?? true
                    )
                    Text("\(rendered.headline)(\(badge.text))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(rendered.contributionLines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(AppPalette.marketTint(
                                for: line.contains("贡献 +") ? 1 : (line.contains("贡献 -") ? -1 : 0)
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = rendered.residualNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(IOSDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(rendered.caveat)
                        .font(.caption2)
                        .foregroundStyle(IOSDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let coverage {
                        Text(coverage.summaryText + (coverage.supportsResidual ? "" : " · 覆盖不完整，不计算残差"))
                            .font(.caption2)
                            .foregroundStyle(IOSDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .none:
                Text("刷新个人持仓后显示当日收益的确定性归因。")
                    .font(.caption)
                    .foregroundStyle(IOSDesign.muted)
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
