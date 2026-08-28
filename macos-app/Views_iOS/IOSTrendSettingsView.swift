#if os(iOS)
import SwiftUI

// MARK: - iOS 趋势/AI 模型设置(W1.8 向导化)
//
// 复用 model.trendSettings(provider/alphaVantage)和
// saveTrendAnalysisSettings()。未配置用户进入分步向导(选供应商 → 贴 Key →
// 检测 → 隐私 → 完成,可选增强收敛为完成页开关);已配置用户进入完整编辑
// 表单,不被向导打扰,可手动「重新配置(向导)」。

struct IOSTrendSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum WizardStep: Int, CaseIterable {
        case provider = 0
        case apiKey = 1
        case check = 2
        case privacy = 3
        case done = 4

        var title: String {
            switch self {
            case .provider: return "供应商"
            case .apiKey: return "API Key"
            case .check: return "检测"
            case .privacy: return "隐私"
            case .done: return "完成"
            }
        }
    }

    @State private var isWizardMode = false
    @State private var wizardStep: WizardStep = .provider
    @State private var selectedPreset: TrendProviderPreset?
    @State private var isCustomProvider = false
    @State private var didAttemptClipboardPrefill = false
    @State private var clipboardHint = ""

    private let presetBlurbs = [
        "智谱": "国内直连、性价比高;glm 系列支持工具调用",
        "OpenAI": "能力全面;国内网络可能需要代理",
        "DeepSeek": "价格低、中文理解好"
    ]

    var body: some View {
        Group {
            if isWizardMode {
                wizardBody
            } else {
                formBody
            }
        }
        .navigationTitle("AI 趋势模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isWizardMode, !model.trendSettings.provider.isConfigured {
                isWizardMode = true
            }
        }
    }

    // MARK: - 向导模式

    private var wizardBody: some View {
        VStack(spacing: 0) {
            stepHeader
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    wizardStepContent
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            wizardFooter
        }
    }

    private var stepHeader: some View {
        HStack(spacing: IOSDesign.spaceS) {
            Image(systemName: "sparkles")
                .foregroundStyle(IOSDesign.accent)
            Text("配置向导")
                .font(.headline.weight(.bold))
            Spacer(minLength: IOSDesign.spaceM)
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 3) {
                    Circle()
                        .fill(step.rawValue <= wizardStep.rawValue ? IOSDesign.accent : Color.gray.opacity(0.3))
                        .frame(width: 6, height: 6)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == wizardStep ? IOSDesign.accent : IOSDesign.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var wizardFooter: some View {
        HStack(spacing: IOSDesign.spaceS) {
            if wizardStep.rawValue > WizardStep.provider.rawValue {
                Button("上一步") {
                    withAnimation { wizardStep = WizardStep(rawValue: wizardStep.rawValue - 1) ?? .provider }
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: IOSDesign.spaceM)
            Button("查看完整设置") {
                isWizardMode = false
            }
            .font(.footnote)
            .foregroundStyle(IOSDesign.muted)
            Button(wizardStep == .done ? "生成第一份研判" : "下一步") {
                advanceWizard()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!wizardCanAdvance)
        }
        .padding(16)
    }

    private var wizardCanAdvance: Bool {
        switch wizardStep {
        case .provider:
            return selectedPreset != nil || isCustomProvider
        case .apiKey:
            return !model.trendSettings.provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !model.trendSettings.provider.baseURL.isEmpty
                && !model.trendSettings.provider.model.isEmpty
        case .check:
            return model.trendConnectionState == .succeeded
        default:
            return true
        }
    }

    private func advanceWizard() {
        if wizardStep == .done {
            model.startTrendAnalysisFromUser(withExpectation: .full)
            dismiss()
            return
        }
        withAnimation { wizardStep = WizardStep(rawValue: wizardStep.rawValue + 1) ?? .done }
    }

    @ViewBuilder
    private var wizardStepContent: some View {
        switch wizardStep {
        case .provider: wizardProviderStep
        case .apiKey: wizardAPIKeyStep
        case .check: wizardCheckStep
        case .privacy: wizardPrivacyStep
        case .done: wizardDoneStep
        }
    }

    private var wizardProviderStep: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            // W1.7 成本预期。
            Label(
                "Key 直接向模型服务商计费,本 App 不中转;一次市场雷达约 ¥0.5–2(视模型与搜索次数)。",
                systemImage: "yensign.circle"
            )
            .font(.footnote)
            .foregroundStyle(IOSDesign.muted)

            ForEach(TrendProviderPreset.allPresets) { preset in
                Button {
                    selectedPreset = preset
                    isCustomProvider = false
                    preset.apply(to: &model.trendSettings.provider)
                    model.saveTrendAnalysisSettings()
                } label: {
                    HStack(spacing: IOSDesign.spaceM) {
                        Image(systemName: (selectedPreset?.id == preset.id && !isCustomProvider) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(IOSDesign.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body.weight(.bold))
                                .foregroundStyle(IOSDesign.ink)
                            Text(presetBlurbs[preset.name] ?? "")
                                .font(.footnote)
                                .foregroundStyle(IOSDesign.muted)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Button {
                isCustomProvider = true
                selectedPreset = nil
            } label: {
                HStack(spacing: IOSDesign.spaceM) {
                    Image(systemName: isCustomProvider ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(IOSDesign.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自定义 / 其他供应商")
                            .font(.body.weight(.bold))
                            .foregroundStyle(IOSDesign.ink)
                        Text("任何 OpenAI 兼容服务;下一步填写地址与模型")
                            .font(.footnote)
                            .foregroundStyle(IOSDesign.muted)
                    }
                    Spacer(minLength: 4)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private var wizardAPIKeyStep: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            if let preset = selectedPreset {
                Button {
                    if let url = URL(string: preset.consoleURL) {
                        openURL(url)
                    }
                } label: {
                    Label("在浏览器打开 \(preset.name) 控制台,创建 API Key", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }

            if isCustomProvider {
                iosWizardField("供应商名称", text: providerNameBinding, placeholder: "如 月之暗面")
                iosWizardField("Base URL", text: baseURLBinding, placeholder: "https://api.example.com/v1")
                iosWizardField("模型名", text: modelBinding, placeholder: "模型名")
            }

            SecureField("粘贴 API Key(sk-…)", text: apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if !clipboardHint.isEmpty {
                Label(clipboardHint, systemImage: "doc.on.clipboard")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            }

            Text("Key 只保存在本机并随设置加密存储,不会上传到任何第三方(模型服务商除外,仅用于调用)。")
                .font(.caption)
                .foregroundStyle(IOSDesign.muted)
        }
        .onAppear(perform: attemptClipboardPrefill)
        .onChange(of: model.trendSettings.provider.apiKey) { _, _ in
            model.saveTrendAnalysisSettings()
        }
        .onChange(of: model.trendSettings.provider.baseURL) { _, _ in
            model.saveTrendAnalysisSettings()
        }
        .onChange(of: model.trendSettings.provider.model) { _, _ in
            model.saveTrendAnalysisSettings()
        }
    }

    /// W1.4:向导内剪贴板智能预填(与 macOS 同一启发式)。
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

    private var wizardCheckStep: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            HStack(spacing: IOSDesign.spaceS) {
                switch model.trendConnectionState {
                case .idle:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(IOSDesign.muted)
                    Text("还没检测。点下方按钮验证 Key 与模型是否可用。")
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                case .checking:
                    ProgressView()
                    Text("正在检测 \(model.trendSettings.provider.model)…")
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(model.lastTrendConnectionMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(model.lastTrendConnectionMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
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
            .buttonStyle(.bordered)
            .disabled(model.trendConnectionState == .checking)

            if model.trendConnectionState == .failed {
                // W1.6 失败救援清单(iOS 版精简为四行)。
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    Text("常见原因")
                        .font(.subheadline.weight(.bold))
                    ForEach(
                        [
                            "Key 无效或未填完整——回到上一步重新粘贴",
                            "账户余额不足——到供应商控制台确认余额",
                            "模型不支持工具调用——换预设推荐模型",
                            "网络不通——确认本机能访问供应商地址"
                        ],
                        id: \.self
                    ) { line in
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(IOSDesign.muted)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var wizardPrivacyStep: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            iosPrivacyCard(
                mode: .sanitized,
                icon: "lock.shield",
                title: "AI 看不到金额(推荐)",
                detail: "只发送持仓结构:基金、占比、涨跌;不发送任何金额。"
            )
            iosPrivacyCard(
                mode: .fullDetail,
                icon: "chart.line.uptrend.xyaxis",
                title: "AI 看到金额,分析更准",
                detail: "持仓结构与金额一起发送;涉及仓位、盈亏的分析更精确。"
            )
        }
    }

    private func iosPrivacyCard(mode: TrendPrivacyMode, icon: String, title: String, detail: String) -> some View {
        let isSelected = model.trendPrivacyMode == mode
        return Button {
            model.trendPrivacyMode = mode
            model.trendSettings.defaultPrivacyMode = mode
            model.saveTrendAnalysisSettings()
        } label: {
            HStack(spacing: IOSDesign.spaceM) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? IOSDesign.accent : IOSDesign.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(IOSDesign.ink)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(IOSDesign.accent)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var wizardDoneStep: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            HStack(spacing: IOSDesign.spaceS) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置完成")
                        .font(.title3.weight(.bold))
                    Text("模型:\(model.trendSettings.provider.model) · 隐私:\(model.trendPrivacyMode.rawValue)")
                        .font(.footnote)
                        .foregroundStyle(IOSDesign.muted)
                }
            }

            // 可选增强收敛为提示(W1.8 简化;不写入占位 Key,诚实引导到完整设置)。
            Label(
                "可选增强:联网搜索 Tavily(解锁全市场雷达)、Alpha Vantage(美股财报)——稍后在「查看完整设置」里粘贴对应 Key。",
                systemImage: "plus.circle"
            )
            .font(.footnote)
            .foregroundStyle(IOSDesign.muted)

            Toggle(isOn: Binding(
                get: { model.trendSettings.dailyAutoAnalysisEnabled },
                set: {
                    model.trendSettings.dailyAutoAnalysisEnabled = $0
                    model.saveTrendAnalysisSettings()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("顺便开启自动分析")
                        .font(.footnote.weight(.semibold))
                    // W1.7:自动分析开启前再次确认费用。
                    Text("每日 09:00 与 21:00 各运行一次,费用由你的 Key 承担,每次约 ¥0.5–2;随时可关。")
                        .font(.caption2)
                        .foregroundStyle(IOSDesign.muted)
                }
            }

            Label(
                "生成约需 5–15 分钟,期间可正常使用;完成后会出现今日研判摘要。",
                systemImage: "clock"
            )
            .font(.footnote)
            .foregroundStyle(IOSDesign.muted)
        }
    }

    private func iosWizardField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(IOSDesign.muted)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 完整编辑表单(已配置用户)

    private var formBody: some View {
        Form {
            Section {
                Button {
                    wizardStep = .provider
                    isWizardMode = true
                } label: {
                    Label("重新配置(向导)", systemImage: "wand.and.stars")
                }
            } footer: {
                Text("已配置时进入此表单;想分步重来可打开向导。")
            }

            providerSection
            alphaVantageSection
            actionsSection
        }
    }

    private var providerSection: some View {
        Section {
            Picker("快速选择", selection: providerPresetBinding) {
                Text("自定义").tag("")
                ForEach(TrendProviderPreset.allPresets) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }
            if let preset = TrendProviderPreset.matching(model.trendSettings.provider) {
                Link(
                    "获取 \(preset.name) API Key →",
                    destination: URL(string: preset.consoleURL)
                        ?? URL(string: "https://example.com")!
                )
                .font(.footnote)
            }
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
                model.startTrendAnalysisFromUser(withExpectation: .full)
            }
            .disabled(!model.trendSettings.provider.isConfigured)
        } footer: {
            if !model.trendSettings.provider.isConfigured {
                Text("⚠️ 请先填写供应商、接口地址、模型名和 API Key。").foregroundStyle(AppPalette.marketGain)
            }
        }
    }

    // MARK: - Bindings

    /// 预设选中态:按 Base URL 反查;选预设即填入供应商/地址/模型(Key 不动)。
    private var providerPresetBinding: Binding<String> {
        Binding(
            get: {
                TrendProviderPreset.matching(model.trendSettings.provider)?.name ?? ""
            },
            set: { name in
                guard let preset = TrendProviderPreset.allPresets.first(where: { $0.name == name })
                else { return }
                preset.apply(to: &model.trendSettings.provider)
            }
        )
    }

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
