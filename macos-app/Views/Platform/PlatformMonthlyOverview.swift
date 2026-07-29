import SwiftUI
import Charts

// MARK: - PlatformMonthlyOverview

struct PlatformMonthlyOverview: View {
    let months: [PlatformMonthSummary]

    private var totalCount: Int {
        months.map(\.totalCount).reduce(0, +)
    }

    private var buyCount: Int {
        months.map(\.buyCount).reduce(0, +)
    }

    private var sellCount: Int {
        months.map(\.sellCount).reduce(0, +)
    }

    private var activeDays: Int {
        months.map(\.activeDays).reduce(0, +)
    }

    private var busiestMonth: PlatformMonthSummary? {
        months.max { left, right in
            if left.totalCount != right.totalCount {
                return left.totalCount < right.totalCount
            }
            return left.month < right.month
        }
    }

    private var averagePerMonthText: String {
        guard !months.isEmpty else { return "0.0" }
        return String(format: "%.1f", Double(totalCount) / Double(months.count))
    }

    private var historyRangeText: String {
        guard let first = months.first?.month, let last = months.last?.month else {
            return "暂无月份"
        }
        return first == last ? first : "\(first) — \(last)"
    }

    private var axisMonths: [String] {
        guard months.count > 12 else { return months.map(\.month) }
        let step = Int(ceil(Double(months.count) / 10.0))
        var values = stride(from: 0, to: months.count, by: step).map { months[$0].month }
        if let last = months.last?.month, values.last != last {
            values.append(last)
        }
        return values
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                summaryPanel
                    .frame(width: 270)
                monthChart
            }

            VStack(alignment: .leading, spacing: 12) {
                summaryPanel
                monthChart
            }
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(AppPalette.appFont(.title))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 38, height: 38)
                    .background(AppPalette.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(AppPalette.brand.opacity(0.22), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("完整历史")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(historyRangeText)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(totalCount)")
                    .font(AppPalette.appFont(.largeTitle, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                Text("笔")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
            }

            VStack(spacing: 8) {
                rhythmLine(title: "买入", value: buyCount, tint: AppPalette.positive)
                rhythmLine(title: "卖出", value: sellCount, tint: AppPalette.warning)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                SnapshotMiniBadge(text: "活跃 \(activeDays) 天", tint: AppPalette.info)
                SnapshotMiniBadge(text: "月均 \(averagePerMonthText) 笔", tint: AppPalette.brand)
                if let busiestMonth {
                    SnapshotMiniBadge(text: "最密 \(busiestMonth.month)", tint: AppPalette.accentWarm)
                    SnapshotMiniBadge(text: "\(busiestMonth.totalCount) 笔", tint: AppPalette.accentWarm)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.45), lineWidth: 1)
        )
    }

    @State private var selectedMonth: PlatformMonthSummary?
    @State private var hoverLocation: CGPoint = .zero

    private var monthChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartLegend
            chartBody
                .overlay { chartTooltip }
                .frame(height: 200)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.35), lineWidth: 1)
        )
    }

    private var chartLegend: some View {
        HStack(spacing: 12) {
            Label("买入", systemImage: "line.diagonal")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.positive)
            Label("卖出", systemImage: "line.diagonal")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
        }
    }

    private var chartBody: some View {
        Chart {
            ForEach(months) { month in
                LineMark(
                    x: .value("月", month.month),
                    y: .value("买入", month.buyCount),
                    series: .value("类型", "买入")
                )
                .foregroundStyle(AppPalette.positive)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                .symbol {
                    Circle()
                        .fill(AppPalette.positive)
                        .frame(width: 5, height: 5)
                }

                LineMark(
                    x: .value("月", month.month),
                    y: .value("卖出", month.sellCount),
                    series: .value("类型", "卖出")
                )
                .foregroundStyle(AppPalette.warning)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                .symbol {
                    Circle()
                        .fill(AppPalette.warning)
                        .frame(width: 5, height: 5)
                }
            }

            if let selectedMonth {
                RuleMark(x: .value("月", selectedMonth.month))
                    .foregroundStyle(AppPalette.line.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityLabel("完整历史调仓折线图")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let plotRect = geo[frame]
                            let relX = location.x - plotRect.origin.x
                            let relY = location.y - plotRect.origin.y
                            guard relX >= 0, relX <= plotRect.width, relY >= 0, relY <= plotRect.height else {
                                selectedMonth = nil
                                return
                            }
                            hoverLocation = location
                            if let xVal: String = proxy.value(atX: relX) {
                                selectedMonth = months.first { $0.month == xVal }
                            }
                        case .ended:
                            selectedMonth = nil
                        }
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(AppPalette.appFont(.caption, design: .rounded))
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppPalette.line.opacity(0.30))
            }
        }
        .chartXAxis {
            AxisMarks(values: axisMonths) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppPalette.line.opacity(0.18))
                if let month = value.as(String.self) {
                    AxisValueLabel {
                        Text(monthAxisLabel(month))
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
    }

    private func monthAxisLabel(_ month: String) -> String {
        guard month.count >= 7 else { return month }
        let year = String(month.prefix(4).suffix(2))
        let monthNumber = String(month.suffix(2))
        return "\(year)-\(monthNumber)"
    }

    private var chartTooltip: some View {
        GeometryReader { geo in
            if let m = selectedMonth {
                let tooltipWidth: CGFloat = 160
                let tooltipHeight: CGFloat = 60
                let tipX = min(max(hoverLocation.x + 12, 0), geo.size.width - tooltipWidth)
                let tipY = min(max(hoverLocation.y - tooltipHeight - 8, 0), geo.size.height - tooltipHeight)
                tooltipContent(month: m)
                    .frame(width: tooltipWidth, alignment: .leading)
                    .position(x: tipX + tooltipWidth / 2, y: tipY + tooltipHeight / 2)
                    .transition(.opacity)
                    .animation(AppPalette.motionFast, value: selectedMonth?.id)
            }
        }
    }

    @ViewBuilder
    private func tooltipContent(month m: PlatformMonthSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.month)
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            HStack(spacing: 8) {
                Text("买入 \(m.buyCount)")
                    .foregroundStyle(AppPalette.positive)
                Text("卖出 \(m.sellCount)")
                    .foregroundStyle(AppPalette.warning)
            }
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            Text("共 \(m.totalCount) 笔 · 活跃 \(m.activeDays) 天")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(AppPalette.spaceS)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.line.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    }

    private func rhythmLine(title: String, value: Int, tint: Color) -> some View {
        let ratio = totalCount > 0 ? Double(value) / Double(totalCount) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
            }
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .foregroundStyle(AppPalette.muted)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.cardStrong)
                    Capsule()
                        .fill(tint.opacity(0.70))
                        .frame(width: max(6, proxy.size.width * ratio))
                }
            }
            .frame(height: 7)
        }
    }
}
