import SwiftUI

struct EnhancementCenterView: View {
    @EnvironmentObject var model: AppModel
    @State var selectedTrendEvidenceDetail: TrendEvidenceDetailSelection?

    /// 通知深链（trade-signals / 跟踪项 UUID）命中时自动展开底部旧趋势跟踪清单。
    @State var isLegacyTrackingExpanded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                investmentDashboardContent
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.selectedTrendTrackingItemID) { _, id in
            if id != nil { isLegacyTrackingExpanded = true }
        }
        .sheet(item: $selectedTrendEvidenceDetail) { selection in
            TrendEvidenceDetailSheet(selection: selection)
        }
    }
}
