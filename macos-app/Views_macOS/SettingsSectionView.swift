#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

// MARK: - Settings

enum SettingsFocus: CaseIterable, Identifiable {
    case general
    case watch
    case trend
    case menuBar
    case valuationAlert
    case sync

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            return "通用"
        case .watch:
            return "提醒与巡检"
        case .trend:
            return "AI 研判"
        case .menuBar:
            return "菜单栏"
        case .valuationAlert:
            return "估值预警"
        case .sync:
            return "数据同步"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "外观、启动与更新"
        case .watch:
            return "主理人动态通知"
        case .trend:
            return "模型与自动分析"
        case .menuBar:
            return "摘要样式与内容"
        case .valuationAlert:
            return "持仓目标买卖提醒"
        case .sync:
            return "跨设备同步数据"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .watch:
            return "bell.badge"
        case .trend:
            return "sparkles"
        case .menuBar:
            return "menubar.rectangle"
        case .valuationAlert:
            return "target"
        case .sync:
            return "icloud.and.arrow.up.and.down"
        }
    }
}

private enum SettingsNavigationLayout {
    case sidebar
    case grid
}

struct SettingsSectionView: View {
    @EnvironmentObject var model: AppModel
    @State var selectedSettingsFocus: SettingsFocus = .general
    @State var isMenuBarHoldingOptionsExpanded = false
    @State var isMenuBarMarketIndexExpanded = false
    @State var isMenuBarFundMarketExpanded = false
    @State var draggedTickerSelectionID: String?
    @State var tickerDropTargetID: String?
    @State var isConfirmingMenuBarReset = false
    @State var isConfirmingHoldingSelectionClear = false

