import SwiftUI

/// 摘要行点击 → 区段锚点滚动与高亮的协调器。
/// 由 `EnhancementCenterView` 持有并经 environment 注入;未注入时行点击降级为无操作。
final class InvestmentSectionAnchorModel: ObservableObject {
    @Published var scrollTo: InvestmentTodayResearchRow.Kind?
    @Published var highlighted: InvestmentTodayResearchRow.Kind?
}

private struct InvestmentSectionAnchorsKey: EnvironmentKey {
    static let defaultValue: InvestmentSectionAnchorModel? = nil
}

extension EnvironmentValues {
    var investmentSectionAnchors: InvestmentSectionAnchorModel? {
        get { self[InvestmentSectionAnchorsKey.self] }
        set { self[InvestmentSectionAnchorsKey.self] = newValue }
    }
}

/// 区段锚点:滚动 id + 命中高亮描边(1 秒后由协调器清除)。
private struct InvestmentSectionAnchorModifier: ViewModifier {
    let kind: InvestmentTodayResearchRow.Kind
    @Environment(\.investmentSectionAnchors) private var anchors

    func body(content: Content) -> some View {
        content
            .id(kind.rawValue)
            .overlay {
                if anchors?.highlighted == kind {
                    RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                        .strokeBorder(AppPalette.brand.opacity(0.55), lineWidth: 1.5)
                        .padding(-AppPalette.spaceXS)
                        .allowsHitTesting(false)
                }
            }
            .animation(AppPalette.motionStandard, value: anchors?.highlighted)
    }
}

extension View {
    func investmentSectionAnchor(_ kind: InvestmentTodayResearchRow.Kind) -> some View {
        modifier(InvestmentSectionAnchorModifier(kind: kind))
    }
}

extension InvestmentTodayResearchRow.Kind {
    /// 与对应区段同款图标,让用户建立「行 ↔ 区段」映射。
    var iconName: String {
        switch self {
        case .closeReview: return "sunset.fill"
        case .intraday: return "clock.arrow.circlepath"
        case .marketRadar: return "scope"
        case .longTerm: return "briefcase.fill"
        }
    }
}

