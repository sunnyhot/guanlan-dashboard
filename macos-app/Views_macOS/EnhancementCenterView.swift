import SwiftUI

struct EnhancementCenterView: View {
    @EnvironmentObject var model: AppModel
    @State var selectedTrendEvidenceDetail: TrendEvidenceDetailSelection?
    /// 2026-09-02:长期研判持仓列表默认收起为摘要,点「查看全部」展开(参照持仓板块)。
    @State var showsAllAssetTrends = false
    /// W2.4(缩窄版):详细模式开关——控制证据账本/风险边界块显隐,全局记忆。
    @AppStorage(AppStorageKey.researchDetailMode) var showsResearchDetailMode = false

    /// 通知深链(旧跟踪项 UUID)命中时,直接打开对应决策案例详情。
    /// 迁移保持了 ID 稳定,旧跟踪项的深链因此仍可路由到迁移后的案例。
    @State private var deepLinkedCase: DecisionCase?

    /// 区段锚点滚动/高亮的协调器(经 environment 注入给各锚点)。
    @StateObject private var sectionAnchors = InvestmentSectionAnchorModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    TrendCatchUpBanner()
                    investmentDashboardContent
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .environment(\.investmentSectionAnchors, sectionAnchors)
            .onAppear {
                // W3.6:进入 AI 页即视为已读,清边栏角标。
                AppModel.markAIResearchSeen()
            }
            .onDisappear {
                // 页面内实时完成的研判不算未读,离开时再记一次。
                AppModel.markAIResearchSeen()
            }
            .onChange(of: model.selectedTrendTrackingItemID) { _, id in
                guard let id else { return }
                deepLinkedCase = model.decisionCases.first { $0.id == id }
            }
            .onChange(of: model.pendingInvestmentSectionAnchor) { _, target in
                // W3.1 链路 A 完成通知深链:滚动到对应研判区段并高亮。
                guard let target else { return }
                sectionAnchors.scrollTo = target
                model.pendingInvestmentSectionAnchor = nil
            }
            .onChange(of: sectionAnchors.scrollTo) { _, target in
                guard let target else { return }
                // 2026-09-02:目标区段在未选中的 Tab 里——先切换,下一 runloop 再滚动
                //(锚点视图随 Tab 内容渲染后才存在)。
                if let tab = AIResearchTab.tab(for: target),
                   model.selectedAIResearchTab != tab {
                    model.selectedAIResearchTab = tab
                    DispatchQueue.main.async {
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
                    return
                }
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
            .sheet(item: $deepLinkedCase) { caseItem in
                DecisionCaseDetailSheet(caseID: caseItem.id)
                    .environmentObject(model)
            }
        }
    }
}

/// W3.5:错过的自动窗口横幅——「昨天的市场扫描没做,现在补吗?」
/// 带「稍后再说」的会话级关闭;连续失败 ≥ 2 次升级为根因排查提示。
/// 已过滤「距下一班自动运行 ≤ 2 小时」的情形(自动会补,不让用户花冤枉钱)。
private struct TrendCatchUpBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var dismissedScopes: Set<String> = []
    @State private var dismissedFailureStreak = false

    private var visibleMissed: [TrendMissedWindow] {
        model.missedTrendWindowsForPrompt.filter { !dismissedScopes.contains($0.scope.rawValue) }
    }

    var body: some View {
        let missed = visibleMissed
        let failure = dismissedFailureStreak ? nil : model.worstAutoFailureStreak
        if missed.isEmpty && failure == nil { EmptyView() } else {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                ForEach(missed, id: \.scope) { window in
                    missedRow(window)
                }
                if let failure {
                    failureRow(failure)
                }
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                    .stroke(AppPalette.warning.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func missedRow(_ window: TrendMissedWindow) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(window.scope.displayName)还没生成")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(
                    window.reason == .failedAttempt
                        ? "\(window.windowKey) 的自动运行未成功,不会自动重试。"
                        : "\(window.windowKey) 的自动运行没有执行(App 当时可能未打开)。"
                )
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: AppPalette.spaceS)
            Button("现在补做") {
                model.startTrendAnalysisFromUser(withExpectation: window.scope)
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            Button {
                // 赋值而非 Set.insert:-O/WMO 下对 @State 调 mutating 方法
                // 会触发 "self is immutable"(Xcode 26.5 起),赋值走 nonmutating set 无此问题。
                dismissedScopes = dismissedScopes.union([window.scope.rawValue])
            } label: {
                Image(systemName: "xmark")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.muted)
            .help("稍后再说")
        }
    }

    private func failureRow(_ failure: (scope: TrendResearchRunScope, streak: Int, reasonText: String?)) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.danger)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("自动研判已连续 \(failure.streak) 次未成功")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(failure.scope.displayName)\(failure.reasonText.map { ":\($0)" } ?? "")。反复补做前先检查 Key 余额、网络或模型。")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppPalette.spaceS)
            Button("去设置") {
                model.selectedSection = .settings
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            Button {
                dismissedFailureStreak = true
            } label: {
                Image(systemName: "xmark")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.muted)
            .help("稍后再说")
        }
    }
}
