import SwiftUI
import Charts

private enum PortfolioAllocationViewMode: String, CaseIterable, Identifiable {
    case direct = "账面类型"
    case lookThrough = "基金穿透"

    var id: Self { self }
}

private struct PortfolioAllocationSlice: Identifiable {
    let id: String
    let label: String
    let weightPct: Double
    let detail: String
    let tint: Color
}

/// 占比百分比（一位小数）。
private func allocationPercentage(_ value: Double) -> String {
    String(format: "%.1f%%", value)
}

/// 占比百分比（两位小数）。
private func allocationPrecisePercentage(_ value: Double) -> String {
    String(format: "%.2f%%", value)
}

private func latestDisclosureDate(in snapshot: PortfolioLookThroughSnapshot) -> String? {
    snapshot.funds
        .compactMap(\.asOf)
        .filter { !$0.isEmpty }
        .max()
}

// MARK: - 主面板

struct PortfolioAllocationPanel: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("portfolio.allocation.viewMode")
    private var selectedModeRawValue = PortfolioAllocationViewMode.direct.rawValue
    @State private var showsFundDisclosure = false

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
                    label: "未取得资产分类",
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

    // MARK: - 基金穿透

    @ViewBuilder
    private var lookThroughDistribution: some View {
        if model.isRefreshingPortfolioLookThrough,
           model.portfolioLookThroughSnapshot == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
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

    private func lookThroughSummary(_ snapshot: PortfolioLookThroughSnapshot) -> some View {
        let assetSlices = lookThroughAssetSlices(snapshot)
        let warnings = uniqueWarnings(
            snapshot.warnings + model.portfolioLookThroughSourceWarnings
        )

        return VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            PortfolioLookThroughMetricStrip(snapshot: snapshot)

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                PortfolioLookThroughSectionHeader(
                    title: "穿透后资产大类",
                    detail: "含直接持有 · 占整个组合"
                )
                PortfolioAllocationStackedBar(slices: assetSlices)
                PortfolioAllocationCompactLegend(slices: assetSlices)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                    PortfolioUnderlyingPositionList(positions: snapshot.topPositions)
                        .frame(maxWidth: .infinity, alignment: .top)

                    Divider()

                    PortfolioIndustryExposureList(industries: snapshot.industries)
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    PortfolioUnderlyingPositionList(positions: snapshot.topPositions)
                    Divider()
                    PortfolioIndustryExposureList(industries: snapshot.industries)
                }
            }

            Divider()

            DisclosureGroup(isExpanded: $showsFundDisclosure) {
                PortfolioFundDisclosureTable(funds: snapshot.funds)
                    .padding(.top, AppPalette.spaceS)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                    Text("基金披露明细")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("查看“基金已披露重仓”的计算来源")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                    Spacer(minLength: AppPalette.spaceS)
                    Text("\(snapshot.funds.count) 只")
                        .font(AppPalette.appFont(.caption, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                }
            }
            .tint(AppPalette.brand)
            .accessibilityHint("展开后显示每只基金占组合、披露重仓占基金以及折算占组合的比例")

            PortfolioDisclosureNotice(
                messages: disclosureNoticeMessages(warnings: warnings)
            )
        }
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            !warning.isEmpty && seen.insert(warning).inserted
        }
    }

    private func disclosureNoticeMessages(warnings: [String]) -> [String] {
        let scopeMessage = "证券暴露包含直接持有和基金公开重仓；基金行业与重仓均不是实时完整持仓。"
        let actionableWarning = warnings.first {
            !$0.contains("并非实时完整持仓")
        }
        return [scopeMessage] + [actionableWarning].compactMap { $0 }
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
}

// MARK: - 账面类型：100% 堆叠条 + 紧凑图例

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
            slices.map { "\($0.label) \(allocationPercentage($0.weightPct))" }.joined(separator: "，")
        )
    }
}

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

// MARK: - 基金穿透：摘要与可核对明细

