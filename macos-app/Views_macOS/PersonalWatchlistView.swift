import Charts
import SwiftUI

struct PersonalWatchlistPanel: View {
    @EnvironmentObject private var model: AppModel

    @State private var selectedItemID: UUID?
    @State private var isPresentingAddSheet = false
    @State private var deletingRecord: PersonalWatchlistRecord?
    @State private var configuringAlertRow: PersonalWatchlistQuoteRow?

    private var rows: [PersonalWatchlistQuoteRow] {
        model.personalWatchlistSnapshot?.rows
            ?? PersonalWatchlistSnapshot.local(records: model.personalWatchlistRecords).rows
    }

    var body: some View {
        SectionCard(
            title: "我的关注",
            subtitle: "记录首次关注价，持续对比场外基金、场内基金与股票的每日走势",
            icon: "star",
            trailing: {
                Spacer()
                Button {
                    Task { await refreshWatchlist() }
                } label: {
                    Label(
                        model.isRefreshingPersonalWatchlist ? "刷新中…" : "刷新",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(rows.isEmpty || model.isRefreshingPersonalWatchlist)

                Button {
                    isPresentingAddSheet = true
                } label: {
                    Label("添加关注", systemImage: "plus.circle")
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .controlSize(.small)
            }
        ) {
            if rows.isEmpty {
                EmptySectionState(
                    title: "还没有关注标的",
                    subtitle: "添加后会锁定首次有效价格，并按交易日记录走势。支持场外基金、场内基金和股票。",
                    actionTitle: "添加关注",
                    action: { isPresentingAddSheet = true }
                )
            } else {
                groupedList
            }
        }
        .sheet(isPresented: $isPresentingAddSheet) {
            PersonalWatchlistAddSheet()
        }
        .sheet(item: $configuringAlertRow) { row in
            PersonalWatchlistAlertSheet(row: row)
        }
        .alert("取消关注？", isPresented: deleteConfirmationBinding) {
            Button("取消关注", role: .destructive) {
                if let deletingRecord {
                    model.removePersonalWatchlistItem(deletingRecord.id)
                    if selectedItemID == deletingRecord.id {
                        selectedItemID = nil
                    }
                }
                deletingRecord = nil
            }
            Button("保留", role: .cancel) {
                deletingRecord = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onChange(of: rows.map(\.id)) { _, _ in
            clearMissingSelection()
        }
    }

    private var groupedList: some View {
        LazyVStack(alignment: .leading, spacing: AppPalette.spaceL) {
            ForEach(PersonalWatchlistCategory.allCases) { category in
                let categoryRows = rows.filter { $0.category == category }
                if !categoryRows.isEmpty {
                    PersonalWatchlistGroup(
                        category: category,
                        rows: categoryRows,
                        selectedItemID: selectedItemID,
                        onSelect: { toggleSelection($0.id) },
                        onConfigureAlerts: { configuringAlertRow = $0 },
                        onDelete: { deletingRecord = $0.record }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingRecord != nil },
            set: { isPresented in
                if !isPresented { deletingRecord = nil }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let deletingRecord else { return "" }
        let name = deletingRecord.item.normalizedName ?? deletingRecord.item.normalizedCode
        return "会删除 \(name) 的关注基准与本地每日价格记录，不会影响实际持仓。"
    }

    private func toggleSelection(_ id: UUID) {
        withAnimation(AppPalette.motionStandard) {
            selectedItemID = selectedItemID == id ? nil : id
        }
    }

    private func clearMissingSelection() {
        guard let selectedItemID,
              !rows.contains(where: { $0.id == selectedItemID }) else { return }
        self.selectedItemID = nil
    }

    private func refreshWatchlist() async {
        do {
            try await model.refreshPersonalWatchlist()
        } catch {
            model.errorMessage = "我的关注刷新失败：\(error.localizedDescription)"
        }
    }
}
