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
    var trendSummary: TrendAssetTagSummary?

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

                    if let trendSummary {
                        trendAnalysisSection(trendSummary)
                    }
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
                            RoundedRectangle(cornerRadius: 2)
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

    private func trendAnalysisSection(_ summary: TrendAssetTagSummary) -> some View {
        detailSection(title: "AI 观点", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                trendDecisionHeader(summary)

                Divider()
                    .overlay(AppPalette.line.opacity(0.46))

                HStack(alignment: .top, spacing: 14) {
                    trendActionBlock(summary.tradePlan)
                    trendEvidenceBlock(summary)
                }

                let invalidationConditions = trendInvalidationConditions(summary)
                if !invalidationConditions.isEmpty {
                    Divider()
                        .overlay(AppPalette.line.opacity(0.46))
                    trendInvalidationBlock(invalidationConditions)
                }
            }
        }
    }

    private func trendDecisionHeader(_ summary: TrendAssetTagSummary) -> some View {
        let tone = summary.primaryDirection?.assetTagTone ?? summary.tradePlan.tone
        let accent = tone.detailAccentColor

        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text("当前判断")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                HStack(spacing: 7) {
                    Text(
                        summary.primaryDirection.map(TrendPlainLanguage.direction)
                            ?? TrendPlainLanguage.actionLabel(summary.tradePlan.label)
                    )
                        .font(AppPalette.appFont(.title3, weight: .bold))
                        .foregroundStyle(accent)
                    Text(TrendPlainLanguage.confidence(summary.primaryConfidence))
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                }
                Text(TrendPlainLanguage.sentence(summary.impactText))
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("数据截至 \(summary.dataAsOf)")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
        }
    }

    private func trendActionBlock(_ plan: TrendAssetTradePlan) -> some View {
        let accent = plan.tone.detailAccentColor

        return VStack(alignment: .leading, spacing: 10) {
            Label("操作建议", systemImage: "arrow.left.arrow.right.circle.fill")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(accent)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TrendPlainLanguage.actionLabel(plan.label))
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(accent)
                Text("·")
                    .foregroundStyle(AppPalette.muted)
                Text(TrendPlainLanguage.actionMethod(plan.method))
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
            }

            Text(TrendPlainLanguage.sentence(plan.detail))
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            if !plan.triggerConditions.isEmpty {
                Divider()
                    .overlay(AppPalette.line.opacity(0.38))
                trendConditionList(
                    title: "执行前确认",
                    items: Array(plan.triggerConditions.prefix(3)),
                    tint: accent
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 174, maxHeight: .infinity, alignment: .topLeading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func trendEvidenceBlock(_ summary: TrendAssetTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("判断依据", systemImage: "list.bullet.clipboard")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.info)

            Text(trendEvidenceTitle(summary))
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(trendEvidenceDetails(summary), id: \.self) { detail in
                    Text(detail)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 174, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.cardStrong.opacity(0.52), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private func trendEvidenceTitle(_ summary: TrendAssetTagSummary) -> String {
        if let horizon = primaryEvidenceHorizon(summary), !horizon.rationale.isEmpty {
            return TrendPlainLanguage.headline(horizon.rationale)
        }
        if !summary.rationale.isEmpty {
            return TrendPlainLanguage.headline(summary.rationale)
        }
        return "暂时没有足够信息"
    }

    private func trendEvidenceDetails(_ summary: TrendAssetTagSummary) -> [String] {
        let title = trendEvidenceTitle(summary)
        var details: [String] = []

        if !summary.rationale.isEmpty,
           TrendPlainLanguage.headline(summary.rationale) != title {
            details.append(TrendPlainLanguage.sentence(summary.rationale))
        }

        if let horizon = primaryEvidenceHorizon(summary) {
            details.append(
                TrendPlainLanguage.outlookSentence(
                    horizon: horizon.horizon,
                    direction: horizon.direction,
                    confidence: horizon.confidence
                )
            )
        }
        return details
    }

    private func primaryEvidenceHorizon(_ summary: TrendAssetTagSummary) -> TrendHorizonView? {
        summary.horizons.first(where: { $0.horizon == .short }) ?? summary.horizons.first
    }

    private func trendConditionList(title: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(TrendPlainLanguage.sentence(item))
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendInvalidationBlock(_ conditions: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
                .frame(width: 28, height: 28)
                .background(AppPalette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

            VStack(alignment: .leading, spacing: 7) {
                Text("什么情况下改变判断")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                Text("出现以下任一情况，需要重新评估上面的结论。")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(conditions, id: \.self) { condition in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(AppPalette.warning)
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(TrendPlainLanguage.sentence(condition))
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.ink.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(AppPalette.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private func trendInvalidationConditions(_ summary: TrendAssetTagSummary) -> [String] {
        var seen = Set<String>()
        return (summary.tradePlan.invalidatingConditions + summary.counterSignals).compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.replacingOccurrences(of: "。", with: "")
            guard !value.isEmpty, seen.insert(key).inserted else { return nil }
            return value
        }
        .prefix(4)
        .map(\.self)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.body, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
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

private extension TrendAssetTagTone {
    var detailAccentColor: Color {
        self == .muted ? AppPalette.info : color
    }

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
