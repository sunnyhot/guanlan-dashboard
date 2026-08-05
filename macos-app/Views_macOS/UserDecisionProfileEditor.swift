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
        let p = AppModel().userDecisionProfile  // 占位,实际用 onAppear 从 model 读
        horizon = p.investmentHorizon
        risk = p.riskTolerance
        concentrationLimit = p.effectiveConcentrationLimit
        overlapLimit = p.effectiveOverlapLimit
        allowsRebalancing = p.allowsActiveRebalancing
        hasCustomLimits = p.concentrationLimit != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            // 标题
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundColor(AppPalette.brand)
                Text("投资偏好设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppPalette.ink)
            }

            // 投资期限
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("投资期限")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppPalette.muted)
                Picker("投资期限", selection: $horizon) {
                    ForEach(InvestmentHorizon.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            // 风险偏好
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("风险偏好")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppPalette.muted)
                Picker("风险偏好", selection: $risk) {
                    ForEach(RiskTolerance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            // 自定义集中度上限
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Toggle("自定义集中度上限", isOn: $hasCustomLimits)
                    .font(.system(size: 12))
                if hasCustomLimits {
                    HStack {
                        Text("单标的上限")
                            .font(.system(size: 12))
                            .foregroundColor(AppPalette.muted)
                        Slider(value: $concentrationLimit, in: 10...80, step: 5)
                        Text("\(Int(concentrationLimit))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppPalette.ink)
                            .frame(width: 40, alignment: .trailing)
                    }
                    HStack {
                        Text("重叠上限")
                            .font(.system(size: 12))
                            .foregroundColor(AppPalette.muted)
                        Slider(value: $overlapLimit, in: 5...50, step: 5)
                        Text("\(Int(overlapLimit))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppPalette.ink)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            // 允许主动再平衡(开启后系统才能给出 adjustReview 建议)
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Toggle(isOn: $allowsRebalancing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许主动再平衡建议")
                            .font(.system(size: 12, weight: .medium))
                        Text("开启后,当标的超限时系统才会给出调整复核建议(adjustReview);关闭时只观察不行动。")
                            .font(.system(size: 11))
                            .foregroundColor(AppPalette.muted)
                    }
                }
            }

            // 保存按钮
            HStack {
                Spacer()
                Button("保存") { saveProfile() }
                    .buttonStyle(.appPrimary)
                    .controlSize(.regular)
            }
        }
        .padding(AppPalette.spaceM)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
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