private struct PortfolioLookThroughSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(detail)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PortfolioLookThroughMetricStrip: View {
    let snapshot: PortfolioLookThroughSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 0) {
                metric(
                    title: "基金披露覆盖",
                    value: "\(snapshot.coveredFundCount)/\(snapshot.expectedFundCount) 只",
                    detail: "覆盖基金金额 \(allocationPercentage(snapshot.fundDataCoveragePct))",
                    tint: AppPalette.brand
                )
                Divider().frame(height: 42)
                metric(
                    title: "基金已披露重仓",
                    value: allocationPercentage(snapshot.disclosedSecurityCoveragePct),
                    detail: "折算占整个组合",
                    tint: AppPalette.info
                )
                Divider().frame(height: 42)
                metric(
                    title: "基金仓位未披露到证券",
                    value: allocationPercentage(snapshot.unknownPortfolioWeightPct),
                    detail: "非重仓部分或缺少披露",
                    tint: AppPalette.muted
                )
            }

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                metric(
                    title: "基金披露覆盖",
                    value: "\(snapshot.coveredFundCount)/\(snapshot.expectedFundCount) 只",
                    detail: "覆盖基金金额 \(allocationPercentage(snapshot.fundDataCoveragePct))",
                    tint: AppPalette.brand
                )
                Divider()
                metric(
                    title: "基金已披露重仓",
                    value: allocationPercentage(snapshot.disclosedSecurityCoveragePct),
                    detail: "折算占整个组合",
                    tint: AppPalette.info
                )
                Divider()
                metric(
                    title: "基金仓位未披露到证券",
                    value: allocationPercentage(snapshot.unknownPortfolioWeightPct),
                    detail: "非重仓部分或缺少披露",
                    tint: AppPalette.muted
                )
            }
        }
        .padding(AppPalette.spaceM)
        .background(
            AppPalette.cardStrong.opacity(0.72),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.borderFaint), lineWidth: 0.5)
        )
    }

    private func metric(
        title: String,
        value: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(AppPalette.appFont(.title3, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text(detail)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppPalette.spaceM)
        .accessibilityElement(children: .combine)
    }
}

/// 穿透后证券暴露的块状图（Treemap）：只展示占组合 ≥1% 的证券，其余合并为「其他」，
/// 每块用调色板的不同颜色区分；块面积反映权重。
/// 穿透后证券暴露饼图（SectorMark）：占组合 ≥1% 的 top10 + 其他。
private struct PortfolioTreemap: View {
    let positions: [PortfolioLookThroughPosition]

    private let palette: [Color] = [
        AppPalette.brand,
        AppPalette.info,
        AppPalette.accentWarm,
        AppPalette.positive,
        AppPalette.warning,
        AppPalette.danger,
        AppPalette.muted,
    ]

    private struct TreemapItem: Identifiable {
        let id = UUID()
        let label: String
        let weight: Double
        let tint: Color
    }

    private var items: [TreemapItem] {
        let sorted = positions.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
        let significant = sorted.filter { $0.portfolioWeightPct >= 1 }
        let shown = Array(significant.prefix(10))
        let shownIDs = Set(shown.map(\.id))
        let otherWeight = sorted
            .filter { !shownIDs.contains($0.id) }
            .reduce(0) { $0 + max(0, $1.portfolioWeightPct) }
        var output = shown.enumerated().map { index, position in
            TreemapItem(
                label: position.name,
                weight: max(0, position.portfolioWeightPct),
                tint: palette[index % palette.count]
            )
        }
        if otherWeight >= 0.05 {
            output.append(TreemapItem(label: "其他", weight: otherWeight, tint: AppPalette.muted))
        }
        return output
    }

    private var totalWeight: Double {
        items.reduce(0) { $0 + max(0, $1.weight) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppPalette.spaceL) {
            donut
            legend
        }
        .accessibilityLabel("穿透后证券暴露饼图")
        .accessibilityValue(
            items
                .map { "\($0.label) \(allocationPrecisePercentage($0.weight))" }
                .joined(separator: "，")
        )
    }

