#if os(iOS)
import SwiftUI

// MARK: - iOS 设置 · 投资智能面板（产品重构 §9）
//
// iOS 不在首页放 Provider 表单，统一进设置。API Key 存 Keychain
// （kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly——不与 macOS 共享）。

struct IOSSettingsIntelligencePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var baseURL = IntelligenceV2ProviderSettings.baseURL
    @State private var modelName = IntelligenceV2ProviderSettings.model
    @State private var apiKeyInput = ""
    @State private var isConfirmingKeyDeletion = false
    @State private var keySaveError: String?

    var body: some View {
        Form {
            modelSection
            dataSourcesSection
            privacySection
        }
        .navigationTitle("投资智能")
        .navigationBarTitleDisplayMode(.inline)
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

    private var modelSection: some View {
        Section {
            LabeledContent("状态") {
                Text(IntelligenceV2ProviderSettings.isConfigured ? "已就绪" : "缺少模型")
                    .foregroundStyle(
                        IntelligenceV2ProviderSettings.isConfigured
                            ? AppPalette.positive : AppPalette.warning)
            }
            LabeledContent("服务商") {
                Text(presetName)
                    .foregroundStyle(.secondary)
            }
            TextField("Base URL（HTTPS）", text: $baseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("模型名", text: $modelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                SecureField(
                    IntelligenceV2ProviderSettings.apiKey.isEmpty
                        ? "API Key（保存后不再显示）"
                        : "已保存（输入新值可替换）",
                    text: $apiKeyInput
                )
                Text(IntelligenceV2ProviderSettings.apiKey.isEmpty ? "未保存" : "已保存")
                    .font(.caption)
                    .foregroundStyle(
                        IntelligenceV2ProviderSettings.apiKey.isEmpty
                            ? AppPalette.muted : AppPalette.positive)
            }
            Button("保存") { saveConfiguration() }
                .disabled(!formIsValid)
            if let keySaveError {
                Text(keySaveError)
                    .font(.caption)
                    .foregroundStyle(AppPalette.warning)
                    .textSelection(.enabled)
            }
            if !IntelligenceV2ProviderSettings.apiKey.isEmpty {
                Button("清除密钥…", role: .destructive) {
                    isConfirmingKeyDeletion = true
                }
            }
        } header: {
            Text("AI 模型")
        } footer: {
            Text(formIsValid ? "" : "Base URL 需为合法 HTTPS 地址，模型名不能为空。")
        }
    }

    private var presetName: String {
        switch baseURL.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "https://open.bigmodel.cn/api/paas/v4": return "智谱"
        case "https://api.openai.com/v1": return "OpenAI"
        case "https://api.deepseek.com/v1": return "DeepSeek"
        default: return "自定义"
        }
    }

    private var formIsValid: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return false }
        return !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveConfiguration() {
        // Key 写入结果必须呈现（v4.4.1：写失败不再假报成功）
        let keyStored = IntelligenceV2ProviderSettings.save(
            baseURL: baseURL, model: modelName, apiKey: apiKeyInput)
        apiKeyInput = ""
        model.objectWillChange.send()
        model.refreshIntelligenceDashboard()
        keySaveError = keyStored
            ? nil
            : "API Key 写入本机钥匙串失败（可能存在访问受限的旧密钥条目）。可先清除密钥后重新保存。"
    }

    private var dataSourcesSection: some View {
        Section {
            LabeledContent("Tavily 网络检索") {
                Text(KeychainHelper.get(account: KeychainHelper.Account.tavilyKey) != nil ? "已配置" : "未配置")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Alpha Vantage 行情") {
                Text(UserDefaults.standard.bool(
                    forKey: IntelligenceV2ProviderSettings.alphaVantageEnabledKey)
                     ? "已启用" : "未启用")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("A 股行情增强通道") {
                Text(remoteChannelConfigured ? "已启用" : "未启用")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("研究数据源")
        } footer: {
            Text("A 股通道未启用时，A 股标的暂不参与市场机会筛选（不影响其他市场）。")
        }
    }

    private var remoteChannelConfigured: Bool {
        if case .notConfigured = model.remoteStagingSyncStatus { return false }
        return true
    }

    private var privacySection: some View {
        Section {
            Text("组合研究会把持仓摘要、市场数据与研究发现发送给你配置的模型服务商。API Key 仅保存在本机钥匙串，不会写入云同步档案。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("隐私")
        }
    }
}
#endif
