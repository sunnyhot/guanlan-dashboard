import SwiftUI

// MARK: - 投资智能 V2 板块（产品重构 P2：页面壳，只做布局与 sheet 调度）
//
// 数据消费只经 AppModel.intelligenceDashboard（Presentation DTO 快照），
// View 不查库、不重算决策、不拼业务文案（文案在 IntelligencePresentationFormatter）。
// 布局：宽 ≥1100 两列（战略配置 2/3 + 系统状态 1/3；盘中 2/3 + 机会 1/3），
// 窄窗单列；内容区上限 1320。AI Provider 配置不在本页——统一在设置中心。

struct IntelligenceSectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var activeSheet: IntelligenceSheet?
    @State private var detailCase: DecisionCaseBox?

    /// 详情 sheet 的 Identifiable 包装（selectedDecisionCaseID 深链消费）。
    struct DecisionCaseBox: Identifiable {
        let caseID: String
        var id: String { caseID }
    }

    enum IntelligenceSheet: String, Identifiable {
        case editTarget
        case classifyHoldings
        case intradayDetail
        case decisionCases
        case closeReviewDetail

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                header
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1_320, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
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
        .alert("旧版 AI 数据已归档", isPresented: legacyNoticeBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.legacyAIMigrationNotice ?? "")
        }
    }

    // MARK: - 头部（最近更新 + 刷新 + 开始研究）

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceM) {
            VStack(alignment: .leading, spacing: 3) {
                Text("投资智能")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                if let generatedAt = model.intelligenceDashboardSnapshot?.generatedAt {
                    Text("最近更新 \(IntelligencePresentationFormatter.dateTimeText(generatedAt))")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            Spacer(minLength: AppPalette.spaceM)
            Button {
                model.refreshIntelligenceDashboard()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            .help("刷新投资智能结果 (⌘⇧R)")
            .accessibilityLabel("刷新投资智能结果")

            Button {
                model.runPortfolioResearch()
            } label: {
                Label(
                    model.researchOperationState.isRunning ? "研究中…" : "开始研究",
                    systemImage: "wand.and.stars")
            }
            .buttonStyle(.appPrimary)
            .controlSize(.small)
            .disabled(
                model.researchOperationState.isRunning
                    || !model.intelligenceV2ProviderConfigured
                    || model.intelligenceRuntime == nil)
            .help(researchButtonHelp)
            .accessibilityLabel("开始组合研究")
        }
    }

    private var researchButtonHelp: String {
        if model.researchOperationState.isRunning { return "研究正在进行" }
        guard model.intelligenceRuntime != nil else { return "投资智能运行时未就绪" }
        guard model.intelligenceV2ProviderConfigured else {
            return "需先在「设置 › 投资智能」中配置 AI 模型"
        }
        guard model.intelligenceIntradayReady else { return "需先完成战略配置与持仓归类" }
        return "运行组合研究 (⌘⇧S)"
    }

    // MARK: - 内容区（自适应两列 / 单列）

    @ViewBuilder
    private var content: some View {
        switch model.intelligenceDashboard {
        case .idle, .loading:
            IntelligenceSkeletonContent()
        case let .failed(error):
            IntelligenceErrorCard(error: error, model: model)
        case let .loaded(snapshot):
            IntelligenceLoadedContent(
                snapshot: snapshot,
                activeSheet: $activeSheet,
                model: model)
        }
    }

    private var legacyNoticeBinding: Binding<Bool> {
        Binding(
            get: { model.legacyAIMigrationNotice != nil },
            set: { if !$0 { model.legacyAIMigrationNotice = nil } }
        )
    }
}

// MARK: - 已加载内容（布局分流）

private struct IntelligenceLoadedContent: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?
    @ObservedObject var model: AppModel

    var body: some View {
        IntelligenceOverviewCard(
            snapshot: snapshot,
            activeSheet: $activeSheet,
            model: model)

        ViewThatFits(in: .horizontal) {
            twoColumnLayout
            singleColumnLayout
        }
    }

    private var twoColumnLayout: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack(alignment: .top, spacing: AppPalette.spaceL) {
                StrategicAllocationCard(
                    snapshot: snapshot, activeSheet: $activeSheet)
                    .frame(maxWidth: .infinity)
                IntelligenceStatusCard(snapshot: snapshot, activeSheet: $activeSheet, model: model)
                    .frame(width: 320)
            }
            HStack(alignment: .top, spacing: AppPalette.spaceL) {
                IntradayDecisionCard(
                    snapshot: snapshot, activeSheet: $activeSheet, model: model)
                    .frame(maxWidth: .infinity)
                MarketDiscoveryCard(snapshot: snapshot, model: model)
                    .frame(width: 320)
            }
            MarketCloseReviewCard(
                snapshot: snapshot, model: model, activeSheet: $activeSheet)
            DecisionCaseCard(model: model, activeSheet: $activeSheet)
            PortfolioResearchCard(snapshot: snapshot, model: model)
            IntelligenceHistoryCard(history: snapshot.history)
        }
    }

    private var singleColumnLayout: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            StrategicAllocationCard(snapshot: snapshot, activeSheet: $activeSheet)
            IntelligenceStatusCard(snapshot: snapshot, activeSheet: $activeSheet, model: model)
            IntradayDecisionCard(snapshot: snapshot, activeSheet: $activeSheet, model: model)
            MarketDiscoveryCard(snapshot: snapshot, model: model)
            MarketCloseReviewCard(snapshot: snapshot, model: model, activeSheet: $activeSheet)
            DecisionCaseCard(model: model, activeSheet: $activeSheet)
            PortfolioResearchCard(snapshot: snapshot, model: model)
            IntelligenceHistoryCard(history: snapshot.history)
        }
    }
}
