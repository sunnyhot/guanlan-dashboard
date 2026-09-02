import SwiftUI

// MARK: - App Panel (General / Updates)

extension SettingsSectionView {
    var appPanel: some View {
        SettingsPanel(title: "通用", subtitle: "应用外观、启动方式、本地数据与软件更新", icon: "gearshape") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                    VStack(spacing: AppPalette.spaceXL) {
                        appearanceAndLaunchCard
                        localDataCard
                    }
                    .frame(minWidth: 360, maxWidth: .infinity)

                    VStack(spacing: AppPalette.spaceXL) {
                        softwareUpdateCard
                        applicationCard
                    }
                    .frame(minWidth: 360, maxWidth: .infinity)
                }

                VStack(spacing: AppPalette.spaceXL) {
                    appearanceAndLaunchCard
                    localDataCard
                    softwareUpdateCard
                    applicationCard
                }
            }
        }
    }

    private var appearanceAndLaunchCard: some View {
        SettingsCardGroup(
            title: "外观与启动",
            subtitle: "显示方式与应用入口",
            icon: "circle.lefthalf.filled",
            tint: AppPalette.info
        ) {
            VStack(spacing: 0) {
                SettingsControlRow(
                    title: "外观",
                    detail: "选择浅色、深色或跟随系统",
                    icon: "paintpalette",
                    tint: AppPalette.info
                ) {
                    Picker("外观", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                SettingsDivider()
                SettingsToggleRow(
                    title: "开机时启动",
                    detail: model.launchAtLoginStatusText,
                    icon: "power",
                    tint: model.launchAtLoginEnabled ? AppPalette.positive : AppPalette.muted,
                    isOn: launchAtLoginBinding
                )

                SettingsDivider()
                SettingsToggleRow(
                    title: "在 Dock 中显示",
                    detail: "关闭后仍可从系统菜单栏打开应用",
                    icon: "dock.rectangle",
                    tint: model.showsInDock ? AppPalette.info : AppPalette.muted,
                    isOn: $model.showsInDock
                )
            }
        }
    }

    private var localDataCard: some View {
        SettingsCardGroup(
            title: "本地数据",
            subtitle: "数据文件仅保存在当前 Mac",
            icon: "externaldrive",
            tint: AppPalette.brand
        ) {
            SettingsControlRow(
                title: "数据目录",
                detail: dataDirectoryDescription,
                icon: "folder",
                tint: AppPalette.brand
            ) {
                Button {
                    model.openDataDirectory()
                } label: {
                    Label("在访达中打开", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.appSecondary)
                .disabled(model.dataDirectoryURL == nil)
            }
        }
    }

    private var softwareUpdateCard: some View {
        SettingsCardGroup(
            title: "软件更新",
            subtitle: "保持应用功能与数据接口最新",
            icon: "arrow.triangle.2.circlepath",
            tint: model.availableUpdate == nil ? AppPalette.brand : AppPalette.positive
        ) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "启动时检查更新",
                    detail: "每次打开应用自动检测新版本",
                    icon: "arrow.triangle.2.circlepath",
                    tint: AppPalette.brand,
                    isOn: $model.autoCheckForUpdatesOnLaunch
                )

                SettingsDivider()
                SettingsRow(
                    title: "当前版本",
                    value: AppUpdateChecker.bundleVersion,
                    detail: updateStatusDetail,
                    icon: "info.circle",
                    tint: model.availableUpdate == nil ? AppPalette.info : AppPalette.positive
                )

                if let update = model.availableUpdate {
                    SettingsDivider()
                    SettingsRow(
                        title: "可用更新",
                        value: update.version,
                        detail: update.asset?.name ?? "Release 可查看",
                        icon: "sparkles",
                        tint: AppPalette.positive
                    )
                }

                SettingsActionRow {
                    Button {
                        Task { await model.checkForUpdates(userInitiated: true) }
                    } label: {
                        Label(model.isCheckingForUpdates ? "检查中…" : "检查更新", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.appPrimary)
                    .tint(AppPalette.brand)
                    .disabled(model.isCheckingForUpdates)

                    if model.availableUpdate != nil {
                        if model.isHomebrewManagedApp {
                            Label("由 Homebrew 管理，请用 brew upgrade 更新", systemImage: "terminal")
                                .font(AppPalette.appFont(.footnote, weight: .medium))
                                .foregroundStyle(AppPalette.muted)
                        } else {
                            Button {
                                Task { await model.downloadAndInstallAvailableUpdate() }
                            } label: {
                                Label(model.isInstallingUpdate ? "安装中…" : "下载并安装", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.appSecondary)
                            .disabled(model.isInstallingUpdate)
                        }

                        Button {
                            model.openAvailableUpdateReleasePage()
                        } label: {
                            Label("Release", systemImage: "safari")
                        }
                        .buttonStyle(.appSecondary)
                    }
                }

                if !model.updateInstallProgress.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.updateDownloadFraction > 0 {
                            ProgressView(value: model.updateDownloadFraction, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(AppPalette.brand)
                        }
                        ToastBar(text: model.updateInstallProgress, tint: AppPalette.info)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var applicationCard: some View {
        SettingsCardGroup(
            title: "应用",
            subtitle: "结束当前会话与后台任务",
            icon: "power",
            tint: AppPalette.danger
        ) {
            SettingsControlRow(
                title: "退出观澜",
                detail: "结束菜单栏组件和所有后台巡检",
                icon: "power",
                tint: AppPalette.danger
            ) {
                Button("退出应用") {
                    model.quitApplication()
                }
                .buttonStyle(.appSecondary)
                .tint(AppPalette.danger)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.updateLaunchAtLoginEnabled($0) }
        )
    }

    private var dataDirectoryDescription: String {
        model.dataDirectoryURL?.path ?? "应用启动后会在这里准备本地数据目录"
    }

    private var updateStatusDetail: String {
        if model.isCheckingForUpdates {
            return "正在检查 GitHub Release"
        }
        if model.availableUpdate != nil {
            return model.isHomebrewManagedApp
                ? "发现新版本；本应用由 Homebrew 管理，请 brew upgrade"
                : "发现新版本，可在下方下载并安装"
        }
        return "当前已是最新版本，也可手动检查"
    }
}
