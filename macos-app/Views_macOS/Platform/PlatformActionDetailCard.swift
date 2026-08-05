import SwiftUI

// MARK: - PlatformActionDetailCard

struct PlatformActionDetailCard: View {
    let action: PlatformActionPayload

    private var isBuy: Bool {
        let raw = (action.side ?? action.action ?? action.actionTitle ?? "").lowercased()
        return raw.contains("buy") || raw.contains("买")
    }

    private var sideText: String { isBuy ? "买入" : "卖出" }
    private var sideColor: Color { isBuy ? AppPalette.positive : AppPalette.warning }
    private var changeTint: Color {
        AppPalette.marketTint(for: action.valuationChangePct ?? action.valuationChangeAmount)
    }

    private var fundIdentityText: String {
        let name = action.fundName ?? action.title ?? "未命名标的"
        guard let code = action.fundCode, !code.isEmpty else { return name }
        return "\(name) · \(code)"
    }

    private var compactActionDateText: String {
        let raw = action.txnDate ?? action.createdAt ?? "未知时间"
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }

    private var actionDescriptionText: String? {
        let comment = action.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return comment.isEmpty ? nil : comment
    }

    private var sourceSummaryText: String? {
        let sources = [action.tradeValuationSource, action.currentValuationSource]
            .compactMap { source -> String? in
                let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .reduce(into: [String]()) { result, source in
                if !result.contains(source) {
                    result.append(source)
                }
            }
        guard !sources.isEmpty else { return nil }
        return "数据来源：\(sources.joined(separator: " · "))"
    }

    private var articleURL: URL? {
        guard let article = action.articleUrl else { return nil }
        return URL(string: article)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                    .fill(
                        LinearGradient(
                            colors: [sideColor, sideColor.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 4, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(action.displayTitle)
                            .font(AppPalette.appFont(.title, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        TintedCapsuleBadge(
                            text: sideText,
                            tint: sideColor,
                            font: AppPalette.appFont(.subheadline, weight: .bold),
                            horizontalPadding: 9,
                            verticalPadding: 4
                        )
                    }

                    Text("\(fundIdentityText) · \(compactActionDateText)")
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 116), spacing: 10),
                    count: 3
                ),
                spacing: 10
            ) {
                if action.isPercentBased {
                    detailMetric("调仓前", QiemanAlfaClient.percentText(before: action.beforePercent, after: nil), tint: AppPalette.ink)
                    detailMetric("调仓后", QiemanAlfaClient.percentText(before: nil, after: action.afterPercent), tint: AppPalette.ink)
                    detailMetric("仓位变化", percentChangeText(before: action.beforePercent, after: action.afterPercent), tint: changeTint)
                    detailMetric("动作", action.action ?? "调整", tint: sideColor)
                    if let group = action.groupName {
                        detailMetric("分组", group, tint: AppPalette.ink)
                    }
                } else {
                    detailMetric("调仓估值", decimalOptional(action.tradeValuation), tint: AppPalette.ink)
                    detailMetric("当前估值", decimalOptional(action.currentValuation), tint: AppPalette.ink)
                    detailMetric("估值变化", percentOptional(action.valuationChangePct), tint: changeTint)
                    detailMetric("变化金额", signedCurrencyText(action.valuationChangeAmount), tint: changeTint)
                    detailMetric("计划份数", action.postPlanUnit.map(String.init) ?? "—", tint: AppPalette.ink)
                    detailMetric("交易份数", action.tradeUnit.map(String.init) ?? "—", tint: AppPalette.ink)
                }
            }

            if let actionDescriptionText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("调仓说明")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    Text(actionDescriptionText)
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(AppPalette.cardStrong.opacity(0.55), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }

            if sourceSummaryText != nil || articleURL != nil {
                Divider()
                    .overlay(AppPalette.line.opacity(0.35))

                HStack(spacing: 10) {
                    if let sourceSummaryText {
                        Label(sourceSummaryText, systemImage: "info.circle")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                            .help(sourceSummaryText)
                    }

                    Spacer(minLength: 8)

                    if let articleURL {
                        Link(destination: articleURL) {
                            Label("平台原文", systemImage: "arrow.up.right.square")
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                .foregroundStyle(AppPalette.brand)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.45), lineWidth: 1)
        )
    }

    private func detailMetric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.title3, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }

    /// 百分比调仓的仓位变化（before→after 的差值，百分点）。
    private func percentChangeText(before: Double?, after: Double?) -> String {
        guard let before, let after else { return "—" }
        let diff = (after - before) * 100
        return String(format: "%+.2f%%", diff)
    }

}