    @ViewBuilder
    private var donut: some View {
        ZStack {
            Chart(items) { item in
                SectorMark(
                    angle: .value("占组合", max(0, item.weight)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .foregroundStyle(item.tint)
                .cornerRadius(2)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)

            VStack(spacing: 1) {
                Text(allocationPrecisePercentage(totalWeight))
                    .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                Text("\(items.count) 项")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 64)
        }
        .frame(width: 132, height: 132)
    }

    @ViewBuilder
    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(item.label)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.ink.opacity(0.84))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(allocationPrecisePercentage(item.weight))
                        .font(AppPalette.appFont(.caption2, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label) 占组合 \(allocationPrecisePercentage(item.weight))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PortfolioUnderlyingPositionList: View {
    let positions: [PortfolioLookThroughPosition]
    @State private var showsDetail = false

    private var sortedPositions: [PortfolioLookThroughPosition] {
        positions.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                PortfolioLookThroughSectionHeader(
                    title: "穿透后证券暴露",
                    detail: "直接持有 + 基金披露重仓 · 占组合"
                )
                Spacer(minLength: 0)
                if !sortedPositions.isEmpty {
                    Button {
                        showsDetail = true
                    } label: {
                        Label("查看完整明细", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("查看穿透后证券暴露完整明细")
                }
            }

            if sortedPositions.isEmpty {
                Text("披露中暂无底层证券")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                PortfolioTreemap(positions: sortedPositions)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsDetail) {
            positionDetailSheet
        }
    }

    private var positionDetailSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("穿透后证券暴露 · 完整明细")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("完成") { showsDetail = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("关闭明细")
            }
            .padding(AppPalette.spaceS)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sortedPositions.enumerated()), id: \.offset) { index, position in
                        PortfolioUnderlyingPositionRow(rank: index + 1, position: position)
                        if index < sortedPositions.count - 1 {
                            Divider().padding(.leading, 30)
                        }
                    }
                }
                .padding(AppPalette.spaceM)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 400, idealHeight: 520)
    }
}

private struct PortfolioUnderlyingPositionRow: View {
    let rank: Int
    let position: PortfolioLookThroughPosition

    private var tint: Color {
        switch position.kind {
        case .stock:
            return AppPalette.brand
        case .bond:
            return AppPalette.info
        }
    }

