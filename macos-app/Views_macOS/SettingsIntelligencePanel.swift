import SwiftUI

// MARK: - 设置 · 投资智能面板（产品重构 §9）
//
// AI Provider 配置从投资智能主页迁入设置中心。三组：
// 1. AI 模型：Provider 预设 / Base URL / 模型名 / API Key（保存 / 显式清除）
// 2. 研究数据源：Tavily / Alpha Vantage / 远程 A 股增强通道状态
// 3. 隐私与诊断：发送给模型的数据说明 / 打开数据目录 / 诊断日志
//
// 纪律：Key 只存 Keychain（UI 只显示已保存/未保存）；清除需二次确认；
// 保存成功用 inline Toast；文件名等内部术语只出现在「高级诊断」折叠区。

struct SettingsIntelligencePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var baseURL = IntelligenceV2ProviderSettings.baseURL
    @State private var modelName = IntelligenceV2ProviderSettings.model
    @State private var apiKeyInput = ""
    @State private var isConfirmingKeyDeletion = false
    @State private var toastMessage: String?
    @State private var keySaveError: String?
    @State private var isAdvancedDiagnosticsExpanded = false

    private struct ProviderPreset: Identifiable {
        let id: String
        let name: String
        let baseURL: String
        let model: String
    }

    private let presets: [ProviderPreset] = [
        ProviderPreset(id: "zhipu", name: "智谱", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.7"),
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        ProviderPreset(id: "custom", name: "自定义", baseURL: "", model: ""),
    ]

    var body: some View {
        VStack(spacing: AppPalette.spaceL) {
            modelSection
            autoRunSection
            dataSourcesSection
            privacySection
        }
        .overlay(alignment: .topTrailing) {
            if let toastMessage {
                Text(toastMessage)
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.positive)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppPalette.positive.opacity(0.08), in: Capsule())
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.toastMessage = nil
                    }
                    .padding(.trailing, 4)
            }
        }
    }

    // MARK: - AI 模型

    private var modelSection: some View {
        SectionCard(
            title: "AI 模型",
            subtitle: IntelligenceV2ProviderSettings.isConfigured ? "已配置" : "未配置",
            icon: "brain"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                LabeledValue(title: "状态", value: IntelligenceV2ProviderSettings.isConfigured ? "已就绪" : "缺少模型配置")

                HStack(spacing: AppPalette.spaceS) {
                    Text("服务商预设")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            // 预设只填 Base URL 与建议模型——不改已有 Key
                            guard preset.id != "custom" else { return }
                            baseURL = preset.baseURL
                            modelName = preset.model
                        }
                        .buttonStyle(.appText)
                        .controlSize(.small)
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .disabled(preset.id == "custom")
                    }
                }

                providerField(title: "Base URL", text: $baseURL, placeholder: "https://open.bigmodel.cn/api/paas/v4")
                providerField(title: "模型名", text: $modelName, placeholder: "glm-4.7")

                HStack(spacing: AppPalette.spaceS) {
                    Text("API Key")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 64, alignment: .leading)
                    SecureField(
                        IntelligenceV2ProviderSettings.apiKey.isEmpty
                            ? "输入密钥（保存后不再显示）"
                            : "已保存（输入新值可替换）",
                        text: $apiKeyInput
                    )
                    .textFieldStyle(.roundedBorder)
                    Text(IntelligenceV2ProviderSettings.apiKey.isEmpty ? "未保存" : "已保存")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(
                            IntelligenceV2ProviderSettings.apiKey.isEmpty
                                ? AppPalette.muted : AppPalette.positive)
                }

                HStack(spacing: AppPalette.spaceS) {
                    Button("保存") { saveConfiguration() }
                        .buttonStyle(.appPrimary)
                        .controlSize(.small)
                        .disabled(!formIsValid)
                    if !IntelligenceV2ProviderSettings.apiKey.isEmpty {
                        Button("清除密钥…") { isConfirmingKeyDeletion = true }
                            .buttonStyle(.appSecondary)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                if !formIsValid && !baseURL.isEmpty {
                    Text("Base URL 需为合法 HTTPS 地址，模型名不能为空。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.warning)
                }
                if let keySaveError {
                    Label(keySaveError, systemImage: "exclamationmark.triangle")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .confirmationDialog(
            "确认清除已保存的 API Key？",
            isPresented: $isConfirmingKeyDeletion,
            titleVisibility: .visible
        ) {
            Button("清除密钥", role: .destructive) {
                IntelligenceV2ProviderSettings.deleteAPIKey()
                apiKeyInput = ""
                model.objectWillChange.send()
                model.refreshIntelligenceDashboard()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后研究功能将不可用，直至重新保存密钥。")
        }
    }

    private var formIsValid: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return false }
        return !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func providerField(title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func saveConfiguration() {
        // Key 写入结果必须呈现（v4.4.1：写失败不再假报「已保存」）
        let keyStored = IntelligenceV2ProviderSettings.save(
            baseURL: baseURL, model: modelName, apiKey: apiKeyInput)
        apiKeyInput = ""
        model.objectWillChange.send()
        model.refreshIntelligenceDashboard()
        if keyStored {
            keySaveError = nil
            toastMessage = IntelligenceV2ProviderSettings.isConfigured
                ? "已保存" : "已保存（还需填写 API Key）"
        } else {
            keySaveError = "API Key 写入本机钥匙串失败（系统拒绝了访问）。\n可先点「清除密钥…」再重新保存；若仍失败，请重启 App 后重试。"
        }
    }

    // MARK: - 自动运行（审计 B1/C5）

    private var autoRunSection: some View {
        SectionCard(
            title: "自动运行",
            subtitle: "按产品模块错峰生成，同一窗口至多自动尝试一次",
            icon: "clock.badge.checkmark"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Toggle(isOn: autoRunTotalBinding) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("启用自动运行")
                            .font(AppPalette.appFont(.subheadline, weight: .medium))
                        Text(IntelligenceScheduleEvaluator.scheduleSummaryText)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if model.intelligenceScheduleSettings.isAutoRunEnabled {
                    Divider()
                    autoRunModuleRow(
                        title: "市场发现",
                        detail: "每日 09:00",
                        binding: autoRunModuleBinding(\.marketDiscoveryEnabled))
                    autoRunModuleRow(
                        title: "盘中评估",
                        detail: "09:15 / 10:15 / 11:15 / 13:15 / 14:15 / 14:50",
                        binding: autoRunModuleBinding(\.intradayEnabled))
                    autoRunModuleRow(
                        title: "收盘复盘",
                        detail: "每日 21:00（错过可手动补做）",
                        binding: autoRunModuleBinding(\.closeReviewEnabled))
                    autoRunModuleRow(
                        title: "组合研究",
                        detail: "周日 20:00（需 AI 模型已配置）",
                        binding: autoRunModuleBinding(\.portfolioResearchEnabled))
                }
            }
        }
    }

    private var autoRunTotalBinding: Binding<Bool> {
        Binding(
            get: { model.intelligenceScheduleSettings.isAutoRunEnabled },
            set: { enabled in
                model.updateIntelligenceSchedule { settings in
                    settings.isAutoRunEnabled = enabled
                }
            })
    }

    private func autoRunModuleBinding(
        _ keyPath: WritableKeyPath<IntelligenceScheduleSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.intelligenceScheduleSettings[keyPath: keyPath] },
            set: { enabled in
                model.updateIntelligenceSchedule { settings in
                    settings[keyPath: keyPath] = enabled
                }
            })
    }

    private func autoRunModuleRow(
        title: String, detail: String, binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                Text(detail)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    // MARK: - 研究数据源

    private var dataSourcesSection: some View {
        SectionCard(
            title: "研究数据源",
            subtitle: "研究证据的可选来源",
            icon: "externaldrive.connected.to.line.below"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                sourceRow(
                    name: "Tavily 网络检索",
                    configured: KeychainHelper.get(account: KeychainHelper.Account.tavilyKey) != nil,
                    hint: "在 App 数据目录的密钥库中管理")
                Divider()
                sourceRow(
                    name: "Alpha Vantage 行情",
                    configured: UserDefaults.standard.bool(forKey: IntelligenceV2ProviderSettings.alphaVantageEnabledKey),
                    hint: "美股 / ETF 日线数据补充")
                Divider()
                remoteChannelRow
            }
        }
    }

    private var remoteChannelRow: some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: remoteChannelConfigured ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(remoteChannelConfigured ? AppPalette.positive : AppPalette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("A 股行情增强通道")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                Text(remoteChannelConfigured
                     ? "已启用——A 股标的参与本地因子筛选"
                     : "未启用——A 股标的暂不参与筛选（不影响其他市场）")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var remoteChannelConfigured: Bool {
        if case .notConfigured = model.remoteStagingSyncStatus { return false }
        return true
    }

    private func sourceRow(name: String, configured: Bool, hint: String) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: configured ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(configured ? AppPalette.positive : AppPalette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                Text(hint)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 隐私与诊断

    private var privacySection: some View {
        SectionCard(
            title: "隐私与诊断",
            subtitle: "发送给模型的数据与本地诊断",
            icon: "hand.raised"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("组合研究会把持仓摘要、市场数据与研究发现发送给你配置的模型服务商。API Key 仅保存在本机钥匙串，不会写入云同步档案。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppPalette.spaceS) {
                    Button("打开数据目录") { model.openDataDirectory() }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    Button("打开诊断日志目录") {
                        if let directory = model.dataDirectoryURL {
                            NSWorkspace.shared.open(
                                directory.appendingPathComponent("ai-analysis-logs", isDirectory: true))
                        }
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(model.dataDirectoryURL == nil)
                }
                DisclosureGroup("高级诊断", isExpanded: $isAdvancedDiagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地同步通道的配置文件位于数据目录（remote-staging-sync.json）；未启用时 A 股行情增强通道不启动。")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("用户战略目标与持仓分类保存在数据目录 investment-intelligence-v2/user-intent/（纯文本事件，可随时查看）。")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
                .font(AppPalette.appFont(.footnote))
            }
        }
    }
}
