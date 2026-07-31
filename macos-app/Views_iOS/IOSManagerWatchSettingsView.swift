#if os(iOS)
import SwiftUI

// MARK: - iOS 主理人关注设置
//
// 复用 model.managerWatchSettings + update/save 方法。对齐 macOS
// SettingsWatchPanel:启用/系统通知/巡检间隔/调仓来源多选/论坛关注。

struct IOSManagerWatchSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            statusSection
            configSection
            sourcesSection
            actionsSection
        }
        .navigationTitle("主理人关注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    model.saveManagerWatchConfiguration()
                    dismiss()
                }
                .bold()
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            Toggle("启用定时巡检", isOn: enabledBinding)
        } footer: {
            if let summary = model.managerWatchSettings.lastResultSummary, !summary.isEmpty {
                Text(summary).foregroundStyle(IOSDesign.muted)
            } else if model.managerWatchSettings.isEnabled {
                Text("已启用,将按间隔自动检查调仓和论坛动态。").foregroundStyle(IOSDesign.muted)
            }
        }
    }

    // MARK: - 配置

    private var configSection: some View {
        Section("巡检配置") {
            Toggle("系统通知", isOn: notificationsBinding)
            Picker("巡检间隔", selection: intervalBinding) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { min in
                    Text("\(min) 分钟").tag(min)
                }
            }
        }
    }

    // MARK: - 调仓来源(多选)

    private var sourcesSection: some View {
        Section {
            ForEach(model.managerWatchAvailableAdjustmentSources) { source in
                Toggle(isOn: sourceBinding(for: source)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName).font(IOSDesign.sansBody(14, weight: .medium))
                        Text(source.detailText).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
                    }
                }
            }
        } header: {
            Text("调仓来源")
        } footer: {
            let total = model.managerWatchAvailableAdjustmentSources.count
            let selected = model.managerWatchSettings.selectedAdjustmentSourceIDs
                .intersection(Set(model.managerWatchAvailableAdjustmentSources.map(\.id))).count
            Text("已选 \(selected) / 共 \(total)。选择要监控的调仓来源。")
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            Button("立即巡检一次") {
                model.runManagerWatchNow()
            }
            .disabled(!model.managerWatchSettings.isEnabled)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.isEnabled },
            set: { model.updateManagerWatchEnabled($0) }
        )
    }
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.notificationsEnabled },
            set: { model.updateManagerWatchNotificationsEnabled($0) }
        )
    }
    private var intervalBinding: Binding<Int> {
        Binding(
            get: { model.managerWatchSettings.intervalMinutes },
            set: { model.updateManagerWatchInterval($0) }
        )
    }
    private func sourceBinding(for source: ManagerWatchAdjustmentSource) -> Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.selectedAdjustmentSourceIDs.contains(source.id) },
            set: { model.updateManagerWatchAdjustmentSource(source, isSelected: $0) }
        )
    }
}
#endif
