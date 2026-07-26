import SwiftUI

// MARK: - Trend Analysis Settings

struct TrendSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @State var trendAutoAnalysisTimesDraft = ""

    var body: some View {
        SettingsPanel(
            title: "AI 研判",
            subtitle: "配置模型连接、Tavily 联网搜索、每日自动分析与操作建议偏好",
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
                    Text("趋势 Agent 单轮生成最多 90 秒（流式输出也受此硬上限约束），超时会收敛任务并自动重试一次；整次运行最多 300 秒。此处可设置更短的服务超时。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsDivider()
                    SettingsGroupHeader(title: "联网搜索")
                    trendSecureField("Tavily API Key", text: tavilyAPIKeyBinding, placeholder: "tvly-...")
                    Text("用于搜索最新行业、宏观和政策信息。搜索查询只包含通用行业和政策关键词，不发送组合金额或个人信息。")
                        .font(.system(size: 11))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.tradeSignalSettings.enabled ? AppPalette.info : AppPalette.muted)
                    .accentIconStyle(
                        tint: model.tradeSignalSettings.enabled ? AppPalette.info : AppPalette.muted,
                        size: 28
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 操作建议")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(model.tradeSignalSummary.headline)
                        .font(.system(size: 10))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
        .font(.system(size: 11, weight: .medium))
    }

    private var tradeSignalAssetPreferenceList: some View {
        trendLabeledControl("单标的偏好") {
            if model.personalAssetRows.isEmpty {
                Text("暂无持仓标的可单独设置")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(row.fundName)
                Text(row.fundCode ?? row.key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
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
                .font(.system(size: 12))
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
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(trendControlBackground, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(trendInputBorder)
        }
    }

    private func trendLabeledControl<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
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
