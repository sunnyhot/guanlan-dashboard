import SwiftUI

/// 投资智能单页通览:公共头部(研判基础 + 实时日志) + Tab 互斥的三链路内容
/// (盘中指引 / 收盘复盘含大盘强弱 / 组合长期研判)。
/// 2026-09-02 布局优化:原「三链路纵向平铺、一屏过载」改为 Tab 切换
/// (参照平台板块 ModuleTabBar 模式),通知深链锚点联动自动切 Tab;
/// 分区统一使用全站 `SectionCard` 容器,与总览/持仓/平台板块保持同一视觉系统。
struct InvestmentIntelligenceDashboardView<Intraday: View, LongTerm: View>: View {
    @EnvironmentObject private var model: AppModel

    @State private var isShowingProfile = false
    /// 按紧迫度注入的内容区段(盘中 / 组合长期)。
    let intradayContent: Intraday
    let longTermContent: LongTerm

    init(
        @ViewBuilder intradayContent: () -> Intraday,
        @ViewBuilder longTermContent: () -> LongTerm
    ) {
        self.intradayContent = intradayContent()
        self.longTermContent = longTermContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            credibilitySection
            TrendLiveLogPanel()
            // 2026-09-02 布局优化:三链路大块改 Tab 互斥切换(参照平台板块),
            // 一屏只承载一条链路;研判基础与实时日志为公共头部。
            ModuleTabBar(
                items: AIResearchTab.allCases,
                selection: $model.selectedAIResearchTab,
                title: { $0.rawValue },
                systemImage: { $0.systemImage }
            ) {
            }
            switch model.selectedAIResearchTab {
            case .intraday:
                intradayContent
            case .closeReview:
                MarketCloseReviewSection()
                    .investmentSectionAnchor(.closeReview)
            case .longTerm:
                longTermContent
            }
        }
        .sheet(isPresented: $isShowingProfile) {
            UserDecisionProfilePanel()
                .environmentObject(model)
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
