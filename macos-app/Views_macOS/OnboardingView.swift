import SwiftUI

/// 首次启动引导：简短、模态式，教用户"做什么"而不是"读什么"。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppPalette.spaceL) {
            // 图标 + 标题
            VStack(spacing: AppPalette.spaceS) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                        .fill(AppPalette.brand)
                        .frame(width: 64, height: 64)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(AppPalette.appFont(.largeTitle, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("且慢主理人看板")
                    .font(AppPalette.appFont(.largeTitle, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("持仓 · 趋势 · 菜单栏 · 一站式")
                    .font(AppPalette.appFont(.body))
                    .foregroundStyle(AppPalette.muted)
            }

            // 功能卡片
            VStack(spacing: 10) {
                OnboardingFeatureRow(
                    icon: "square.stack.3d.up",
                    title: "持仓与组合管理",
                    description: "自动抓取且慢持仓、净值、调仓动态"
                )
                OnboardingFeatureRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "组合分析",
                    description: "组合诊断 / 收益归因 / 基金穿透，本地一键计算"
                )
                OnboardingFeatureRow(
                    icon: "menubar.rectangle",
                    title: "菜单栏实时行情",
                    description: "估值/指数常驻菜单栏，不开主界面也能看"
                )
            }

            // 快捷键
            VStack(spacing: 6) {
                Text("快捷键")
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle(AppPalette.muted)
                HStack(spacing: 12) {
                    OnboardingShortcutHint(key: "⌘1-4", label: "切换板块")
                    OnboardingShortcutHint(key: "⌘R", label: "刷新")
                    OnboardingShortcutHint(key: "⌘F", label: "搜索")
                }
            }

            Button {
                dismiss()
            } label: {
                Text("开始使用")
                    .font(AppPalette.appFont(.title3, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.appPrimary)
            .tint(AppPalette.brand)
        }
        .padding(32)
        .frame(width: 420)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                    .fill(AppPalette.brand.opacity(AppPalette.accentFill))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(AppPalette.appFont(.title3, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(description)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppPalette.canvasGradient, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }
}

private struct OnboardingShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(key)
                .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.brand)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppPalette.brand.opacity(AppPalette.accentFill), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
    }
}
