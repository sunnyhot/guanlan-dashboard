#if os(iOS)
import SwiftUI

// MARK: - iOS 持仓页
//
// 三段子 tab：组合分析 / 持仓明细 / 关注列表。
// - 组合分析：概览卡 + 诊断 + 归因 + 穿透（复用 Core 纯函数派生）。
// - 持仓明细 / 关注列表：List 全量展示，分页每页 10 条（滚到底自动加载下一页）。

struct PortfolioSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: PortfolioSegment = .analysis

    enum PortfolioSegment: String, CaseIterable, Identifiable {
        case analysis = "组合分析"
        case holdings = "持仓明细"
        case watchlist = "关注列表"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch segment {
            case .analysis:  analysisContent
            case .holdings:  IOSHoldingsListTab(segment: $segment)
            case .watchlist: IOSWatchlistListTab(segment: $segment)
            }
        }
        .background(IOSDesign.paper)
    }

    // MARK: 分段 Picker（注入各子内容顶部，随内容滚动，大标题联动正常）

    fileprivate var segmentPicker: some View {
        Picker("", selection: $segment) {
            ForEach(PortfolioSegment.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, IOSDesign.spaceM)
        .padding(.top, 2)
        .padding(.bottom, IOSDesign.spaceS)
    }

    // MARK: 组合分析

    private var analysisContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                segmentPicker
                overviewCard
                IOSPortfolioDiagnosticsPanel(summary: model.portfolioDiagnosticsSummary)
                IOSProfitAttributionPanel(summary: model.profitAttributionSummary)
                IOSPortfolioLookThroughPanel(snapshot: model.portfolioLookThroughSnapshot)
            }
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .refreshable {
            try? await model.refreshLatest(updateNotice: false)
            await model.refreshPortfolioLookThrough(force: true)
        }
        .task(id: model.portfolioLookThroughRequestKey) {
            await model.refreshPortfolioLookThrough()
        }
    }

    // MARK: - 资产概览卡

    private var overviewCard: some View {
        let snapshot = model.userPortfolioSnapshot
        return IOSSectionCard(title: "我的持仓", subtitle: snapshot?.refreshedAt ?? "尚未加载", icon: "briefcase.fill") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    IOSStatTile(
                        title: "总市值",
                        value: snapshot.map { currencyText($0.totalMarketValue) } ?? "—"
                    )
                    IOSStatTile(
                        title: snapshot?.dailyChangeTitle ?? "今日涨跌",
                        value: dailyChangeText(snapshot?.dailyChangeSummary.amount),
                        tone: marketTone(for: snapshot?.dailyChangeSummary.amount)
                    )
                    IOSStatTile(
                        title: "累计收益",
                        value: profitText(snapshot?.totalProfitAmount),
                        tone: marketTone(for: snapshot?.totalProfitAmount)
                    )
                    IOSStatTile(
                        title: "累计收益率",
                        value: profitPctText(snapshot?.totalProfitPct),
                        tone: marketTone(for: snapshot?.totalProfitPct)
                    )
                }
                if let pct = snapshot?.dailyChangeSummary.pct {
                    HStack {
                        Text("今日涨跌幅")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.muted)
                        Spacer()
                        Text(dailyChangePercentText(pct))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(marketTone(for: pct).color)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - 格式化辅助

    private func dailyChangeText(_ amount: Double?) -> String {
        guard let amount else { return "—" }
        return signedCurrencyText(amount)
    }

    private func profitText(_ amount: Double?) -> String {
        guard let amount else { return "—" }
        return signedCurrencyText(amount)
    }

    private func profitPctText(_ pct: Double?) -> String {
        guard let pct else { return "—" }
        return dailyChangePercentText(pct)
    }
}

// MARK: - 持仓明细 tab（List 全量 + 分页每页 10 条）

