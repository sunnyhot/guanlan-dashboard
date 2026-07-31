#if os(iOS)
import SwiftUI

// MARK: - iOS 持仓详情 Sheet
//
// 复用 Core 层 PersonalAssetDetailSummary.make(row:) 的跨平台计算,
// 用 iPhone 友好的 sheet 布局展示基金详情(估值/收益/待确认/计划)。

struct IOSPersonalAssetDetailSheet: View {
    let row: PersonalAssetAggregateRow
    @Environment(\.dismiss) private var dismiss

    private var summary: PersonalAssetDetailSummary {
        PersonalAssetDetailSummary.make(row: row)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    metricsSection
                    attentionSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(summary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                if let code = summary.codeText {
                    Text(code)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let market = summary.marketText {
                    IOSTintedBadge(text: market, tone: .neutral)
                }
                if !summary.statusText.isEmpty {
                    Text(summary.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            Text(summary.effectiveAmountText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSDesign.accent)
                .padding(.top, 4)
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("核心指标")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(summary.metrics.enumerated()), id: \.offset) { _, metric in
                    metricTile(metric)
                }
            }
        }
    }

    private func metricTile(_ metric: PersonalAssetDetailMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.muted)
            Text(metric.value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(metricColor(metric.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = metric.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    // MARK: - 关注项(计划/待确认提醒)

    private var attentionSection: some View {
        Group {
            if !summary.attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("持仓提醒")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(Array(summary.attentionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(AppPalette.warning)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppPalette.ink)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppPalette.muted)
                                }
                            }
                            Spacer()
                            if !item.metric.isEmpty {
                                Text(item.metric)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppPalette.warning)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 辅助

    private func metricColor(_ tone: PersonalAssetDetailTone) -> Color {
        switch tone {
        case .neutral: return AppPalette.ink
        case .marketGain: return AppPalette.marketGain
        case .marketLoss: return AppPalette.marketLoss
        case .warning: return AppPalette.warning
        case .info: return AppPalette.info
        case .brand: return AppPalette.brand
        case .muted: return AppPalette.muted
        }
    }
}
#endif
