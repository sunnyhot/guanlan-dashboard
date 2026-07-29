import SwiftUI

// MARK: - Trend Analysis Settings

struct TrendSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @State var trendAutoAnalysisTimesDraft = ""

    var body: some View {
        SettingsPanel(
            title: "AI 研判",
            subtitle: "配置模型连接、官方数据、结构化行情补充、联网搜索、每日自动分析与操作建议偏好",
            icon: "sparkles"
        ) {
            configurationContent
        }
        .onAppear {
            if trendAutoAnalysisTimesDraft.isEmpty {
                trendAutoAnalysisTimesDraft = model.trendSettings.dailyAutoAnalysisTimesText
            }
        }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "自动分析")

                SettingsRow(
                    title: "当前状态",
                    value: model.enhancementTrendStatus.valueText,
                    detail: model.enhancementTrendStatus.detailText,
                    icon: "waveform.path.ecg",
                    tint: model.enhancementTrendStatus.severity.settingsTint
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "每日定时分析",
                    detail: "默认 09:30、14:30；打开主界面时会补跑错过的最近一次",
                    icon: "clock.badge.checkmark",
                    tint: model.trendSettings.dailyAutoAnalysisEnabled ? AppPalette.positive : AppPalette.muted,
                    isOn: trendAutoAnalysisBinding
                )

                SettingsDivider()

                VStack(alignment: .leading, spacing: 12) {
                    trendField("每日时间", text: trendAutoAnalysisTimesBinding, placeholder: "09:30, 14:30")
                        .disabled(!model.trendSettings.dailyAutoAnalysisEnabled)
                        .opacity(model.trendSettings.dailyAutoAnalysisEnabled ? 1 : 0.55)

                    SettingsDivider()
                    SettingsGroupHeader(title: "操作建议")

                    tradeSignalPreferenceControls

                    SettingsDivider()
                    SettingsGroupHeader(title: "模型连接")

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

                    SettingsDivider()
                    SettingsGroupHeader(title: "官方数据源")
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

                    SettingsDivider()
                    SettingsGroupHeader(title: "结构化市场数据")
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

                    SettingsDivider()
                    SettingsGroupHeader(title: "联网补充搜索")
                    trendSecureField("Tavily API Key", text: tavilyAPIKeyBinding, placeholder: "tvly-...")
                    Text("在官方源无法覆盖新闻、宏观或政策信息时补充检索。搜索查询只包含通用行业和政策关键词，不发送组合金额或个人信息。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 13)

                SettingsDivider()

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

    private var tradeSignalPreferenceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "bell.badge")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(model.tradeSignalSettings.enabled ? AppPalette.info : AppPalette.muted)
                    .accentIconStyle(
                        tint: model.tradeSignalSettings.enabled ? AppPalette.info : AppPalette.muted,
                        size: 28
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 操作建议")
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(model.tradeSignalSummary.headline)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppPalette.spaceM) {
                    tradeSignalToggles
                }

                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    tradeSignalToggles
                }
            }

            Picker("风险偏好", selection: tradeSignalRiskPreferenceBinding) {
                ForEach(TradeSignalRiskPreference.allCases) { preference in
                    Text(preference.displayText).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Picker("观察周期", selection: tradeSignalHorizonPreferenceBinding) {
                ForEach(TradeSignalHorizonPreference.allCases) { horizon in
                    Text(horizon.displayText).tag(horizon)
                }
            }
            .pickerStyle(.segmented)

            trendLabeledControl("最低置信度") {
                HStack(spacing: AppPalette.spaceS) {
                    Slider(value: tradeSignalMinimumConfidenceBinding, in: 0...100, step: 5)
                    Text("\(model.tradeSignalSettings.minimumConfidence)")
                        .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.info)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            tradeSignalAssetPreferenceList
        }
        .padding(.vertical, 8)
    }

    private var tradeSignalToggles: some View {
        Group {
            Toggle("启用观察", isOn: tradeSignalEnabledBinding)
                .toggleStyle(.switch)
            Toggle("本地通知", isOn: tradeSignalLocalNotificationsBinding)
                .toggleStyle(.switch)
            Toggle("关注买入", isOn: tradeSignalAllowBuyBinding)
                .toggleStyle(.switch)
            Toggle("关注卖出", isOn: tradeSignalAllowSellBinding)
                .toggleStyle(.switch)
            Toggle("沿用上次分析", isOn: tradeSignalUseStaleAnalysisBinding)
                .toggleStyle(.switch)
        }
        .font(AppPalette.appFont(.subheadline, weight: .medium))
    }

    private var tradeSignalAssetPreferenceList: some View {
        trendLabeledControl("单标的偏好") {
            if model.personalAssetRows.isEmpty {
                Text("暂无持仓标的可单独设置")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(model.personalAssetRows.prefix(8), id: \.key) { row in
                        tradeSignalAssetPreferenceRow(row)
                    }
                }
            }
        }
    }

    private func tradeSignalAssetPreferenceRow(_ row: PersonalAssetAggregateRow) -> some View {
        HStack(alignment: .center, spacing: AppPalette.spaceS) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fundName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(row.fundName)
                Text(row.fundCode ?? row.key)
                    .font(AppPalette.appFont(.footnote, weight: .medium, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: AppPalette.spaceS)

            Picker("\(row.fundName)观察模式", selection: tradeSignalAssetModeBinding(for: row)) {
                ForEach(TradeSignalAssetPreferenceMode.allCases) { mode in
                    Text(mode.displayText).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 128)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
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

    private var tradeSignalEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.tradeSignalSettings.enabled },
            set: { isEnabled in updateTradeSignalSettings { $0.enabled = isEnabled } }
        )
    }

    private var tradeSignalLocalNotificationsBinding: Binding<Bool> {
        Binding(
            get: { model.tradeSignalSettings.localNotificationsEnabled },
            set: { isEnabled in updateTradeSignalSettings { $0.localNotificationsEnabled = isEnabled } }
        )
    }

    private var tradeSignalAllowBuyBinding: Binding<Bool> {
        Binding(
            get: { model.tradeSignalSettings.allowBuySignals },
            set: { isEnabled in updateTradeSignalSettings { $0.allowBuySignals = isEnabled } }
        )
    }

    private var tradeSignalAllowSellBinding: Binding<Bool> {
        Binding(
            get: { model.tradeSignalSettings.allowSellSignals },
            set: { isEnabled in updateTradeSignalSettings { $0.allowSellSignals = isEnabled } }
        )
    }

    private var tradeSignalUseStaleAnalysisBinding: Binding<Bool> {
        Binding(
            get: { model.tradeSignalSettings.useStaleAnalysis },
            set: { isEnabled in updateTradeSignalSettings { $0.useStaleAnalysis = isEnabled } }
        )
    }

    private var tradeSignalRiskPreferenceBinding: Binding<TradeSignalRiskPreference> {
        Binding(
            get: { model.tradeSignalSettings.riskPreference },
            set: { preference in updateTradeSignalSettings { $0.riskPreference = preference } }
        )
    }

    private var tradeSignalHorizonPreferenceBinding: Binding<TradeSignalHorizonPreference> {
        Binding(
            get: { model.tradeSignalSettings.primaryHorizon },
            set: { horizon in updateTradeSignalSettings { $0.primaryHorizon = horizon } }
        )
    }

    private var tradeSignalMinimumConfidenceBinding: Binding<Double> {
        Binding(
            get: { Double(model.tradeSignalSettings.minimumConfidence) },
            set: { value in updateTradeSignalSettings { $0.minimumConfidence = Int(value.rounded()) } }
        )
    }

    private func tradeSignalAssetModeBinding(for row: PersonalAssetAggregateRow) -> Binding<TradeSignalAssetPreferenceMode> {
        Binding(
            get: {
                model.tradeSignalSettings.assetPreferences.first { $0.assetKey == row.key }?.mode ?? .followGlobal
            },
            set: { mode in
                updateTradeSignalSettings { settings in
                    updateTradeSignalAssetMode(mode, assetKey: row.key, settings: &settings)
                }
            }
        )
    }

    private func saveTrendSettingsFromDraft() {
        model.trendSettings.updateDailyAutoAnalysisTimes(from: trendAutoAnalysisTimesDraft)
        trendAutoAnalysisTimesDraft = model.trendSettings.dailyAutoAnalysisTimesText
        model.saveTrendAnalysisSettings()
        model.saveTradeSignalSettings()
    }

    private func updateTradeSignalSettings(_ update: (inout TradeSignalSettings) -> Void) {
        var settings = model.tradeSignalSettings
        update(&settings)
        model.tradeSignalSettings = settings
        model.saveTradeSignalSettings()
    }

    private func updateTradeSignalAssetMode(
        _ mode: TradeSignalAssetPreferenceMode,
        assetKey: String,
        settings: inout TradeSignalSettings
    ) {
        if let index = settings.assetPreferences.firstIndex(where: { $0.assetKey == assetKey }) {
            if mode == .followGlobal {
                settings.assetPreferences.remove(at: index)
            } else {
                settings.assetPreferences[index].mode = mode
            }
        } else if mode != .followGlobal {
            settings.assetPreferences.append(TradeSignalAssetPreference(assetKey: assetKey, mode: mode))
        }

        settings.assetPreferences.sort {
            $0.assetKey.localizedStandardCompare($1.assetKey) == .orderedAscending
        }
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

extension EnhancementPresentationSeverity {
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
        case .neutral:
            return AppPalette.muted
        }
    }
}