struct IOSHoldingsListTab: View {
    @Binding private var segment: PortfolioSectionView.PortfolioSegment
    @EnvironmentObject private var model: AppModel
    @State private var detailRow: PersonalAssetAggregateRow?
    @State private var editingRow: PersonalAssetAggregateRow?
    @State private var pendingDeleteRow: PersonalAssetAggregateRow?
    @State private var showingAdd = false
    @State private var displayedCount = 10
    @State private var refreshTrigger = false
    private let pageSize = 10
    private let pinnedStore = PinnedItemsStore(namespace: "holdings")

    init(segment: Binding<PortfolioSectionView.PortfolioSegment>) {
        self._segment = segment
    }

    private var allRows: [PersonalAssetAggregateRow] {
        _ = refreshTrigger // 依赖触发刷新
        let rows = model.personalAssetRows.filter { $0.holdingRow != nil }
        return pinnedStore.sorted(rows, id: \.id)
    }

    var body: some View {
        List {
            // 分段 Picker 随列表滚动（与其他 tab 一致）
            Picker("", selection: $segment) {
                ForEach(PortfolioSectionView.PortfolioSegment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 0, leading: IOSDesign.spaceM, bottom: IOSDesign.spaceS, trailing: IOSDesign.spaceM))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if allRows.isEmpty {
                IOSEmptyState(
                    title: "暂无持仓",
                    subtitle: "点击右上角「添加」,录入你的第一只基金或股票。",
                    actionTitle: "添加持仓"
                ) {
                    showingAdd = true
                }
                .listRowInsets(EdgeInsets(top: 40, leading: IOSDesign.spaceM, bottom: 40, trailing: IOSDesign.spaceM))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(allRows.prefix(displayedCount))) { row in
                    let isPinned = pinnedStore.contains(row.id)
                    IOSHoldingRow(row: row, isPinned: isPinned) { detailRow = row }
                        .padding(IOSDesign.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
                        .overlay(RoundedRectangle(cornerRadius: IOSDesign.radiusM).stroke(IOSDesign.ink.opacity(0.1), lineWidth: 1))
                        .listRowInsets(EdgeInsets(top: 4, leading: IOSDesign.spaceM, bottom: 4, trailing: IOSDesign.spaceM))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteRow = row
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editingRow = row
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(IOSDesign.accent)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                togglePin(row.id)
                            } label: {
                                Label(isPinned ? "取消置顶" : "置顶",
                                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                            }
                            .tint(AppPalette.warning)
                        }
                        .onAppear { loadMoreIfNeeded(current: row) }
                }
                if displayedCount < allRows.count {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, IOSDesign.spaceS)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(IOSDesign.paper)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable {
            try? await model.refreshLatest(updateNotice: false)
        }
        .sheet(item: $detailRow) { row in
            IOSPersonalAssetDetailSheet(row: row)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingRow) { row in
            IOSEditHoldingSheet(row: row)
        }
        .sheet(isPresented: $showingAdd) {
            IOSAddHoldingSheet()
        }
        .confirmationDialog(
            pendingDeleteRow.map { "确认删除「\($0.fundName)」的持仓？" } ?? "",
            isPresented: Binding(get: { pendingDeleteRow != nil }, set: { if !$0 { pendingDeleteRow = nil } }),
            titleVisibility: .visible
        ) {
            if let row = pendingDeleteRow {
                Button("删除全部(持仓+待确认+计划)", role: .destructive) {
                    model.deletePersonalAssetEntry(row, scope: .all)
                    pendingDeleteRow = nil
                }
                Button("仅删除持仓", role: .destructive) {
                    model.deletePersonalAssetEntry(row, scope: .holding)
                    pendingDeleteRow = nil
                }
                Button("取消", role: .cancel) { pendingDeleteRow = nil }
            }
        } message: {
            Text("删除后不可恢复。可选择删除范围。")
        }
    }

    private func loadMoreIfNeeded(current row: PersonalAssetAggregateRow) {
        let visible = allRows.prefix(displayedCount)
        guard row.id == visible.last?.id, displayedCount < allRows.count else { return }
        displayedCount = min(displayedCount + pageSize, allRows.count)
    }

    private func togglePin(_ id: String) {
        if pinnedStore.contains(id) {
            pinnedStore.unpin(id)
        } else {
            pinnedStore.pin(id)
        }
        refreshTrigger.toggle()
        displayedCount = max(displayedCount, pageSize) // 置顶重排后重置可见数
    }
}

// MARK: - 关注列表 tab（List 全量 + 分页每页 10 条）

struct IOSWatchlistListTab: View {
    @Binding private var segment: PortfolioSectionView.PortfolioSegment
    @EnvironmentObject private var model: AppModel
    @State private var detailRecord: PersonalWatchlistRecord?
    @State private var showingAdd = false
    @State private var displayedCount = 10
    @State private var refreshTrigger = false
    private let pageSize = 10
    private let pinnedStore = PinnedItemsStore(namespace: "watchlist")

