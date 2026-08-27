import SwiftUI

/// V1「今日研判」摘要：四条产品链各一行，点击定位到对应区段。
/// 文案与状态全部从 V2 Presentation Snapshot 派生，不读取旧 V1 数据文件。
struct IntelligenceTodaySummaryCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot?
    let loadState: AppModel.IntelligenceDashboardLoadState
    let onSelect: (IntelligenceSectionView.SectionAnchor) -> Void

    var body: some View {
        SectionCard(
            title: "今日研判",
            subtitle: "先看结论，再按盘中、市场、组合与复盘逐层展开",
            icon: "sparkles",
            trailing: {
                if let snapshot {
                    Text(IntelligencePresentationFormatter.headlineStatusLabel(snapshot.headline.status))
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(headlineTint(snapshot.headline.status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(headlineTint(snapshot.headline.status).opacity(0.1), in: Capsule())
                }
            }
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.headline.reason)
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let validityNote = snapshot.headline.validityNote {
                            Text(validityNote)
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }

                    VStack(spacing: AppPalette.spaceS) {
                        summaryRow(intradayRow(snapshot))
                        summaryRow(marketRow(snapshot))
                        summaryRow(longTermRow(snapshot))
                        summaryRow(closeReviewRow(snapshot))
                    }
                }
            } else {
                unavailableContent
            }
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        switch loadState {
        case .idle, .loading:
            HStack(spacing: AppPalette.spaceS) {
                ProgressView().controlSize(.small)
                Text("正在恢复最近一次研判…")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }
            .padding(.vertical, AppPalette.spaceS)
        case let .failed(error):
            VStack(alignment: .leading, spacing: 4) {
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                Text(error.message)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loaded:
            Text("最近研判暂不可用。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
        }
    }

    private func summaryRow(_ row: SummaryRow) -> some View {
        Button {
            onSelect(row.anchor)
        } label: {
            HStack(alignment: .top, spacing: AppPalette.spaceM) {
                Image(systemName: row.icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
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
                    .foregroundStyle(AppPalette.muted)
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
        .accessibilityHint("滚动到“\(row.title)”区段")
    }

    private func intradayRow(_ snapshot: InvestmentIntelligenceDashboardSnapshot) -> SummaryRow {
        let headline: String
        if let intraday = snapshot.intraday {
            headline = IntelligencePresentationFormatter.intradayDecisionLabel(intraday.decision)
                + (intraday.validity == .expired ? "（已过期，需重新评估）" : "")
        } else {
            headline = "等待首次盘中评估"
        }
        return SummaryRow(
            anchor: .intraday,
            title: "盘中实时指引",
            headline: headline,
            icon: "clock.arrow.circlepath"
        )
    }

    private func marketRow(_ snapshot: InvestmentIntelligenceDashboardSnapshot) -> SummaryRow {
        let headline: String
        if let discovery = snapshot.discovery {
            switch discovery.state {
            case .hasCandidates:
                headline = "筛出 \(discovery.topCandidates.count) 个候选，等待逐项验证"
            case .noCandidates:
                headline = "本期没有标的通过筛选阈值"
            case .insufficientData:
                headline = "市场数据仍在准备，暂不下结论"
            }
        } else {
            headline = "等待首次市场扫描"
        }
        return SummaryRow(
            anchor: .marketRadar,
            title: "全市场机会雷达",
            headline: headline,
            icon: "scope"
        )
    }

    private func longTermRow(_ snapshot: InvestmentIntelligenceDashboardSnapshot) -> SummaryRow {
        let headline = snapshot.research?.producedAt == nil
            ? "等待首次组合长期研判"
            : (snapshot.research?.narrativeHeadline ?? "组合研判已更新")
        return SummaryRow(
            anchor: .longTerm,
            title: "我的组合长期研判",
            headline: headline,
            icon: "briefcase.fill"
        )
    }

    private func closeReviewRow(_ snapshot: InvestmentIntelligenceDashboardSnapshot) -> SummaryRow {
        let headline = snapshot.closeReview.map {
            IntelligencePresentationFormatter.closeReviewStateLabel($0.state)
        } ?? "等待首次收盘复盘"
        return SummaryRow(
            anchor: .closeReview,
            title: "收盘复盘",
            headline: headline,
            icon: "sunset.fill"
        )
    }

    private func headlineTint(
        _ status: InvestmentIntelligenceDashboardSnapshot.Headline.Status
    ) -> Color {
        switch status {
        case .rebalanceSuggested: return AppPalette.warning
        case .holdConfigured: return AppPalette.positive
        case .undecidable: return AppPalette.info
        case .notReady: return AppPalette.muted
        }
    }

    private struct SummaryRow {
        let anchor: IntelligenceSectionView.SectionAnchor
        let title: String
        let headline: String
        let icon: String
    }
}