    var menuBarTickerEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.menuBarTickerSettings.isEnabled },
            set: { model.setMenuBarTickerEnabled($0) }
        )
    }

    var menuBarTickerCustomColorBinding: Binding<Color> {
        #if canImport(AppKit)
        return Binding(
            get: {
                Color(nsColor: MenuBarTickerAppearance.nsColor(hex: model.menuBarTickerSettings.appearance.customTextColorHex) ?? .labelColor)
            },
            set: { color in
                model.updateMenuBarTickerAppearance { appearance in
                    appearance.textColorMode = .custom
                    appearance.customTextColorHex = MenuBarTickerAppearance.normalizedHex(from: NSColor(color))
                }
            }
        )
        #else
        // iOS: menu-bar settings tab is hidden; provide a no-op binding so the
        // computed property still compiles cross-platform.
        return Binding(
            get: { Color(hex: model.menuBarTickerSettings.appearance.customTextColorHex) ?? AppPalette.ink },
            set: { color in
                // ColorPicker-derived hex not persisted on iOS (no menu bar).
                _ = color
            }
        )
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                settingsLayout(for: proxy.size.width)
                    .frame(maxWidth: 1_320, alignment: .topLeading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func settingsLayout(for availableWidth: CGFloat) -> some View {
        if availableWidth >= 1_120 {
            HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                settingsNavigation(layout: .sidebar)
                    .frame(width: 240)

                selectedSettingsContent
            }
        } else {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                settingsNavigation(layout: .grid)
                selectedSettingsContent
            }
        }
    }

    private var selectedSettingsContent: some View {
        selectedSettingsPanel
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(selectedSettingsFocus)
    }

    private func settingsNavigation(layout: SettingsNavigationLayout) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .top, spacing: AppPalette.spaceM) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置中心")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("按功能快速切换，当前状态一目了然")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer(minLength: AppPalette.spaceM)

                Text("\(SettingsFocus.allCases.count) 个分区")
                    .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppPalette.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppPalette.brandSoft, in: Capsule())
            }

            switch layout {
            case .sidebar:
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(SettingsFocus.allCases) { focus in
                        settingsNavigationButton(for: focus, layout: layout)
                    }
                }
            case .grid:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(SettingsFocus.allCases) { focus in
                            settingsNavigationButton(for: focus, layout: layout)
                                .frame(minWidth: 158, maxWidth: .infinity)
                        }
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 170), spacing: 10),
                            GridItem(.flexible(minimum: 170), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ForEach(SettingsFocus.allCases) { focus in
                            settingsNavigationButton(for: focus, layout: layout)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            AppPalette.panelBackground.opacity(0.56),
            in: RoundedRectangle(cornerRadius: AppPalette.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.borderFaint), lineWidth: 1)
        )
        .shadow(
            color: AppPalette.panelShadowColor,
            radius: AppPalette.panelShadowRadius,
            y: AppPalette.panelShadowY
        )
    }

    private func settingsNavigationButton(
        for focus: SettingsFocus,
        layout: SettingsNavigationLayout
    ) -> some View {
        Button {
            selectedSettingsFocus = focus
        } label: {
            SettingsNavigationRow(
                title: focus.title,
                subtitle: focus.subtitle,
                status: settingsStatus(for: focus),
                icon: focus.systemImage,
                tint: settingsStatusTint(for: focus),
                isSelected: selectedSettingsFocus == focus,
                isCompact: layout == .sidebar
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
    }

    private func settingsStatus(for focus: SettingsFocus) -> String {
        switch focus {
        case .general:
            return model.appearance.rawValue
        case .watch:
            return model.managerWatchSettings.isEnabled
                ? model.managerWatchSettings.intervalLabel
                : "已关闭"
        case .trend:
            let modelName = model.trendSettings.provider.model
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return model.trendSettings.provider.isConfigured && !modelName.isEmpty
                ? modelName
                : "未配置"
        case .menuBar:
            return model.menuBarTickerSettings.isEnabled
                ? "\(model.menuBarTickerVisibleEntries.count) 项"
                : "已关闭"
        case .valuationAlert:
            return model.portfolioValuationAlertSettings.isEnabled
                ? "\(model.portfolioValuationAlertProfiles.values.reduce(0) { $0 + $1.rules.filter(\.isEnabled).count }) 条规则"
                : "已关闭"
        case .sync:
            return SyncClient.shared.isConfigured ? "已配置" : "未配置"
        }
    }

    private func settingsStatusTint(for focus: SettingsFocus) -> Color {
        switch focus {
        case .general:
            return AppPalette.brand
        case .watch:
            return model.managerWatchSettings.isEnabled ? AppPalette.positive : AppPalette.muted
        case .trend:
            return model.trendSettings.provider.isConfigured ? AppPalette.brand : AppPalette.muted
        case .menuBar:
            return model.menuBarTickerSettings.isEnabled ? AppPalette.info : AppPalette.muted
        case .valuationAlert:
            return model.portfolioValuationAlertSettings.isEnabled ? AppPalette.warning : AppPalette.muted
        case .sync:
            return SyncClient.shared.isConfigured ? AppPalette.positive : AppPalette.muted
        }
    }

    @ViewBuilder
    private var selectedSettingsPanel: some View {
        switch selectedSettingsFocus {
        case .general:
            appPanel
        case .watch:
            watchPanel
        case .trend:
            TrendSettingsPanel()
        case .menuBar:
            menuBarPanel
        case .valuationAlert:
            valuationAlertPanel
        case .sync:
            MacSyncConfigPanel()
        }
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let status: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let isCompact: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(isSelected ? AppPalette.brand : tint)
                .frame(width: 32, height: 32)
                .background(
                    (isSelected ? AppPalette.brandSoft : tint.opacity(0.09)),
                    in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                )

            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                    Text(status)
                        .font(AppPalette.appFont(.caption, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(tint.opacity(0.08), in: Capsule())
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: isCompact ? 68 : 76, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius)
                .fill(
                    isSelected
                        ? AppPalette.selectionFill.opacity(0.82)
                        : (isHovering ? AppPalette.cardHover.opacity(0.72) : AppPalette.card.opacity(0.54))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius)
                .stroke(
                    isSelected
                        ? AppPalette.selectionStroke.opacity(AppPalette.selectionStrokeOpacity)
                        : AppPalette.hairline.opacity(AppPalette.borderFaint),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isSelected ? AppPalette.selectionGlow.opacity(0.10) : .clear,
            radius: 8,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius))
        .onHover { hovering in
            withAnimation(AppPalette.motionFast) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(status)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
