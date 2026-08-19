import SwiftUI

struct EnhancementCenterView: View {
    @EnvironmentObject var model: AppModel
    @State var selectedTrendEvidenceDetail: TrendEvidenceDetailSelection?

    /// 通知深链（trade-signals / 跟踪项 UUID）命中时自动展开底部旧趋势跟踪清单。
    @State var isLegacyTrackingExpanded = false

    /// 摘要行 → 区段锚点滚动/高亮的协调器(经 environment 注入给摘要卡与各锚点)。
    @StateObject private var sectionAnchors = InvestmentSectionAnchorModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    investmentDashboardContent
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .environment(\.investmentSectionAnchors, sectionAnchors)
            .onChange(of: model.selectedTrendTrackingItemID) { _, id in
                if id != nil { isLegacyTrackingExpanded = true }
            }
            .onChange(of: sectionAnchors.scrollTo) { _, target in
                guard let target else { return }
                withAnimation(AppPalette.motionStandard) {
                    proxy.scrollTo(target.rawValue, anchor: .top)
                }
                sectionAnchors.highlighted = target
                sectionAnchors.scrollTo = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak sectionAnchors] in
                    if sectionAnchors?.highlighted == target {
                        sectionAnchors?.highlighted = nil
                    }
                }
            }
            .sheet(item: $selectedTrendEvidenceDetail) { selection in
                TrendEvidenceDetailSheet(selection: selection)
            }
        }
    }
}
