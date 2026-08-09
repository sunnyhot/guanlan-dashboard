import Charts
import SwiftUI

struct PersonalWatchlistDetailChart: View {
    let row: PersonalWatchlistQuoteRow

    @State private var range: PersonalWatchlistChartRange = .ninety
    @State private var hoveredPoint: PersonalWatchlistChartPoint?
    @State private var hoverLocation: CGPoint = .zero

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var allChartPoints: [PersonalWatchlistChartPoint] {
        row.dailyPoints.compactMap { point in
            guard let date = Self.dateFormatter.date(from: point.date) else { return nil }
            return PersonalWatchlistChartPoint(
                date: date,
                dateText: point.date,
                price: point.price
            )
        }
    }

    private var chartPoints: [PersonalWatchlistChartPoint] {
        guard let limit = range.pointLimit else { return allChartPoints }
        return Array(allChartPoints.suffix(limit))
    }

    private var changeTint: Color {
        AppPalette.marketTint(for: row.changeSinceFollowPct)
    }

    private var yDomain: ClosedRange<Double> {
        let prices = chartPoints.map(\.price) + [row.record.baseline?.price].compactMap { $0 }
        guard let minimum = prices.min(), let maximum = prices.max() else { return 0...1 }
        let spread = max(maximum - minimum, abs(maximum) * 0.01, 0.0001)
        return (minimum - spread * 0.12)...(maximum + spread * 0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Label("价格走势", systemImage: "chart.xyaxis.line")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 8)
                Picker("范围", selection: $range) {
                    ForEach(PersonalWatchlistChartRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 156)
            }

            if chartPoints.isEmpty {
                VStack(spacing: AppPalette.spaceS) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(AppPalette.appFont(.largeTitle))
                        .foregroundStyle(AppPalette.muted)
                    Text("等待首个有效行情")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("刷新成功后会按交易日记录并绘制折线。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 128)
            } else {
                chart
                    .frame(height: 148)
                    .overlay { tooltipOverlay }
            }

            HStack(spacing: AppPalette.spaceS) {
                Label("实线：每日价格", systemImage: "minus")
                    .foregroundStyle(changeTint)
                Label("虚线：关注起点", systemImage: "line.diagonal")
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 4)
                Text("已记录 \(row.dailyPoints.count) 个交易日")
                    .foregroundStyle(AppPalette.muted)
            }
            .font(AppPalette.appFont(.caption, weight: .medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.38)
        .animation(AppPalette.motionStandard, value: range)
        .onChange(of: row.id) { _, _ in
            hoveredPoint = nil
        }
    }

    private var chart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("价格", point.price)
                )
                .foregroundStyle(changeTint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if let baseline = row.record.baseline?.price {
                RuleMark(y: .value("关注价", baseline))
                    .foregroundStyle(AppPalette.muted.opacity(0.62))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            if let hoveredPoint {
                RuleMark(x: .value("日期", hoveredPoint.date))
                    .foregroundStyle(AppPalette.line.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("日期", hoveredPoint.date),
                    y: .value("价格", hoveredPoint.price)
                )
                .foregroundStyle(changeTint)
                .symbolSize(36)
            } else if let last = chartPoints.last {
                PointMark(
                    x: .value("日期", last.date),
                    y: .value("价格", last.price)
                )
                .foregroundStyle(changeTint)
                .symbolSize(28)
            }
        }
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppPalette.line.opacity(0.28))
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(watchlistAxisPrice(price))
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppPalette.line.opacity(0.16))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(AppPalette.appFont(.caption, design: .monospaced))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let plotRect = geometry[frame]
                            let relativeX = location.x - plotRect.origin.x
                            let relativeY = location.y - plotRect.origin.y
                            guard relativeX >= 0,
                                  relativeX <= plotRect.width,
                                  relativeY >= 0,
                                  relativeY <= plotRect.height,
                                  let date: Date = proxy.value(atX: relativeX) else {
                                hoveredPoint = nil
                                return
                            }
                            hoverLocation = location
                            hoveredPoint = chartPoints.min {
                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                            }
                        case .ended:
                            hoveredPoint = nil
                        }
                    }
            }
        }
    }

    private var tooltipOverlay: some View {
        GeometryReader { geometry in
            if let hoveredPoint {
                let width: CGFloat = 164
                let height: CGFloat = 66
                let x = min(max(hoverLocation.x + 12, 0), geometry.size.width - width)
                let y = min(max(hoverLocation.y - height - 8, 0), geometry.size.height - height)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hoveredPoint.dateText)
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(watchlistPriceText(hoveredPoint.price, item: row.item))
                        .font(AppPalette.appFont(.body, weight: .semibold, design: .monospaced))
                        .foregroundStyle(changeTint)
                    if let baseline = row.record.baseline?.price, baseline > 0 {
                        Text("较关注价 \(percentOptional((hoveredPoint.price / baseline - 1) * 100))")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(AppPalette.spaceS)
                .frame(width: width, alignment: .leading)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .cardStroke(opacity: 0.48)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .position(x: x + width / 2, y: y + height / 2)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

}
