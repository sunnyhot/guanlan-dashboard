import SwiftUI
import Charts

// MARK: - PlatformHoldingsPieChart

struct PlatformHoldingsPieChart: View {
    let holdings: [HoldingItemPayload]

    private var assetClassSlices: [HoldingAllocationSlice] {
        slices(for: .assetClass)
    }

    private var assetTypeSlices: [HoldingAllocationSlice] {
        slices(for: .assetType)
    }

    private func slices(for dimension: PlatformHoldingAllocationDimension) -> [HoldingAllocationSlice] {
        PlatformHoldingAllocationBuilder.make(holdings: holdings, dimension: dimension).enumerated().map { index, allocation in
            HoldingAllocationSlice(
                label: allocation.label,
                value: allocation.value,
                assetCount: allocation.assetCount,
                ratio: allocation.ratio,
                tint: allocationPalette[index % allocationPalette.count]
            )
        }
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
        if !assetClassSlices.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    distributionPanel(title: "资产大类", slices: assetClassSlices)
                        .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                    distributionPanel(title: "资产类型", slices: assetTypeSlices)
                        .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    distributionPanel(title: "资产大类", slices: assetClassSlices)
                    distributionPanel(title: "资产类型", slices: assetTypeSlices)
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

    private func distributionPanel(title: String, slices: [HoldingAllocationSlice]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    pieVisual(slices: slices)
                        .frame(width: 172, height: 160)
                    legend(slices: slices)
                        .frame(minWidth: 180)
                }

                VStack(alignment: .leading, spacing: 10) {
                    pieVisual(slices: slices)
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                    legend(slices: slices)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppPalette.cardStrong.opacity(0.55), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.28), lineWidth: 1)
        )
    }

    private func pieVisual(slices: [HoldingAllocationSlice]) -> some View {
        let totalValue = slices.map(\.value).reduce(0, +)
        let largestSlice = slices.first

        return ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("当前份数", slice.value),
                    innerRadius: .ratio(0.58),
                    angularInset: 1.2
                )
                .foregroundStyle(slice.tint)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)

            VStack(spacing: 1) {
                Text(unitsText(totalValue))
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
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

    private func legend(slices: [HoldingAllocationSlice]) -> some View {
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

                    Text("\(unitsText(slice.value)) 份")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func unitsText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

struct PlatformHoldingAllocation: Identifiable, Equatable {
    let label: String
    let value: Double
    let assetCount: Int
    let ratio: Double

    var id: String { label }
}

enum PlatformHoldingAllocationDimension {
    case assetClass
    case assetType
}

enum PlatformHoldingAllocationBuilder {
    static func make(
        holdings: [HoldingItemPayload],
        dimension: PlatformHoldingAllocationDimension = .assetClass
    ) -> [PlatformHoldingAllocation] {
        let valuedHoldings = holdings.compactMap { holding -> (HoldingItemPayload, Double)? in
            guard let units = holding.currentUnits, units > 0 else { return nil }
            let value = Double(units)
            return (holding, value)
        }
        let grouped = Dictionary(grouping: valuedHoldings) { holding, _ in
            allocationLabel(for: holding, dimension: dimension)
        }
        let buckets = grouped.map { label, entries in
            (
                label: label,
                value: entries.map(\.1).reduce(0, +),
                assetCount: entries.count
            )
        }
        .filter { $0.value > 0 }
        .sorted {
            if $0.value != $1.value {
                return $0.value > $1.value
            }
            return $0.label < $1.label
        }

        let total = buckets.map(\.value).reduce(0, +)
        guard total > 0 else { return [] }
        return buckets.map { bucket in
            PlatformHoldingAllocation(
                label: bucket.label,
                value: bucket.value,
                assetCount: bucket.assetCount,
                ratio: bucket.value / total
            )
        }
    }

    private static func allocationLabel(
        for holding: HoldingItemPayload,
        dimension: PlatformHoldingAllocationDimension
    ) -> String {
        switch dimension {
        case .assetClass:
            return assetClassLabel(for: holding)
        case .assetType:
            return assetTypeLabel(for: holding)
        }
    }

    private static func assetClassLabel(for holding: HoldingItemPayload) -> String {
        let largeClass = (holding.largeClass ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return largeClass.isEmpty ? "未分类" : largeClass
    }

    private static func assetTypeLabel(for holding: HoldingItemPayload) -> String {
        let searchableText = [
            holding.largeClass,
            holding.strategyType,
            holding.label,
            holding.fundName,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        if containsAny(["债券", "固收", "纯债", "信用债", "利率债", "可转债", "短债"], in: searchableText) {
            return "债券"
        }
        if containsAny(["现金", "货币", "同业存单", "短融"], in: searchableText) {
            return "现金及货币"
        }
        if containsAny(["商品", "黄金", "原油", "贵金属"], in: searchableText) {
            return "商品"
        }
        if containsAny(["REIT", "不动产", "另类"], in: searchableText) {
            return "另类资产"
        }
        if containsAny(["股票", "A股", "港股", "美股", "权益", "中概", "指数"], in: searchableText) {
            return "股票"
        }
        return "其他"
    }

    private static func containsAny(_ keywords: [String], in value: String) -> Bool {
        keywords.contains { value.localizedCaseInsensitiveContains($0) }
    }

}

private struct HoldingAllocationSlice: Identifiable {
    let label: String
    let value: Double
    let assetCount: Int
    let ratio: Double
    let tint: Color

    var id: String { label }
}
