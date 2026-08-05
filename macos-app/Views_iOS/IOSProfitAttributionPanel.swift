#if os(iOS)
import SwiftUI

// MARK: - iOS 收益归因面板
//
// 复用 Core 的 `ProfitAttributionSummary`（纯函数派生）。
// iPhone 单列：headline + 顶部指标卡（总收益/收益率/覆盖/待确认/下次计划）+ 贡献/拖累分组列表。
// 涨跌色遵循中国股市惯例（红涨绿跌）。

struct IOSProfitAttributionPanel: View {
    let summary: ProfitAttributionSummary

    private var gainEntries: [ProfitAttributionEntry] {
        summary.entries.filter { $0.kind == .gain }.sorted { abs($0.amountValue) > abs($1.amountValue) }
    }

    private var dragEntries: [ProfitAttributionEntry] {
        summary.entries.filter { $0.kind == .drag }.sorted { abs($0.amountValue) > abs($1.amountValue) }
    }

    private var neutralEntries: [ProfitAttributionEntry] {
        summary.entries.filter { $0.kind == .neutral }
    }

    var body: some View {
        IOSSectionCard(title: "收益归因", subtitle: summary.headline, icon: "chart.pie") {
            VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                metricsGrid

                if summary.entries.isEmpty {
                    Text("等待收益数据")
                        .font(IOSDesign.sansBody(14, weight: .semibold))
                        .foregroundStyle(IOSDesign.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, IOSDesign.spaceM)
                } else {
                    if !gainEntries.isEmpty {
                        entryGroup(title: "主要贡献", icon: "arrow.up.circle.fill", tone: .positive, entries: gainEntries)
                    }
                    if !dragEntries.isEmpty {
                        entryGroup(title: "主要拖累", icon: "arrow.down.circle.fill", tone: .negative, entries: dragEntries)
                    }
                    if !neutralEntries.isEmpty {
                        entryGroup(title: "基本持平", icon: "minus.circle", tone: .neutral, entries: neutralEntries)
                    }
                }
            }
        }
    }

    // MARK: 顶部指标 2×3 网格

    private var metricsGrid: some View {
        let totalTone = marketTone(for: summary.totalProfitValue)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
            IOSStatTile(title: "总收益", value: summary.totalProfitText, tone: totalTone)
            IOSStatTile(title: "总收益率", value: summary.totalProfitRateText, tone: totalTone)
            IOSStatTile(title: "收益覆盖", value: summary.coverageText, tone: .neutral)
            IOSStatTile(title: "待确认", value: summary.pendingExposureText, tone: .neutral)
        }
    }

    // MARK: 分组列表

    private func entryGroup(title: String, icon: String, tone: IOSStatTile.StatTone, entries: [ProfitAttributionEntry]) -> some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone.color)
                Text(title)
                    .font(IOSDesign.sansBody(13, weight: .semibold))
                    .foregroundStyle(IOSDesign.muted)
            }
            ForEach(entries) { entry in
                entryRow(entry, tone: tone)
            }
        }
    }

    private func entryRow(_ entry: ProfitAttributionEntry, tone: IOSStatTile.StatTone) -> some View {
        HStack(alignment: .top, spacing: IOSDesign.spaceS) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(IOSDesign.sansBody(14, weight: .medium))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(1)
                HStack(spacing: IOSDesign.spaceXS) {
                    Text(entry.codeText)
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                    Text("影响 \(entry.impactShareText)")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.amountText)
                    .font(IOSDesign.monoNumber(14))
                    .foregroundStyle(tone.color)
                Text(entry.rateText)
                    .font(IOSDesign.monoNumber(12, weight: .medium))
                    .foregroundStyle(tone.color)
            }
        }
        .padding(.vertical, IOSDesign.spaceXS)
    }
}
#endif
