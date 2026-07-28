import SwiftUI

// MARK: - PlatformActionRow

struct PlatformActionRow: View {
    let action: PlatformActionPayload
    var isSelected: Bool = false
    var isCompact: Bool = false
    var showsCompactArticleLink: Bool = false
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
                    HStack(alignment: .center, spacing: 8) {
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
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(isBuy ? "买入" : "卖出")
                                .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                                .foregroundStyle(sideColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(sideColor.opacity(0.14), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(sideColor.opacity(0.22), lineWidth: 1)
                                )
                            if showsCompactArticleLink,
                               let article = action.articleUrl,
                               let url = URL(string: article) {
                                Link("打开平台原文", destination: url)
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.brand)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        compactMetricPill(title: "时间", value: compactDateText(action.txnDate ?? action.createdAt), tint: AppPalette.muted)
                        if action.isPercentBased {
                            compactMetricPill(title: "仓位", value: QiemanAlfaClient.percentText(before: action.beforePercent, after: action.afterPercent), tint: AppPalette.ink, isEmphasized: true)
                        } else {
                            compactMetricPill(title: "调仓", value: decimalText(action.tradeValuation), tint: AppPalette.ink)
                            compactMetricPill(title: "当前", value: decimalText(action.currentValuation), tint: AppPalette.ink)
                            compactMetricPill(title: "变化", value: percentText(action.valuationChangePct), tint: changeTint, isEmphasized: true)
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
                            Text(isBuy ? "买入" : "卖出")
                                .font(AppPalette.appFont(.subheadline, weight: .bold))
                                .foregroundStyle(sideColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(sideColor.opacity(0.14), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(sideColor.opacity(0.22), lineWidth: 1)
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

    @ViewBuilder
    private func compactMetricPill(title: String, value: String, tint: Color, isEmphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .medium, design: .rounded))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(isEmphasized ? .subheadline : .footnote, weight: isEmphasized ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}
