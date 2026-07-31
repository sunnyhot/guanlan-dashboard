import Charts
import SwiftUI

struct PersonalAssetPriceTrendChart: View {
    @EnvironmentObject private var model: AppModel

    let row: PersonalAssetAggregateRow

    @State private var range: PersonalAssetPriceTrendRange = .ninety
    @State private var series = PersonalAssetPriceTrendSeries(dailyPoints: [])
    @State private var hoveredPoint: PersonalAssetPriceTrendPoint?
    @State private var hoverLocation: CGPoint = .zero
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadGeneration = 0

    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var visiblePoints: [PersonalAssetPriceTrendPoint] {
        series.points(for: range)
    }

    private var rangeChangePct: Double? {
        series.changePct(for: range)
    }

    private var trendTint: Color {
        AppPalette.marketTint(for: rangeChangePct)
    }

    private var priceTitle: String {
        row.usesMarketTradeColumns ? "收盘价走势" : "单位净值走势"
    }

    private var priceLabel: String {
        row.usesMarketTradeColumns ? "价格" : "净值"
    }

    private var historyHolding: UserPortfolioHolding? {
        if let holding = row.holdingRow?.holding ?? row.rawHolding ?? row.archivedHolding {
            return holding
        }
        guard let code = row.fundCode, !code.isEmpty else { return nil }
        return UserPortfolioHolding(
            fundCode: code,
            assetType: row.assetType,
            units: 1,
            costPrice: row.costPrice,
            displayName: row.fundName,
            stockMarket: row.detectedMarket,
            fundMarket: row.detectedFundMarket
        )
    }

