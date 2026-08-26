import SwiftUI

private extension PersonalAssetDetailTone {
    var color: Color {
        switch self {
        case .brand:
            return AppPalette.brand
        case .info:
            return AppPalette.info
        case .warning:
            return AppPalette.warning
        case .neutral:
            return AppPalette.ink
        case .muted:
            return AppPalette.muted
        case .marketGain:
            return AppPalette.marketGain
        case .marketLoss:
            return AppPalette.marketLoss
        }
    }
}

private enum AssetDetailLayout {
    static let sheetWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 620
    static let idealHeight: CGFloat = 720
    static let maximumHeight: CGFloat = 780
    static let secondaryColumnWidth: CGFloat = 292
}

struct PersonalAssetDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow

    private var summary: PersonalAssetDetailSummary {
        PersonalAssetDetailSummary.make(row: row)
    }

    var body: some View {
        let summary = summary

        VStack(spacing: 0) {
            header(summary)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    detailMetricStrip(summary.metrics)

                    PersonalAssetPriceTrendChart(row: row)

                    supportingSections(summary.attentionItems)

                    PortfolioValuationAlertSection(row: row)
                }
                .padding(16)
            }
        }
        .frame(width: AssetDetailLayout.sheetWidth)
        .frame(
            minHeight: AssetDetailLayout.minimumHeight,
            idealHeight: AssetDetailLayout.idealHeight,
            maxHeight: AssetDetailLayout.maximumHeight
        )
        .background(AppPalette.surface)
    }

    private func header(_ summary: PersonalAssetDetailSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: row.assetType == .stock ? "chart.line.uptrend.xyaxis" : "chart.pie")
                .font(AppPalette.appFont(.title, weight: .semibold))
                .foregroundStyle(row.assetType == .stock ? AppPalette.info : AppPalette.brand)
                .frame(width: 44, height: 44)
                .background((row.assetType == .stock ? AppPalette.info : AppPalette.brand).opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.title)
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let codeText = summary.codeText, !codeText.isEmpty {
                        Text(codeText)
                            .font(AppPalette.appFont(.footnote, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                    }
                    if let marketText = summary.marketText {
                        ToolbarBadge(title: marketText, tint: AppPalette.info)
                    }
                    ToolbarBadge(title: summary.statusText, tint: row.hasPending ? AppPalette.warning : AppPalette.brand)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(summary.effectiveAmountText)
                        .font(AppPalette.appFont(.largeTitle, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(
                        row.holdingUnits.map { "总持仓 · \(unitsText($0)) 份" }
                            ?? "总持仓"
                    )
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(AppPalette.appFont(.subheadline, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.appIcon)
                .foregroundStyle(AppPalette.muted)
                .help("关闭")
                .accessibilityLabel("关闭资产详情")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(AppPalette.card, in: Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line.opacity(0.42))
                .frame(height: 1)
        }
    }

    private func detailMetricStrip(_ metrics: [PersonalAssetDetailMetric]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                detailMetric(metric)
                if index < metrics.count - 1 {
                    Divider()
                        .frame(height: 46)
                        .overlay(AppPalette.line.opacity(0.46))
                }
            }
        }
        .padding(.vertical, 8)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.32)
    }

    private func detailMetric(_ metric: PersonalAssetDetailMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(metric.title)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(metric.value)
                .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                .foregroundStyle(metric.tone.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.64)
            if let detail = metric.detail, !detail.isEmpty {
                Text(detail)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                .minimumScaleFactor(0.70)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .padding(.horizontal, 10)
    }

    private func attentionSection(_ items: [PersonalAssetDetailAttentionItem]) -> some View {
        detailSection(title: "待处理事项", icon: "list.bullet.rectangle") {
            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(AppPalette.appFont(.title3, weight: .semibold))
                        .foregroundStyle(AppPalette.positive)
                    Text("暂无买入中、进行中计划或归档提醒")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .padding(12)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .center, spacing: 10) {
                            RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                                .fill(item.tone.color)
                                .frame(width: 3, height: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(AppPalette.appFont(.body, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                Text(item.detail.isEmpty ? "暂无附加信息" : item.detail)
                                    .font(AppPalette.appFont(.footnote))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.metric)
                                .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                                .foregroundStyle(item.tone.color)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .padding(12)
                        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                    }
                }
            }
        }
    }

    private func supportingSections(_ items: [PersonalAssetDetailAttentionItem]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                attentionSection(items)
                    .frame(maxWidth: .infinity, alignment: .top)
                sourceSection
                    .frame(width: AssetDetailLayout.secondaryColumnWidth, alignment: .top)
            }

            VStack(spacing: 14) {
                attentionSection(items)
                sourceSection
            }
        }
    }

    private var sourceSection: some View {
        detailSection(title: "本地记录", icon: "tray.full") {
            HStack(spacing: 10) {
                compactFact(title: "持仓", value: row.hasHolding ? "已记录" : (row.hasArchivedHolding ? "已归档" : "暂无"), tint: row.hasHolding ? AppPalette.brand : AppPalette.muted)
                compactFact(title: "买入中", value: "\(row.pendingTradeCount) 笔", tint: row.pendingTradeCount > 0 ? AppPalette.warning : AppPalette.muted)
                compactFact(title: "计划", value: "\(row.activePlanCount) / \(row.pausedPlanCount) / \(row.endedPlanCount)", tint: row.totalPlanCount > 0 ? AppPalette.info : AppPalette.muted)
            }
        }
    }

    private func compactFact(title: String, value: String, tint: Color) -> some View {
        LabeledValue(
            title: title,
            value: value,
            tint: tint,
            valueWeight: .semibold,
            valueDesign: .rounded,
            spacing: 4,
            minimumScaleFactor: 0.72
        )
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.28)
    }

    private func detailSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .accentIconStyle(tint: AppPalette.brand, size: 22)
                Text(title)
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(AppPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke(opacity: 0.36)
    }
}
