import SwiftUI

/// W1.1 六步配置向导:新用户在 AI 页内完成「选供应商 → 拿 Key → 检测 →
/// 隐私 → 可选增强 → 生成首份研判」,不再跳设置页面对裸字段。
///
/// 直接写 `model.trendSettings` 并逐步保存(与设置面板同一模式),崩溃/退出
/// 不丢进度;每步只有单一任务。已配置用户从设置页以「重新配置」进入。
struct TrendSetupWizardSheet: View {
    enum Step: Int, CaseIterable {
        case provider = 0
        case apiKey = 1
        case check = 2
        case privacy = 3
        case extras = 4
        case done = 5

        var title: String {
            switch self {
            case .provider: return "选择供应商"
            case .apiKey: return "获取并粘贴 Key"
            case .check: return "检测模型"
            case .privacy: return "隐私模式"
            case .extras: return "可选增强(可跳过)"
            case .done: return "完成"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// 空态「缺 Tavily」等入口可直达对应步骤。
    var initialStep: Step = .provider

    @State private var step: Step = .provider
    @State private var selectedPreset: TrendProviderPreset?
    @State private var isCustomProvider = false
    @State private var didAttemptClipboardPrefill = false
    @State private var clipboardHint = ""
    @State private var isShowingDemoPreview = false

    private let presetBlurbs = [
        "智谱": "国内直连、性价比高;glm 系列支持工具调用",
        "OpenAI": "能力全面;国内网络可能需要代理",
        "DeepSeek": "价格低、中文理解好"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    stepContent
                }
                .padding(AppPalette.spaceL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 560)
        .sheet(isPresented: $isShowingDemoPreview) {
            DemoTrendReportPreviewSheet()
                .environmentObject(model)
        }
        .onAppear {
            step = initialStep
            if selectedPreset == nil, !isCustomProvider,
               let preset = TrendProviderPreset.matching(model.trendSettings.provider) {
                selectedPreset = preset
            }
        }
    }

    // MARK: - 骨架

    private var header: some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: "sparkles")
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
            Text("AI 研判配置向导")
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            Spacer(minLength: AppPalette.spaceM)
            ForEach(Step.allCases, id: \.rawValue) { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.rawValue <= step.rawValue ? AppPalette.brand : AppPalette.hairline.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(item.title)
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(item == step ? AppPalette.brand : AppPalette.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, AppPalette.spaceL)
        .padding(.vertical, AppPalette.spaceM)
    }

    private var footer: some View {
        HStack(spacing: AppPalette.spaceS) {
            if step.rawValue > Step.provider.rawValue {
                Button("上一步") {
                    withAnimation(AppPalette.motionStandard) {
                        step = Step(rawValue: step.rawValue - 1) ?? .provider
                    }
                }
                .buttonStyle(.appSecondary)
            }
            Spacer(minLength: AppPalette.spaceM)
            Button("取消") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.muted)
            nextButton
        }
        .padding(.horizontal, AppPalette.spaceL)
        .padding(.vertical, AppPalette.spaceM)
    }

