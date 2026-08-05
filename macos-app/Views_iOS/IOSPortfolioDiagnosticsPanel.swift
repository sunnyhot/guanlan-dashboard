#if os(iOS)
import SwiftUI

// MARK: - iOS 组合诊断面板
//
// 复用 Core 的 `PortfolioDiagnosticsSummary`（纯函数派生，零 UI 依赖）。
// iPhone 单列布局：headline + 5 张诊断卡（集中度/待确认/计划覆盖/今日波动/估值覆盖）。
// 对齐 macOS `PortfolioDiagnosticsPanel` 的信息密度，但用 `IOSDesign` 杂志型排版。

struct IOSPortfolioDiagnosticsPanel: View {
    let summary: PortfolioDiagnosticsSummary

    var body: some View {
        IOSSectionCard(title: "组合诊断", subtitle: summary.headline, icon: "stethoscope") {
            VStack(spacing: IOSDesign.spaceS) {
                ForEach(summary.items) { item in
                    IOSDiagnosticTile(item: item)
                }
            }
        }
    }
}

// MARK: - 诊断项卡片

private struct IOSDiagnosticTile: View {
    let item: PortfolioDiagnosticItem

    private var iconName: String {
        switch item.kind {
        case .concentration:       return "scope"
        case .pendingExposure:     return "clock.badge.exclamationmark"
        case .planCoverage:        return "calendar.badge.clock"
        case .dailyMovement:       return "waveform.path.ecg"
        case .quoteCoverage:       return "dot.radiowaves.left.and.right"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: IOSDesign.spaceS) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(levelColor)
                .frame(width: 30, height: 30)
                .background(levelColor.opacity(0.10), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: IOSDesign.spaceS) {
                    Text(item.title)
                        .font(IOSDesign.sansBody(15, weight: .semibold))
                        .foregroundStyle(IOSDesign.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(item.metric)
                        .font(IOSDesign.monoNumber(15))
                        .foregroundStyle(levelColor)
                        .lineLimit(1)
                }
                Text(item.detail)
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                IOSTintedBadge(text: levelLabel, tone: levelTone)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IOSDesign.spaceS)
        .background(IOSDesign.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: 等级 → 颜色/标签（中国股市惯例：风险/留意用暖警示色，正常用品牌色）

    private var levelColor: Color {
        switch item.level {
        case .risk:  return AppPalette.danger
        case .watch: return AppPalette.warning
        case .info:  return AppPalette.info
        case .good:  return AppPalette.positive
        }
    }

    private var levelLabel: String {
        switch item.level {
        case .risk:  return "风险"
        case .watch: return "留意"
        case .info:  return "观察"
        case .good:  return "正常"
        }
    }

    private var levelTone: IOSStatTile.StatTone {
        switch item.level {
        case .risk:  return .negative
        case .watch: return .negative
        case .info:  return .neutral
        case .good:  return .positive
        }
    }
}
#endif
