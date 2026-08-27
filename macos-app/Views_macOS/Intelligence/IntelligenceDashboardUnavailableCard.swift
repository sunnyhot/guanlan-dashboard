import SwiftUI

/// Dashboard 快照不可用时保留明确恢复入口，避免整页只剩空白。
struct IntelligenceDashboardUnavailableCard: View {
    let loadState: AppModel.IntelligenceDashboardLoadState
    let onRetry: () -> Void

    var body: some View {
        SectionCard(
            title: "研判内容暂不可用",
            subtitle: "V2 数据与 Agent 运行时仍保留，可重新载入最近产出",
            icon: "arrow.clockwise.circle"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                switch loadState {
                case .idle, .loading:
                    HStack(spacing: AppPalette.spaceS) {
                        ProgressView().controlSize(.small)
                        Text("正在读取最近的盘中、市场、组合与复盘结果…")
                            .foregroundStyle(AppPalette.muted)
                    }
                case let .failed(error):
                    Text(error.message)
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("诊断码：\(error.diagnosticCode)")
                        .font(AppPalette.appFont(.caption, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                        .textSelection(.enabled)
                case .loaded:
                    Text("快照已加载，但当前没有可展示的内容。")
                        .foregroundStyle(AppPalette.muted)
                }
                Button("重新载入", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            .font(AppPalette.appFont(.footnote))
        }
    }
}
