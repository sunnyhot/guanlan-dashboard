#if os(iOS)
import SwiftUI

// MARK: - 投资智能 V2（iOS 产品页；产品重构 §10）
//
// 与 macOS 消费同一 InvestmentIntelligenceDashboardSnapshot 与同一文案
// formatter——同一 Artifact 双端必须展示相同结论、原因与有效状态；
// iOS 不复制业务判断、不单独维护状态矩阵。单列布局，sheet 承载编辑器。

struct IOSIntelligenceSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showTargetEditor = false
    @State private var showAssignmentEditor = false

    var body: some View {
        List {
            switch model.intelligenceDashboard {
            case .idle, .loading:
                loadingSection
            case let .failed(error):
                failedSection(error)
            case let .loaded(snapshot):
                loadedSections(snapshot)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("投资智能")
        .refreshable { model.refreshIntelligenceDashboard() }
        .sheet(isPresented: $showTargetEditor) {
            IOSAllocationTargetEditor()
        }
        .sheet(isPresented: $showAssignmentEditor) {
            IOSAssetClassAssignmentEditor()
        }
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

    // MARK: - 加载 / 失败

    private var loadingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在加载投资智能结果…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func failedSection(_ error: IntelligenceUserFacingError) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.title)
                    .font(.subheadline.weight(.semibold))
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("重试") { model.refreshIntelligenceDashboard() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text(error.diagnosticCode)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 已加载

    private func loadedSections(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Group {
            headlineSection(snapshot)
            allocationSection(snapshot)
            statusSection(snapshot)
            intradaySection(snapshot)
            discoverySection(snapshot)
            researchSection(snapshot)
            historySection(snapshot)
        }
    }

    private func headlineSection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(IntelligencePresentationFormatter.headlineStatusLabel(snapshot.headline.status))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(headlineColor(snapshot.headline.status))
                Text(snapshot.headline.reason)
                    .font(.subheadline)
                HStack(spacing: 12) {
                    if let validity = snapshot.headline.validityNote {
                        Label(validity, systemImage: "clock")
                    }
                    if let dataAsOf = snapshot.headline.dataAsOf {
                        Label(
                            IntelligencePresentationFormatter.dateTimeText(dataAsOf),
                            systemImage: "database")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                primaryAction(snapshot)
            }
            .padding(.vertical, 4)
        } header: {
            Text("今日结论")
        }
    }

    private func headlineColor(
        _ status: InvestmentIntelligenceDashboardSnapshot.Headline.Status
    ) -> Color {
        switch status {
        case .rebalanceSuggested: return AppPalette.warning
        case .holdConfigured: return AppPalette.positive
        case .undecidable: return AppPalette.info
        case .notReady: return AppPalette.muted
        }
    }

    @ViewBuilder
    private func primaryAction(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        switch snapshot.readiness.blocker {
        case .missingTarget:
            Button("设置目标") { showTargetEditor = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .unclassifiedHoldings:
            Button("完善分类") { showAssignmentEditor = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .staleValuation:
            Button("更新持仓数据") {
                Task { try? await model.refreshLatest(updateNotice: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case nil:
            Button(
                model.intradayOperationState.isRunning ? "评估中…" : "评估持仓"
            ) {
                model.runIntradayDecision()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.intradayOperationState.isRunning)
        }
    }

    private func allocationSection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            ForEach(snapshot.allocation.rows, id: \.assetClass) { row in
                HStack {
                    Text(IntelligencePresentationFormatter.assetClassName(row.assetClass))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("当前 \(IntelligencePresentationFormatter.percentText(row.currentWeight))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("目标 \(IntelligencePresentationFormatter.percentText(row.targetWeight))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(IntelligencePresentationFormatter.deviationText(row.deviation))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            abs(row.deviation ?? 0) > Decimal(string: "0.05")!
                                ? AppPalette.warning : AppPalette.muted)
                        .frame(minWidth: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            Button("编辑战略目标") { showTargetEditor = true }
        } header: {
            Text("战略配置与偏差")
        } footer: {
            Text(snapshot.allocation.targetConfigured
                 ? "偏差 = 当前 − 目标；带内（±5%）不触发调整。"
                 : "设定五类资产目标后，系统将对照当前配置给出偏差与建议。")
        }
    }

    private func statusSection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            LabeledContent("战略目标") {
                Text(snapshot.allocation.targetConfigured ? "已设定" : "未设定")
                    .foregroundStyle(snapshot.allocation.targetConfigured ? AppPalette.positive : AppPalette.warning)
            }
            LabeledContent("持仓分类") {
                Text(classificationText(snapshot))
                    .foregroundStyle(isClassificationOK(snapshot) ? AppPalette.positive : AppPalette.warning)
            }
            LabeledContent("市场数据") {
                Text(snapshot.readiness.marketCoverage.map {
                    IntelligencePresentationFormatter.coverageText($0)
                } ?? "暂无报告")
                .foregroundStyle(.secondary)
            }
            LabeledContent("AI 模型") {
                Text(snapshot.readiness.providerConfigured ? "已配置" : "未配置")
                    .foregroundStyle(snapshot.readiness.providerConfigured ? AppPalette.positive : AppPalette.warning)
            }
            if !snapshot.readiness.providerConfigured {
                Button("前往设置配置 AI 模型") {
                    model.requestSettingsSection(.intelligence)
                }
            }
        } header: {
            Text("系统状态")
        }
    }

    private func classificationText(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> String {
        if case let .unclassifiedHoldings(subjects) = snapshot.readiness.blocker {
            return "\(subjects.count) 项待归类"
        }
        if case .staleValuation = snapshot.readiness.blocker { return "估值已过期" }
        return "已完成"
    }

    private func isClassificationOK(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> Bool {
        if case .unclassifiedHoldings = snapshot.readiness.blocker { return false }
        return true
    }

    private func intradaySection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            if case let .running(_, stage) = model.intradayOperationState {
                HStack {
                    ProgressView()
                    Text(stageText(stage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if case let .failed(error) = model.intradayOperationState {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppPalette.warning)
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let intraday = snapshot.intraday {
                LabeledContent("结论", value: IntelligencePresentationFormatter.intradayDecisionLabel(intraday.decision))
                if intraday.validity == .expired {
                    Label("本报告已过期，建议重新评估", systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.warning)
                }
                ForEach(intraday.holdReasons, id: \.self) { reason in
                    Text("· \(reason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(intraday.moves, id: \.subjectKey) { move in
                    Text(IntelligencePresentationFormatter.plannedMoveText(move))
                        .font(.footnote)
                }
                LabeledContent(
                    "评估时间",
                    value: IntelligencePresentationFormatter.dateTimeText(intraday.producedAt))
            } else if snapshot.readiness.blocker == nil {
                Text("尚未运行盘中评估。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(
                model.intradayOperationState.isRunning ? "评估中…" : "重新评估"
            ) {
                model.runIntradayDecision()
            }
            .disabled(model.intradayOperationState.isRunning
                      || snapshot.readiness.blocker != nil)
        } header: {
            Text("盘中执行建议")
        } footer: {
            Text("调整幅度只来自对照战略目标的规划器，非模型猜测。")
        }
    }

    private func discoverySection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            if case let .running(_, stage) = model.discoveryOperationState {
                HStack {
                    ProgressView()
                    Text(stageText(stage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let discovery = snapshot.discovery {
                switch discovery.state {
                case .insufficientData:
                    Label("市场数据准备中——多数标的暂无足够行情", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .noCandidates:
                    Label("本期无候选（全部标的已参与筛选）", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .hasCandidates:
                    EmptyView()
                }
                ForEach(discovery.topCandidates, id: \.rank) { candidate in
                    HStack {
                        Text("#\(candidate.rank)")
                            .font(.caption.bold())
                            .foregroundStyle(AppPalette.brand)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name)
                                .font(.subheadline.weight(.medium))
                            Text(candidate.factorsSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("评分 \(candidate.score.rounded(toScale: 3))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                LabeledContent(
                    IntelligencePresentationFormatter.coverageText(discovery.coverage),
                    value: IntelligencePresentationFormatter.dateTimeText(discovery.producedAt))
                    .font(.caption)
            }
            Button(
                model.discoveryOperationState.isRunning ? "更新中…" : "更新市场机会"
            ) {
                model.runMarketDiscovery()
            }
            .disabled(model.discoveryOperationState.isRunning
                      || model.intelligenceRuntime == nil)
        } header: {
            Text("市场机会")
        } footer: {
            Text("本地因子先筛，只对少数标的消耗研究预算。")
        }
    }

    private func researchSection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            if case let .running(_, stage) = model.researchOperationState {
                HStack {
                    ProgressView()
                    Text(stageText(stage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if case let .failed(error) = model.researchOperationState {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppPalette.warning)
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !snapshot.readiness.providerConfigured {
                Button("配置 AI 模型后启用研究（前往设置）") {
                    model.requestSettingsSection(.intelligence)
                }
            } else if let research = snapshot.research, research.producedAt != nil {
                Text(research.narrativeHeadline)
                    .font(.subheadline.weight(.semibold))
                if !research.portfolioStatement.isEmpty {
                    Text(research.portfolioStatement)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                ForEach(research.topSignals, id: \.self) { signal in
                    Text("· \(signal)")
                        .font(.footnote)
                }
                Text("证据 \(research.evidenceCount) 条 · 信号 \(research.signalCount) 条 · \(IntelligencePresentationFormatter.dateTimeText(research.producedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(
                model.researchOperationState.isRunning ? "研究中…" : "开始组合研究"
            ) {
                model.runPortfolioResearch()
            }
            .disabled(
                model.researchOperationState.isRunning
                    || !snapshot.readiness.providerConfigured
                    || model.intelligenceRuntime == nil
                    || snapshot.readiness.blocker != nil)
        } header: {
            Text("组合研究")
        } footer: {
            Text("证据 → 论点 → 信号 → 决策，全程可溯。")
        }
    }

    private func historySection(
        _ snapshot: InvestmentIntelligenceDashboardSnapshot
    ) -> some View {
        Section {
            if snapshot.history.isEmpty {
                Text("暂无记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.history.prefix(20)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(IntelligencePresentationFormatter.historyKindLabel(item.kind))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(IntelligencePresentationFormatter.historyValidityLabel(item.isValid))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(item.isValid ? AppPalette.positive : AppPalette.muted)
                    }
                    Text(item.conclusionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(IntelligencePresentationFormatter.dateTimeText(item.producedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !item.targetResolvable {
                        Text("目标不可溯（旧链路产物，仅供审计）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("最近记录")
        }
    }

    private func stageText(_ stage: AppModel.IntelligenceOperationState.Stage) -> String {
        switch stage {
        case .preparing: return "准备数据…"
        case .collecting: return "收集证据…"
        case .synthesizing: return "合成论点…"
        case .evaluating: return "评估决策…"
        case .persisting: return "写入结果…"
        }
    }
}
#endif
