#if os(iOS)
import SwiftUI

// MARK: - iOS 设置页
//
// 精简版设置:iPhone 上用原生 Form/List 风格。包含外观、主理人配置、
// AI 模型入口、关于。macOS 专属项(菜单栏、开机自启、应用内自更新)在
// iOS 隐藏——它们对应的平台能力已抽协议(NoOp)。

struct SettingsSectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("qieman.dashboard.update.autoCheckOnLaunch") private var autoCheckOnLaunch = true

    @FocusState private var focusedField: Field?

    enum Field { case managerName, prodCode }

    var body: some View {
        List {
            appearanceSection
            managerSection
            trendSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // 键盘上方 Done 按钮,收起键盘
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .refreshable {
            try? await model.refreshLatest(persist: false)
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: appearanceBinding) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.rawValue).tag(appearance)
                }
            }
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.appearance },
            set: { model.appearance = $0 }
        )
    }

    // MARK: - 主理人配置

    private var managerSection: some View {
        Section("主理人") {
            HStack {
                Text("关注主理人")
                Spacer()
                TextField("主理人昵称", text: managerNameBinding)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(AppPalette.muted)
                    .focused($focusedField, equals: .managerName)
            }
            HStack {
                Text("产品代码")
                Spacer()
                TextField("LONG_WIN", text: prodCodeBinding)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(AppPalette.muted)
                    .focused($focusedField, equals: .prodCode)
            }
            Button("立即刷新数据") {
                Task { try? await model.refreshLatest(persist: false) }
            }
        }
    }

    // MARK: - AI 趋势模型

    private var trendSection: some View {
        Section("AI 与数据") {
            NavigationLink {
                IOSTrendSettingsView()
            } label: {
                HStack {
                    Label("AI 趋势模型", systemImage: "sparkles")
                    Spacer()
                    if model.trendSettings.provider.isConfigured {
                        Text("已配置").foregroundStyle(IOSDesign.muted)
                    } else {
                        Text("未配置").foregroundStyle(AppPalette.marketGain)
                    }
                }
            }
        }
    }

    private var managerNameBinding: Binding<String> {
        Binding(
            get: { model.form.managerName },
            set: { model.form.managerName = $0 }
        )
    }

    private var prodCodeBinding: Binding<String> {
        Binding(
            get: { model.form.prodCode },
            set: { model.form.prodCode = $0 }
        )
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion).foregroundStyle(AppPalette.muted)
            }
            HStack {
                Text("平台")
                Spacer()
                Text("iOS").foregroundStyle(AppPalette.muted)
            }
            // iOS 不支持应用内自更新;说明文字告知用户通过 App Store 更新
            HStack {
                Text("更新方式")
                Spacer()
                Text("App Store").foregroundStyle(AppPalette.muted)
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }
}
#endif
