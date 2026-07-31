import SwiftUI

// MARK: - PlatformActionRow

struct PlatformActionRow: View {
    let action: PlatformActionPayload
    var isSelected: Bool = false
    var isCompact: Bool = false
    var showsCompactArticleLink: Bool = false
    var showsFourColumnMetrics: Bool = false
    var titlePrefix: String = ""

    private var displayTitleWithPrefix: String {
        titlePrefix.isEmpty ? action.displayTitle : titlePrefix + action.displayTitle
    }

    private var isBuy: Bool { action.side == "buy" }
    private var sideColor: Color { isBuy ? AppPalette.positive : AppPalette.warning }
    private var changeTint: Color {
        AppPalette.marketTint(for: action.valuationChangePct)
    }

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [sideColor, sideColor.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isCompact ? 2 : 3)

            VStack(alignment: .leading, spacing: isCompact ? 6 : 6) {
                if isCompact {
                    if showsFourColumnMetrics {
                        compactFourColumnLayout
                    } else {
                        ViewThatFits(in: .horizontal) {
                            compactWideLayout
                            compactStackedLayout
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayTitleWithPrefix)
                                .font(AppPalette.appFont(.headline, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text("\(action.fundName ?? action.title ?? "未命名标的") · \(action.fundCode ?? "无代码")")
                                .font(AppPalette.appFont(.subheadline))
                                .foregroundStyle(AppPalette.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            TintedCapsuleBadge(
                                text: isBuy ? "买入" : "卖出",
                                tint: sideColor,
                                font: AppPalette.appFont(.subheadline, weight: .bold),
                                horizontalPadding: 9,
                                verticalPadding: 4
                            )
                            if let article = action.articleUrl, let url = URL(string: article) {
                                Link("打开平台原文", destination: url)
                                    .font(AppPalette.appFont(.footnote))
                                    .foregroundStyle(AppPalette.brand)
                            }
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 10) {
                        LabeledValue(title: "调仓时间", value: action.txnDate ?? action.createdAt ?? "未知")
                        if action.isPercentBased {
                            LabeledValue(title: "调仓前", value: QiemanAlfaClient.percentText(before: action.beforePercent, after: nil))
                            LabeledValue(title: "调仓后", value: QiemanAlfaClient.percentText(before: nil, after: action.afterPercent))
                            if let group = action.groupName {
                                LabeledValue(title: "分组", value: group)
                            }
                        } else {
                            LabeledValue(title: "调仓估值", value: decimalText(action.tradeValuation))
                            LabeledValue(title: "当前估值", value: decimalText(action.currentValuation))
                            LabeledValue(title: "变化", value: percentText(action.valuationChangePct), tint: changeTint)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 7 : 10)
        .interactiveSurface(
            isSelected: isSelected,
            tint: isSelected ? AppPalette.brand : sideColor,
            fill: AppPalette.card,
            hoverFill: AppPalette.cardHover,
            selectedFill: AppPalette.brand.opacity(0.12),
            strokeOpacity: 0.35,
            activeStrokeOpacity: 0.54,
            lift: isCompact ? 0.6 : 1
        )
    }

    private var compactIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitleWithPrefix)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .help(displayTitleWithPrefix)
            Text("\(action.fundName ?? action.title ?? "未命名标的") · \(action.fundCode ?? "无代码")")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }

    private var compactWideLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            compactIdentity
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .leading)

            compactWideMetrics

            Spacer(minLength: 8)
            compactActions
        }
    }

    private var compactStackedLayout: some View {
        VStack(alignment: .leading, spacing: 7) {
            compactHeader

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 7, alignment: .leading)],
                alignment: .leading,
                spacing: 7
            ) {
                compactMetricCells
            }
        }
    }

    private var compactFourColumnLayout: some View {
        VStack(alignment: .leading, spacing: 7) {
            compactHeader

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: 7, alignment: .leading),
                    count: 4
                ),
                alignment: .leading,
                spacing: 7
            ) {
                compactMetricCells
            }
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            compactIdentity
            Spacer(minLength: 8)
            compactActions
        }
    }

    @ViewBuilder
    private var compactMetricCells: some View {
        compactMetricCell(
            title: "调仓日期",
            value: compactDateText(action.txnDate ?? action.createdAt),
            tint: AppPalette.muted
        )
        if action.isPercentBased {
            compactMetricCell(
                title: "仓位变化",
                value: QiemanAlfaClient.percentText(before: action.beforePercent, after: action.afterPercent),
                tint: AppPalette.ink,
                isEmphasized: true
            )
        } else {
            compactMetricCell(title: "调仓估值", value: decimalText(action.tradeValuation), tint: AppPalette.ink)
            compactMetricCell(title: "当前估值", value: decimalText(action.currentValuation), tint: AppPalette.ink)
            compactMetricCell(
                title: "估值变化",
                value: percentText(action.valuationChangePct),
                tint: changeTint,
                isEmphasized: true
            )
        }
    }

    @ViewBuilder
    private var compactWideMetrics: some View {
        HStack(spacing: 0) {
            compactMetric(
                title: "调仓日期",
                value: compactDateText(action.txnDate ?? action.createdAt),
                tint: AppPalette.muted
            )
            .frame(width: 100, alignment: .leading)

            compactMetricDivider

            if action.isPercentBased {
                compactMetric(
                    title: "仓位变化",
                    value: QiemanAlfaClient.percentText(before: action.beforePercent, after: action.afterPercent),
                    tint: AppPalette.ink,
                    isEmphasized: true
                )
                .frame(width: 150, alignment: .leading)
            } else {
                compactMetric(title: "调仓估值", value: decimalText(action.tradeValuation), tint: AppPalette.ink)
                    .frame(width: 84, alignment: .leading)

                compactMetricDivider

                compactMetric(title: "当前估值", value: decimalText(action.currentValuation), tint: AppPalette.ink)
                    .frame(width: 84, alignment: .leading)

                compactMetricDivider

                compactMetric(
                    title: "估值变化",
                    value: percentText(action.valuationChangePct),
                    tint: changeTint,
                    isEmphasized: true
                )
                .frame(width: 84, alignment: .leading)
            }
        }
    }

    private var compactMetricDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var compactActions: some View {
        VStack(alignment: .trailing, spacing: 3) {
            TintedCapsuleBadge(
                text: isBuy ? "买入" : "卖出",
                tint: sideColor,
                font: AppPalette.appFont(.footnote, weight: .bold, design: .rounded),
                horizontalPadding: 8,
                verticalPadding: 3
            )
            if showsCompactArticleLink,
               let article = action.articleUrl,
               let url = URL(string: article) {
                Link(destination: url) {
                    Label("平台原文", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.brand)
                .help("打开平台原文")
            }
        }
    }

    private func decimalText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.4f", value)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", value)
    }

    private func compactDateText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未知" }
        if value.count >= 10 {
            return String(value.prefix(10))
        }
        return value
    }

    private func compactMetric(
        title: String,
        value: String,
        tint: Color,
        isEmphasized: Bool = false
    ) -> some View {
        LabeledValue(
            title: title,
            value: value,
            tint: tint,
            titleSize: .caption,
            titleWeight: .medium,
            valueSize: isEmphasized ? .subheadline : .footnote,
            valueWeight: isEmphasized ? .bold : .semibold,
            minimumScaleFactor: 0.72
        )
    }

    private func compactMetricCell(
        title: String,
        value: String,
        tint: Color,
        isEmphasized: Bool = false
    ) -> some View {
        compactMetric(title: title, value: value, tint: tint, isEmphasized: isEmphasized)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(AppPalette.paper.opacity(0.62), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        )
    }
}
