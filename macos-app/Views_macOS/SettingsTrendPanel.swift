import SwiftUI

// MARK: - Trend Analysis Settings

struct TrendSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    /// W1.5:预设应用反馈 Toast;W1.4:剪贴板预填也复用这条 Toast。
    @State private var presetFeedbackText = ""
    @State private var didAttemptClipboardPrefill = false
    /// W1.1:配置向导入口(未配置 → 引导;已配置 → 重新配置)。
    @State private var isShowingWizard = false

    var body: some View {
        SettingsPanel(
            title: "AI 研判",
            subtitle: "配置模型连接、数据来源、共享缓存与分模块自动分析",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceXL) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                        VStack(spacing: AppPalette.spaceXL) {
                            trendAutoAnalysisCard
                            trendNotificationsCard
                            advancedSourcesGroup
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)

                        VStack(spacing: AppPalette.spaceXL) {
                            trendModelConnectionCard
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)
                    }

                    VStack(spacing: AppPalette.spaceXL) {
                        trendAutoAnalysisCard
                        trendNotificationsCard
                        trendModelConnectionCard
                        advancedSourcesGroup
                    }
                }

                trendActionsRow
            }
        }
    }

    // MARK: - Cards

    /// 可选数据源默认收起:普通用户只需模型连接;不配 Tavily 则全市场雷达
    /// 不可用(该说明保留在 Tavily 卡内,展开可见)。
    private var advancedSourcesGroup: some View {
        DisclosureGroup("高级数据源(可选):SEC / Alpha Vantage / Tavily") {
            VStack(spacing: AppPalette.spaceXL) {
                trendOfficialSourcesCard
                trendAlphaVantageCard
                trendWebSearchCard
            }
            .padding(.top, AppPalette.spaceS)
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .font(AppPalette.appFont(.footnote, weight: .medium))
        .foregroundStyle(AppPalette.muted)
    }

    private var trendAutoAnalysisCard: some View {
        SettingsCardGroup(
            title: "自动分析",
            subtitle: "按产品模块错峰生成，盘中周期保持不变",
            icon: "clock.badge.checkmark",
            tint: model.trendSettings.dailyAutoAnalysisEnabled ? AppPalette.positive : AppPalette.muted
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "当前状态",
                    value: model.enhancementTrendStatus.valueText,
                    detail: model.enhancementTrendStatus.detailText,
                    icon: "waveform.path.ecg",
                    tint: model.enhancementTrendStatus.severity.settingsTint
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "分模块自动分析",
                    detail: "市场、收盘与长期研判使用独立任务；同一时间只运行一个 AI 任务",
                    icon: "clock.badge.checkmark",
                    tint: model.trendSettings.dailyAutoAnalysisEnabled ? AppPalette.positive : AppPalette.muted,
                    isOn: trendAutoAnalysisBinding
                )

                SettingsDivider(isInset: true)

                SettingsRow(
                    title: "盘中实时指引",
                    value: "按现有交易时段",
                    detail: model.nextHourGuidanceScheduleText,
                    icon: "clock.arrow.circlepath",
                    tint: AppPalette.info
                )

                SettingsDivider(isInset: true)

                SettingsRow(
                    title: "全市场机会雷达",
                    value: "每日 09:00",
                    detail: "只更新大类资产、宽基与行业机会，不读取个人持仓",
                    icon: "scope",
                    tint: AppPalette.brand
                )

                SettingsDivider(isInset: true)

                SettingsRow(
                    title: "今日收盘复盘",
                    value: "每日 21:00",
                    detail: "只更新组合当日涨跌归因与次日观察",
                    icon: "sunset.fill",
                    tint: AppPalette.warning
                )

                SettingsDivider(isInset: true)

                SettingsRow(
                    title: "组合长期研判",
                    value: "每周日 20:00",
                    detail: "更新组合周期、持仓趋势与行动候选；错过后在下一个 20:00 窗口补跑",
                    icon: "calendar.badge.clock",
                    tint: AppPalette.positive
                )

                SettingsDivider(isInset: true)

                SettingsRow(
                    title: "共享数据缓存",
                    value: "自动复用",
                    detail: "基金披露 24 小时；Tavily 搜索 6 小时；SEC 与结构化行情按来源时效缓存",
                    icon: "externaldrive.badge.checkmark",
                    tint: AppPalette.muted
                )

                SettingsDivider(isInset: true)

                SettingsControlRow(
                    title: "完整诊断日志",
                    detail: "每次 AI 任务独立保存请求、响应、工具结果、校验和最终状态；保留最近 20 份且总量不超过 200 MB",
                    icon: "doc.text.magnifyingglass",
                    tint: AppPalette.info
                ) {
                    Button(
                        "打开日志目录",
                        systemImage: "folder",
                        action: model.openAIAnalysisDiagnosticLogsDirectory
                    )
                    .buttonStyle(.appSecondary)
                    .disabled(model.aiAnalysisDiagnosticLogsDirectoryURL == nil)
                }
            }
        }
    }

    private var trendModelConnectionCard: some View {
        SettingsCardGroup(
            title: "模型连接",
            subtitle: "供应商、密钥与服务超时",
            icon: "cpu",
            tint: AppPalette.brand
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // W1.1:向导入口——未配置时引导,已配置时提供「重新配置」。
                HStack(spacing: AppPalette.spaceS) {
                    if model.trendSettings.provider.isConfigured {
                        Button {
                            isShowingWizard = true
                        } label: {
                            Label("重新配置(向导)", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    } else {
                        Button {
                            isShowingWizard = true
                        } label: {
                            Label("打开配置向导,一步步完成", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.appPrimary)
                        .tint(AppPalette.brand)
                    }
                    Spacer(minLength: 0)
                }

                // 隐私说明按当前模式如实描述:脱敏不发送金额,完整明细包含金额。
                Text(
                    model.trendPrivacyMode == .sanitized
                        ? "隐私说明:研判会把持仓结构(基金、占比、涨跌、计划状态)发送给你配置的模型服务商;当前「脱敏摘要」模式不发送任何金额。"
                        : "隐私说明:当前「完整明细」模式会把持仓结构与金额一起发送给你配置的模型服务商。"
                )
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("供应商预设")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    HStack(spacing: 8) {
                        ForEach(TrendProviderPreset.allPresets) { preset in
                            providerPresetChip(preset)
                        }
                        Spacer(minLength: 0)
                    }
                    if let preset = TrendProviderPreset.matching(model.trendSettings.provider) {
                        Button {
                            if let url = URL(string: preset.consoleURL) {
                                openURL(url)
                            }
                        } label: {
                            Label("获取 \(preset.name) API Key", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    }
                }

                if !presetFeedbackText.isEmpty {
                    presetFeedbackToast
                }

                Picker("隐私模式", selection: trendPrivacyModeBinding) {
                    ForEach(TrendPrivacyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                trendField("供应商", text: trendProviderNameBinding, placeholder: "智谱 / OpenAI / 其他")
                trendField("Base URL", text: trendProviderBaseURLBinding, placeholder: "https://open.bigmodel.cn/api/coding/paas/v4")
                trendField("模型", text: trendProviderModelBinding, placeholder: "glm-5.2")
                trendSecureField("API Key", text: trendProviderAPIKeyBinding, placeholder: "sk-...")

                DisclosureGroup("高级:服务超时") {
                    VStack(alignment: .leading, spacing: 8) {
                        trendField("服务超时秒数", text: trendProviderTimeoutBinding, placeholder: "300")
                        Text("趋势 Agent 单轮生成最多 180 秒（流式输出也受此硬上限约束），超时会收敛任务并自动重试一次；整次运行使用扩展研究预算。此处可设置更短的服务超时。")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
                .disclosureGroupStyle(FullRowDisclosureGroupStyle())
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            }
            .padding(.vertical, 12)
        }
        .onAppear {
            attemptClipboardPrefill()
        }
        .sheet(isPresented: $isShowingWizard) {
            TrendSetupWizardSheet()
                .environmentObject(model)
        }
    }

    /// W1.5/W1.4 共用的预设与预填反馈;6 秒后自动消失。
    private var presetFeedbackToast: some View {
        ToastBar(
            text: presetFeedbackText,
            tint: AppPalette.positive,
            onDismiss: { presetFeedbackText = "" }
        )
        .task(id: presetFeedbackText) {
            let captured = presetFeedbackText
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if presetFeedbackText == captured {
                presetFeedbackText = ""
            }
        }
    }

    /// W1.4:打开面板时识别剪贴板中的 API Key,空字段自动预填并说明来源;
    /// 已填过 Key 不覆盖,不符合已知 Key 形状不动作。
    private func attemptClipboardPrefill() {
        guard !didAttemptClipboardPrefill else { return }
        didAttemptClipboardPrefill = true
        guard let text = PasteboardHelper.readPlainText(),
              let match = TrendAPIKeyPasteHeuristics.classify(text) else { return }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match {
        case .providerKey(let suggestedPresetName):
            guard model.trendSettings.provider.apiKey.isEmpty else { return }
            var appliedPresetName: String?
            if let suggestedPresetName,
               let preset = TrendProviderPreset.allPresets.first(where: { $0.name == suggestedPresetName }),
               TrendProviderPreset.matching(model.trendSettings.provider) == nil {
                preset.apply(to: &model.trendSettings.provider)
                appliedPresetName = preset.name
            }
            model.trendSettings.provider.apiKey = key
            saveTrendSettingsFromDraft()
            if let appliedPresetName {
                presetFeedbackText = "检测到剪贴板中的 \(appliedPresetName) Key,已填好地址、模型与 Key,可点「检测模型」验证。"
            } else {
                presetFeedbackText = "检测到剪贴板中的模型 Key,已填入;请确认供应商与地址匹配后再检测。"
            }
        case .tavilyKey:
            guard model.trendSettings.webSearch.apiKey.isEmpty else { return }
            model.trendSettings.webSearch.apiKey = key
            saveTrendSettingsFromDraft()
            presetFeedbackText = "检测到剪贴板中的 Tavily Key,已填入联网搜索。"
        }
    }

    /// W3.1:研判通知偏好——默认只开「收盘复盘完成 + 自动失败」最小集。
    private var trendNotificationsCard: some View {
        SettingsCardGroup(
            title: "研判通知",
            subtitle: "生成完成与失败时的系统通知,点击直达对应区段",
            icon: "bell.badge",
            tint: AppPalette.info
        ) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "收盘复盘完成",
                    detail: "每日 21:00 复盘生成后通知(默认开)",
                    icon: "sunset.fill",
                    tint: AppPalette.warning,
                    isOn: notificationBinding(\.closeReviewSuccessEnabled)
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "自动运行失败",
                    detail: "自动研判失败时提醒手动补做(默认开)",
                    icon: "exclamationmark.triangle",
                    tint: AppPalette.danger,
                    isOn: notificationBinding(\.autoFailureEnabled)
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "市场雷达完成",
                    detail: "每日 09:00 全市场机会更新后通知(默认关)",
                    icon: "scope",
                    tint: AppPalette.brand,
                    isOn: notificationBinding(\.marketRadarSuccessEnabled)
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "长期研判完成",
                    detail: "每周日 20:00 组合研判更新后通知(默认关)",
                    icon: "briefcase.fill",
                    tint: AppPalette.positive,
                    isOn: notificationBinding(\.longTermSuccessEnabled)
                )

                SettingsDivider(isInset: true)

                SettingsToggleRow(
                    title: "首份研判送达",
                    detail: "手动生成第一份研判完成时通知(默认关)",
                    icon: "sparkles",
                    tint: AppPalette.info,
                    isOn: notificationBinding(\.firstReportEnabled)
                )
            }
        }
    }

    private func notificationBinding(
        _ keyPath: WritableKeyPath<TrendNotificationPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.trendSettings.notifications[keyPath: keyPath] },
            set: {
                model.trendSettings.notifications[keyPath: keyPath] = $0
                saveTrendSettingsFromDraft()
            }
        )
    }

    private func providerPresetChip(_ preset: TrendProviderPreset) -> some View {
        let isSelected = TrendProviderPreset.matching(model.trendSettings.provider)?.id == preset.id
        return Button {
            applyProviderPreset(preset)
        } label: {
            Text(preset.name)
                .font(AppPalette.appFont(.footnote, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppPalette.brand : AppPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    isSelected ? AppPalette.brand.opacity(0.10) : AppPalette.cardStrong,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        isSelected ? AppPalette.brand.opacity(0.35) : AppPalette.hairline.opacity(0.32),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help("填入 \(preset.name) 的接口地址与默认模型")
    }

    /// 应用预设并立即保存;只预填供应商/地址/模型,Key 与超时不动。
    /// W1.5:应用后用 Toast 说明「下一步只剩贴 Key」,替代静默填表。
    private func applyProviderPreset(_ preset: TrendProviderPreset) {
        preset.apply(to: &model.trendSettings.provider)
        saveTrendSettingsFromDraft()
        presetFeedbackText = "已填好\(preset.name)地址与模型,只需贴 Key"
    }

    private var trendOfficialSourcesCard: some View {
        SettingsCardGroup(
            title: "官方数据源",
            subtitle: "SEC 官方披露",
            icon: "doc.text.magnifyingglass",
            tint: AppPalette.info
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用 SEC 官方披露", isOn: officialSourcesEnabledBinding)
                    .toggleStyle(.switch)
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                trendField(
                    "SEC 联系邮箱",
                    text: secContactEmailBinding,
                    placeholder: "name@example.com"
                )
                .disabled(!model.trendSettings.officialSources.enabled)
                .opacity(model.trendSettings.officialSources.enabled ? 1 : 0.55)
                Text("SEC 接口免费且不需要 API Key。邮箱只用于按 SEC 要求组成请求 User-Agent，不会发送持仓和个人资产；有美股或基金底层美股时，Agent 会先查 SEC 披露。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    private var trendAlphaVantageCard: some View {
        SettingsCardGroup(
            title: "结构化市场数据",
            subtitle: "Alpha Vantage 行情补充",
            icon: "chart.bar.xaxis",
            tint: AppPalette.info
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用 Alpha Vantage", isOn: alphaVantageEnabledBinding)
                    .toggleStyle(.switch)
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                trendSecureField(
                    "Alpha Vantage API Key",
                    text: alphaVantageAPIKeyBinding,
                    placeholder: "个人 API Key"
                )
                .disabled(!model.trendSettings.alphaVantage.enabled)
                .opacity(model.trendSettings.alphaVantage.enabled ? 1 : 0.55)
                trendField(
                    "每日联网额度",
                    text: alphaVantageDailyLimitBinding,
                    placeholder: "25"
                )
                .disabled(!model.trendSettings.alphaVantage.enabled)
                .opacity(model.trendSettings.alphaVantage.enabled ? 1 : 0.55)
                Text("用于 ETF 持仓、财报日历和日线统计；属于第三方供应商数据，优先级低于 SEC/交易所等官方源。默认按免费额度 25 次/日限制，缓存命中不计数；API Key 由每位用户自行配置，不会随 App 分发。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    private var trendWebSearchCard: some View {
        SettingsCardGroup(
            title: "联网补充搜索",
            subtitle: "Tavily 新闻与政策检索",
            icon: "magnifyingglass.circle",
            tint: AppPalette.info
        ) {
            VStack(alignment: .leading, spacing: 12) {
                trendSecureField("Tavily API Key", text: tavilyAPIKeyBinding, placeholder: "tvly-...")
                Text("在官方源无法覆盖新闻、宏观或政策信息时补充检索。搜索查询只包含通用行业和政策关键词，不发送组合金额或个人信息。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    private var trendActionsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsActionRow {
                Button {
                    saveTrendSettingsFromDraft()
                } label: {
                    Label("保存配置", systemImage: "checkmark.circle")
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)

                Button {
                    Task { await model.checkTrendAIConnection() }
                } label: {
                    Label(
                        model.trendConnectionState == .checking ? "检测中" : "检测模型",
                        systemImage: model.trendConnectionState == .checking ? "hourglass" : "antenna.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(.appSecondary)
                .disabled(!model.trendSettings.provider.isConfigured || model.trendConnectionState == .checking)
            }

            if !model.lastTrendConnectionMessage.isEmpty {
                ToastBar(
                    text: model.lastTrendConnectionMessage,
                    tint: trendConnectionTint,
                    onDismiss: { model.lastTrendConnectionMessage = "" }
                )
                    .padding(.top, 12)
            }

            if !model.lastTrendError.isEmpty && model.lastTrendError != model.lastTrendConnectionMessage {
                ToastBar(
                    text: TrendErrorTriage.explain(model.lastTrendError).reasonText,
                    tint: AppPalette.warning,
                    onDismiss: { model.lastTrendError = "" }
                )
                    .padding(.top, 12)
            }
        }
    }

    private func trendField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        trendLabeledControl(label) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.body))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(trendControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(trendInputBorder)
        }
    }

    private func trendSecureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        trendLabeledControl(label) {
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.body))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(trendControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(trendInputBorder)
        }
    }

    private func trendLabeledControl<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendInputBorder: some View {
        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
            .stroke(AppPalette.hairline.opacity(0.32), lineWidth: 1)
    }

    private var trendProviderNameBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.provider.providerName },
            set: { model.trendSettings.provider.providerName = $0 }
        )
    }

    private var trendProviderBaseURLBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.provider.baseURL },
            set: { model.trendSettings.provider.baseURL = $0 }
        )
    }

    private var trendProviderModelBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.provider.model },
            set: { model.trendSettings.provider.model = $0 }
        )
    }

    private var trendProviderAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.provider.apiKey },
            set: { model.trendSettings.provider.apiKey = $0 }
        )
    }

    private var trendProviderTimeoutBinding: Binding<String> {
        Binding(
            get: {
                String(Int(model.trendSettings.provider.timeoutSeconds.rounded()))
            },
            set: { rawValue in
                if let timeout = Double(rawValue), timeout > 0 {
                    model.trendSettings.provider.timeoutSeconds = timeout
                }
            }
        )
    }

    private var tavilyAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.webSearch.apiKey },
            set: { model.trendSettings.webSearch.apiKey = $0 }
        )
    }

    private var officialSourcesEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.trendSettings.officialSources.enabled },
            set: { model.trendSettings.officialSources.enabled = $0 }
        )
    }

    private var alphaVantageEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.trendSettings.alphaVantage.enabled },
            set: { model.trendSettings.alphaVantage.enabled = $0 }
        )
    }

    private var alphaVantageAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.alphaVantage.apiKey },
            set: { model.trendSettings.alphaVantage.apiKey = $0 }
        )
    }

    private var alphaVantageDailyLimitBinding: Binding<String> {
        Binding(
            get: {
                String(model.trendSettings.alphaVantage.normalizedDailyRequestLimit)
            },
            set: { rawValue in
                if let limit = Int(rawValue), limit > 0 {
                    model.trendSettings.alphaVantage.dailyRequestLimit = min(
                        10_000,
                        limit
                    )
                }
            }
        )
    }

    private var secContactEmailBinding: Binding<String> {
        Binding(
            get: { model.trendSettings.officialSources.secContactEmail },
            set: { model.trendSettings.officialSources.secContactEmail = $0 }
        )
    }

    private var trendPrivacyModeBinding: Binding<TrendPrivacyMode> {
        Binding(
            get: { model.trendPrivacyMode },
            set: { mode in
                model.trendPrivacyMode = mode
                model.trendSettings.defaultPrivacyMode = mode
            }
        )
    }

    private var trendAutoAnalysisBinding: Binding<Bool> {
        Binding(
            get: { model.trendSettings.dailyAutoAnalysisEnabled },
            set: { isEnabled in
                model.trendSettings.dailyAutoAnalysisEnabled = isEnabled
                saveTrendSettingsFromDraft()
            }
        )
    }

    private func saveTrendSettingsFromDraft() {
        model.saveTrendAnalysisSettings()
    }

    private var trendConnectionTint: Color {
        switch model.trendConnectionState {
        case .idle:
            return AppPalette.muted
        case .checking:
            return AppPalette.info
        case .succeeded:
            return AppPalette.positive
        case .failed:
            return AppPalette.warning
        }
    }

    private var trendControlBackground: Color {
        AppPalette.cardStrong.opacity(AppPalette.bgDefault)
    }
}

extension TrendDashboardTone {
    var settingsTint: Color {
        switch self {
        case .brand:
            return AppPalette.brand
        case .info:
            return AppPalette.info
        case .positive:
            return AppPalette.positive
        case .warning:
            return AppPalette.warning
        case .danger:
            return AppPalette.danger
        case .muted:
            return AppPalette.muted
        }
    }
}
