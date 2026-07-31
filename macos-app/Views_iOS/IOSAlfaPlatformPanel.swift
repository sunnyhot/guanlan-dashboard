#if os(iOS)
import SwiftUI

// MARK: - iOS alfa 投顾组合面板
//
// 复用 AppModel 的 alfa 状态/方法。chip 筛选已添加组合 + 添加(目录/手输 poCode)
// + 选中组合的调仓动作列表 + 持仓卡片(目标占比/净值/日涨跌)。

struct IOSAlfaPlatformPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
                portfolioChips
                if model.alfaPortfolios.isEmpty {
                    IOSEmptyState(
                        title: "暂无投顾组合",
                        subtitle: "添加且慢投顾组合(如晓磊),跟踪其调仓动态与持仓配置。",
                        actionTitle: "添加组合"
                    ) {
                        showingAddSheet = true
                    }
                    .padding(.top, IOSDesign.spaceL)
                } else {
                    selectedPortfolioContent
                }
                if let err = model.alfaError, !err.isEmpty {
                    Text(err).font(IOSDesign.sansBody(12)).foregroundStyle(AppPalette.marketGain).padding(.horizontal)
                }
            }
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.vertical, IOSDesign.spaceS + 4)
        }
        .background(IOSDesign.paper)
        .refreshable {
            await model.refreshAlfaPayload()
        }
        .task {
            if model.alfaPortfolios.isEmpty {
                await model.loadAlfaCatalog()
            }
            if model.alfaPayload == nil {
                await model.fetchAllAlfaPayloads()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            IOSAddAlfaPortfolioSheet()
        }
    }

    // MARK: - 组合 chip 筛选

    private var portfolioChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: IOSDesign.spaceS) {
                ForEach(model.alfaPortfolios) { portfolio in
                    chipButton(portfolio)
                }
                Button { showingAddSheet = true } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                        .font(IOSDesign.sansBody(13, weight: .medium))
                        .padding(.horizontal, IOSDesign.spaceS + 2)
                        .padding(.vertical, 6)
                        .background(IOSDesign.accent.opacity(0.1), in: Capsule())
                        .foregroundStyle(IOSDesign.accent)
                }
            }
        }
    }

    private func chipButton(_ p: AlfaPortfolioCatalogItem) -> some View {
        let selected = model.selectedAlfaPoCode == p.poCode
        return Button {
            Task { await model.selectAlfaPortfolio(p.poCode) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(IOSDesign.sansBody(13, weight: .semibold))
                Text(p.author).font(IOSDesign.sansBody(10)).opacity(0.7)
            }
            .padding(.horizontal, IOSDesign.spaceS + 2)
            .padding(.vertical, 5)
            .background(selected ? IOSDesign.accent : IOSDesign.card, in: Capsule())
            .foregroundStyle(selected ? .white : IOSDesign.ink)
        }
    }

    // MARK: - 选中组合内容

    @ViewBuilder
    private var selectedPortfolioContent: some View {
        if model.isLoadingAlfa {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let selected = model.selectedAlfaPortfolio {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
                // 组合信息卡
                IOSSectionCard(title: selected.name, subtitle: "\(selected.author) · \(selected.category)", icon: "person.crop.circle.badge.checkmark") {
                    EmptyView()
                }
                // 调仓动作
                let actions = model.filteredAlfaActions
                if !actions.isEmpty {
                    IOSSectionCard(title: "调仓动态", subtitle: "\(actions.count) 笔", icon: "arrow.triangle.2.circlepath") {
                        ForEach(Array(actions.prefix(20)), id: \.id) { action in
                            alfaActionRow(action)
                            if action.id != actions.prefix(20).last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                // 持仓
                let holdings = model.filteredAlfaHoldings
                if !holdings.isEmpty {
                    holdingsCard(holdings, author: selected.author)
                }
            }
        } else {
            Text("选择上方组合查看详情").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted).padding()
        }
    }

    private func alfaActionRow(_ action: PlatformActionPayload) -> some View {
        Button { detailAction = action } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let side = action.side { sideBadge(side) }
                    Text(action.displayTitle).font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Spacer()
                }
                actionSummary(action)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @State private var detailAction: PlatformActionPayload?

    private func holdingsCard(_ holdings: [AlfaHoldingPart], author: String) -> some View {
        let total = holdings.reduce(0.0) { $0 + $1.percent }
        return IOSSectionCard(title: "目标持仓", subtitle: "\(holdings.count) 只 · 配置 \(String(format: "%.0f%%", total * 100))", icon: "piechart") {
            ForEach(Array(holdings.enumerated()), id: \.element.id) { idx, part in
                holdingRow(part, rank: idx + 1)
                if part.id != holdings.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .sheet(item: $detailAction) { action in
            IOSPlatformActionDetailSheet(action: action).presentationDetents([.large])
        }
    }

    private func holdingRow(_ part: AlfaHoldingPart, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(rank)").font(IOSDesign.monoNumber(11)).foregroundStyle(IOSDesign.muted).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.fundName).font(IOSDesign.sansBody(13, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Text(part.fundCode).font(IOSDesign.sansBody(10)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                Text(part.percentText).font(IOSDesign.monoNumber(13)).foregroundStyle(IOSDesign.accent)
            }
            ProgressView(value: part.percent, total: 1.0).tint(IOSDesign.accent.opacity(0.5))
            HStack {
                if let nav = part.nav {
                    Text("净值 \(String(format: "%.4f", nav))").font(IOSDesign.sansBody(10)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                if let ret = part.dailyReturn {
                    Text(part.dailyReturnText).font(IOSDesign.monoNumber(11)).foregroundStyle(ret >= 0 ? AppPalette.marketGain : AppPalette.marketLoss)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 复用 sideBadge / actionSummary(简化版)

    private func sideBadge(_ side: String) -> some View {
        let isBuy = side.lowercased() == "buy"
        return Text(isBuy ? "买入" : "卖出")
            .font(IOSDesign.sansBody(10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((isBuy ? AppPalette.marketGain : AppPalette.marketLoss).opacity(0.12), in: Capsule())
            .foregroundStyle(isBuy ? AppPalette.marketGain : AppPalette.marketLoss)
    }

    @ViewBuilder
    private func actionSummary(_ action: PlatformActionPayload) -> some View {
        if action.isPercentBased {
            HStack(spacing: 4) {
                if let b = action.beforePercent { Text(String(format: "%.1f%%", b*100)).font(IOSDesign.monoNumber(11)).foregroundStyle(IOSDesign.muted) }
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(IOSDesign.muted)
                if let a = action.afterPercent { Text(String(format: "%.1f%%", a*100)).font(IOSDesign.monoNumber(11, weight: .semibold)).foregroundStyle(IOSDesign.accent) }
                if let g = action.groupName, !g.isEmpty { Spacer(); Text(g).font(IOSDesign.sansBody(10)).foregroundStyle(IOSDesign.muted) }
            }
        }
    }
}

// MARK: - 添加 alfa 组合 Sheet

struct IOSAddAlfaPortfolioSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualCode = ""

    var body: some View {
        NavigationStack {
            List {
                if !model.alfaCatalog.isEmpty {
                    Section("推荐组合") {
                        ForEach(model.alfaCatalog) { item in
                            Button {
                                Task {
                                    let ok = await model.addAlfaPortfolio(item)
                                    if ok { dismiss() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.name).foregroundStyle(IOSDesign.ink)
                                        Text("\(item.author) · \(item.category)").font(.caption).foregroundStyle(IOSDesign.muted)
                                    }
                                    Spacer()
                                    if model.alfaPortfolios.contains(where: { $0.poCode == item.poCode }) {
                                        Image(systemName: "checkmark").foregroundStyle(IOSDesign.accent)
                                    } else {
                                        Image(systemName: "plus.circle").foregroundStyle(IOSDesign.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("手动添加") {
                    TextField("组合代码,如 SI000192", text: $manualCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") {
                        Task {
                            let ok = await model.addAlfaPortfolioByCode(manualCode)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoadingAlfa)
                }
                if model.isLoadingAlfa { Section { ProgressView() } }
            }
            .navigationTitle("添加投顾组合")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .task { if model.alfaCatalog.isEmpty { await model.loadAlfaCatalog() } }
        }
    }
}
#endif
