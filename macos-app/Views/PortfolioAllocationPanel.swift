import SwiftUI

private enum PortfolioAllocationViewMode: String, CaseIterable, Identifiable {
    case direct = "账面类型"
    case lookThrough = "基金穿透"

    var id: Self { self }
}

private enum PortfolioAllocationDetailTab: String, CaseIterable, Identifiable {
    case industry = "行业分布"
    case position = "底层重仓"

    var id: Self { self }
}

private struct PortfolioAllocationSlice: Identifiable {
    let id: String
    let label: String
    let weightPct: Double
    let detail: String
    let tint: Color
}

private struct PortfolioAllocationInsightValue {
    let name: String
    let pct: Double
}

/// 占比百分比（一位小数），用于摘要、图例等概览场景。
private func allocationPercentage(_ value: Double) -> String {
    String(format: "%.1f%%", value)
}

/// 占比百分比（两位小数），用于明细列表等需要精度的场景。
private func allocationPrecisePercentage(_ value: Double) -> String {
    String(format: "%.2f%%", value)
}

/// 各披露来源中最新的截止日期，未取得时返回 nil。
private func latestDisclosureDate(in snapshot: PortfolioLookThroughSnapshot) -> String? {
    snapshot.funds
        .compactMap(\.asOf)
        .filter { !$0.isEmpty }
        .max()
}

