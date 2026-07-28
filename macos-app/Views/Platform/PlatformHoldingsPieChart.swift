import SwiftUI
import Charts

// MARK: - PlatformHoldingsPieChart

struct PlatformHoldingsPieChart: View {
    let holdings: [HoldingItemPayload]

    private var slices: [HoldingAllocationSlice] {
        let grouped = Dictionary(grouping: holdings.filter { ($0.currentUnits ?? 0) > 0 }, by: categoryLabel)
        var buckets = grouped.map { label, items in
            HoldingAllocationBucket(
                label: label,
                units: items.compactMap(\.currentUnits).reduce(0, +),
                assetCount: items.count
            )
        }
        .filter { $0.units > 0 }
        .sorted {
            if $0.units != $1.units {
                return $0.units > $1.units
            }
            return $0.label < $1.label
        }

        if buckets.count > 6 {
            let remainder = buckets.dropFirst(5).reduce(HoldingAllocationBucket(label: "其他", units: 0, assetCount: 0)) { partial, bucket in
                HoldingAllocationBucket(
                    label: partial.label,
                    units: partial.units + bucket.units,
                    assetCount: partial.assetCount + bucket.assetCount
                )
            }
            buckets = Array(buckets.prefix(5)) + [remainder]
        }

        let total = buckets.map(\.units).reduce(0, +)
        return buckets.enumerated().map { index, bucket in
            HoldingAllocationSlice(
                label: bucket.label,
                units: bucket.units,
                assetCount: bucket.assetCount,
                ratio: total > 0 ? Double(bucket.units) / Double(total) : 0,
                tint: allocationPalette[index % allocationPalette.count]
            )
        }
    }

    private var totalUnits: Int {
        slices.map(\.units).reduce(0, +)
    }

    private var largestSlice: HoldingAllocationSlice? {
        slices.first
    }

    private let allocationPalette: [Color] = [
        AppPalette.brand,
        AppPalette.info,
        AppPalette.accentWarm,
        AppPalette.positive,
        AppPalette.warning,
        AppPalette.danger,
        AppPalette.muted,
    ]

    var body: some View {
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.pie.fill")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.brand)
                    Text("当前持仓分布")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    Text("按当前份数")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        pieVisual
                            .frame(width: 220, height: 176)
                        legend
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        pieVisual
                            .frame(maxWidth: .infinity)
                            .frame(height: 176)
                        legend
                    }
                }
            }
            .padding(14)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                    .stroke(AppPalette.line.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var pieVisual: some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("份数", slice.units),
                    innerRadius: .ratio(0.58),
                    angularInset: 1.2
                )
                .foregroundStyle(slice.tint)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)

            VStack(spacing: 1) {
                Text("\(totalUnits)")
                    .font(AppPalette.appFont(.largeTitle, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                Text("当前份数")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                if let largestSlice {
                    Text("最大 \(largestSlice.label)")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(slice.tint)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.label)
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                        Text("\(slice.assetCount) 只 · \(percentText(slice.ratio))")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    Text("\(slice.units) 份")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryLabel(for holding: HoldingItemPayload) -> String {
        let largeClass = (holding.largeClass ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !largeClass.isEmpty {
            return largeClass
        }

        let strategyType = (holding.strategyType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !strategyType.isEmpty {
            return strategyType
        }

        return "未分类"
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private struct HoldingAllocationBucket {
    let label: String
    let units: Int
    let assetCount: Int
}

private struct HoldingAllocationSlice: Identifiable {
    let label: String
    let units: Int
    let assetCount: Int
    let ratio: Double
    let tint: Color

    var id: String { label }
}
