import SwiftUI

// iOS 端:用户决策画像编辑(Slice 5)。
// 与 macOS 版对齐,用 IOSDesign 排版。

struct IOSUserDecisionProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var horizon: InvestmentHorizon = .longTerm
    @State private var risk: RiskTolerance = .conservative
    @State private var concentrationLimit: Double = 30
    @State private var overlapLimit: Double = 15
    @State private var allowsRebalancing: Bool = false
    @State private var hasCustomLimits: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            HStack(spacing: IOSDesign.spaceS) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundColor(IOSDesign.accent)
                Text("投资偏好设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(IOSDesign.ink)
            }

            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                Text("投资期限").font(.system(size: 13, weight: .medium)).foregroundColor(IOSDesign.muted)
                Picker("投资期限", selection: $horizon) {
                    ForEach(InvestmentHorizon.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                Text("风险偏好").font(.system(size: 13, weight: .medium)).foregroundColor(IOSDesign.muted)
                Picker("风险偏好", selection: $risk) {
                    ForEach(RiskTolerance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Toggle("自定义上限", isOn: $hasCustomLimits)
                .font(.system(size: 13))
            if hasCustomLimits {
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    HStack {
                        Text("单标的 \(Int(concentrationLimit))%").font(.system(size: 12)).foregroundColor(IOSDesign.muted)
                        Slider(value: $concentrationLimit, in: 10...80, step: 5)
                    }
                    HStack {
                        Text("重叠 \(Int(overlapLimit))%").font(.system(size: 12)).foregroundColor(IOSDesign.muted)
                        Slider(value: $overlapLimit, in: 5...50, step: 5)
                    }
                }
            }

            Toggle(isOn: $allowsRebalancing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许主动再平衡建议").font(.system(size: 13, weight: .medium))
                    Text("开启后超限时才给调整复核建议;关闭时只观察。")
                        .font(.system(size: 11)).foregroundColor(IOSDesign.muted)
                }
            }

            Button("保存") { saveProfile() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
        }
        .padding(IOSDesign.spaceM)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
        .onAppear { syncFromModel() }
    }

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