    private var sourceSummary: String {
        let fundContributors = position.contributors.filter { !$0.isDirectHolding }
        let hasDirectHolding = position.contributors.contains(where: \.isDirectHolding)
        var names: [String] = []
        for contributor in fundContributors where !names.contains(contributor.fundName) {
            names.append(contributor.fundName)
        }

        if hasDirectHolding, names.isEmpty {
            return "直接持有"
        }
        if hasDirectHolding {
            return "直接持有 + 来自 \(names.count) 只基金"
        }
        if names.count == 1, let contributor = fundContributors.first {
            return "来自 \(names[0]) · 基金内 \(allocationPrecisePercentage(contributor.underlyingWeightPct))"
        }
        if names.count > 1 {
            let visibleNames = names.prefix(2).joined(separator: "、")
            let suffix = names.count > 2 ? "等" : ""
            return "来自 \(names.count) 只基金 · \(visibleNames)\(suffix)"
        }
        return "暂无来源明细"
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppPalette.spaceS) {
            Text("\(rank)")
                .font(AppPalette.appFont(.caption, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.muted)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(position.name)
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(position.code)
                        .font(AppPalette.appFont(.caption2, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                Text(sourceSummary)
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: AppPalette.spaceS)

            VStack(alignment: .trailing, spacing: 2) {
                Text(allocationPrecisePercentage(position.portfolioWeightPct))
                    .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                Text(position.kind.displayName)
                    .font(AppPalette.appFont(.caption2, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "第 \(rank) 名，\(position.name)，\(position.kind.displayName)，占组合 \(allocationPrecisePercentage(position.portfolioWeightPct))，\(sourceSummary)"
        )
    }
}

private struct PortfolioIndustryExposureList: View {
    let industries: [PortfolioLookThroughIndustry]

    private var displayedIndustries: [PortfolioLookThroughIndustry] {
        Array(
            industries
                .sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
                .prefix(8)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            PortfolioLookThroughSectionHeader(
                title: "基金披露行业",
                detail: "折算占整个组合 · 真实 0–100% 刻度"
            )

            if displayedIndustries.isEmpty {
                Text("披露中暂无行业配置")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: AppPalette.spaceL) {
                    industryDonut
                    industryLegend
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var industryDonut: some View {
        ZStack {
            Chart(Array(displayedIndustries.enumerated()), id: \.element.id) { index, industry in
                SectorMark(
                    angle: .value("行业占比", industrySliceWeight(industry.portfolioWeightPct)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.2
                )
                .foregroundStyle(industryColor(index: index))
                .cornerRadius(2)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)

            VStack(spacing: 1) {
                Text(allocationPrecisePercentage(totalIndustryWeight))
                    .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                Text("\(displayedIndustries.count) 个行业")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 64)
        }
        .frame(width: 132, height: 132)
        .accessibilityLabel("基金披露行业饼图")
        .accessibilityValue(
            displayedIndustries
                .map { "\($0.name) \(allocationPrecisePercentage($0.portfolioWeightPct))" }
                .joined(separator: "，")
        )
    }

    @ViewBuilder
    private var industryLegend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(displayedIndustries.enumerated()), id: \.element.id) { index, industry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(industryColor(index: index))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(industry.name)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.ink.opacity(0.84))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(allocationPrecisePercentage(industry.portfolioWeightPct))
                        .font(AppPalette.appFont(.caption2, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(industry.name)，占组合 \(allocationPrecisePercentage(industry.portfolioWeightPct))"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 行业饼图配色：按 index 在调色板中循环取色。
    private func industryColor(index: Int) -> Color {
        [
            AppPalette.brand,
            AppPalette.info,
            AppPalette.accentWarm,
            AppPalette.positive,
            AppPalette.warning,
            AppPalette.danger,
            AppPalette.muted,
        ][index % 7]
    }

    /// 行业饼图按“行业间占比”归一化到 0–100，使饼图铺满整圈；组合口径合计另在中央标注。
    private func industrySliceWeight(_ weight: Double) -> Double {
        guard totalIndustryWeight > 0 else { return 0 }
        return max(0, weight) / totalIndustryWeight * 100
    }

    /// 已展示行业的合计占比，用于饼图中央汇总。
    private var totalIndustryWeight: Double {
        displayedIndustries.reduce(0) { $0 + max(0, $1.portfolioWeightPct) }
    }
}

private struct PortfolioFundDisclosureTable: View {
    let funds: [PortfolioFundLookThroughSummary]

    private var sortedFunds: [PortfolioFundLookThroughSummary] {
        funds.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: AppPalette.spaceL, verticalSpacing: 0) {
                GridRow {
                    header("基金", width: 240, alignment: .leading)
                    header("基金占组合", width: 88)
                    header("披露重仓占基金", width: 108)
                    header("折算占组合", width: 88)
                    header("报告期", width: 88)
                }
                .padding(.vertical, 5)

                Divider().gridCellColumns(5)

                ForEach(Array(sortedFunds.enumerated()), id: \.offset) { index, fund in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fund.fundName)
                                .font(AppPalette.appFont(.caption, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(1)
                            Text(fund.fundCode)
                                .font(AppPalette.appFont(.caption2, design: .monospaced))
                                .foregroundStyle(AppPalette.muted)
                        }
                        .frame(width: 240, alignment: .leading)

                        value(allocationPrecisePercentage(fund.portfolioWeightPct), width: 88)
                        value(allocationPrecisePercentage(fund.disclosedSecurityWeightPct), width: 108)
                        value(
                            allocationPrecisePercentage(
                                fund.portfolioWeightPct * fund.disclosedSecurityWeightPct / 100
                            ),
                            width: 88,
                            emphasized: true
                        )
                        Text(fund.asOf ?? "未取得")
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(fund.asOf == nil ? AppPalette.warning : AppPalette.muted)
                            .frame(width: 88, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)

                    if index < sortedFunds.count - 1 {
                        Divider().gridCellColumns(5)
                    }
                }
            }
            .frame(minWidth: 680, alignment: .leading)
            .padding(.bottom, 2)
        }
        .accessibilityLabel("基金披露计算明细")
    }

    private func header(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .trailing
    ) -> some View {
        Text(text)
            .font(AppPalette.appFont(.caption2, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
            .frame(width: width, alignment: alignment)
    }

    private func value(
        _ text: String,
        width: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        Text(text)
            .font(
                AppPalette.appFont(
                    .caption,
                    weight: emphasized ? .semibold : .regular,
                    design: .rounded
                )
            )
            .foregroundStyle(emphasized ? AppPalette.ink : AppPalette.muted)
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }
}

private struct PortfolioDisclosureNotice: View {
    let messages: [String]

    var body: some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: "info.circle")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.info)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("数据口径")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppPalette.spaceS)
        .background(
            AppPalette.info.opacity(0.06),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .accessibilityElement(children: .combine)
    }
}