    @ViewBuilder
    private var nextButton: some View {
        switch step {
        case .provider, .apiKey, .privacy, .extras:
            Button("下一步") {
                withAnimation(AppPalette.motionStandard) {
                    step = Step(rawValue: step.rawValue + 1) ?? .done
                }
            }
            .buttonStyle(.appPrimary)
            .disabled(!canAdvance)
        case .check:
            Button("下一步") {
                withAnimation(AppPalette.motionStandard) {
                    step = .privacy
                }
            }
            .buttonStyle(.appPrimary)
            .disabled(model.trendConnectionState != .succeeded)
        case .done:
            Button {
                dismiss()
                model.startTrendAnalysisFromUser(withExpectation: .full)
            } label: {
                Label("立即生成第一份研判", systemImage: "sparkles")
            }
            .buttonStyle(.appPrimary)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .provider:
            return selectedPreset != nil || isCustomProvider
        case .apiKey:
            return !model.trendSettings.provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !model.trendSettings.provider.baseURL.isEmpty
                && !model.trendSettings.provider.model.isEmpty
        default:
            return true
        }
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .provider: providerStep
        case .apiKey: apiKeyStep
        case .check: checkStep
        case .privacy: privacyStep
        case .extras: extrasStep
        case .done: doneStep
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            // W1.7 成本预期:第一次见就讲清楚计费方式与量级。
            Label(
                "Key 直接向模型服务商计费,本 App 不中转、不抽成;一次市场雷达约 ¥0.5–2(视模型与搜索次数)。",
                systemImage: "yuan.currency.sign.circle"
            )
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)
            .padding(AppPalette.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.info.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

            ForEach(TrendProviderPreset.allPresets) { preset in
                presetCard(preset)
            }
            customProviderCard

            Button {
                isShowingDemoPreview = true
            } label: {
                Label("先预览一份示例研判,看看能得到什么", systemImage: "eye")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.brand)
        }
    }

    private func presetCard(_ preset: TrendProviderPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id && !isCustomProvider
        return Button {
            selectedPreset = preset
            isCustomProvider = false
            preset.apply(to: &model.trendSettings.provider)
            model.saveTrendAnalysisSettings()
        } label: {
            HStack(spacing: AppPalette.spaceM) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppPalette.brand : AppPalette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: AppPalette.spaceS) {
                        Text(preset.name)
                            .font(AppPalette.appFont(.body, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                        TintedCapsuleBadge(
                            text: "支持工具调用",
                            tint: AppPalette.positive,
                            font: AppPalette.appFont(.caption2, weight: .semibold),
                            horizontalPadding: 5,
                            verticalPadding: 1
                        )
                        Spacer(minLength: 4)
                    }
                    Text(presetBlurbs[preset.name] ?? "")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: 4)
                Button("没有账号?去注册") {
                    if let url = URL(string: preset.consoleURL) {
                        openURL(url)
                    }
                }
                .buttonStyle(.plain)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.brand)
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(isSelected ? AppPalette.brand.opacity(0.5) : AppPalette.hairline.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var customProviderCard: some View {
        let isSelected = isCustomProvider
        return Button {
            isCustomProvider = true
            selectedPreset = nil
        } label: {
            HStack(spacing: AppPalette.spaceM) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppPalette.brand : AppPalette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自定义 / 其他供应商")
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("任何 OpenAI 兼容服务;下一步填写地址与模型")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: 4)
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(isSelected ? AppPalette.brand.opacity(0.5) : AppPalette.hairline.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            if let preset = selectedPreset {
                Button {
                    if let url = URL(string: preset.consoleURL) {
                        openURL(url)
                    }
                } label: {
                    Label("在浏览器打开 \(preset.name) 控制台,创建 API Key", systemImage: "safari")
                }
                .buttonStyle(.appSecondary)
            } else {
                Label("自定义供应商:请先在服务商处拿到地址、模型名与 Key", systemImage: "info.circle")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            if isCustomProvider {
                wizardField("供应商名称", text: $model.trendSettings.provider.providerName, placeholder: "如 月之暗面")
                wizardField("Base URL", text: $model.trendSettings.provider.baseURL, placeholder: "https://api.example.com/v1")
                wizardField("模型", text: $model.trendSettings.provider.model, placeholder: "模型名")
            }

            SecureField("粘贴 API Key(sk-…)", text: $model.trendSettings.provider.apiKey)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.body))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.hairline.opacity(0.32), lineWidth: 1)
                )

            if !clipboardHint.isEmpty {
                Label(clipboardHint, systemImage: "doc.on.clipboard")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.positive)
            }

            Text("Key 只保存在本机并随设置加密存储,不会上传到任何第三方(模型服务商除外,仅用于调用)。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .onAppear(perform: attemptClipboardPrefill)
        .onChange(of: model.trendSettings.provider.apiKey) { _, newValue in
            model.saveTrendAnalysisSettings()
        }
        .onChange(of: model.trendSettings.provider.baseURL) { _, newValue in
            model.saveTrendAnalysisSettings()
        }
        .onChange(of: model.trendSettings.provider.model) { _, newValue in
            model.saveTrendAnalysisSettings()
        }
    }

    /// W1.4:向导内剪贴板智能预填——识别已知 Key 形状且字段为空时自动填入并说明。
    private func attemptClipboardPrefill() {
        guard !didAttemptClipboardPrefill else { return }
        didAttemptClipboardPrefill = true
        guard let text = PasteboardHelper.readPlainText(),
              let match = TrendAPIKeyPasteHeuristics.classify(text) else { return }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match {
        case .providerKey(let suggestedPresetName):
            guard model.trendSettings.provider.apiKey.isEmpty else { return }
            if let suggestedPresetName,
               let preset = TrendProviderPreset.allPresets.first(where: { $0.name == suggestedPresetName }) {
                preset.apply(to: &model.trendSettings.provider)
                selectedPreset = preset
            }
            model.trendSettings.provider.apiKey = key
            model.saveTrendAnalysisSettings()
            clipboardHint = "已从剪贴板识别并填入 Key\(suggestedPresetName.map { "(疑似 \($0))" } ?? "")"
        }
    }

    private var checkStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(spacing: AppPalette.spaceS) {
                switch model.trendConnectionState {
                case .idle:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(AppPalette.muted)
                    Text("还没检测。点下方按钮验证 Key 与模型是否可用(会发起一次最小请求)。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("正在检测 \(model.trendSettings.provider.model) 的工具调用能力…")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppPalette.positive)
                    Text(model.lastTrendConnectionMessage)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.positive)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppPalette.danger)
                    Text(model.lastTrendConnectionMessage)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await model.checkTrendAIConnection() }
            } label: {
                Label(
                    model.trendConnectionState == .checking ? "检测中…" : "检测模型",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }
            .buttonStyle(.appSecondary)
            .disabled(model.trendConnectionState == .checking)

            if model.trendConnectionState == .failed {
                rescueChecklist
            }
        }
    }

    /// W1.6 失败救援清单:常见原因 + 逐条可执行动作,检测失败时展示。
    private var rescueChecklist: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Text("常见原因与修复动作")
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            ForEach(Array(rescueItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: AppPalette.spaceS) {
                    Image(systemName: item.icon)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(item.detail)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppPalette.spaceS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            }
            HStack(spacing: AppPalette.spaceS) {
                Button("重新检测") {
                    Task { await model.checkTrendAIConnection() }
                }
                .buttonStyle(.appSecondary)
                Button("去设置排查") {
                    model.selectedSection = .settings
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.brand)
                .font(AppPalette.appFont(.footnote, weight: .medium))
            }
        }
        .padding(AppPalette.spaceM)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private struct RescueItem {
        let icon: String
        let title: String
        let detail: String
    }

    private var rescueItems: [RescueItem] {
        [
            RescueItem(
                icon: "key.horizontal",
                title: "Key 无效或未填完整",
                detail: "回到上一步重新粘贴;注意前后空格,Key 以 sk- 等前缀开头。"
            ),
            RescueItem(
                icon: "creditcard",
                title: "账户余额不足",
                detail: "到供应商控制台确认余额或充值后,回到这里重新检测。"
            ),
            RescueItem(
                icon: "cpu",
                title: "模型不支持工具调用",
                detail: "换用预设推荐的模型(如 glm-5.2 / gpt-4o / deepseek-chat);本 App 的研判依赖工具调用能力。"
            ),
            RescueItem(
                icon: "wifi.exclamationmark",
                title: "网络不通或需要代理",
                detail: "OpenAI 等海外服务在国内网络可能需要代理;确认本机能访问供应商地址。"
            )
        ]
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            privacyCard(
                mode: .sanitized,
                icon: "lock.shield",
                title: "AI 看不到金额(推荐)",
                detail: "只发送持仓结构:基金、占比、涨跌、计划状态;不发送任何金额。大多数研判够用。"
            )
            privacyCard(
                mode: .fullDetail,
                icon: "chart.line.uptrend.xyaxis",
                title: "AI 看到金额,分析更准",
                detail: "持仓结构与金额一起发送;涉及仓位、盈亏的分析会更精确。"
            )
            Text("可随时在「设置 → AI 研判」切换。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
    }

    private func privacyCard(mode: TrendPrivacyMode, icon: String, title: String, detail: String) -> some View {
        let isSelected = model.trendPrivacyMode == mode
        return Button {
            model.trendPrivacyMode = mode
            model.trendSettings.defaultPrivacyMode = mode
            model.saveTrendAnalysisSettings()
        } label: {
            HStack(spacing: AppPalette.spaceM) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.headline))
                    .foregroundStyle(isSelected ? AppPalette.brand : AppPalette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(detail)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppPalette.brand)
                }
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(isSelected ? AppPalette.brand.opacity(0.5) : AppPalette.hairline.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var extrasStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Text("两项都是可选的,可以全部跳过;之后随时在设置里补配。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)

            extraCard(
                title: "Alpha Vantage",
                badge: "增强美股财报与日线",
                detail: "ETF 持仓、财报日历与日线统计更完整;免费额度每日 25 次。",
                keyField: Binding(
                    get: { model.trendSettings.alphaVantage.apiKey },
                    set: {
                        model.trendSettings.alphaVantage.apiKey = $0
                        model.trendSettings.alphaVantage.enabled = !$0.isEmpty
                    }
                ),
                placeholder: "Alpha Vantage Key",
                consoleURL: "https://www.alphavantage.co/support/#api-key"
            )

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack(spacing: AppPalette.spaceS) {
                    Text("SEC 官方披露")
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    TintedCapsuleBadge(
                        text: "免费,只需邮箱",
                        tint: AppPalette.positive,
                        font: AppPalette.appFont(.caption2, weight: .semibold),
                        horizontalPadding: 5,
                        verticalPadding: 1
                    )
                }
                Toggle("启用 SEC 官方披露(有美股或基金底层美股时更有用)", isOn: $model.trendSettings.officialSources.enabled)
                    .toggleStyle(.switch)
                    .font(AppPalette.appFont(.footnote))
                if model.trendSettings.officialSources.enabled {
                    wizardField(
                        "SEC 联系邮箱",
                        text: Binding(
                            get: { model.trendSettings.officialSources.secContactEmail },
                            set: { model.trendSettings.officialSources.secContactEmail = $0 }
                        ),
                        placeholder: "name@example.com"
                    )
                }
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        }
        .onChange(of: model.trendSettings.alphaVantage.apiKey) { _, _ in
            model.saveTrendAnalysisSettings()
        }
        .onChange(of: model.trendSettings.officialSources.enabled) { _, _ in
            model.saveTrendAnalysisSettings()
        }
    }

    private func extraCard(
        title: String,
        badge: String,
        detail: String,
        keyField: Binding<String>,
        placeholder: String,
        consoleURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                TintedCapsuleBadge(
                    text: badge,
                    tint: AppPalette.info,
                    font: AppPalette.appFont(.caption2, weight: .semibold),
                    horizontalPadding: 5,
                    verticalPadding: 1
                )
                Spacer(minLength: 4)
                Button("去获取 Key") {
                    if let url = URL(string: consoleURL) {
                        openURL(url)
                    }
                }
                .buttonStyle(.plain)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.brand)
            }
            Text(detail)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(placeholder, text: keyField)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.body))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.hairline.opacity(0.32), lineWidth: 1)
                )
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong.opacity(0.6), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.hairline.opacity(0.25), lineWidth: 1)
        )
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "checkmark.seal.fill")
                    .font(AppPalette.appFont(.title2))
                    .foregroundStyle(AppPalette.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置完成")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("模型:\(model.trendSettings.provider.model) · 隐私:\(model.trendPrivacyMode.rawValue)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            Toggle(isOn: Binding(
                get: { model.trendSettings.dailyAutoAnalysisEnabled },
                set: {
                    model.trendSettings.dailyAutoAnalysisEnabled = $0
                    model.saveTrendAnalysisSettings()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("顺便开启自动分析")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    // W1.7:自动分析开启前再次确认费用。
                    Text("每日 09:00(市场雷达)与 21:00(收盘复盘)各运行一次,费用由你的 Key 承担,每次约 ¥0.5–2;随时可关。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Label(
                "生成约需 5–15 分钟,期间可正常使用;进度在 AI 页顶部实时可见,完成后这里会出现今日研判摘要。",
                systemImage: "clock"
            )
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)
        }
    }

    private func wizardField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.body))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.hairline.opacity(0.32), lineWidth: 1)
                )
        }
    }
}
