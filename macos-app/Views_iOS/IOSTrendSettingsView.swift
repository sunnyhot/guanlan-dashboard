#if os(iOS)
import SwiftUI

// MARK: - iOS 趋势/AI 模型设置
//
// 复用 model.trendSettings(provider/webSearch/alphaVantage)和
// saveTrendAnalysisSettings()。让用户在 iOS 设备上直接配置 OpenAI 兼容
// 模型、Tavily、Alpha Vantage 的 API Key——否则 AI 研判无法在本机配置。

struct IOSTrendSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            providerSection
            webSearchSection
            alphaVantageSection
            actionsSection
        }
        .navigationTitle("AI 趋势模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    model.saveTrendAnalysisSettings()
                    dismiss()
                }
                .bold()
            }
        }
    }

    // MARK: - AI 模型供应商

    private var providerSection: some View {
        Section {
            LabeledContent {
                TextField("OpenAI / 兼容服务", text: providerNameBinding)
                    .multilineTextAlignment(.trailing)
            } label: { Text("供应商名称") }
            LabeledContent {
                TextField("https://api.openai.com/v1", text: baseURLBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: { Text("接口地址") }
            LabeledContent {
                TextField("gpt-4o", text: modelBinding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: { Text("模型名") }
            SecureField("API Key", text: apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent {
                TextField("秒", text: timeoutBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            } label: { Text("超时") }
        } header: {
            Text("AI 模型")
        } footer: {
            Text("兼容 OpenAI 接口的模型供应商。API Key 在设备上使用安全存储；手动同步时会随端到端加密数据传输，服务端不能读取。")
        }
    }

    // MARK: - Tavily 网络搜索

    private var webSearchSection: some View {
        Section {
            SecureField("Tavily API Key", text: tavilyKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("网络搜索 (Tavily)")
        } footer: {
            Text("可选。用于 AI 研判时检索最新市场资讯。")
        }
    }

    // MARK: - Alpha Vantage

    private var alphaVantageSection: some View {
        Section {
            Toggle("启用 Alpha Vantage 行情", isOn: alphaVantageEnabledBinding)
            if model.trendSettings.alphaVantage.enabled {
                SecureField("Alpha Vantage API Key", text: alphaVantageKeyBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent {
                    TextField("次/天", value: alphaVantageLimitBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                } label: { Text("每日限额") }
            }
        } header: {
            Text("Alpha Vantage 行情")
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            Button("立即生成趋势研判") {
                Task { await model.startTrendAnalysis(userInitiated: true) }
            }
            .disabled(!model.trendSettings.provider.isConfigured)
        } footer: {
            if !model.trendSettings.provider.isConfigured {
                Text("⚠️ 请先填写供应商、接口地址、模型名和 API Key。").foregroundStyle(AppPalette.marketGain)
            }
        }
    }

    // MARK: - Bindings

    private var providerNameBinding: Binding<String> {
        Binding(get: { model.trendSettings.provider.providerName },
                set: { model.trendSettings.provider.providerName = $0 })
    }
    private var baseURLBinding: Binding<String> {
        Binding(get: { model.trendSettings.provider.baseURL },
                set: { model.trendSettings.provider.baseURL = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { model.trendSettings.provider.model },
                set: { model.trendSettings.provider.model = $0 })
    }
    private var apiKeyBinding: Binding<String> {
        Binding(get: { model.trendSettings.provider.apiKey },
                set: { model.trendSettings.provider.apiKey = $0 })
    }
    private var timeoutBinding: Binding<String> {
        Binding(get: { String(Int(model.trendSettings.provider.timeoutSeconds.rounded())) },
                set: { if let t = Double($0) { model.trendSettings.provider.timeoutSeconds = t } })
    }
    private var tavilyKeyBinding: Binding<String> {
        Binding(get: { model.trendSettings.webSearch.apiKey },
                set: { model.trendSettings.webSearch.apiKey = $0 })
    }
    private var alphaVantageEnabledBinding: Binding<Bool> {
        Binding(get: { model.trendSettings.alphaVantage.enabled },
                set: { model.trendSettings.alphaVantage.enabled = $0 })
    }
    private var alphaVantageKeyBinding: Binding<String> {
        Binding(get: { model.trendSettings.alphaVantage.apiKey },
                set: { model.trendSettings.alphaVantage.apiKey = $0 })
    }
    private var alphaVantageLimitBinding: Binding<Int> {
        Binding(get: { model.trendSettings.alphaVantage.dailyRequestLimit },
                set: { model.trendSettings.alphaVantage.dailyRequestLimit = $0 })
    }
}
#endif