struct PortfolioAllocationPanel: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("portfolio.allocation.viewMode")
    private var selectedModeRawValue = PortfolioAllocationViewMode.direct.rawValue
    @State private var showsDetailPopover = false

    private let palette: [Color] = [
        AppPalette.brand,
        AppPalette.info,
        AppPalette.accentWarm,
        AppPalette.positive,
        AppPalette.warning,
        AppPalette.danger,
        AppPalette.muted,
    ]

    private var selectedMode: PortfolioAllocationViewMode {
        PortfolioAllocationViewMode(rawValue: selectedModeRawValue) ?? .direct
    }

    private var selectedModeBinding: Binding<PortfolioAllocationViewMode> {
        Binding(
            get: { selectedMode },
            set: { selectedModeRawValue = $0.rawValue }
        )
    }

    private var subtitleText: String {
        switch selectedMode {
        case .direct:
            return "按直接持有形式汇总当前有效敞口"
        case .lookThrough:
            if let snapshot = model.portfolioLookThroughSnapshot,
               let date = latestDisclosureDate(in: snapshot) {
                return "基金公开定期报告 · 最新 \(date)"
            }
            return "基金公开定期报告穿透至资产大类、行业与底层证券"
        }
    }

    var body: some View {
        SectionCard(
            title: "资产分布",
            subtitle: subtitleText,
            icon: "chart.pie",
            trailing: {
                Picker("资产分布视图", selection: selectedModeBinding) {
                    ForEach(PortfolioAllocationViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .accessibilityLabel("资产分布视图")
            }
        ) {
            switch selectedMode {
            case .direct:
                directDistribution
            case .lookThrough:
                lookThroughDistribution
            }
        }
        .task(id: "\(selectedModeRawValue)|\(model.portfolioLookThroughRequestKey)") {
            guard selectedMode == .lookThrough else { return }
            await model.refreshPortfolioLookThrough()
        }
    }

    // MARK: - 账面类型

    @ViewBuilder
    private var directDistribution: some View {
        if let summary = PortfolioAssetDistributionSummary.make(rows: model.personalAssetRows) {
            let slices = directSlices(summary)
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("有效敞口")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                    Text(compactCurrencyText(summary.totalExposure))
                        .font(AppPalette.appFont(.body, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                    Text("· \(totalAssetCount(in: summary)) 个标的")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)

                PortfolioAllocationStackedBar(slices: slices)

                PortfolioAllocationCompactLegend(slices: slices)

                Text("有效敞口包含已持有市值、待确认买入与下次计划投入。")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            allocationEmptyState(
                icon: "chart.pie",
                title: "暂无可展示的资产类型",
                detail: "添加持仓、买入中记录或进行中的计划后，这里会按资产类型汇总。"
            )
        }
    }

    private func directSlices(_ summary: PortfolioAssetDistributionSummary) -> [PortfolioAllocationSlice] {
        summary.items.enumerated().map { index, item in
            PortfolioAllocationSlice(
                id: item.category.rawValue,
                label: item.category.displayName,
                weightPct: item.weightPct,
                detail: "\(item.assetCount) 个标的 · \(currencyText(item.amount))",
                tint: palette[index % palette.count]
            )
        }
    }

    private func totalAssetCount(in summary: PortfolioAssetDistributionSummary) -> Int {
        summary.items.reduce(0) { $0 + $1.assetCount }
    }

    // MARK: - 基金穿透

    @ViewBuilder
    private var lookThroughDistribution: some View {
        if model.isRefreshingPortfolioLookThrough,
           model.portfolioLookThroughSnapshot == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取基金公开披露…")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在读取基金公开披露")
        } else if let snapshot = model.portfolioLookThroughSnapshot,
                  snapshot.coveredFundCount > 0 {
            lookThroughSummary(snapshot)
        } else if model.personalAssetRows.contains(where: {
            $0.assetType == .fund && $0.effectiveHoldingAmount > 0.001
        }) {
            lookThroughErrorState
        } else {
            allocationEmptyState(
                icon: "square.stack.3d.up.slash",
                title: "当前没有可穿透的基金资产",
                detail: "录入基金持仓或待确认买入后，这里会根据公开定期报告展示底层分布。"
            )
        }
    }

    private var lookThroughErrorState: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
                .accessibilityHidden(true)
            Text(
                model.portfolioLookThroughSourceWarnings.first
                    ?? "公开披露源暂时没有返回可用的持仓与资产配置。"
            )
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await model.refreshPortfolioLookThrough(force: true) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            .disabled(model.isRefreshingPortfolioLookThrough)
            .accessibilityLabel("重新读取基金穿透数据")
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func lookThroughSummary(_ snapshot: PortfolioLookThroughSnapshot) -> some View {
        let slices = lookThroughAssetSlices(snapshot)
        let warnings = uniqueWarnings(
            snapshot.warnings + model.portfolioLookThroughSourceWarnings
        )
        let topIndustry = snapshot.industries.first
            .map { PortfolioAllocationInsightValue(name: $0.name, pct: $0.portfolioWeightPct) }
        let topPosition = snapshot.topPositions.first
            .map { PortfolioAllocationInsightValue(name: $0.name, pct: $0.portfolioWeightPct) }

        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("基金覆盖 \(snapshot.coveredFundCount)/\(snapshot.expectedFundCount) 只")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                Text("（金额 \(allocationPercentage(snapshot.fundDataCoveragePct))）")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
                Text("· 已披露重仓占组合 \(allocationPercentage(snapshot.disclosedSecurityCoveragePct))")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            PortfolioAllocationStackedBar(slices: slices)

            PortfolioAllocationCompactLegend(slices: slices)

            PortfolioAllocationInsightRow(
                topIndustry: topIndustry,
                topPosition: topPosition,
                isDetailPresented: $showsDetailPopover
            ) {
                PortfolioAllocationDetailPopover(snapshot: snapshot, warnings: warnings)
            }
        }
    }

    private func lookThroughAssetSlices(
        _ snapshot: PortfolioLookThroughSnapshot
    ) -> [PortfolioAllocationSlice] {
        var slices = snapshot.assetClasses.enumerated().map { index, item in
            PortfolioAllocationSlice(
                id: item.id,
                label: item.name,
                weightPct: item.portfolioWeightPct,
                detail: "穿透后占组合有效敞口",
                tint: assetClassColor(name: item.name, fallbackIndex: index)
            )
        }

        let classifiedWeight = slices.reduce(0) { $0 + max(0, $1.weightPct) }
        let unclassifiedWeight = max(0, 100 - classifiedWeight)
        if unclassifiedWeight > 0.05 {
            slices.append(
                PortfolioAllocationSlice(
                    id: "unclassified",
                    label: "未取得配置",
                    weightPct: unclassifiedWeight,
                    detail: "未覆盖基金或缺少资产配置披露",
                    tint: AppPalette.muted
                )
            )
        }
        return slices
    }

    private func assetClassColor(name: String, fallbackIndex: Int) -> Color {
        switch name {
        case "股票":
            return AppPalette.brand
        case "债券":
            return AppPalette.info
        case "现金":
            return AppPalette.positive
        case "其他":
            return AppPalette.accentWarm
        default:
            return palette[fallbackIndex % palette.count]
        }
    }

    private func allocationEmptyState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.title3, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func compactCurrencyText(_ value: Double) -> String {
        if abs(value) >= 10_000 {
            return "¥\(String(format: "%.1f", value / 10_000))万"
        }
        return "¥\(String(format: "%.0f", value))"
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            !warning.isEmpty && seen.insert(warning).inserted
        }
    }
}

// MARK: - 100% 横向堆叠条

