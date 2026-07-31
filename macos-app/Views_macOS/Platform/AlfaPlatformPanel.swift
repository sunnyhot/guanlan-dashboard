import SwiftUI

// MARK: - AlfaPlatformPanel

/// alfa 投顾组合调仓面板：组合单选 + 该组合的调仓与当前持仓。
/// 复用 `PlatformActionRow` / `PlatformActionDetailCard` 渲染。
struct AlfaPlatformPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddSheet = false
    @State private var manualPoCode = ""

    let isCompact: Bool
    let availableWidth: CGFloat
    let scrollProxy: ScrollViewProxy

    private let detailAnchor = "alfa-detail-panel"

    private var actions: [PlatformActionPayload] {
        model.filteredAlfaActions
    }

    private var selectedAction: PlatformActionPayload? {
        if let selectedActionID = model.selectedAlfaActionID,
           let matched = actions.first(where: { $0.id == selectedActionID }) {
            return matched
        }
        return actions.first
    }

    private var selectedPortfolio: AlfaPortfolioCatalogItem? {
        model.selectedAlfaPortfolio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar

            if model.alfaPortfolios.isEmpty {
                emptyPortfoliosState
            } else if model.isLoadingAlfa {
                loadingState
            } else if let error = model.alfaError, actions.isEmpty {
                errorState(error)
            } else if actions.isEmpty {
                emptyActionsState
            } else if isCompact {
                VStack(alignment: .leading, spacing: 8) {
                    actionsList(isCompact: true, scrollProxy: scrollProxy)
                    if let selected = selectedAction {
                        PlatformActionDetailCard(action: selected)
                            .id(detailAnchor)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    actionsList(isCompact: false, scrollProxy: scrollProxy)
                        .frame(width: min(max(availableWidth * 0.36, 320), 420), alignment: .top)
                    if let selected = selectedAction {
                        PlatformActionDetailCard(action: selected)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }

            holdingsSection
        }
        .sheet(isPresented: $showingAddSheet) {
            addPortfolioSheet
        }
        .onAppear {
            if model.alfaCatalog.isEmpty {
                Task { await model.loadAlfaCatalog() }
            }
            // 进入面板时若没有数据则自动加载（调仓 + 持仓）
            if !model.alfaPortfolios.isEmpty, model.alfaPayload == nil, model.alfaHoldings.isEmpty, !model.isLoadingAlfa {
                Task { await model.fetchAllAlfaPayloads() }
            }
        }
    }

    // MARK: - 筛选栏

    private var filterBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if model.alfaPortfolios.isEmpty {
                    Text("投顾组合")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(model.alfaPortfolios) { portfolio in
                            portfolioChip(portfolio)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.line.opacity(0.5), lineWidth: 1)
        )
    }

    private func portfolioChip(_ portfolio: AlfaPortfolioCatalogItem) -> some View {
        let selected = model.selectedAlfaPoCode == portfolio.poCode
        return Button {
            model.selectedAlfaActionID = nil
            Task { await model.selectAlfaPortfolio(portfolio.poCode) }
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                Text(portfolio.name)
                    .lineLimit(1)
            }
            .font(AppPalette.appFont(.subheadline, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? AppPalette.onBrand : AppPalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                    .fill(selected ? AppPalette.brand : AppPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                    .stroke(selected ? AppPalette.brand : AppPalette.line.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingAlfa)
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            Button {
                showingAddSheet = true
            } label: {
                Label("添加", systemImage: "plus.circle")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.brand)

            if !model.alfaPortfolios.isEmpty {
                Button {
                    Task { await model.refreshAlfaPayload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.muted)
            }
        }
    }

    // MARK: - 调仓列表

    private func actionsList(isCompact: Bool, scrollProxy: ScrollViewProxy) -> some View {
        SectionCard(
            title: "调仓记录",
            subtitle: isCompact ? "窄窗口先选动作，再向下看详情" : "左侧选动作，右侧看详情",
            icon: "list.bullet.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TintedCapsuleBadge(
                        text: "\(actions.count) 条",
                        tint: AppPalette.muted,
                        style: .neutral,
                        font: AppPalette.appFont(.caption, weight: .bold, design: .rounded),
                        horizontalPadding: 6,
                        verticalPadding: 2
                    )
                    Spacer()
                }

                if isCompact {
                    LazyVStack(spacing: 4) {
                        actionButtons(isCompact: true, scrollProxy: scrollProxy)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            actionButtons(isCompact: false, scrollProxy: scrollProxy)
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(height: PlatformWorkspaceLayout.actionListHeight)
                    .clipped()
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(isCompact: Bool, scrollProxy: ScrollViewProxy) -> some View {
        ForEach(actions.prefix(60)) { action in
            Button {
                model.selectedAlfaActionID = action.id
                if isCompact {
                    withAnimation(AppPalette.motionSlow) {
                        scrollProxy.scrollTo(detailAnchor, anchor: .top)
                    }
                }
            } label: {
                PlatformActionRow(
                    action: action,
                    isSelected: selectedAction?.id == action.id,
                    isCompact: true,
                    titlePrefix: ""
                )
            }
            .buttonStyle(PressResponsiveButtonStyle())
        }
    }

    // MARK: - 当前持仓

    @ViewBuilder
    private var holdingsSection: some View {
        let holdings = model.filteredAlfaHoldings
        if let selectedPortfolio, !holdings.isEmpty {
            SectionCard(
                title: "当前持仓",
                subtitle: "\(selectedPortfolio.name) · 单组合目标配置",
                icon: "bag"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    holdingsSummary(portfolio: selectedPortfolio, holdings: holdings)

                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: isCompact ? 280 : 340, maximum: 520),
                                spacing: 10,
                                alignment: .top
                            ),
                        ],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(Array(holdings.enumerated()), id: \.element.id) { index, part in
                            AlfaHoldingCard(part: part, rank: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func holdingsSummary(
        portfolio: AlfaPortfolioCatalogItem,
        holdings: [AlfaHoldingPart]
    ) -> some View {
        let totalPercent = holdings.reduce(0) { $0 + $1.percent }
        return HStack(spacing: 8) {
            Label(portfolio.author.isEmpty ? portfolio.poCode : portfolio.author, systemImage: "person.crop.circle")
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Spacer()
            TintedCapsuleBadge(
                text: "\(holdings.count) 只基金",
                tint: AppPalette.info,
                font: AppPalette.appFont(.footnote, weight: .semibold),
                horizontalPadding: 8,
                verticalPadding: 4,
                softFillOpacity: 0.10,
                softStrokeOpacity: nil
            )
            TintedCapsuleBadge(
                text: String(format: "目标配置 %.2f%%", totalPercent * 100),
                tint: AppPalette.brand,
                font: AppPalette.appFont(.footnote, weight: .semibold, design: .rounded),
                horizontalPadding: 8,
                verticalPadding: 4,
                softFillOpacity: 0.10,
                softStrokeOpacity: nil
            )
        }
    }

    // MARK: - 状态视图

    private var emptyPortfoliosState: some View {
        EmptySectionState(
            title: "还没有添加投顾组合",
            subtitle: "点右上角「添加」，选择一个近一年有公开调仓记录的且慢投顾组合。",
            actionTitle: "添加组合"
        ) {
            showingAddSheet = true
        }
    }

    private var emptyActionsState: some View {
        EmptySectionState(
            title: "暂无调仓记录",
            subtitle: "所选投顾组合目前没有公开的调仓动作。",
            actionTitle: "刷新"
        ) {
            Task { await model.refreshAlfaPayload() }
        }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在拉取投顾调仓…")
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func errorState(_ message: String) -> some View {
        EmptySectionState(
            title: "拉取失败",
            subtitle: message,
            actionTitle: "重试"
        ) {
            Task { await model.refreshAlfaPayload() }
        }
    }

    // MARK: - 添加组合 sheet

    private var addPortfolioSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("添加投顾组合")
                    .font(AppPalette.appFont(.title3, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("完成") { showingAddSheet = false }
                    .buttonStyle(.appText)
            }

            Text("从且慢严选组合列表选择，或直接输入组合码（如 ZH157591）。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)

            if model.isLoadingAlfaCatalog {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("加载组合列表…")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
            } else {
                catalogList
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("手动输入组合码")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                HStack(spacing: 8) {
                    TextField("如 ZH157591", text: $manualPoCode)
                        .textFieldStyle(.plain)
                        .font(AppPalette.appFont(.body))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    Button("添加") {
                        Task {
                            let ok = await model.addAlfaPortfolioByCode(manualPoCode)
                            if ok { manualPoCode = "" }
                        }
                    }
                    .buttonStyle(.appPrimary)
                    .disabled(manualPoCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var catalogList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let grouped = Dictionary(grouping: model.alfaCatalog, by: { $0.category })
                let sortedCategories = grouped.keys.sorted()
                ForEach(sortedCategories, id: \.self) { category in
                    Text(category.isEmpty ? "其他" : category)
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.top, 6)
                    ForEach(grouped[category] ?? []) { item in
                        let added = model.alfaPortfolios.contains(where: { $0.poCode == item.poCode })
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(AppPalette.appFont(.body, weight: .medium))
                                    .foregroundStyle(AppPalette.ink)
                                Text("\(item.author) · \(item.poCode)")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                            }
                            Spacer()
                            if added {
                                Image(systemName: "checkmark")
                                    .font(AppPalette.appFont(.footnote, weight: .bold))
                                    .foregroundStyle(AppPalette.muted)
                            } else {
                                Button("添加") {
                                    Task { _ = await model.addAlfaPortfolio(item) }
                                }
                                .buttonStyle(.appText)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                                .fill(AppPalette.card)
                        )
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }
}
