import SwiftUI

// MARK: - 投资智能 V2 板块（十六轮审查 P1-1 生产接线的 UI 面）
//
// 消费面全部走 AppModel 的 V2 运行时动作 + ArtifactQueryService 派生状态：
// - 市场发现（WF2，纯本地因子）与盘中执行决策（WF3，纯本地）随时可跑
// - 组合研究（WF1）需 LLM 配置（baseURL/模型走 UserDefaults，API Key 走
//   Keychain——与旧链路同一 account，升级用户免重填）
// - 旧 AI 数据迁移通知（一次性 alert）

struct IntelligenceSectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var llmBaseURL = IntelligenceV2ProviderSettings.baseURL
    @State private var llmModel = IntelligenceV2ProviderSettings.model
    @State private var llmAPIKey = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                intradayCard
                discoveryCard
                researchCard
                providerConfigCard
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - 盘中执行决策

    private var intradayCard: some View {
        SectionCard(
            title: "盘中执行决策",
            subtitle: "信号 + 可执行性 + 再平衡执行（非 LLM 猜仓位）",
            icon: "clock.arrow.circlepath",
            trailing: {
                Button {
                    model.runIntradayDecision()
                } label: {
                    Label(
                        model.isRunningIntradayDecision ? "决策中…" : "立即评估",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(model.isRunningIntradayDecision || model.intelligenceRuntime == nil)
            }
        ) {
            if let report = model.latestIntradayReport {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    LabeledValue(
                        title: "结论",
                        value: report.decision == .executeRebalance ? "执行再平衡" : "持有不动"
                    )
                    if !report.holdReasons.isEmpty {
                        Text(report.holdReasons.joined(separator: "；"))
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                    if let plan = report.plan, !plan.actions.isEmpty {
                        Text("计划动作 \(plan.actions.count) 条（provenance 全程可溯）")
                            .font(AppPalette.appFont(.footnote))
                    }
                    Text("评估时间 \(report.asOf.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            } else {
                emptyHint("评估持仓相对「维持当前配置」的偏差与可执行性")
            }
        }
    }

    // MARK: - 市场发现

    private var discoveryCard: some View {
        SectionCard(
            title: "市场发现",
            subtitle: "本地因子先筛 + top-K 选择性研究（替代盲扫）",
            icon: "dot.radiowaves.left.and.right",
            trailing: {
                Button {
                    model.runMarketDiscovery()
                } label: {
                    Label(
                        model.isRunningMarketDiscovery ? "扫描中…" : "立即扫描",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(model.isRunningMarketDiscovery || model.intelligenceRuntime == nil)
            }
        ) {
            if let report = model.latestDiscoveryReport {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    if report.candidates.isEmpty {
                        Text("暂无候选（数据不足的标的 \(report.coverageGaps.count) 个已记录）")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                    ForEach(report.candidates.prefix(8), id: \.universeKey) { candidate in
                        HStack {
                            Text("#\(candidate.rank)")
                                .font(AppPalette.appFont(.caption, weight: .bold))
                                .foregroundStyle(AppPalette.brand)
                                .frame(width: 28, alignment: .leading)
                            Text(candidate.displayName)
                                .font(AppPalette.appFont(.subheadline, weight: .medium))
                            Spacer()
                            Text("评分 \(candidate.score)")
                                .font(AppPalette.appFont(.caption, design: .rounded))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                    Text("universe v\(report.universeVersion) · 候选 \(report.candidates.count) · 数据缺口 \(report.coverageGaps.count)")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                    // 数据供给诊断（十八轮 P1-1 生产接线：维护摘要可见，
                    // 缺口可解释——A 股通道未启用不再是「莫名缺数据」）
                    if let syncSummary = model.latestMarketDataSyncSummary {
                        Text("数据维护：\(syncSummary)")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    if case .notConfigured = model.remoteStagingSyncStatus {
                        Text("A股行情需启用远程增强通道（remote-staging-sync.json），未启用时 A 股标的计入数据缺口")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            } else {
                emptyHint("从内置 universe（31 标的）用本地动量/趋势/回撤因子排序")
            }
        }
    }

    // MARK: - 组合研究（WF1，需 LLM）

    private var researchCard: some View {
        SectionCard(
            title: "组合研究",
            subtitle: "Research → 论点 → 信号 → 决策（全链可溯）",
            icon: "sparkles",
            trailing: {
                Button {
                    model.runPortfolioResearch()
                } label: {
                    Label(
                        model.isRunningPortfolioResearch ? "研究中…" : "开始研究",
                        systemImage: "wand.and.stars"
                    )
                }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
                .disabled(
                    model.isRunningPortfolioResearch
                        || !model.intelligenceV2ProviderConfigured
                        || model.intelligenceRuntime == nil
                )
            }
        ) {
            if !model.intelligenceV2ProviderConfigured {
                Label("配置 AI 模型后启用（下方填写）", systemImage: "lock")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            } else if let artifactID = model.latestResearchArtifactID {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    LabeledValue(title: "最新决策 Artifact", value: String(artifactID.prefix(24)) + "…")
                    // 概要来自 AppModel published 状态（启动恢复 / 研究完成时
                    // 异步刷新）——View body 不做同步 SQLite 查询（十八轮 P2-5）
                    if let summary = model.latestPortfolioDecisionSummary {
                        LabeledValue(title: "结论", value: summary.status == "singlePreferred"
                                     ? "方案 \(summary.admissiblePlans.first ?? "?") 胜出"
                                     : "多方案待裁决")
                        Text("信号引用 \(summary.signalCount) 条 · \(summary.producedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            } else {
                emptyHint("多轮工具调用收集证据，产出结构化信号与决策方案")
            }
        }
    }

    // MARK: - Provider 配置

    private var providerConfigCard: some View {
        SectionCard(
            title: "AI 模型配置",
            subtitle: "baseURL / 模型存本地设置，API Key 存 Keychain（不落盘）",
            icon: "key"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                LabeledTextField(title: "Base URL", text: $llmBaseURL, placeholder: "https://open.bigmodel.cn/api/paas/v4")
                LabeledTextField(title: "模型", text: $llmModel, placeholder: "glm-4.7")
                SecureField("API Key（Keychain）", text: $llmAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存配置") {
                        IntelligenceV2ProviderSettings.save(
                            baseURL: llmBaseURL, model: llmModel, apiKey: llmAPIKey
                        )
                        llmAPIKey = ""
                        model.objectWillChange.send()
                    }
                    .buttonStyle(.appPrimary)
                    .controlSize(.small)
                    .disabled(llmBaseURL.isEmpty || llmModel.isEmpty)
                    if model.intelligenceV2ProviderConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .font(AppPalette.appFont(.caption, weight: .medium))
                            .foregroundStyle(AppPalette.positive)
                    }
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.subheadline))
            .foregroundStyle(AppPalette.muted)
            .padding(.vertical, AppPalette.spaceS)
    }
}

/// 轻量标题输入行（配置卡用；不引通用组件依赖）。
private struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
