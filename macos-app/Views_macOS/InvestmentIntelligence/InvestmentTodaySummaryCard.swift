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

    var body: some View {
        let summary = model.investmentTodayResearchSummary

        SectionCard(
            title: "今日研判",
            subtitle: "四条研判各一行，点击定位到对应区段",
            icon: "sparkles",
            trailing: {
                Spacer()
                Button {
                    isShowingGuide = true
                } label: {
                    Label("怎么读", systemImage: "questionmark.circle")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
            }
        ) {
            if summary.hasAnyContent {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(summary.rows) { row in
                        summaryRow(row)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    InvestmentEmptyState(
                        icon: "sparkles",
                        title: "还没有任何研判",
                        detail: "配置 AI 模型并生成第一份研判后，这里会出现今日摘要。"
                    )
                    Button("去设置配置模型", systemImage: "gearshape") {
                        model.selectedSection = .settings
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            ResearchReadingGuideSheet()
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
