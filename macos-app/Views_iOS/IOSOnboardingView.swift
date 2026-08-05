#if os(iOS)
import SwiftUI

// MARK: - iOS 首次启动引导
//
// 替换 ContentView 里的 OnboardingPlaceholder（占位符）。
// 内容：App 图标 + 标题 + 3 张功能卡（持仓管理 / AI 趋势研判 / 平台动态）+ 底部「开始使用」。
// 去掉 macOS 版的菜单栏卡和快捷键提示（iOS 不适用）。
// 用 IOSDesign 杂志型排版（暖砖红 + serif 标题）。

struct IOSOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            IOSDesign.paper.ignoresSafeArea()

            ScrollView {
                VStack(spacing: IOSDesign.spaceL) {
                    header
                    featureCards
                    Spacer(minLength: IOSDesign.spaceS)
                    startButton
                }
                .padding(.horizontal, IOSDesign.spaceL)
                .padding(.top, IOSDesign.spaceXL)
                .padding(.bottom, IOSDesign.spaceL)
            }
        }
    }

    // MARK: 顶部图标 + 标题

    private var header: some View {
        VStack(spacing: IOSDesign.spaceS) {
            ZStack {
                RoundedRectangle(cornerRadius: IOSDesign.radiusM)
                    .fill(IOSDesign.accent)
                    .frame(width: 72, height: 72)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("且慢主理人看板")
                .font(IOSDesign.serifHeading(28))
                .foregroundStyle(IOSDesign.ink)
            Text("持仓 · 研判 · 平台动态 · 一站式")
                .font(IOSDesign.sansBody(15))
                .foregroundStyle(IOSDesign.muted)
        }
        .padding(.top, IOSDesign.spaceL)
    }

    // MARK: 功能卡片

    private var featureCards: some View {
        VStack(spacing: IOSDesign.spaceS) {
            featureRow(
                icon: "square.stack.3d.up.fill",
                title: "持仓与组合管理",
                description: "自动抓取且慢持仓、净值、调仓动态，组合诊断 / 收益归因 / 基金穿透一键查看。"
            )
            featureRow(
                icon: "sparkles",
                title: "AI 趋势研判",
                description: "配置模型后生成结构化趋势分析，跟踪清单帮你记录行动候选。"
            )
            featureRow(
                icon: "chart.bar.xaxis",
                title: "平台动态",
                description: "主理人调仓、论坛发言、策略雷达，买卖方筛选快速定位。"
            )
        }
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: IOSDesign.spaceM) {
            ZStack {
                RoundedRectangle(cornerRadius: IOSDesign.radiusS)
                    .fill(IOSDesign.accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IOSDesign.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(IOSDesign.serifHeading(16, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                Text(description)
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(IOSDesign.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
        .overlay(RoundedRectangle(cornerRadius: IOSDesign.radiusM).stroke(IOSDesign.ink.opacity(0.08), lineWidth: 1))
    }

    // MARK: 开始按钮

    private var startButton: some View {
        Button {
            dismiss()
        } label: {
            Text("开始使用")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(IOSDesign.accent, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
        }
    }
}
#endif
