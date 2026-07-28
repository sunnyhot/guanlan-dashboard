import SwiftUI

struct ManagerWatchControlCard: View {
    @EnvironmentObject private var model: AppModel

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.isEnabled },
            set: { model.updateManagerWatchEnabled($0) }
        )
    }

    private var forumBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.watchForum },
            set: { model.updateManagerWatchForumEnabled($0) }
        )
    }

    private var platformBinding: Binding<Bool> {
        Binding(
            get: { model.managerWatchSettings.watchPlatform },
            set: { model.updateManagerWatchPlatformEnabled($0) }
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.updateLaunchAtLoginEnabled($0) }
        )
    }

    var body: some View {
        SectionCard(title: "主理人提醒", subtitle: "App 常驻时自动巡检新调仓和新发言，并通过系统通知推送", icon: "bell.badge") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    managerWatchControls
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    managerWatchStatusPanel
                        .frame(width: 380, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    managerWatchControls
                    managerWatchStatusPanel
                }
            }
        }
    }

    private var managerWatchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Toggle("开启通知巡检", isOn: enabledBinding)
                    .toggleStyle(.switch)
                ToolbarBadge(
                    title: model.managerWatchStatusText,
                    tint: model.managerWatchSettings.isEnabled ? AppPalette.positive : AppPalette.muted
                )
                ToolbarBadge(title: model.managerWatchSettings.intervalLabel, tint: AppPalette.info)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                compactField("产品", text: prodCodeBinding, minWidth: 220)
                compactField("主理人", text: managerNameBinding, minWidth: 220)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Toggle("监控平台调仓", isOn: platformBinding)
                        .toggleStyle(.checkbox)
                    Toggle("监控主理人发言", isOn: forumBinding)
                        .toggleStyle(.checkbox)
                    intervalMenu
                        .frame(maxWidth: 240)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("监控平台调仓", isOn: platformBinding)
                        .toggleStyle(.checkbox)
                    Toggle("监控主理人发言", isOn: forumBinding)
                        .toggleStyle(.checkbox)
                    intervalMenu
                }
            }
            .font(AppPalette.appFont(.body))

            HStack(spacing: 10) {
                Button("保存设置") {
                    model.saveManagerWatchConfiguration()
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)

                Button("同步当前查询") {
                    model.syncManagerWatchTargetsFromCurrentForm()
                }
                .buttonStyle(.appSecondary)

                Button("立即巡检") {
                    model.runManagerWatchNow()
                }
                .buttonStyle(.appSecondary)
            }
        }
        .padding(14)
        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.55), lineWidth: 1)
        )
    }

    private var managerWatchStatusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bell.and.waves.left.and.right")
                    .font(AppPalette.appFont(.title2, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.brandSoft, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

                VStack(alignment: .leading, spacing: 2) {
                    Text("巡检状态")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(model.managerWatchScopeText)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ManagerWatchStatusTile(title: "巡检目标", value: model.managerWatchScopeText, tint: AppPalette.brand)
                ManagerWatchStatusTile(
                    title: "上次检查",
                    value: model.managerWatchSettings.lastCheckedAt ?? "暂无",
                    tint: AppPalette.muted
                )
                ManagerWatchStatusTile(
                    title: "上次成功",
                    value: model.managerWatchSettings.lastSuccessAt ?? "暂无",
                    tint: AppPalette.positive
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("开机自启", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                HStack(spacing: 8) {
                    ToolbarBadge(title: model.launchAtLoginStatusText, tint: model.launchAtLoginEnabled ? AppPalette.positive : AppPalette.muted)
                    ToolbarBadge(title: "关闭窗口后保留菜单栏", tint: AppPalette.info)
                }
            }
            .font(AppPalette.appFont(.body))

            if let error = model.managerWatchSettings.lastErrorMessage, !error.isEmpty {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppPalette.warning)
                        .frame(width: 4)
                    Text(error)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.ink)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }
        }
        .padding(14)
        .background(AppPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.55), lineWidth: 1)
        )
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
            Label("频率：\(model.managerWatchSettings.intervalLabel)", systemImage: "timer")
                .font(AppPalette.appFont(.body, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private func compactField(_ label: String, text: Binding<String>, minWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .accessibilityLabel(label)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
        }
        .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
    }
}

struct ManagerWatchStatusTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.body, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}
