import Charts
import SwiftUI

struct PersonalWatchlistSparkline: View {
    let row: PersonalWatchlistQuoteRow

    private var points: [PersonalWatchlistDailyPoint] {
        Array(row.dailyPoints.suffix(30))
    }

    private var tint: Color {
        AppPalette.marketTint(for: row.changeSinceFollowPct)
    }

    private var yDomain: ClosedRange<Double> {
        let prices = points.map(\.price)
        guard let minimum = prices.min(), let maximum = prices.max() else { return 0...1 }
        let spread = max(maximum - minimum, abs(maximum) * 0.01, 0.0001)
        return (minimum - spread * 0.10)...(maximum + spread * 0.10)
    }

    var body: some View {
        if points.isEmpty {
            Text("待记录")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("日期", point.date),
                        y: .value("价格", point.price)
                    )
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }

                if let baseline = row.record.baseline?.price {
                    RuleMark(y: .value("关注价", baseline))
                        .foregroundStyle(AppPalette.muted.opacity(0.38))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                }

                if let last = points.last {
                    PointMark(
                        x: .value("日期", last.date),
                        y: .value("价格", last.price)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(12)
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityLabel("\(row.displayName) 近 30 个交易日走势")
        }
    }
}

enum PersonalWatchlistChartRange: String, CaseIterable, Identifiable {
    case thirty = "30日"
    case ninety = "90日"
    case all = "全部"

    var id: String { rawValue }

    var pointLimit: Int? {
        switch self {
        case .thirty: return 30
        case .ninety: return 90
        case .all: return nil
        }
    }
}

struct PersonalWatchlistChartPoint: Identifiable {
    let date: Date
    let dateText: String
    let price: Double
    let quotedAt: String?

    var id: String { dateText }
}
