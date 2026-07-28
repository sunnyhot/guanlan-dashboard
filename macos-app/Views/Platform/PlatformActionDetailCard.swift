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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
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
                        Text(sideText)
                            .font(AppPalette.appFont(.subheadline, weight: .bold))
                            .foregroundStyle(sideColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(sideColor.opacity(0.14), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(sideColor.opacity(0.22), lineWidth: 1)
                            )
                    }

                    Text("\(action.fundName ?? action.title ?? "未命名标的") · \(action.fundCode ?? "无代码")")
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()
            }

            Label("调仓概览", systemImage: "rectangle.grid.2x2")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.info)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 116), spacing: 10),
                    count: 4
                ),
                spacing: 10
            ) {
                detailMetric("调仓时间", action.txnDate ?? action.createdAt ?? "未知", tint: AppPalette.ink)
                if action.isPercentBased {
                    detailMetric("调仓前", QiemanAlfaClient.percentText(before: action.beforePercent, after: nil), tint: AppPalette.ink)
                    detailMetric("调仓后", QiemanAlfaClient.percentText(before: nil, after: action.afterPercent), tint: AppPalette.ink)
                    detailMetric("仓位变化", percentChangeText(before: action.beforePercent, after: action.afterPercent), tint: changeTint)
                    detailMetric("动作", action.action ?? "调整", tint: sideColor)
                    if let group = action.groupName {
                        detailMetric("分组", group, tint: AppPalette.ink)
                    }
                    detailMetric("调仓单", action.adjustmentId.map(String.init) ?? "—", tint: AppPalette.ink)
                } else {
                    detailMetric("调仓估值", decimalOptional(action.tradeValuation), tint: AppPalette.ink)
                    detailMetric("当前估值", decimalOptional(action.currentValuation), tint: AppPalette.ink)
                    detailMetric("估值变化", percentOptional(action.valuationChangePct), tint: changeTint)
                    detailMetric("变化金额", signedCurrencyText(action.valuationChangeAmount), tint: changeTint)
                    detailMetric("计划份数", action.postPlanUnit.map(String.init) ?? "—", tint: AppPalette.ink)
                    detailMetric("交易份数", action.tradeUnit.map(String.init) ?? "—", tint: AppPalette.ink)
                    detailMetric("净值", decimalOptional(action.nav), tint: AppPalette.ink)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("来源与记录", systemImage: "doc.text.magnifyingglass")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.info)

                if let comment = action.comment, !comment.isEmpty {
                    Text(comment)
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WrapLine(items: [
                    sourceText("调仓估值", source: action.tradeValuationSource, date: action.tradeValuationDate),
                    sourceText("当前估值", source: action.currentValuationSource, date: action.currentValuationTime),
                    action.navDate.map { "净值日期 \($0)" },
                    action.adjustmentId.map { "调仓单 \($0)" },
                    action.orderCountInAdjustment.map { "同单动作 \($0)" }
                ].compactMap { $0 })

                if let article = action.articleUrl, let url = URL(string: article) {
                    Link(destination: url) {
                        Label("打开平台原文", systemImage: "arrow.up.right.square")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.brand)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppPalette.cardStrong.opacity(0.58), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                    .stroke(AppPalette.line.opacity(0.28), lineWidth: 1)
            )
        }
        .padding(14)
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

    private func sourceText(_ title: String, source: String?, date: String?) -> String? {
        let parts = [source, date].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !parts.isEmpty else { return nil }
        return "\(title)：\(parts.joined(separator: " · "))"
    }
}

// MARK: - WrapLine

struct WrapLine: View {
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    chips
                }

                VStack(alignment: .leading, spacing: 6) {
                    chips
                }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(items, id: \.self) { item in
            Text(item)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppPalette.cardStrong.opacity(0.60), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                        .stroke(AppPalette.line.opacity(AppPalette.borderSubtle), lineWidth: 1)
                )
        }
    }
}
