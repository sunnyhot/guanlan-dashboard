import SwiftUI

// MARK: - 投资智能 V2（iOS 轻量页，与 macOS IntelligenceSectionView 对应）

struct IOSIntelligenceSectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            intradaySection
            discoverySection
            researchSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("投资智能")
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

    private var intradaySection: some View {
        Section {
            Button {
                model.runIntradayDecision()
            } label: {
                Label(
                    model.isRunningIntradayDecision ? "决策中…" : "立即评估盘中决策",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .disabled(model.isRunningIntradayDecision || model.intelligenceRuntime == nil)

            if let report = model.latestIntradayReport {
                LabeledContent("结论", value: report.decision == .executeRebalance ? "执行再平衡" : "持有不动")
                if !report.holdReasons.isEmpty {
                    Text(report.holdReasons.joined(separator: "；"))
                        .font(.footnote)
                        .foregroundStyle(AppPalette.muted)
                }
            }
        } header: {
            Text("盘中执行决策")
        } footer: {
            Text("信号 + 可执行性 + 再平衡执行；Δw 只来自带出处的规划器（非 LLM 猜仓位）。")
        }
    }

    private var discoverySection: some View {
        Section {
            Button {
                model.runMarketDiscovery()
            } label: {
                Label(
                    model.isRunningMarketDiscovery ? "扫描中…" : "立即扫描市场机会",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .disabled(model.isRunningMarketDiscovery || model.intelligenceRuntime == nil)

            ForEach(model.latestDiscoveryReport?.candidates.prefix(6) ?? [], id: \.universeKey) { candidate in
                HStack {
                    Text("#\(candidate.rank)")
                        .font(.caption.bold())
                        .foregroundStyle(AppPalette.brand)
                    Text(candidate.displayName)
                    Spacer()
                    Text("评分 \(candidate.score)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppPalette.muted)
                }
            }
        } header: {
            Text("市场发现")
        } footer: {
            Text("本地动量/趋势/回撤因子先筛，只对 top-K 做后续研究。")
        }
    }

    private var researchSection: some View {
        Section {
            Button {
                model.runPortfolioResearch()
            } label: {
                Label(
                    model.isRunningPortfolioResearch ? "研究中…" : "开始组合研究",
                    systemImage: "wand.and.stars"
                )
            }
            .disabled(
                model.isRunningPortfolioResearch
                    || !model.intelligenceV2ProviderConfigured
                    || model.intelligenceRuntime == nil
            )
            if !model.intelligenceV2ProviderConfigured {
                Text("需先在 macOS 端配置 AI 模型（API Key 存 Keychain，跨端不共享）")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.muted)
            }
            if let artifactID = model.latestResearchArtifactID {
                LabeledContent("最新决策", value: String(artifactID.prefix(18)) + "…")
            }
        } header: {
            Text("组合研究")
        } footer: {
            Text("多轮工具调用收集证据 → 结构化信号 → 可溯决策。")
        }
    }
}
