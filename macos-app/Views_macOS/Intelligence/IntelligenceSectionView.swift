import SwiftUI

// MARK: - AI 研判（V1 产品旅程 + V2 数据与 Agent 底座）
//
// 页面恢复 V1 的用户决策顺序：今日研判 → 盘中实时 → 市场机会 →
// 组合长期研判 → 收盘复盘 → 关注与复核。战略目标、持仓分类、Provider、
// 数据覆盖与 artifact 历史仍由 V2 提供，但收进次级「数据与系统」区域。

struct IntelligenceSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeSheet: IntelligenceSheet?
    @State private var detailCase: DecisionCaseBox?

    enum SectionAnchor: String {
        case intraday
        case marketRadar
        case longTerm
        case closeReview
        case decisions
    }

    enum IntelligenceSheet: String, Identifiable {
        case editTarget
        case classifyHoldings
        case intradayDetail
        case decisionCases
        case closeReviewDetail

        var id: String { rawValue }
    }

    struct DecisionCaseBox: Identifiable {
        let caseID: String
        var id: String { caseID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    IntelligenceTodaySummaryCard(
                        snapshot: model.intelligenceDashboardSnapshot,
                        loadState: model.intelligenceDashboard,
                        onSelect: { anchor in
                            withAnimation(AppPalette.motionStandard) {
                                proxy.scrollTo(anchor.rawValue, anchor: .top)
                            }
                        }
                    )

                    if let snapshot = model.intelligenceDashboardSnapshot {
                        IntradayDecisionCard(
                            snapshot: snapshot,
                            activeSheet: $activeSheet,
                            model: model
                        )
                        .id(SectionAnchor.intraday.rawValue)

                        MarketDiscoveryCard(snapshot: snapshot, model: model)
                            .id(SectionAnchor.marketRadar.rawValue)

                        PortfolioResearchCard(snapshot: snapshot, model: model)
                            .id(SectionAnchor.longTerm.rawValue)

                        MarketCloseReviewCard(
                            snapshot: snapshot,
                            model: model,
                            activeSheet: $activeSheet
                        )
                        .id(SectionAnchor.closeReview.rawValue)
                    } else {
                        IntelligenceDashboardUnavailableCard(
                            loadState: model.intelligenceDashboard,
                            onRetry: model.refreshIntelligenceDashboard
                        )
                    }

                    DecisionCaseCard(model: model, activeSheet: $activeSheet)
                        .id(SectionAnchor.decisions.rawValue)

                    IntelligenceDataAndSystemCard(
                        snapshot: model.intelligenceDashboardSnapshot,
                        activeSheet: $activeSheet,
                        model: model
                    )
                }
                .padding(14)
                .frame(maxWidth: 1_180, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .editTarget:
                AllocationTargetEditor()
            case .classifyHoldings:
                AssetClassAssignmentEditor()
            case .intradayDetail:
                IntradayDecisionDetailSheet()
            case .decisionCases:
                DecisionCaseListSheet()
            case .closeReviewDetail:
                MarketCloseReviewDetailSheet()
            }
        }
        .sheet(item: $detailCase) { box in
            if let decisionCase = model.decisionCases.first(where: { $0.id == box.caseID }) {
                DecisionCaseDetailSheet(decisionCase: decisionCase)
            }
        }
        .onChange(of: model.selectedDecisionCaseID) { _, caseID in
            guard let caseID else { return }
            detailCase = DecisionCaseBox(caseID: caseID)
            model.selectedDecisionCaseID = nil
        }
        .onAppear(perform: model.refreshIntelligenceDashboard)
        .alert("旧版 AI 数据已归档", isPresented: legacyNoticeBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.legacyAIMigrationNotice ?? "")
        }
    }

    private var legacyNoticeBinding: Binding<Bool> {
        Binding(
            get: { model.legacyAIMigrationNotice != nil },
            set: { if !$0 { model.legacyAIMigrationNotice = nil } }
        )
    }
}
