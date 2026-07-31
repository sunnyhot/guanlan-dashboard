#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判页
//
// 完整版趋势报告:状态/风险标签 + 标题详情 + 周期研判 + 板块研判 + 操作按钮。
// 复用 trendDashboardSummary 和 startTrendAnalysis。

struct EnhancementSectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let summary = model.trendDashboardSummary
                statusCard(summary)
                if !summary.horizons.isEmpty {
                    horizonsCard(summary)
                }
                if !summary.sectors.isEmpty {
                    sectorsCard(summary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            try? await model.refreshLatest(persist: false)
        }
    }

    private func statusCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "AI 趋势研判", subtitle: summary.dataAsOf ?? "尚未生成", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IOSTintedBadge(text: summary.stateText, tone: .neutral)
                    if summary.riskLevel != nil, !summary.riskText.isEmpty {
                        IOSTintedBadge(text: summary.riskText, tone: trendToneToStat(summary.riskTone))
                    }
                    Spacer()
                }
                Text(summary.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let generated = summary.generatedAt {
                    Text("生成于 \(generated)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                }
                actionButtons(summary)
            }
        }
    }

    private func actionButtons(_ summary: TrendDashboardSummary) -> some View {
        VStack(spacing: 8) {
            Button {
                handleTrendAction(summary.primaryAction)
            } label: {
                Label(summary.primaryAction.title, systemImage: summary.primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(trendToneColor(summary.primaryAction.tone))
            .disabled(summary.primaryAction.isDisabled)

            if let secondary = summary.secondaryAction {
                Button {
                    handleTrendAction(secondary)
                } label: {
                    Label(secondary.title, systemImage: secondary.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(trendToneColor(secondary.tone))
                .disabled(secondary.isDisabled)
            }
        }
    }

    private func horizonsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "周期研判", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.horizons) { horizon in
                    trendRow(
                        title: horizon.title,
                        direction: horizon.directionText,
                        rationale: horizon.rationale,
                        tone: horizon.tone
                    )
                }
            }
        }
    }

    private func sectorsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "板块研判", icon: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.sectors) { sector in
                    trendRow(
                        title: sector.name,
                        direction: sector.directionText,
                        rationale: sector.rationale,
                        tone: sector.tone
                    )
                }
            }
        }
    }

    private func trendRow(title: String, direction: String, rationale: String, tone: TrendDashboardTone) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(trendToneColor(tone))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    Text(direction)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trendToneColor(tone))
                }
                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func handleTrendAction(_ action: TrendDashboardAction) {
        // 主要操作(如生成/重新生成)直接触发,其他跳转
        Task {
            await model.startTrendAnalysis(userInitiated: true)
        }
    }
}

// MARK: - TrendDashboardTone → 颜色(iOS 版)
// (定义在 OverviewSectionView.swift 同 module,这里为 AI 研判页复用)
// 注意:OverviewSectionView.swift 里的 trendToneToColor 是 file-private 函数,
// 这里提供 module 内可访问的版本。

func trendToneColor(_ tone: TrendDashboardTone) -> Color {
    switch tone {
    case .brand: return AppPalette.brand
    case .positive: return AppPalette.marketGain
    case .info: return AppPalette.info
    case .warning: return AppPalette.warning
    case .danger: return AppPalette.marketLoss
    case .muted: return AppPalette.muted
    }
}

func trendToneToStat(_ tone: TrendDashboardTone) -> IOSStatTile.StatTone {
    switch tone {
    case .positive: return .positive
    case .danger: return .negative
    default: return .neutral
    }
}
#endif