/// 「今日研判」摘要卡:四条链路各一行,点击定位到对应区段;
/// 无任何内容时整卡退化为统一引导态(全页引导位的第一步)。
struct InvestmentTodaySummaryCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.investmentSectionAnchors) private var anchors
    @AppStorage(AppStorageKey.researchReadingGuideShown) private var hasSeenReadingGuide = false
    @State private var isShowingGuide = false
    /// W2.4(缩窄版):详细模式开关(证据账本/风险边界显隐),全局记忆。
    @AppStorage(AppStorageKey.researchDetailMode) private var showsResearchDetailMode = false
    /// W1.2:空态能力清单 → 向导/示例入口。
    @State private var isShowingWizard = false
    @State private var wizardStep: TrendSetupWizardSheet.Step = .provider
    @State private var isShowingDemoPreview = false

    var body: some View {
        let summary = model.investmentTodayResearchSummary
        let verdict = todayVerdictText

        SectionCard(
            title: "今日研判",
            subtitle: "四条研判各一行，点击定位到对应区段",
            icon: "sparkles",
            trailing: {
                Spacer()
                if let pct = model.portfolioLookThroughSnapshot?.disclosedSecurityCoveragePct,
                   pct < 70 {
                    // W2.2:低覆盖警示角标——读结论前先知道「判断基础有限」。
                    Label("穿透 \(Int(pct))%", systemImage: "exclamationmark.triangle.fill")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                        .help("穿透覆盖率 \(Int(pct))%,判断基础有限;详见下方「研判基础」。")
                }
                Button {
                    isShowingGuide = true
                } label: {
                    Label("怎么读", systemImage: "questionmark.circle")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                Button {
                    showsResearchDetailMode.toggle()
                } label: {
                    Image(systemName: showsResearchDetailMode ? "eye.fill" : "eye")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .help(
                    showsResearchDetailMode
                        ? "详细模式已开:长期研判展示完整证据与风险边界。点击切回简洁。"
                        : "简洁模式:长期研判隐藏完整证据与风险边界。点击开启详细。"
                )
                .accessibilityLabel(showsResearchDetailMode ? "切换到简洁模式" : "切换到详细模式")
            }
        ) {
            if summary.hasAnyContent {
                VStack(spacing: AppPalette.spaceS) {
                    // W2.3:「今天一句话」hero——纯派生,冲突时双短句,无内容不显示。
                    if let verdict {
                        HStack(spacing: AppPalette.spaceS) {
                            Image(systemName: "quote.opening")
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                .foregroundStyle(AppPalette.brand)
                            Text("今天:\(verdict)")
                                .font(AppPalette.appFont(.subheadline, weight: .bold))
                                .foregroundStyle(AppPalette.ink)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, AppPalette.spaceS)
                        .padding(.vertical, 6)
                        .background(AppPalette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    }
                    ForEach(summary.rows) { row in
                        summaryRow(row)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    // W1.2:空态先讲「会得到什么、缺什么怎么补」,再给入口。
                    VStack(spacing: AppPalette.spaceS) {
                        capabilityRow(
                            title: "盘中实时指引",
                            icon: "clock.arrow.circlepath",
                            status: model.trendSettings.provider.isConfigured ? .available : .missingModel
                        )
                        capabilityRow(
                            title: "今日收盘复盘",
                            icon: "sunset.fill",
                            status: model.trendSettings.provider.isConfigured ? .available : .missingModel
                        )
                        capabilityRow(
                            title: "我的组合长期研判",
                            icon: "briefcase.fill",
                            status: model.trendSettings.provider.isConfigured ? .available : .missingModel
                        )
                        capabilityRow(
                            title: "全市场机会雷达",
                            icon: "scope",
                            status: radarCapabilityStatus
                        )
                    }
                    HStack(spacing: AppPalette.spaceS) {
                        if !model.trendSettings.provider.isConfigured {
                            Button("开始配置模型", systemImage: "wand.and.stars") {
                                wizardStep = .provider
                                isShowingWizard = true
                            }
                            .buttonStyle(.appPrimary)
                            .controlSize(.small)
                        } else if !model.trendSettings.webSearch.isConfigured {
                            Button("补上 Tavily,解锁雷达", systemImage: "plus.circle") {
                                wizardStep = .extras
                                isShowingWizard = true
                            }
                            .buttonStyle(.appPrimary)
                            .controlSize(.small)
                        } else {
                            Button("生成第一份研判", systemImage: "sparkles") {
                                model.startTrendAnalysisFromUser(withExpectation: .full)
                            }
                            .buttonStyle(.appPrimary)
                            .controlSize(.small)
                        }
                        Button("预览示例研判", systemImage: "eye") {
                            isShowingDemoPreview = true
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            ResearchReadingGuideSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingWizard) {
            TrendSetupWizardSheet(initialStep: wizardStep)
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingDemoPreview) {
            DemoTrendReportPreviewSheet()
                .environmentObject(model)
        }
        .onChange(of: summary.hasAnyContent) { _, hasContent in
            // 首个报告落盘、内容首次出现时自动弹一次指南;hasAnyContent 由
            // false→true 只发生在生成成功落盘之后,生成中不会触发。
            guard hasContent, !hasSeenReadingGuide else { return }
            isShowingGuide = true
            hasSeenReadingGuide = true
        }
    }

    // MARK: - W1.2 空态能力清单

    /// W2.3:hero 输入装配(纯派生在 Core,可测)。
    private var todayVerdictText: String? {
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

    private enum CapabilityStatus {
        case available
        case missingModel
        case missingTavily

        var icon: String {
            switch self {
            case .available: return "checkmark.circle.fill"
            case .missingModel: return "xmark.circle.fill"
            case .missingTavily: return "exclamationmark.triangle.fill"
            }
        }

        var text: String {
            switch self {
            case .available: return "可用"
            case .missingModel: return "未配置模型,点此开始"
            case .missingTavily: return "缺 Tavily,点此补上"
            }
        }

        var tint: Color {
            switch self {
            case .available: return AppPalette.positive
            case .missingModel: return AppPalette.muted
            case .missingTavily: return AppPalette.warning
            }
        }

        var isActionable: Bool {
            switch self {
            case .available: return false
            case .missingModel, .missingTavily: return true
            }
        }
    }

    private var radarCapabilityStatus: CapabilityStatus {
        guard model.trendSettings.provider.isConfigured else { return .missingModel }
        guard model.trendSettings.webSearch.isConfigured else { return .missingTavily }
        return .available
    }

    @ViewBuilder
    private func capabilityRow(title: String, icon: String, status: CapabilityStatus) -> some View {
        let row = HStack(spacing: AppPalette.spaceS) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
                .frame(width: 22)
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.ink)
            Spacer(minLength: AppPalette.spaceS)
            Label(status.text, systemImage: status.icon)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(status.tint)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, AppPalette.spaceS)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

        if status.isActionable {
            Button {
                wizardStep = status == .missingTavily ? .extras : .provider
                isShowingWizard = true
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func summaryRow(_ row: InvestmentTodayResearchRow) -> some View {
        Button {
            anchors?.scrollTo = row.kind
        } label: {
            HStack(alignment: .top, spacing: AppPalette.spaceM) {
                Image(systemName: row.kind.iconName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppPalette.spaceS) {
                        Text(row.title)
                            .font(AppPalette.appFont(.caption, weight: .semibold))
                            .foregroundStyle(AppPalette.muted)
                        if !row.footnote.isEmpty {
                            Text(row.footnote)
                                .font(AppPalette.appFont(.caption2))
                                .foregroundStyle(AppPalette.muted)
                                .lineLimit(1)
                        }
                    }
                    Text(row.headline)
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AppPalette.spaceS)

                Image(systemName: "arrow.down.circle")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted.opacity(0.7))
            }
            .padding(AppPalette.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .background(
                AppPalette.cardStrong.opacity(0.6),
                in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("滚动到「\(row.title)」区段")
    }
}
