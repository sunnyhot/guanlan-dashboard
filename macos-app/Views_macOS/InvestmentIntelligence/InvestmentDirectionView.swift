import SwiftUI

struct InvestmentDirectionView: View {
    let analysis: MarketOpportunityAnalysis?
    let hasTrendReport: Bool
    let isProviderConfigured: Bool

    @State private var selectedSignal: InvestmentDirectionSignal?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            if analysis?.marketScanCompleted == true {
                InvestmentDirectionGroupView(
                    title: "全市场板块机会",
                    subtitle: "扫描行业与主题，按证据门槛分为开始关注、重点机会和可考虑买入。",
                    systemImage: "globe.asia.australia.fill",
                    signals: analysis?.marketSectorOpportunities ?? [],
                    emptyText: marketOpportunityEmptyText,
                    selectedSignal: $selectedSignal
                )

                Divider()

                InvestmentDirectionGroupView(
                    title: "大盘与宽基风向",
                    subtitle: "用于判断板块机会所处的整体市场环境。",
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

    private var marketOpportunityEmptyText: String {
        if !isProviderConfigured {
            return "AI 模型未配置，暂时无法扫描全市场板块。"
        }
        if true {
            return "联网搜索源已下线，全市场机会扫描暂停（本地研判不受影响）。"
        }
        if hasTrendReport {
            return "本轮没有发现达到证据门槛的市场板块机会。"
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
        if true {
            return "联网搜索源已下线，全市场扫描暂停；组合内研判不受影响。"
        }
        if hasTrendReport {
            return "当前报告不含全市场分组扫描结果（可能是一份早期报告或只跑了组合研判）。已隐藏旧机会和空白占位，请点击右上角「扫描市场」重新生成。"
        }
        return "点击右上角「扫描市场」，完成大类资产、大盘宽基和六组行业板块扫描。"
    }
}