    private var yDomain: ClosedRange<Double> {
        var prices = visiblePoints.map(\.price)
        if let costPrice = row.costPrice, costPrice > 0 {
            prices.append(costPrice)
        }
        guard let minimum = prices.min(), let maximum = prices.max() else { return 0...1 }
        let spread = max(maximum - minimum, abs(maximum) * 0.01, 0.0001)
        return (minimum - spread * 0.10)...(maximum + spread * 0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            compactToolbar

            if isLoading, series.points.isEmpty {
                loadingState
            } else if series.points.isEmpty {
                emptyState
            } else {
                chart
                    .frame(height: 192)
                    .overlay { tooltipOverlay }
                    .transition(.opacity)
                footer
            }
        }
        .padding(12)
        .background(AppPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke(opacity: 0.36)
        .animation(AppPalette.motionStandard, value: range)
        .animation(AppPalette.motionStandard, value: isLoading)
        .task(id: "\(row.id)-\(loadGeneration)") {
            await loadHistory()
        }
        .onChange(of: range) { _, _ in
            hoveredPoint = nil
        }
    }

    private var compactToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                chartIdentity
                Spacer(minLength: 4)
                if !series.points.isEmpty {
                    inlineSummary
                }
                loadingIndicator
                rangePicker
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    chartIdentity
                    Spacer(minLength: 8)
                    loadingIndicator
                    rangePicker
                }
                if !series.points.isEmpty {
                    inlineSummary
                }
            }
        }
    }

    private var chartIdentity: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
                .accentIconStyle(tint: AppPalette.brand, size: 22)
            Text(priceTitle)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if isLoading, !series.points.isEmpty {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var rangePicker: some View {
        Picker("走势区间", selection: $range) {
            ForEach(PersonalAssetPriceTrendRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 192)
        .disabled(series.points.isEmpty)
    }

    private var inlineSummary: some View {
        HStack(spacing: 10) {
            trendMetric(
                title: "最新\(priceLabel)",
                value: visiblePoints.last.map { decimalText($0.price) } ?? "—",
                tint: AppPalette.ink
            )
            Divider()
                .frame(height: 26)
            trendMetric(
                title: "\(range.rawValue)涨跌",
                value: percentOptional(rangeChangePct),
                tint: trendTint
            )
            Divider()
                .frame(height: 26)
            trendMetric(
                title: "区间",
                value: visibleRangeText,
                tint: AppPalette.muted
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func trendMetric(title: String, value: String, tint: Color) -> some View {
        LabeledValue(
            title: title,
            value: value,
            tint: tint,
            titleSize: .caption,
            titleWeight: .medium,
            valueSize: .subheadline,
            valueDesign: .rounded,
            minimumScaleFactor: 1.0
        )
    }

    private var visibleRangeText: String {
        guard let first = visiblePoints.first?.dateText, let last = visiblePoints.last?.dateText else {
            return "—"
        }
        return "\(String(first.dropFirst(5))) – \(String(last.dropFirst(5)))"
    }

    private var chart: some View {
        Chart {
            ForEach(visiblePoints) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("区间下界", yDomain.lowerBound),
                    yEnd: .value(priceLabel, point.price)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [trendTint.opacity(0.20), trendTint.opacity(0.015)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value(priceLabel, point.price)
                )
                .foregroundStyle(trendTint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            if let costPrice = row.costPrice, costPrice > 0 {
                RuleMark(y: .value("持仓成本", costPrice))
                    .foregroundStyle(AppPalette.muted.opacity(0.72))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            if let hoveredPoint {
                RuleMark(x: .value("日期", hoveredPoint.date))
                    .foregroundStyle(AppPalette.line.opacity(0.72))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("日期", hoveredPoint.date),
                    y: .value(priceLabel, hoveredPoint.price)
                )
                .foregroundStyle(trendTint)
                .symbolSize(42)
            } else if let last = visiblePoints.last {
                PointMark(
                    x: .value("日期", last.date),
                    y: .value(priceLabel, last.price)
                )
                .foregroundStyle(trendTint)
                .symbolSize(30)
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
                        Text(decimalText(price))
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(AppPalette.line.opacity(0.14))
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
                            hoveredPoint = visiblePoints.min {
                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                            }
                        case .ended:
                            hoveredPoint = nil
                        }
                    }
            }
        }
        .accessibilityLabel("\(row.fundName)\(range.rawValue)\(priceTitle)，区间涨跌\(percentOptional(rangeChangePct))")
    }

    private var tooltipOverlay: some View {
        GeometryReader { geometry in
            if let hoveredPoint {
                let width: CGFloat = 156
                let height: CGFloat = 64
                let x = min(max(hoverLocation.x + 12, 0), geometry.size.width - width)
                let y = min(max(hoverLocation.y - height - 8, 0), geometry.size.height - height)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hoveredPoint.dateText)
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(priceLabel) \(decimalText(hoveredPoint.price))")
                        .font(AppPalette.appFont(.body, weight: .semibold, design: .monospaced))
                        .foregroundStyle(trendTint)
                    if let first = visiblePoints.first?.price, first > 0 {
                        Text("较区间起点 \(percentOptional((hoveredPoint.price / first - 1) * 100))")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(9)
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

    private var footer: some View {
        HStack(spacing: 12) {
            Label("实线：\(priceLabel)", systemImage: "minus")
                .foregroundStyle(trendTint)
            if row.costPrice != nil {
                Label("虚线：持仓成本", systemImage: "line.diagonal")
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: 6)
            Text("已加载 \(series.points.count) 个交易日")
                .foregroundStyle(AppPalette.muted)
        }
        .font(AppPalette.appFont(.caption, weight: .medium))
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在加载历史走势…")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text("首次打开可能需要几秒钟")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 168)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.xyaxis.line")
                .font(AppPalette.appFont(.largeTitle))
                .foregroundStyle(AppPalette.muted)
            Text(loadError ?? "暂时没有可用走势")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text("可以稍后重试，不影响当前持仓数据。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
            Button("重新加载") {
                loadGeneration += 1
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 168)
    }

    @MainActor
    private func loadHistory() async {
        guard let holding = historyHolding else {
            loadError = "缺少标的代码，无法加载走势"
            series = PersonalAssetPriceTrendSeries(dailyPoints: [])
            return
        }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            var points = try await model.platformClient.fetchPersonalAssetPriceHistory(for: holding)
            if let currentPrice = row.currentPrice, currentPrice > 0 {
                let rawDate = row.holdingRow?.resolvedPriceTime ?? ""
                let date = PersonalWatchlistItem.normalizedDate(rawDate)
                points.append(
                    PersonalWatchlistDailyPoint(
                        date: date.isEmpty ? Self.todayFormatter.string(from: Date()) : date,
                        price: currentPrice,
                        quotedAt: rawDate,
                        sourceLabel: row.holdingRow?.resolvedPriceSource
                    )
                )
            }
            guard !Task.isCancelled else { return }
            series = PersonalAssetPriceTrendSeries(dailyPoints: points)
            if series.points.isEmpty {
                loadError = "暂时没有拉到可用走势"
            }
        } catch {
            guard !Task.isCancelled else { return }
            series = PersonalAssetPriceTrendSeries(dailyPoints: [])
            loadError = "走势加载失败"
        }
    }
}
