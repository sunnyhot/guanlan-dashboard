import SwiftUI

/// 投资智能单页通览。
///
/// 区段按紧迫度排列(W2.1):今日研判摘要 → 研判基础(W2.2 上移,读结论先看基础)
/// → 实时进度 → 盘中指引 → 全市场机会 → 收盘复盘 → 组合长期研判 → 判断记录。
/// 顶部只复盘全市场，不展示持仓收益、DecisionCase 或组合画像。
/// 分区统一使用全站 `SectionCard` 容器，与总览/持仓/平台板块保持同一视觉系统。
struct InvestmentIntelligenceDashboardView<Intraday: View, Radar: View, LongTerm: View>: View {
    @EnvironmentObject private var model: AppModel

    @State private var selectedCase: DecisionCase?
    @State private var reviewCase: DecisionCase?
    @State private var isShowingProfile = false
    /// 按紧迫度注入的三个内容区段(盘中 / 全市场雷达 / 组合长期)。
    let intradayContent: Intraday
    let radarContent: Radar
    let longTermContent: LongTerm

    init(
        @ViewBuilder intradayContent: () -> Intraday,
        @ViewBuilder radarContent: () -> Radar,
        @ViewBuilder longTermContent: () -> LongTerm
    ) {
        self.intradayContent = intradayContent()
        self.radarContent = radarContent()
        self.longTermContent = longTermContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            credibilitySection
            TrendLiveLogPanel()
            intradayContent
            radarContent
            MarketCloseReviewSection()
                .investmentSectionAnchor(.closeReview)
            longTermContent
            MarketSignalSection()
            recordsSection
        }
        .sheet(item: $selectedCase) { decisionCase in
            DecisionCaseDetailSheet(caseID: decisionCase.id)
                .environmentObject(model)
        }
        .sheet(item: $reviewCase) { decisionCase in
            DecisionReviewSheet(caseID: decisionCase.id)
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingProfile) {
            UserDecisionProfilePanel()
                .environmentObject(model)
        }
    }

    // MARK: - 判断记录与阶段复盘

    private var recordsSection: some View {
        SectionCard(
            title: "判断与复盘",
            subtitle: "当时的判断和后来的结果，方便回头看",
            icon: "clock.arrow.circlepath"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                if !model.reviewDueDecisionCases.isEmpty {
                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        Text("待复盘")
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        ForEach(model.reviewDueDecisionCases) { decisionCase in
                            HStack(spacing: AppPalette.spaceM) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(decisionCase.title)
                                        .font(AppPalette.appFont(.body, weight: .semibold))
                                        .foregroundStyle(AppPalette.ink)
                                    Text(reviewText(for: decisionCase))
                                        .font(AppPalette.appFont(.caption))
                                        .foregroundStyle(AppPalette.muted)
                                }
                                Spacer()
                                Button("开始复盘") { reviewCase = decisionCase }
                                    .buttonStyle(.appPrimary)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, AppPalette.spaceS)
                            Divider()
                        }
                    }
                }

                DecisionHistoryView(cases: model.historicalDecisionCases) { selectedCase = $0 }

                if model.reviewDueDecisionCases.isEmpty && model.historicalDecisionCases.isEmpty {
                    InvestmentEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: "闭环刚刚开始",
                        detail: "关注一个决策事项后，系统会在约定时间提醒复盘。"
                    )
                }
            }
        }
    }

    // MARK: - 研判基础（可信度与数据时效）

    private var credibilitySection: some View {
        SectionCard(
            title: "研判基础",
            subtitle: "穿透覆盖与数据时效",
            icon: "shield.checkered",
            trailing: {
                Spacer()
                Button {
                    isShowingProfile = true
                } label: {
                    Label(
                        model.userDecisionProfile.isCustomized ? "决策偏好" : "设置决策偏好",
                        systemImage: "person.crop.circle"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
            }
        ) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: credibilityIsLow ? "exclamationmark.triangle.fill" : "shield.checkered")
                    .font(AppPalette.appFont(.caption))
                Text(credibilityText)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(credibilityTint)
                TermHelpView(term: .lookThroughCoverage)
                Spacer()
            }
        }
    }

    private var coveragePct: Double? {
        model.portfolioLookThroughSnapshot?.disclosedSecurityCoveragePct
    }

    /// 穿透用的最新季报截止日期（各基金 asOf 中最新的）。
    private var latestDisclosureDate: String? {
        guard let funds = model.portfolioLookThroughSnapshot?.funds else { return nil }
        let dates = funds.compactMap(\.asOf).filter { !$0.isEmpty }
        return dates.max()
    }

    private var credibilityIsLow: Bool {
        guard let pct = coveragePct else { return true }
        return pct < 70
    }

    private var credibilityTint: Color {
        credibilityIsLow ? AppPalette.warning : AppPalette.muted
    }

    private var credibilityText: String {
        var parts: [String] = []
        if let pct = coveragePct {
            parts.append("基于\(Int(pct))%穿透数据")
        } else {
            parts.append("穿透数据未就绪")
        }
        if let disclosureDate = latestDisclosureDate {
            parts.append("季报截至\(String(disclosureDate.prefix(10)))")
        }
        if let evaluatedAt = evaluatedAtText {
            parts.append("评估于\(evaluatedAt)")
        }
        if credibilityIsLow {
            parts.append("判断基础有限")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 文案

    private var evaluatedAtText: String? {
        let text = model.investmentIntelligenceSummary.evaluatedAtText
        return text.isEmpty ? nil : String(text.prefix(16))
    }

    private func reviewText(for decisionCase: DecisionCase) -> String {
        guard let due = decisionCase.reviewDueAt else { return "关注后设置复查时间" }
        return "\(String(due.prefix(10))) 复查"
    }
}
