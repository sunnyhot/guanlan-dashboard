import SwiftUI

/// macOS 端:用户决策画像编辑(P3 #4,补齐 iOS 独有缺口)。
/// 字段与 `IOSUserDecisionProfileEditor` 完全对齐:投资期限、风险偏好、
/// 可选单标的/重叠度上限、是否允许主动再平衡建议。偏好约束全部 AI 研判
/// 的建议口径,主力端此前没有任何编辑入口。
struct UserDecisionProfilePanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var horizon: InvestmentHorizon = .longTerm
    @State private var risk: RiskTolerance = .conservative
    @State private var concentrationLimit: Double = 30
    @State private var overlapLimit: Double = 15
    @State private var allowsRebalancing: Bool = false
    @State private var hasCustomLimits: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack(spacing: AppPalette.spaceS) {
                Label("决策偏好", systemImage: "person.crop.circle.badge.questionmark")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                    .buttonStyle(.appSecondary)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("关闭决策偏好")
            }

            Text("偏好会约束 AI 研判给出的建议口径(期限、风险、集中度上限);不设置时使用默认值,关闭本窗口不会丢失已保存的偏好。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("投资期限")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Picker("投资期限", selection: $horizon) {
                    ForEach(InvestmentHorizon.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("风险偏好")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Picker("风险偏好", selection: $risk) {
                    ForEach(RiskTolerance.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("自定义上限", isOn: $hasCustomLimits)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
            if hasCustomLimits {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    HStack {
                        Text("单标的 \(Int(concentrationLimit))%")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                        Slider(value: $concentrationLimit, in: 10...80, step: 5)
                    }
                    HStack {
                        Text("重叠 \(Int(overlapLimit))%")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                        Slider(value: $overlapLimit, in: 5...50, step: 5)
                    }
                }
                .padding(AppPalette.spaceS)
                .background(
                    AppPalette.cardStrong.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                )
            }

            Toggle(isOn: $allowsRebalancing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许主动再平衡建议")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                    Text("开启后超限时才给调整复核建议;关闭时只观察。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            HStack(spacing: AppPalette.spaceM) {
                Button {
                    saveProfile()
                } label: {
                    Label("保存", systemImage: "checkmark.circle")
                }
                .buttonStyle(.appPrimary)
                .controlSize(.regular)

                if model.userDecisionProfile.isCustomized {
                    Button {
                        model.updateUserDecisionProfile(.default)
                        syncFromModel()
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.regular)
                }

                Spacer()
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 420)
        .onAppear { syncFromModel() }
    }

    private func syncFromModel() {
        let profile = model.userDecisionProfile
        horizon = profile.investmentHorizon
        risk = profile.riskTolerance
        concentrationLimit = profile.effectiveConcentrationLimit
        overlapLimit = profile.effectiveOverlapLimit
        allowsRebalancing = profile.allowsActiveRebalancing
        hasCustomLimits = profile.concentrationLimit != nil
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
        dismiss()
    }
}