/// 按真实组合百分比绘制的资产大类堆叠条，高度约 11pt。
/// 颜色不作为唯一区分依据（图例与可访问性值同时提供文字 + 百分比）。
private struct PortfolioAllocationStackedBar: View {
    let slices: [PortfolioAllocationSlice]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.tint)
                        .frame(width: proxy.size.width * CGFloat(max(0, slice.weightPct) / 100))
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 11)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.borderFaint), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("资产分布占比")
        .accessibilityValue(
            slices
                .map { "\($0.label) \(allocationPercentage($0.weightPct))" }
                .joined(separator: "，")
        )
    }
}

// MARK: - 紧凑图例（FlowLayout 自适应换行）

private struct PortfolioAllocationCompactLegend: View {
    let slices: [PortfolioAllocationSlice]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(slices) { slice in
                HStack(spacing: 4) {
                    Circle()
                        .fill(slice.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(slice.label)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(allocationPercentage(slice.weightPct))
                        .font(AppPalette.appFont(.caption, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(slice.label) \(allocationPercentage(slice.weightPct))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 洞察行（最大行业 / 最大重仓 / 查看明细）

private struct PortfolioAllocationInsightRow<Detail: View>: View {
    let topIndustry: PortfolioAllocationInsightValue?
    let topPosition: PortfolioAllocationInsightValue?
    @Binding var isDetailPresented: Bool
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .center, spacing: AppPalette.spaceM) {
            insightItem(label: "最大行业", value: topIndustry)
            insightDivider
            insightItem(label: "最大重仓", value: topPosition)
            Spacer(minLength: 8)
            Button {
                isDetailPresented = true
            } label: {
                Label("查看明细…", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            .accessibilityLabel("查看资产穿透明细")
            .accessibilityHint("打开行业分布与底层重仓的完整列表")
            .popover(isPresented: $isDetailPresented, arrowEdge: .top) {
                detail()
            }
        }
    }

    private var insightDivider: some View {
        Divider()
            .frame(height: 20)
            .opacity(0.6)
    }

    @ViewBuilder
    private func insightItem(
        label: String,
        value: PortfolioAllocationInsightValue?
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value?.name ?? "暂无")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text(value.map { allocationPrecisePercentage($0.pct) } ?? "—")
                    .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label) \(value?.name ?? "暂无") \(value.map { allocationPrecisePercentage($0.pct) } ?? "")"
        )
    }
}

// MARK: - 明细 Popover

private struct PortfolioAllocationDetailPopover: View {
    let snapshot: PortfolioLookThroughSnapshot
    let warnings: [String]
    @State private var selectedTab = PortfolioAllocationDetailTab.industry

    private var latestDateText: String? {
        latestDisclosureDate(in: snapshot).map { "最新 \($0)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Picker("穿透明细视图", selection: $selectedTab) {
                    ForEach(PortfolioAllocationDetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("穿透明细视图")

                if let latestDateText {
                    Text(latestDateText)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Group {
                switch selectedTab {
                case .industry:
                    detailList(
                        emptyMessage: "披露中暂无行业配置",
                        items: snapshot.industries.map {
                            PortfolioAllocationDetailRowData(
                                name: $0.name,
                                kindLabel: "行业",
                                weightPct: $0.portfolioWeightPct
                            )
                        }
                    )
                case .position:
                    detailList(
                        emptyMessage: "披露中暂无底层证券",
                        items: snapshot.topPositions.map {
                            PortfolioAllocationDetailRowData(
                                name: $0.name,
                                kindLabel: "\($0.kind.displayName) · \($0.contributors.count) 个来源",
                                weightPct: $0.portfolioWeightPct
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text("基金公开定期报告，并非实时完整持仓。")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
                ForEach(Array(warnings.prefix(2)), id: \.self) { warning in
                    Text(warning)
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppPalette.spaceM)
        .frame(width: 560, height: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func detailList(
        emptyMessage: String,
        items: [PortfolioAllocationDetailRowData]
    ) -> some View {
        if items.isEmpty {
            Text(emptyMessage)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                PortfolioAllocationDetailRow(data: item)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

private struct PortfolioAllocationDetailRowData: Identifiable {
    let name: String
    let kindLabel: String
    let weightPct: Double
    let id = UUID()
}

private struct PortfolioAllocationDetailRow: View {
    let data: PortfolioAllocationDetailRowData

    var body: some View {
        HStack(spacing: 8) {
            Text(data.name)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(data.kindLabel)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            Text(allocationPrecisePercentage(data.weightPct))
                .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.name) \(data.kindLabel) \(allocationPrecisePercentage(data.weightPct))")
    }
}
