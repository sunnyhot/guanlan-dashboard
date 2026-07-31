import SwiftUI

/// ⌘K 快捷命令面板：搜索 + 快速跳转/操作。
struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(AppPalette.appFont(.headline, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                TextField("搜索操作或跳转…", text: $searchText)
                    .font(AppPalette.appFont(.title3))
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { performFirst() }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppPalette.appFont(.body))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppPalette.canvasGradient)

            Divider()

            // 操作列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredItems) { item in
                        Button {
                            perform(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(AppPalette.appFont(.headline, weight: .medium))
                                    .foregroundStyle(AppPalette.brand)
                                    .frame(width: 20)
                                Text(item.title)
                                    .font(AppPalette.appFont(.headline))
                                    .foregroundStyle(AppPalette.ink)
                                Spacer()
                                if let shortcut = item.shortcut {
                                    Text(shortcut)
                                        .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                                        .foregroundStyle(AppPalette.muted)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 380, height: 360)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .onAppear { isSearchFocused = true }
    }

    private var allItems: [CommandPaletteItem] {
        [
            .init(title: "总览", icon: "square.grid.2x2", shortcut: "⌘1") { navigate(.overview) },
            .init(title: "我的持仓", icon: "chart.bar.fill", shortcut: "⌘2") { navigate(.portfolio) },
            .init(title: "调仓动态", icon: "arrow.triangle.2.circlepath", shortcut: "⌘3") { navigate(.platform) },
            .init(title: "AI 研判", icon: "sparkles", shortcut: "⌘5") { navigate(.enhancement) },
            .init(title: "设置", icon: "gearshape.fill", shortcut: "⌘6") { navigate(.settings) },
            .init(title: "刷新数据", icon: "arrow.clockwise", shortcut: "⌘R") {
                Task { try? await model.refreshLatest(persist: false) }
            },
            .init(title: "生成趋势分析", icon: "wand.and.stars", shortcut: nil) {
                model.startTrendAnalysis(userInitiated: true)
            },
            .init(title: "检测模型", icon: "antenna.radiowaves.left.and.right", shortcut: nil) {
                Task { await model.checkTrendAIConnection() }
            },
        ]
    }

    private var filteredItems: [CommandPaletteItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allItems }
        return allItems.filter { $0.title.lowercased().contains(trimmed) }
    }

    private func navigate(_ section: AppSection) {
        model.selectedSection = section
    }

    private func perform(_ item: CommandPaletteItem) {
        item.action()
        dismiss()
    }

    private func performFirst() {
        if let first = filteredItems.first { perform(first) }
    }
}

private struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
