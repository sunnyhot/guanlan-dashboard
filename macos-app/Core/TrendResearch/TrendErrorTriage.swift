import Foundation

/// 把模型/网络错误翻译成普通用户能行动的「原因 + 建议动作」。
///
/// `lastTrendError` / `nextHourGuidanceError` 在 AppModel 里已被展平为 String
/// (来源是 `OpenAICompatibleAgentClientError.errorDescription`),视图层只能
/// 拿到字符串;因此这里按关键词分诊,关键词与 errorDescription 的格式耦合
/// 由测试锁定(用真实错误构造消息再分诊,改文案会先红测试)。
enum TrendErrorTriage {
    struct Explanation: Hashable, Sendable {
        /// 人话原因,直接作为错误展示主文案。
        let reasonText: String
        /// 建议动作文案;nil 表示原文已含建议或无需动作。
        let actionText: String?
        /// 动作是否为「去设置」(视图据此渲染跳转按钮)。
        let shouldOpenSettings: Bool
    }

    static func explain(_ message: String) -> Explanation {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Explanation(reasonText: message, actionText: nil, shouldOpenSettings: false)
        }

        // 429/超时的 errorDescription 本身已是完整人话,只补动作。
        if trimmed.contains("HTTP 429") || trimmed.contains("额度") || trimmed.contains("限流") {
            return Explanation(
                reasonText: trimmed,
                actionText: "稍后再试,或更换供应商",
                shouldOpenSettings: false
            )
        }
        if trimmed.contains("HTTP 401") || trimmed.contains("HTTP 403") {
            return Explanation(
                reasonText: "API Key 无效或权限不足:\(trimmed)",
                actionText: "去设置检查 API Key,必要时到供应商控制台确认",
                shouldOpenSettings: true
            )
        }
        if trimmed.contains("HTTP 404") {
            return Explanation(
                reasonText: "接口地址可能不对(常见是缺少 /v1 等路径后缀):\(trimmed)",
                actionText: "去设置检查 Base URL",
                shouldOpenSettings: true
            )
        }
        if let range = trimmed.range(of: "HTTP 5"), range.lowerBound < trimmed.endIndex {
            return Explanation(
                reasonText: "模型服务商暂时故障:\(trimmed)",
                actionText: "稍后再试",
                shouldOpenSettings: false
            )
        }
        if trimmed.contains("超时") {
            return Explanation(
                reasonText: trimmed,
                actionText: nil,
                shouldOpenSettings: false
            )
        }
        if trimmed.contains("地址无效") {
            return Explanation(
                reasonText: trimmed,
                actionText: "去设置检查 Base URL 是否完整",
                shouldOpenSettings: true
            )
        }
        if trimmed.contains("返回格式不符合") {
            return Explanation(
                reasonText: "模型接口返回格式不兼容,可能是模型不支持工具调用:\(trimmed)",
                actionText: "去设置更换支持 Tool Calling 的模型",
                shouldOpenSettings: true
            )
        }
        if trimmed.contains("尚未配置") {
            return Explanation(
                reasonText: trimmed,
                actionText: "去设置配置模型",
                shouldOpenSettings: true
            )
        }
        if trimmed.contains("请求失败") {
            return Explanation(
                reasonText: "网络不通或模型服务异常:\(trimmed)",
                actionText: "检查网络后重试",
                shouldOpenSettings: false
            )
        }

        return Explanation(reasonText: trimmed, actionText: nil, shouldOpenSettings: false)
    }
}
