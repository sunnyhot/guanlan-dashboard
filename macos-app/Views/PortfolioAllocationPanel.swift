import Charts
import SwiftUI

private enum PortfolioAllocationViewMode: String, CaseIterable, Identifiable {
    case direct = "账面类型"
    case lookThrough = "基金穿透"

    var id: Self { self }

    var subtitle: String {
        switch self {
        case .direct:
            return "按直接持有形式观察当前有效敞口"
        case .lookThrough:
            return "按基金公开定期报告穿透至资产大类、行业和底层证券"
        }
    }
}

private struct PortfolioAllocationSlice: Identifiable {
    let id: String
    let label: String
    let weightPct: Double
    let detail: String
    let tint: Color
}

private struct PortfolioRankedExposure: Identifiable {
    let id: String
    let label: String
    let detail: String
    let weightPct: Double
}

struct PortfolioAllocationPanel: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("portfolio.allocation.viewMode")
    private var selectedModeRawValue = PortfolioAllocationViewMode.direct.rawValue

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

    var body: some View {
        SectionCard(
            title: "资产分布",
            subtitle: selectedMode.subtitle,
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

    @ViewBuilder
    private var directDistribution: some View {
        if let summary = PortfolioAssetDistributionSummary.make(rows: model.personalAssetRows) {
            let slices = summary.items.enumerated().map { index, item in
                PortfolioAllocationSlice(
                    id: item.category.rawValue,
                    label: item.category.displayName,
                    weightPct: item.weightPct,
                    detail: "\(item.assetCount) 个标的 · \(currencyText(item.amount))",
                    tint: palette[index % palette.count]
                )
            }

            distributionOverview(
                slices: slices,
                centerValue: compactCurrencyText(summary.totalExposure),
                centerLabel: "有效敞口"
            )

            Text("有效敞口包含已持有市值、待确认买入金额与下次计划投入，便于和组合分析中的总持仓口径保持一致。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            allocationEmptyState(
                icon: "chart.pie",
                title: "暂无可展示的资产类型",
                detail: "添加持仓、买入中记录或进行中的计划后，这里会按资产类型汇总。"
            )
        }
    }

    @ViewBuilder
    private var lookThroughDistribution: some View {
        if model.isRefreshingPortfolioLookThrough,
           model.portfolioLookThroughSnapshot == nil {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在读取基金公开披露")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("将汇总资产大类、行业和底层证券，首次读取可能需要片刻。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .center)
        } else if let snapshot = model.portfolioLookThroughSnapshot,
                  snapshot.coveredFundCount > 0 {
            lookThroughContent(snapshot)
        } else if model.personalAssetRows.contains(where: {
            $0.assetType == .fund && $0.effectiveHoldingAmount > 0.001
        }) {
            VStack(alignment: .leading, spacing: 10) {
                allocationEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "暂未取得基金穿透数据",
                    detail: model.portfolioLookThroughSourceWarnings.first
                        ?? "公开披露源暂时没有返回可用的持仓与资产配置。"
                )

                Button {
                    Task {
                        await model.refreshPortfolioLookThrough(force: true)
                    }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(model.isRefreshingPortfolioLookThrough)
            }
        } else {
            allocationEmptyState(
                icon: "square.stack.3d.up.slash",
                title: "当前没有可穿透的基金资产",
                detail: "录入基金持仓或待确认买入后，这里会根据公开定期报告展示底层分布。"
            )
        }
    }

    private func lookThroughContent(_ snapshot: PortfolioLookThroughSnapshot) -> some View {
        let assetSlices = lookThroughAssetSlices(snapshot)
        let industryItems = snapshot.industries.prefix(8).map {
            PortfolioRankedExposure(
                id: $0.id,
                label: $0.name,
                detail: "穿透后行业暴露",
                weightPct: $0.portfolioWeightPct
            )
        }
        let positionItems = snapshot.topPositions.prefix(8).map {
            PortfolioRankedExposure(
                id: $0.id,
                label: $0.name,
                detail: "\($0.kind.displayName) · \($0.contributors.count) 个来源",
                weightPct: $0.portfolioWeightPct
            )
        }

        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                StatChip(
                    title: "基金披露覆盖",
                    value: "\(snapshot.coveredFundCount) / \(snapshot.expectedFundCount) 只"
                )
                StatChip(
                    title: "基金金额覆盖",
                    value: percentageText(snapshot.fundDataCoveragePct)
                )
                StatChip(
                    title: "底层重仓覆盖组合",
                    value: percentageText(snapshot.disclosedSecurityCoveragePct)
                )
                StatChip(
                    title: "未披露底层仓位",
                    value: percentageText(snapshot.unknownPortfolioWeightPct)
                )
            }

            distributionOverview(
                slices: assetSlices,
                centerValue: "\(snapshot.coveredFundCount)/\(snapshot.expectedFundCount)",
                centerLabel: "基金已穿透"
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    PortfolioRankedExposurePanel(
                        title: "行业分布",
                        emptyMessage: "披露中暂无行业配置",
                        items: Array(industryItems),
                        tint: AppPalette.brand
                    )
                    PortfolioRankedExposurePanel(
                        title: "底层重仓",
                        emptyMessage: "披露中暂无底层证券",
                        items: Array(positionItems),
                        tint: AppPalette.info
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    PortfolioRankedExposurePanel(
                        title: "行业分布",
                        emptyMessage: "披露中暂无行业配置",
                        items: Array(industryItems),
                        tint: AppPalette.brand
                    )
                    PortfolioRankedExposurePanel(
                        title: "底层重仓",
                        emptyMessage: "披露中暂无底层证券",
                        items: Array(positionItems),
                        tint: AppPalette.info
                    )
                }
            }

            lookThroughFootnote(snapshot)
        }
    }

    private func distributionOverview(
        slices: [PortfolioAllocationSlice],
        centerValue: String,
        centerLabel: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                allocationDonut(
                    slices: slices,
                    centerValue: centerValue,
                    centerLabel: centerLabel
                )
                .frame(width: 190, height: 176)

                allocationLegend(slices)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 12) {
                allocationDonut(
                    slices: slices,
                    centerValue: centerValue,
                    centerLabel: centerLabel
                )
                .frame(maxWidth: .infinity)
                .frame(height: 176)

                allocationLegend(slices)
            }
        }
        .padding(12)
        .background(
            AppPalette.cardStrong.opacity(0.58),
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.28), lineWidth: 1)
        )
    }

    private func allocationDonut(
        slices: [PortfolioAllocationSlice],
        centerValue: String,
        centerLabel: String
    ) -> some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("资产占比", max(0, slice.weightPct)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.4
                )
                .foregroundStyle(slice.tint)
                .cornerRadius(3)
            }
            .chartLegend(.hidden)

            VStack(spacing: 2) {
                Text(centerValue)
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(centerLabel)
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 92)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerLabel)，\(centerValue)")
        .accessibilityValue(
            slices.map { "\($0.label) \(percentageText($0.weightPct))" }.joined(separator: "，")
        )
    }

    private func allocationLegend(_ slices: [PortfolioAllocationSlice]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(slice.tint)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(slice.label)
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                        Text(slice.detail)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(percentageText(slice.weightPct))
                        .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
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

    @ViewBuilder
    private func lookThroughFootnote(_ snapshot: PortfolioLookThroughSnapshot) -> some View {
        let latestDisclosureDate = snapshot.funds.compactMap(\.asOf).max()
        let warnings = uniqueWarnings(
            snapshot.warnings + model.portfolioLookThroughSourceWarnings
        )

        VStack(alignment: .leading, spacing: 5) {
            Text(
                latestDisclosureDate.map { "公开定期报告 · 最新披露 \($0)" }
                    ?? "公开定期报告"
            )
            .font(AppPalette.appFont(.caption, weight: .semibold))
            .foregroundStyle(AppPalette.muted)

            ForEach(Array(warnings.prefix(2)), id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func allocationEmptyState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.title2, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 34, height: 34)
                .background(
                    AppPalette.muted.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            AppPalette.cardStrong.opacity(0.52),
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
    }

    private func percentageText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
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

private struct PortfolioRankedExposurePanel: View {
    let title: String
    let emptyMessage: String
    let items: [PortfolioRankedExposure]
    let tint: Color

    private var maximumWeight: Double {
        max(items.map(\.weightPct).max() ?? 0, 0.01)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            if items.isEmpty {
                Text(emptyMessage)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(1)
                                Text(item.detail)
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Text(String(format: "%.2f%%", item.weightPct))
                                .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                                .monospacedDigit()
                        }

                        ProgressView(
                            value: max(0, item.weightPct),
                            total: maximumWeight
                        )
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .accessibilityLabel(item.label)
                        .accessibilityValue(String(format: "%.2f%%", item.weightPct))
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
        .background(
            tint.opacity(0.045),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }
}
