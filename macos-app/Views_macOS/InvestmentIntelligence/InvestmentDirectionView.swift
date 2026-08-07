import SwiftUI

struct InvestmentDirectionView: View {
    let analysis: MarketOpportunityAnalysis?
    let hasTrendReport: Bool
    let isProviderConfigured: Bool
    let isWebSearchConfigured: Bool

    @State private var selectedSignal: InvestmentDirectionSignal?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("板块决策雷达 · 持仓动作与全市场机会分开判断")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(statusText)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(statusTint)
                }
            } icon: {
                Image(systemName: "scope")
                    .foregroundStyle(AppPalette.brand)
            }
            .padding(AppPalette.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppPalette.brand.opacity(0.06),
                in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
            )

            InvestmentDirectionGroupView(
                title: "我已持有的板块",
                subtitle: "只显示研判报告中有持仓依据和可追溯证据的投资板块；F10 统计行业不直接生成卡片。",
                systemImage: "briefcase.fill",
                signals: analysis?.heldSectors ?? [],
                emptyText: "本轮没有形成有证据的持仓板块结论，不会用原始统计行业或默认文案占位。",
                selectedSignal: $selectedSignal
            )

            Divider()

            if analysis?.marketScanCompleted == true {
                InvestmentDirectionGroupView(
                    title: "全市场板块机会",
                    subtitle: "扫描持仓之外的行业与主题，按证据门槛分为开始关注、重点机会和可考虑买入。",
                    systemImage: "globe.asia.australia.fill",
                    signals: analysis?.marketSectorOpportunities ?? [],
                    emptyText: marketOpportunityEmptyText,
                    selectedSignal: $selectedSignal
                )

                Divider()

                InvestmentDirectionGroupView(
                    title: "大盘与宽基风向",
                    subtitle: "用于判断板块机会所处的整体市场环境，不等同于个人持仓结论。",
                    systemImage: "chart.line.uptrend.xyaxis",
                    signals: analysis?.markets ?? [],
                    emptyText: "完成全市场扫描，但没有形成达到证据门槛的大盘或宽基结论。",
                    selectedSignal: $selectedSignal
                )

                InvestmentDirectionGroupView(
                    title: "大类资产风向",
                    subtitle: "比较股票、债券、黄金、商品等大类环境，为板块判断提供跨资产背景。",
                    systemImage: "circle.grid.2x2.fill",
                    signals: analysis?.assetClasses ?? [],
                    emptyText: "完成全市场扫描，但没有形成达到证据门槛的大类资产结论。",
                    selectedSignal: $selectedSignal
                )
            } else {
                InvestmentDirectionMarketScanStateView(
                    title: marketScanStateTitle,
                    detail: marketScanStateDetail
                )
            }
        }
        .sheet(item: $selectedSignal) { signal in
            InvestmentDirectionDetailSheet(signal: signal)
        }
    }

    private var statusText: String {
        if let analysis {
            if !analysis.marketScanCompleted {
                return "当前是旧版组合报告，已隐藏未完成扫描的全市场结论。"
            }
            return "共呈现 \(analysis.surfacedSignalCount) 个有依据的结论 · 更新于 \(String(analysis.generatedAt.prefix(16)))"
        }
        if !isProviderConfigured {
            return "先配置 AI 模型，再生成板块决策雷达。"
        }
        if !isWebSearchConfigured {
            return "配置联网搜索后，才能扫描持仓以外的全市场机会。"
        }
        if hasTrendReport {
            return "当前报告没有完成新版全市场板块扫描，请重新扫描市场。"
        }
        return "扫描后会同时给出已持有板块动作和未持有板块机会。"
    }

    private var statusTint: Color {
        if !isProviderConfigured
            || !isWebSearchConfigured
            || (hasTrendReport && analysis == nil)
            || analysis?.marketScanCompleted == false {
            return AppPalette.warning
        }
        return AppPalette.muted
    }

    private var marketOpportunityEmptyText: String {
        if !isProviderConfigured {
            return "AI 模型未配置，暂时无法扫描全市场板块。"
        }
        if !isWebSearchConfigured {
            return "联网搜索未配置，暂时无法发现持仓之外的板块机会。"
        }
        if hasTrendReport {
            return "本轮没有发现达到证据门槛的未持有板块机会。"
        }
        return "等待首次全市场板块扫描。"
    }

    private var marketScanStateTitle: String {
        hasTrendReport ? "需要重新扫描全市场" : "尚未生成全市场机会"
    }

    private var marketScanStateDetail: String {
        if !isProviderConfigured {
            return "先配置 AI 模型，再运行全市场扫描。"
        }
        if !isWebSearchConfigured {
            return "先配置联网搜索，再运行全市场扫描。"
        }
        if hasTrendReport {
            return "当前报告生成于全市场分组扫描升级之前。已隐藏旧机会和空白占位，请点击右上角“扫描市场”重新生成。"
        }
        return "点击右上角“扫描市场”，完成大类资产、大盘宽基和六组行业板块扫描。"
    }
}
