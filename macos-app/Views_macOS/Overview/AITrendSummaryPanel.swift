import SwiftUI

struct AITrendSummaryPanel: View {
    let summary: TrendDashboardSummary
    let action: (TrendDashboardAction) -> Void

    private func trendSectorWideColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top), count: max(1, min(4, count)))
    }

    private func trendSectorMediumColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top), count: max(1, min(2, count)))
    }

    private var trendSectorCompactColumns: [GridItem] {
        [GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top)]
    }

    var body: some View {
        SectionCard(title: "AI 趋势摘要", subtitle: subtitle, icon: "sparkles", trailing: {
            Spacer()
            ToolbarBadge(title: summary.stateText, tint: summary.status.tint)
            ToolbarBadge(title: summary.riskText, tint: summary.riskTone.color)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
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
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))

                if !summary.horizons.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(summary.horizons) { horizon in
                            AITrendHorizonCard(item: horizon)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !summary.sectors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("板块观点")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        ViewThatFits(in: .horizontal) {
                            LazyVGrid(columns: trendSectorWideColumns(count: summary.sectors.count), alignment: .leading, spacing: 10) {
                                ForEach(summary.sectors) { sector in
                                    AITrendSectorCard(item: sector)
                                }
                            }

                            LazyVGrid(columns: trendSectorMediumColumns(count: summary.sectors.count), alignment: .leading, spacing: 10) {
                                ForEach(summary.sectors) { sector in
                                    AITrendSectorCard(item: sector)
                                }
                            }

                            LazyVGrid(columns: trendSectorCompactColumns, alignment: .leading, spacing: 10) {
                                ForEach(summary.sectors) { sector in
                                    AITrendSectorCard(item: sector)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        return parts.isEmpty ? "组合级 AI 判断与条件式复核入口" : parts.joined(separator: " · ")
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

private struct AITrendHorizonCard: View {
    let item: TrendDashboardHorizonItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.tone.color)
                    .frame(width: 7, height: 7)
                Text(item.title)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: 4)
                TintedCapsuleBadge(
                    text: item.directionText,
                    tint: item.tone.color,
                    font: AppPalette.appFont(.caption, weight: .bold),
                    horizontalPadding: 6,
                    verticalPadding: 2,
                    softFillOpacity: 0.12,
                    softStrokeOpacity: nil
                )
                TrendConfidenceMeter(confidence: item.confidence)
            }
            Text(item.rationale)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.paper.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(item.tone.color.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct AITrendSectorCard: View {
    let item: TrendDashboardSectorItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.tone.color)
                    .frame(width: 7, height: 7)
                Text(item.name)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TintedCapsuleBadge(
                    text: item.directionText,
                    tint: item.tone.color,
                    font: AppPalette.appFont(.caption, weight: .bold),
                    horizontalPadding: 6,
                    verticalPadding: 2,
                    softFillOpacity: 0.12,
                    softStrokeOpacity: nil
                )
                TrendConfidenceMeter(confidence: item.confidence)
            }
            Text(item.exposureText)
                .font(AppPalette.appFont(.caption, weight: .semibold))
                .foregroundStyle(AppPalette.info)
            Text(item.rationale)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(item.tone.color.opacity(0.14), lineWidth: 1)
        )
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
