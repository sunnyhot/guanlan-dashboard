import SwiftUI

// MARK: - 总览「今日结论」浅链卡（审计 C1）
//
// 只读浅链：状态 + 主因 + 收盘复盘徽标，一键跳投资智能板块。不在总览
// 复制任何业务判断（数据与文案全部来自 IntelligenceDashboardSnapshot /
// Formatter）；快照未加载（如启动早期）时不显示，不占位。

struct IntelligenceTodayCard: View {
    @ObservedObject var model: AppModel

    private var snapshot: InvestmentIntelligenceDashboardSnapshot? {
        model.intelligenceDashboardSnapshot
    }

    var body: some View {
        if let snapshot {
            content(snapshot)
        }
    }

    private func content(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        SectionCard(
            title: "投资智能 · 今日结论",
            subtitle: "只读摘要，完整结果在「投资智能」板块",
            icon: "sparkles.rectangle.stack",
            trailing: {
                Button("查看投资智能") {
                    model.selectedSection = .intelligence
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack(spacing: AppPalette.spaceS) {
                    Text(IntelligencePresentationFormatter.headlineStatusLabel(snapshot.headline.status))
                        .font(AppPalette.appFont(.subheadline, weight: .bold))
                        .foregroundStyle(statusColor(snapshot.headline.status))
                    if let closeReview = snapshot.closeReview,
                       closeReview.state == .todayDone {
                        Label("已复盘", systemImage: "checkmark.seal")
                            .font(AppPalette.appFont(.caption, weight: .medium))
                            .foregroundStyle(AppPalette.positive)
                    }
                    Spacer(minLength: 0)
                    if let dataAsOf = snapshot.headline.dataAsOf {
                        Text(IntelligencePresentationFormatter.dateTimeText(dataAsOf))
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                Text(snapshot.headline.reason)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let validityNote = snapshot.headline.validityNote {
                    Label(validityNote, systemImage: "clock")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }
        }
    }

    private func statusColor(
        _ status: InvestmentIntelligenceDashboardSnapshot.Headline.Status
    ) -> Color {
        switch status {
        case .rebalanceSuggested: return AppPalette.warning
        case .holdConfigured: return AppPalette.positive
        case .undecidable: return AppPalette.info
        case .notReady: return AppPalette.muted
        }
    }
}
