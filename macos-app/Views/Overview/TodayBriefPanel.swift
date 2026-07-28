import SwiftUI

private extension TodayBriefTone {
    var overviewTint: Color {
        switch self {
        case .brand:
            return AppPalette.brand
        case .info:
            return AppPalette.info
        case .warning:
            return AppPalette.warning
        case .danger:
            return AppPalette.danger
        case .positive:
            return AppPalette.positive
        case .muted:
            return AppPalette.muted
        case .marketGain:
            return AppPalette.marketGain
        case .marketLoss:
            return AppPalette.marketLoss
        }
    }
}

struct TodayBriefPanel: View {
    let items: [TodayBriefItem]
    let summaryItems: [TodayBriefSummaryItem]
    let action: (TodayBriefItem) -> Void
    let summaryAction: () -> Void

    private var todayBriefWideColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top), count: 4)
    }

    private var todayBriefMediumColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top), count: 2)
    }

    private var todayBriefCompactColumns: [GridItem] {
        [GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .accentIconStyle(tint: AppPalette.brand, size: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("今日看点")
                        .font(AppPalette.appFont(.title3, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("资产摘要 + 今日事项")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ToolbarBadge(title: items.isEmpty ? "暂无" : "\(items.count) 项", tint: items.isEmpty ? AppPalette.muted : AppPalette.brand)
            }

            if !summaryItems.isEmpty {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: todayBriefWideColumns, alignment: .leading, spacing: 10) {
                        ForEach(summaryItems) { item in
                            TodayBriefSummaryCard(item: item, action: summaryAction)
                        }
                    }

                    LazyVGrid(columns: todayBriefMediumColumns, alignment: .leading, spacing: 10) {
                        ForEach(summaryItems) { item in
                            TodayBriefSummaryCard(item: item, action: summaryAction)
                        }
                    }

                    LazyVGrid(columns: todayBriefCompactColumns, alignment: .leading, spacing: 10) {
                        ForEach(summaryItems) { item in
                            TodayBriefSummaryCard(item: item, action: summaryAction)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(AppPalette.appFont(.title, weight: .semibold))
                        .foregroundStyle(AppPalette.positive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今天暂无需要处理的事项")
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text("持仓、计划和最新记录刷新后会自动出现在这里")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .padding(12)
                .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                .cardStroke(opacity: 0.28)
            } else {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: todayBriefWideColumns, alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            TodayBriefItemButton(item: item) {
                                action(item)
                            }
                        }
                    }

                    LazyVGrid(columns: todayBriefMediumColumns, alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            TodayBriefItemButton(item: item) {
                                action(item)
                            }
                        }
                    }

                    LazyVGrid(columns: todayBriefCompactColumns, alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            TodayBriefItemButton(item: item) {
                                action(item)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke()
        .sectionShadow()
    }
}

struct TodayBriefSummaryCard: View {
    let item: TodayBriefSummaryItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: item.icon)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 30, height: 30)
                    .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(item.tint.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                    Text(item.value)
                        .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(item.detail)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right")
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle(item.tint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .interactiveSurface(
                tint: item.tint,
                fill: AppPalette.cardStrong.opacity(0.72),
                hoverFill: AppPalette.cardHover,
                strokeOpacity: 0.16,
                activeStrokeOpacity: 0.36,
                lift: 0.6
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("打开我的持仓")
    }
}

struct TodayBriefItemButton: View {
    let item: TodayBriefItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.iconName)
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(item.tone.overviewTint)
                    .frame(width: 32, height: 32)
                    .background(item.tone.overviewTint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(item.tone.overviewTint.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(item.detail)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.metric)
                        .font(AppPalette.appFont(.headline, weight: .bold, design: .rounded))
                        .foregroundStyle(item.tone.overviewTint)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Image(systemName: "arrow.up.right")
                        .font(AppPalette.appFont(.caption, weight: .bold))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(minWidth: 54, alignment: .trailing)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .interactiveSurface(
                tint: item.tone.overviewTint,
                fill: AppPalette.cardStrong.opacity(0.72),
                hoverFill: AppPalette.cardHover,
                strokeOpacity: 0.18,
                activeStrokeOpacity: 0.40,
                lift: 0.8
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.title)
    }
}
