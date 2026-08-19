import Foundation

/// 常用 OpenAI 兼容供应商预设:一键填入 Base URL 与默认模型,并附带
/// 获取 API Key 的控制台链接。预设只做预填,模型名等字段填入后仍可修改,
/// 自定义供应商不受影响。
struct TrendProviderPreset: Hashable, Sendable, Identifiable {
    let name: String
    let baseURL: String
    let defaultModel: String
    /// 获取 API Key 的控制台页面。
    let consoleURL: String

    var id: String { name }

    /// 首发预设。智谱的地址与模型取自设置页既有 placeholder(与项目实际用法
    /// 一致);OpenAI / DeepSeek 为各自公开稳定的标准接入地址。
    static let allPresets: [TrendProviderPreset] = [
        TrendProviderPreset(
            name: "智谱",
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
            defaultModel: "glm-5.2",
            consoleURL: "https://open.bigmodel.cn/usercenter/apikeys"
        ),
        TrendProviderPreset(
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o",
            consoleURL: "https://platform.openai.com/api-keys"
        ),
        TrendProviderPreset(
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-chat",
            consoleURL: "https://platform.deepseek.com/api_keys"
        ),
    ]

    /// 应用预设:只填供应商名、Base URL 与默认模型;API Key 与超时等
    /// 用户已有配置一律不动。
    func apply(to settings: inout TrendAIProviderSettings) {
        settings.providerName = name
        settings.baseURL = baseURL
        settings.model = defaultModel
    }

    /// 当前配置命中的预设(按 Base URL 匹配,用于高亮已选与展示取 Key 入口)。
    static func matching(_ settings: TrendAIProviderSettings) -> TrendProviderPreset? {
        let configured = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return nil }
        return allPresets.first { $0.baseURL == configured }
    }
}
