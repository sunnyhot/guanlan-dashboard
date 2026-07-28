import SwiftUI

struct AITrendSummaryPanel: View {
    let summary: TrendDashboardSummary
    let action: (TrendDashboardAction) -> Void

    var body: some View {
        SectionCard(title: "AI 趋势摘要", subtitle: subtitle, icon: "sparkles", trailing: {
            Spacer()
            ToolbarBadge(title: summary.stateText, tint: summary.status.tint)
            ToolbarBadge(title: summary.riskText, tint: summary.riskTone.color)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(summary.riskTone.color)
                        .frame(width: 3, height: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary.headline)
                            .font(AppPalette.appFont(.title3, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary.detail)
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))

                if !summary.horizons.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(summary.horizons.enumerated()), id: \.element.id) { index, horizon in
                            AITrendHorizonRow(item: horizon)
                            if index < summary.horizons.count - 1 {
                                Divider()
                                    .padding(.leading, AppPalette.spaceM)
                            }
                        }
                    }
                    .background(AppPalette.cardStrong.opacity(0.28), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                }

                if !summary.sectors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("板块观点")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        VStack(spacing: 0) {
                            ForEach(Array(summary.sectors.prefix(3).enumerated()), id: \.element.id) { index, sector in
                                AITrendSectorRow(item: sector)
                                if index < min(3, summary.sectors.count) - 1 {
                                    Divider()
                                        .padding(.leading, AppPalette.spaceM)
                                }
                            }
                        }
                        .background(AppPalette.cardStrong.opacity(0.28), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                        if summary.sectors.count > 3 {
                            Text("其余 \(summary.sectors.count - 3) 项请在完整报告中查看")
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        trendActionButton(summary.primaryAction)
                        if let secondaryAction = summary.secondaryAction {
                            trendActionButton(secondaryAction)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        trendActionButton(summary.primaryAction)
                        if let secondaryAction = summary.secondaryAction {
                            trendActionButton(secondaryAction)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let parts = [
            summary.dataAsOf.map { "数据 \($0)" },
            summary.externalSignalText,
            summary.generatedAt.map { "生成 \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? "组合级 AI 判断与条件式复核入口" : parts.joined(separator: "  ")
    }

    @ViewBuilder
    private func trendActionButton(_ item: TrendDashboardAction) -> some View {
        if item.isPrimary {
            Button {
                action(item)
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
            .buttonStyle(.appPrimary)
            .tint(item.tone.color)
            .controlSize(.small)
            .disabled(item.isDisabled)
        } else {
            Button {
                action(item)
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
            .buttonStyle(.appSecondary)
            .tint(item.tone.color)
            .controlSize(.small)
            .disabled(item.isDisabled)
        }
    }
}

private struct AITrendHorizonRow: View {
    let item: TrendDashboardHorizonItem

    var body: some View {
        HStack(alignment: .top, spacing: AppPalette.spaceM) {
            Text(item.title)
                .font(AppPalette.appFont(.body, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.rationale)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(item.directionText)
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle(item.tone.color)
                    .lineLimit(1)
                TrendConfidenceMeter(confidence: item.confidence)
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, 10)
    }
}

private struct AITrendSectorRow: View {
    let item: TrendDashboardSectorItem

    var body: some View {
        HStack(alignment: .top, spacing: AppPalette.spaceM) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: AppPalette.spaceS) {
                    Text(item.name)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(item.exposureText)
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.info)
                }
                Text(item.rationale)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(item.directionText)
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle(item.tone.color)
                    .lineLimit(1)
                TrendConfidenceMeter(confidence: item.confidence)
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, 10)
    }
}

private extension TrendDashboardStatus {
    var tint: Color {
        switch self {
        case .unconfigured, .stale, .rejected:
            return AppPalette.warning
        case .empty, .generating:
            return AppPalette.info
        case .ready:
            return AppPalette.positive
        case .failed:
            return AppPalette.danger
        }
    }
}

private extension TrendDashboardTone {
    var color: Color {
        switch self {
        case .brand:
            return AppPalette.brand
        case .positive:
            return AppPalette.positive
        case .info:
            return AppPalette.info
        case .warning:
            return AppPalette.warning
        case .danger:
            return AppPalette.danger
        case .muted:
            return AppPalette.muted
        }
    }
}
