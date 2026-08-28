import SwiftUI

/// 点击标的条目弹出的 Sheet，展示完整的理由、触发/失效条件、依据。
struct NextHourGuidanceActionDetailSheet: View {
    let action: NextHourGuidanceAction
    let teamEvidence: [TrendEvidence]
    let evidence: [TrendEvidence]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 固定标题栏
            headerBar

            Divider()

            // 可滚动内容
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    // 操作说明
                    detailSection("操作说明", icon: "arrow.right.circle") {
                        Text(action.instruction)
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 结论(W4.4:一句话结论 + 为什么,与研判结论卡同构)
                    if !action.rationale.isEmpty {
                        let verdict = TrendVerdictPresentation.split(rationale: action.rationale)
                        detailSection("结论", icon: "questionmark.bubble") {
                            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                                Text(verdict.headline.isEmpty ? action.rationale : verdict.headline)
                                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !verdict.reasoning.isEmpty {
                                    Text(verdict.reasoning)
                                        .font(AppPalette.appFont(.subheadline))
                                        .foregroundStyle(AppPalette.muted)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    // 触发/失效条件
                    if !action.trigger.isEmpty || !action.invalidation.isEmpty {
                        detailSection("条件", icon: "scope") {
                            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                                conditionRow("触发", action.trigger, tint: AppPalette.info)
                                conditionRow("失效", action.invalidation, tint: AppPalette.warning)
                            }
                        }
                    }

                    NextHourGuidanceTeamInsightsView(evidence: teamEvidence)

                    // 判断依据
                    if !evidence.isEmpty {
                        detailSection("判断依据（\(evidence.count) 条）", icon: "doc.text.magnifyingglass") {
                            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                                ForEach(evidence) { ev in
                                    evidenceRow(ev)
                                }
                            }
                        }
                    }
                }
                .padding(AppPalette.spaceL)
            }
        }
        .frame(width: 600, height: 640)
    }

    // MARK: - 固定标题栏

    private var headerBar: some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(AppPalette.accentFill), in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.targetName)
                        .font(AppPalette.appFont(.headline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(action.action.displayName)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(tint)
                }
                HStack(spacing: AppPalette.spaceS) {
                    TintedCapsuleBadge(
                        text: "把握 \(confidenceLabel) \(action.confidence)",
                        tint: confidenceColor,
                        font: AppPalette.appFont(.footnote, weight: .bold),
                        horizontalPadding: 8, verticalPadding: 3
                    )
                    if !action.evidenceIDs.isEmpty {
                        TintedCapsuleBadge(
                            text: "依据 \(action.evidenceIDs.count) 条",
                            tint: AppPalette.info,
                            font: AppPalette.appFont(.footnote, weight: .bold),
                            horizontalPadding: 8, verticalPadding: 3
                        )
                    }
                }
            }
            Spacer()
            Button("关闭盘中指引详情", systemImage: "xmark.circle.fill", action: close)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(AppPalette.muted)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
    }

    // MARK: - 辅助

    private func close() {
        dismiss()
    }

    private var tint: Color {
        switch action.action {
        case .buy, .buySmall:
            AppPalette.marketGain
        case .sell, .reduceSmall:
            AppPalette.marketLoss
        case .hold, .watch, .wait, .avoidChasing:
            AppPalette.info
        }
    }

    private var confidenceLabel: String {
        switch action.confidence {
        case 85...:
            "很高"
        case 70...:
            "较高"
        case 55...:
            "中等"
        default:
            "偏低"
        }
    }

    private var confidenceColor: Color {
        switch action.confidence {
        case 70...:
            AppPalette.positive
        case 55...:
            AppPalette.info
        default:
            AppPalette.warning
        }
    }

    private func detailSection<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label(title, systemImage: icon)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            content()
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private func conditionRow(_ title: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 证据行：根据来源类型用不同图标和颜色，不套额外卡片层。
    private func evidenceRow(_ item: TrendEvidence) -> some View {
        let (icon, iconColor) = evidenceIcon(for: item)
        return HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.summary)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlFill.opacity(0.5), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    /// 根据证据来源类型返回图标和颜色。
    private func evidenceIcon(for item: TrendEvidence) -> (String, Color) {
        let source = item.sourceName
        if source.contains("行情") {
            return ("chart.line.uptrend.xyaxis", AppPalette.brand)
        } else if source.contains("新闻") {
            return ("newspaper", AppPalette.info)
        } else if source.contains("持仓") {
            return ("chart.pie.fill", AppPalette.positive)
        } else if source.contains("官方") || source.contains("SEC") {
            return ("doc.text.fill", AppPalette.warning)
        } else {
            return ("link", AppPalette.muted)
        }
    }
}
