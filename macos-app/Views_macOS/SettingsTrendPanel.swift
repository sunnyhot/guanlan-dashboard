import SwiftUI

// MARK: - Trend Analysis Settings

struct TrendSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @State var trendAutoAnalysisTimesDraft = ""

    var body: some View {
        SettingsPanel(
            title: "AI 研判",
            subtitle: "配置模型连接、官方数据、结构化行情补充、联网搜索与每日自动分析",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceXL) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                        VStack(spacing: AppPalette.spaceXL) {
                            trendAutoAnalysisCard
                            trendOfficialSourcesCard
                            trendAlphaVantageCard
                            trendWebSearchCard
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)

                        VStack(spacing: AppPalette.spaceXL) {
                            trendModelConnectionCard
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)
                    }

                    VStack(spacing: AppPalette.spaceXL) {
                        trendAutoAnalysisCard
                        trendModelConnectionCard
                        trendOfficialSourcesCard
                        trendAlphaVantageCard
                        trendWebSearchCard
                    }
                }

                trendActionsRow
            }
        }
        .onAppear {
            if trendAutoAnalysisTimesDraft.isEmpty {
                trendAutoAnalysisTimesDraft = model.trendSettings.dailyAutoAnalysisTimesText
            }
        }
    }

    // MARK: - Cards

    private var trendAutoAnalysisCard: some View {
        SettingsCardGroup(
            title: "自动分析",
            subtitle: "每日定时生成，错过会补跑最近一次",
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
                    title: "每日定时分析",
                    detail: "默认 09:30、14:30；打开主界面时会补跑错过的最近一次",
                    icon: "clock.badge.checkmark",
                    tint: model.trendSettings.dailyAutoAnalysisEnabled ? AppPalette.positive : AppPalette.muted,
                    isOn: trendAutoAnalysisBinding
                )

                SettingsDivider(isInset: true)

                trendField("每日时间", text: trendAutoAnalysisTimesBinding, placeholder: "09:30, 14:30")
                    .disabled(!model.trendSettings.dailyAutoAnalysisEnabled)
                    .opacity(model.trendSettings.dailyAutoAnalysisEnabled ? 1 : 0.55)
                    .padding(.vertical, 12)
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
                trendField("服务超时秒数", text: trendProviderTimeoutBinding, placeholder: "300")
                Text("趋势 Agent 单轮生成最多 180 秒（流式输出也受此硬上限约束），超时会收敛任务并自动重试一次；整次运行使用扩展研究预算。此处可设置更短的服务超时。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
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
                    text: model.lastTrendError,
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

    private var trendAutoAnalysisTimesBinding: Binding<String> {
        Binding(
            get: {
                trendAutoAnalysisTimesDraft.isEmpty
                    ? model.trendSettings.dailyAutoAnalysisTimesText
                    : trendAutoAnalysisTimesDraft
            },
            set: { trendAutoAnalysisTimesDraft = $0 }
        )
    }

    private func saveTrendSettingsFromDraft() {
        model.trendSettings.updateDailyAutoAnalysisTimes(from: trendAutoAnalysisTimesDraft)
        trendAutoAnalysisTimesDraft = model.trendSettings.dailyAutoAnalysisTimesText
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