    init(segment: Binding<PortfolioSectionView.PortfolioSegment>) {
        self._segment = segment
    }

    private var allRecords: [PersonalWatchlistRecord] {
        _ = refreshTrigger
        return pinnedStore.sorted(model.personalWatchlistRecords, id: \.item.id.uuidString)
    }

    var body: some View {
        List {
            // 分段 Picker 随列表滚动（与其他 tab 一致）
            Picker("", selection: $segment) {
                ForEach(PortfolioSectionView.PortfolioSegment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 0, leading: IOSDesign.spaceM, bottom: IOSDesign.spaceS, trailing: IOSDesign.spaceM))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if allRecords.isEmpty {
                IOSEmptyState(
                    title: "暂无关注",
                    subtitle: "点击右上角「添加」,关注你的第一只基金或股票。",
                    actionTitle: "添加关注"
                ) {
                    showingAdd = true
                }
                .listRowInsets(EdgeInsets(top: 40, leading: IOSDesign.spaceM, bottom: 40, trailing: IOSDesign.spaceM))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(allRecords.prefix(displayedCount))) { record in
                    let isPinned = pinnedStore.contains(record.item.id.uuidString)
                    IOSWatchlistRow(record: record, showsBaseline: false, isPinned: isPinned) { detailRecord = record }
                        .padding(IOSDesign.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
                        .overlay(RoundedRectangle(cornerRadius: IOSDesign.radiusM).stroke(IOSDesign.ink.opacity(0.1), lineWidth: 1))
                        .listRowInsets(EdgeInsets(top: 4, leading: IOSDesign.spaceM, bottom: 4, trailing: IOSDesign.spaceM))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.removePersonalWatchlistItem(record.item.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                togglePin(record.item.id.uuidString)
                            } label: {
                                Label(isPinned ? "取消置顶" : "置顶",
                                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                            }
                            .tint(AppPalette.warning)
                        }
                        .onAppear { loadMoreIfNeeded(current: record) }
                }
                if displayedCount < allRecords.count {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, IOSDesign.spaceS)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(IOSDesign.paper)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable {
            try? await model.refreshPersonalWatchlist(updateNotice: false)
        }
        .sheet(item: $detailRecord) { record in
            IOSWatchlistDetailSheet(record: record)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAdd) {
            IOSAddWatchlistItemSheet()
        }
    }

    private func loadMoreIfNeeded(current record: PersonalWatchlistRecord) {
        let visible = allRecords.prefix(displayedCount)
        guard record.id == visible.last?.id, displayedCount < allRecords.count else { return }
        displayedCount = min(displayedCount + pageSize, allRecords.count)
    }

    private func togglePin(_ id: String) {
        if pinnedStore.contains(id) {
            pinnedStore.unpin(id)
        } else {
            pinnedStore.pin(id)
        }
        refreshTrigger.toggle()
        displayedCount = max(displayedCount, pageSize)
    }
}
#endif
