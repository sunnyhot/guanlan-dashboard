import SwiftUI

struct PersonalWatchlistListRow: View {
    let row: PersonalWatchlistQuoteRow
    let isSelected: Bool
    let tint: Color
    let onSelect: () -> Void
    let onConfigureAlerts: () -> Void
    let onDelete: () -> Void

    private var changeTint: Color {
        AppPalette.marketTint(for: row.changeSinceFollowPct)
    }

    private var activeAlertCount: Int {
        row.record.alertRules?.ruleCount ?? 0
    }

    private var triggeredAlertCount: Int {
        row.record.alertState?.breachedKinds.count ?? 0
    }

    private var alertTint: Color {
        if triggeredAlertCount > 0 { return AppPalette.warning }
        return activeAlertCount > 0 ? tint : AppPalette.muted
    }

    var body: some View {
        GeometryReader { geometry in
            let showsSparkline = geometry.size.width >= 900
            let contentWidth = max(
                0,
                geometry.size.width
                    - alertControlWidth
                    - AppPalette.spaceM * 2
                    - AppPalette.spaceL * CGFloat(showsSparkline ? 5 : 4)
                    - disclosureWidth
            )

            HStack(spacing: AppPalette.spaceS) {
                Button(action: onSelect) {
                    HStack(spacing: AppPalette.spaceL) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.displayName)
                                .font(AppPalette.appFont(.body, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(row.item.normalizedCode)
                                    .font(AppPalette.appFont(.footnote, design: .monospaced))
                                    .foregroundStyle(AppPalette.muted)
                                Text(row.item.marketLabel)
                                    .font(AppPalette.appFont(.caption, weight: .medium))
                                    .foregroundStyle(tint)
                            }
                        }
                        .frame(
                            width: contentWidth * (showsSparkline ? 0.26 : 0.30),
                            alignment: .leading
                        )

                        watchlistValue(
                            title: "关注价 · \(row.item.followedDate)",
                            value: watchlistPriceText(row.record.baseline?.price, item: row.item),
                            tint: AppPalette.ink
                        )
                        .frame(
                            width: contentWidth * (showsSparkline ? 0.20 : 0.26),
                            alignment: .leading
                        )

                        watchlistValue(
                            title: row.category == .offExchangeFund ? "当前净值" : "当前价格",
                            value: watchlistPriceText(row.currentPrice, item: row.item),
                            tint: AppPalette.ink
                        )
                        .frame(
                            width: contentWidth * (showsSparkline ? 0.17 : 0.24),
                            alignment: .leading
                        )

                        watchlistValue(
                            title: "关注以来",
                            value: percentOptional(row.changeSinceFollowPct),
                            tint: changeTint
                        )
                        .frame(
                            width: contentWidth * (showsSparkline ? 0.15 : 0.20),
                            alignment: .leading
                        )

                        if showsSparkline {
                            PersonalWatchlistSparkline(row: row)
                                .frame(width: contentWidth * 0.22)
                                .frame(height: 38)
                                .clipped()
                        }

                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .font(AppPalette.appFont(.footnote, weight: .bold))
                            .foregroundStyle(isSelected ? tint : AppPalette.muted)
                            .frame(width: disclosureWidth)
                    }
                    .padding(.horizontal, AppPalette.spaceM)
                    .padding(.vertical, 10)
                    .frame(
                        width: max(0, geometry.size.width - alertControlWidth),
                        alignment: .leading
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                }
                .buttonStyle(.plain)

                Menu {
                    Button(action: onConfigureAlerts) {
                        Label(
                            activeAlertCount > 0 ? "编辑提醒" : "设置提醒",
                            systemImage: "bell"
                        )
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("取消关注", systemImage: "star.slash")
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: activeAlertCount > 0 ? "bell.fill" : "bell")
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        if triggeredAlertCount > 0 {
                            Circle()
                                .fill(AppPalette.warning)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -2)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(alertTint)
                .help(alertHelpText)
                .padding(.trailing, AppPalette.spaceM)
                .accessibilityLabel("\(row.displayName)，\(alertHelpText)")
            }
        }
        .frame(height: 58)
        .interactiveSurface(
            isSelected: isSelected,
            tint: tint,
            fill: AppPalette.cardStrong,
            hoverFill: AppPalette.cardHover,
            lift: AppPalette.hoverLift
        )
        .animation(AppPalette.motionStandard, value: isSelected)
        .accessibilityLabel("\(row.displayName)，\(isSelected ? "收起走势" : "展开走势")")
    }

    private var alertControlWidth: CGFloat {
        28 + AppPalette.spaceM + AppPalette.spaceS
    }

    private var disclosureWidth: CGFloat {
        14
    }

    private var alertHelpText: String {
        guard activeAlertCount > 0 else { return "设置价格提醒" }
        if triggeredAlertCount > 0 {
            return "\(activeAlertCount) 条提醒，\(triggeredAlertCount) 条已触发"
        }
        return "\(activeAlertCount) 条提醒正在监控"
    }

    private func watchlistValue(title: String, value: String, tint: Color) -> some View {
        LabeledValue(
            title: title,
            value: value,
            tint: tint,
            titleSize: .caption,
            titleLineLimit: 1,
            valueSize: .subheadline,
            spacing: 3,
            minimumScaleFactor: 0.75
        )
    }
}
