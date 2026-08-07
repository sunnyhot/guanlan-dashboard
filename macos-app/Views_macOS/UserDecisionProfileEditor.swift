import SwiftUI

// macOS 端:用户决策画像编辑(Slice 5)。
//
// 这是用户唯一能开启强行动(adjustReview/exitReview)的入口:
// 复核方案规定未自定义 Profile 禁止强行动(见 UserDecisionProfile.allowsStrongAction)。
// 嵌入 EnhancementTodayPanel 的投资智能板块,或设置面板。
// 由 InvestmentIntelligence.enabled gate。

struct UserDecisionProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var horizon: InvestmentHorizon
    @State private var risk: RiskTolerance
    @State private var concentrationLimit: Double
    @State private var overlapLimit: Double
    @State private var allowsRebalancing: Bool
    @State private var hasCustomLimits: Bool

    init() {
        // SwiftUI 的 State 先用领域默认值初始化，onAppear 再从 EnvironmentObject 同步。
        // 这里不能临时创建 AppModel，否则会启动一套无关的全局状态容器。
        horizon = .longTerm
        risk = .conservative
        concentrationLimit = RiskTolerance.conservative.defaultConcentrationLimit
        overlapLimit = RiskTolerance.conservative.defaultOverlapLimit
        allowsRebalancing = false
        hasCustomLimits = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            VStack(alignment: .leading, spacing: 4) {
                Text("投资偏好")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("这些边界决定系统何时只观察，何时提示你复核调整。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            }

            HStack(alignment: .top, spacing: AppPalette.spaceL) {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    Text("投资期限")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    Picker("投资期限", selection: $horizon) {
                        ForEach(InvestmentHorizon.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    Text("风险偏好")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    Picker("风险偏好", selection: $risk) {
                        ForEach(RiskTolerance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Toggle("自定义集中度上限", isOn: $hasCustomLimits)
                    .font(AppPalette.appFont(.body, weight: .medium))
                if hasCustomLimits {
                    HStack {
                        Text("单标的上限")
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.muted)
                        Slider(value: $concentrationLimit, in: 10...80, step: 5)
                        Text("\(Int(concentrationLimit))%")
                            .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                            .frame(width: 40, alignment: .trailing)
                    }
                    HStack {
                        Text("重叠上限")
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.muted)
                        Slider(value: $overlapLimit, in: 5...50, step: 5)
                        Text("\(Int(overlapLimit))%")
                            .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Toggle(isOn: $allowsRebalancing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("允许主动再平衡建议")
                        .font(AppPalette.appFont(.body, weight: .medium))
                    Text("开启后，标的显著超限时系统可以提示“复核调整”；关闭时只会建议观察。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            HStack {
                Text(allowsRebalancing ? "已允许强行动复核" : "强行动建议已关闭")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                Spacer()
                Button("保存偏好") { saveProfile() }
                    .buttonStyle(.appPrimary)
            }
        }
        .onAppear { syncFromModel() }
    }

    // MARK: - 操作

    private func syncFromModel() {
        let p = model.userDecisionProfile
        horizon = p.investmentHorizon
        risk = p.riskTolerance
        concentrationLimit = p.effectiveConcentrationLimit
        overlapLimit = p.effectiveOverlapLimit
        allowsRebalancing = p.allowsActiveRebalancing
        hasCustomLimits = p.concentrationLimit != nil
    }

    private func saveProfile() {
        let profile = UserDecisionProfile(
            investmentHorizon: horizon,
            riskTolerance: risk,
            concentrationLimit: hasCustomLimits ? concentrationLimit : nil,
            overlapLimit: hasCustomLimits ? overlapLimit : nil,
            allowsActiveRebalancing: allowsRebalancing,
            isCustomized: true,
            customizedAt: AppModel.timestampString()
        )
        model.updateUserDecisionProfile(profile)
    }
}
