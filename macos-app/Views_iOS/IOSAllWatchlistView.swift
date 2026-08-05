#if os(iOS)
import SwiftUI

// MARK: - iOS 全部关注列表（从持仓页 push 进来）
//
// 与 IOSAllHoldingsView 对称：首页关注列表只展示前 5 条，超出部分通过「查看全部」push 到本视图。
// List（lazy）+ 行删除 + 顶部添加按钮 + 下拉刷新。行点击进 IOSWatchlistDetailSheet。
// 行渲染复用 IOSWatchlistRow（与首页共享）。

struct IOSAllWatchlistView: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailRecord: PersonalWatchlistRecord?
    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(model.personalWatchlistRecords) { record in
                IOSWatchlistRow(record: record) { detailRecord = record }
                    .listRowInsets(EdgeInsets(top: 6, leading: IOSDesign.spaceM, bottom: 6, trailing: IOSDesign.spaceM))
                    .listRowSeparator(.hidden)
            }
            .onDelete { indexSet in
                for i in indexSet {
                    model.removePersonalWatchlistItem(model.personalWatchlistRecords[i].item.id)
                }
            }
        }
        .listStyle(.plain)
        .background(IOSDesign.paper)
        .scrollContentBackground(.hidden)
        .navigationTitle("关注列表")
        .navigationBarTitleDisplayMode(.inline)
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
}
#endif
