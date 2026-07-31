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

                AdjustmentSourceMultiSelect()

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
                    detail: "按主理人名称巡检；对应“平台动态 → 论坛发言”",
                    icon: "text.bubble",
                    tint: model.managerWatchSettings.watchForum ? AppPalette.info : AppPalette.muted,
                    isOn: forumBinding
                )

                settingsField("论坛主理人", text: managerNameBinding, placeholder: "ETF拯救世界")
                    .disabled(!model.managerWatchSettings.watchForum)
                    .opacity(model.managerWatchSettings.watchForum ? 1 : 0.55)
                    .padding(.leading, 35)
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

// MARK: - Adjustment Source Multi-Select

/// 调仓来源的紧凑下拉多选：一个按钮触发 Popover，内部可连续勾选多个来源；
/// 长赢调仓被选中时，在其下方就地展开产品代码输入框。
private struct AdjustmentSourceMultiSelect: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingPopover = false

    private var availableSources: [ManagerWatchAdjustmentSource] {
        model.managerWatchAvailableAdjustmentSources
    }

    private var selectedCount: Int {
        let availableIDs = Set(availableSources.map(\.id))
        return model.managerWatchSettings.selectedAdjustmentSourceIDs.intersection(availableIDs).count
    }

    private var totalCount: Int { availableSources.count }

    var body: some View {
        Button {
            withAnimation(AppPalette.motionFast) {
                isShowingPopover.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text("调仓来源")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("已选 \(selectedCount) / 共 \(totalCount)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(AppPalette.muted)
                    .rotationEffect(.degrees(isShowingPopover ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settingsControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isShowingPopover ? "已展开" : "已折叠")
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var settingsControlBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("调仓来源")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(availableSources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source)
                        if index < availableSources.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            .clipped()
        }
        .padding(.vertical, 4)
        .frame(width: 320)
        .background(AppPalette.card)
    }

    @ViewBuilder
    private func sourceRow(_ source: ManagerWatchAdjustmentSource) -> some View {
        let isSelected = model.managerWatchSettings.selectedAdjustmentSourceIDs.contains(source.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.updateManagerWatchAdjustmentSource(source, isSelected: !isSelected)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(isSelected ? AppPalette.positive : AppPalette.muted)

                    Image(systemName: source.kind == .longWin ? "chart.xyaxis.line" : "chart.pie")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(source.kind == .longWin ? AppPalette.info : AppPalette.brand)
                        .frame(width: 28, height: 28)
                        .background(
                            (source.kind == .longWin ? AppPalette.info : AppPalette.brand).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(source.detailText)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])

            if source.kind == .longWin, isSelected {
                inlineProdCodeField
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    private var inlineProdCodeField: some View {
        HStack(spacing: 8) {
            Text("产品代码")
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField("LONG_WIN", text: prodCodeBinding)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.footnote))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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

    private var prodCodeBinding: Binding<String> {
        Binding(
            get: { model.managerWatchSettings.prodCode },
            set: { model.managerWatchSettings.prodCode = $0 }
        )
    }
}
