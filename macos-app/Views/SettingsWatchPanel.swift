import SwiftUI

// MARK: - Watch Panel

extension SettingsSectionView {
    var watchPanel: some View {
        SettingsPanel(
            title: "提醒与巡检",
            subtitle: "监控平台动态中的调仓来源与论坛发言，并保存命中记录",
            icon: "bell.badge"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                    VStack(spacing: AppPalette.spaceXL) {
                        managerWatchRuntimeCard
                        managerWatchStatusCard
                    }
                    .frame(minWidth: 360, maxWidth: .infinity)

                    managerWatchTargetsCard
                        .frame(minWidth: 420, maxWidth: .infinity)
                }

                VStack(spacing: AppPalette.spaceXL) {
                    managerWatchRuntimeCard
                    managerWatchTargetsCard
                    managerWatchStatusCard
                }
            }
        }
    }

    private var managerWatchRuntimeCard: some View {
        SettingsCardGroup(
            title: "运行与通知",
            subtitle: "巡检在 App 运行期间按频率执行",
            icon: "waveform.path.ecg",
            tint: model.managerWatchSettings.isEnabled ? AppPalette.positive : AppPalette.info
        ) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "启用巡检",
                    detail: model.managerWatchStatusText,
                    icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    tint: model.managerWatchSettings.isEnabled ? AppPalette.positive : AppPalette.muted,
                    isOn: enabledBinding
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "系统通知",
                    detail: model.managerWatchSettings.notificationsEnabled
                        ? "命中新增动态时发送 macOS 通知"
                        : "关闭后仍巡检并保留应用内记录",
                    icon: "bell",
                    tint: model.managerWatchSettings.notificationsEnabled ? AppPalette.info : AppPalette.muted,
                    isOn: notificationsBinding
                )

                SettingsDivider(isInset: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("巡检频率")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    intervalMenu
                }
                .padding(.vertical, 12)

                SettingsDivider()

                SettingsActionRow {
                    Button {
                        model.runManagerWatchNow()
                    } label: {
                        Label(model.isManagerWatchPolling ? "巡检中…" : "立即巡检", systemImage: "play.circle")
                    }
                    .buttonStyle(.appPrimary)
                    .tint(AppPalette.brand)
                    .disabled(model.isManagerWatchPolling)

                    Button {
                        model.saveManagerWatchConfiguration()
                    } label: {
                        Label("保存目标", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.appSecondary)
                }
            }
        }
    }

    private var managerWatchTargetsCard: some View {
        SettingsCardGroup(
            title: "平台动态来源",
            subtitle: "调仓来源可多选；论坛发言按产品与主理人巡检",
            icon: "rectangle.stack.badge.play",
            tint: AppPalette.brand
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroupHeader(title: "调仓动态 · 可多选")

                VStack(spacing: 0) {
                    ForEach(Array(model.managerWatchAvailableAdjustmentSources.enumerated()), id: \.element.id) { index, source in
                        managerWatchAdjustmentSourceRow(source)
                        if index < model.managerWatchAvailableAdjustmentSources.count - 1 {
                            SettingsDivider(isInset: true)
                        }
                    }
                }

                if model.alfaPortfolios.isEmpty {
                    Text("在“平台动态 → 调仓动态 → 投顾组合”中添加组合后，可在这里继续多选。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                SettingsDivider()
                    .padding(.top, 12)

                SettingsGroupHeader(title: "论坛发言")

                SettingsToggleRow(
                    title: "巡检论坛发言",
                    detail: "对应“平台动态 → 论坛发言”",
                    icon: "text.bubble",
                    tint: model.managerWatchSettings.watchForum ? AppPalette.info : AppPalette.muted,
                    isOn: forumBinding
                )

                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                        spacing: 10
                    ) {
                        settingsField(
                            "产品代码",
                            text: prodCodeBinding,
                            placeholder: "LONG_WIN"
                        )
                        settingsField(
                            "论坛主理人",
                            text: managerNameBinding,
                            placeholder: "ETF拯救世界"
                        )
                    }

                    Text("产品代码同时用于长赢调仓；修改后保存，下一轮会静默重建对应基线。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        model.syncManagerWatchTargetsFromCurrentForm()
                    } label: {
                        Label("使用平台动态当前查询", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.appSecondary)
                }
                .disabled(!model.managerWatchSettings.watchForum
                    && !model.managerWatchSettings.selectedAdjustmentSourceIDs.contains(
                        ManagerWatchAdjustmentSource.longWinID
                    ))
                .opacity(
                    model.managerWatchSettings.watchForum
                        || model.managerWatchSettings.selectedAdjustmentSourceIDs.contains(
                            ManagerWatchAdjustmentSource.longWinID
                        )
                        ? 1
                        : 0.55
                )
                .padding(.bottom, 10)
            }
        }
    }

    private var managerWatchStatusCard: some View {
        SettingsCardGroup(
            title: "最近状态",
            subtitle: model.managerWatchSettings.lastResultSummary ?? "等待首次巡检",
            icon: "checklist.checked",
            tint: model.managerWatchSettings.lastErrorMessage == nil ? AppPalette.positive : AppPalette.warning
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "下次巡检",
                    value: model.managerWatchNextCheckText,
                    detail: model.managerWatchScopeText,
                    icon: "calendar.badge.clock",
                    tint: AppPalette.info
                )
                SettingsDivider(isInset: true)
                SettingsRow(
                    title: "增量基线",
                    value: model.managerWatchBaselineStatusText,
                    detail: "目标变化后会先静默建立基线",
                    icon: "scope",
                    tint: model.managerWatchBaselineStatusText == "已建立" ? AppPalette.positive : AppPalette.warning
                )
                SettingsDivider(isInset: true)
                SettingsRow(
                    title: "上次检查",
                    value: model.managerWatchSettings.lastCheckedAt ?? "暂无",
                    detail: model.managerWatchSettings.lastResultSummary ?? "尚无巡检结果",
                    icon: "clock",
                    tint: AppPalette.muted
                )
                SettingsDivider(isInset: true)
                SettingsRow(
                    title: "上次成功",
                    value: model.managerWatchSettings.lastSuccessAt ?? "暂无",
                    detail: model.managerWatchSettings.lastHitAt.map { "最近命中 \($0)" } ?? "尚未命中新增动态",
                    icon: "checkmark.circle",
                    tint: AppPalette.positive
                )

                if let error = model.managerWatchSettings.lastErrorMessage, !error.isEmpty {
                    ToastBar(text: error, tint: AppPalette.warning)
                        .padding(.vertical, 10)
                }
                if let error = model.managerWatchSettings.lastNotificationErrorMessage, !error.isEmpty {
                    ToastBar(text: error, tint: AppPalette.warning)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func managerWatchAdjustmentSourceRow(
        _ source: ManagerWatchAdjustmentSource
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.managerWatchSettings.selectedAdjustmentSourceIDs.contains(source.id) },
                set: { model.updateManagerWatchAdjustmentSource(source, isSelected: $0) }
            )
        ) {
            HStack(spacing: 10) {
                Image(systemName: source.kind == .longWin ? "chart.xyaxis.line" : "chart.pie")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(source.kind == .longWin ? AppPalette.info : AppPalette.brand)
                    .frame(width: 28, height: 28)
                    .background(
                        (source.kind == .longWin ? AppPalette.info : AppPalette.brand).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(source.detailText)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 9)
        .accessibilityHint("选择后会独立保存增量基线")
    }

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

    private var forumBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.watchForum },
            set: { model.updateManagerWatchForumEnabled($0) }
        )
    }

    private var prodCodeBinding: Binding<String> {
        Binding(
            get: { model.managerWatchSettings.prodCode },
            set: { model.managerWatchSettings.prodCode = $0 }
        )
    }

    private var managerNameBinding: Binding<String> {
        Binding(
            get: { model.managerWatchSettings.managerName },
            set: { model.managerWatchSettings.managerName = $0 }
        )
    }

    private var settingsControlBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var intervalMenu: some View {
        Menu {
            ForEach(ManagerWatchIntervalOption.allCases) { option in
                Button {
                    model.updateManagerWatchInterval(option.rawValue)
                } label: {
                    HStack {
                        Text(option.label)
                        if model.managerWatchSettings.intervalMinutes == option.rawValue {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("每 \(model.managerWatchSettings.intervalLabel)", systemImage: "timer")
                .font(AppPalette.appFont(.body, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(settingsControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private func settingsField(
        _ label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(settingsControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
                .onSubmit {
                    model.saveManagerWatchConfiguration()
                }
        }
    }
}
