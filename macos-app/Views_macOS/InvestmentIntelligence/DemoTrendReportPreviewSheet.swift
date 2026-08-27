import SwiftUI

/// W1.3:示例研判预览——配置前先看到「我会得到什么」。
/// 只读渲染 `DemoTrendReport` 静态数据,结论卡复用 `VerdictCard`,
/// 与真实报告同一套视觉;显著标注「示例数据,非真实研判」。
struct DemoTrendReportPreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var report: TrendAnalysisReport { DemoTrendReport.shared }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    sampleBanner

                    sectionTitle("组合方向", icon: "clock")
                    HStack(alignment: .top, spacing: AppPalette.spaceS) {
                        ForEach(report.horizons, id: \.horizon) { horizon in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(horizon.direction.tint)
                                    Text(horizon.horizon.displayText)
                                        .font(AppPalette.appFont(.body, weight: .bold))
                                        .foregroundStyle(AppPalette.ink)
                                }
                                VerdictCard(
                                    direction: horizon.direction,
                                    confidence: horizon.confidence,
                                    rationale: horizon.rationale,
                                    counterSignals: horizon.counterSignals
                                )
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .staticSurface(
                                tint: horizon.direction.tint,
                                fill: AppPalette.cardStrong,
                                strokeOpacity: 0.18,
                                activeStrokeOpacity: 0.40
                            )
                        }
                    }

                    sectionTitle("大盘与板块", icon: "globe.asia.australia")
                    VStack(spacing: AppPalette.spaceS) {
                        ForEach(report.marketOutlook) { outlook in
                            demoClaimRow(
                                name: outlook.name,
                                direction: outlook.direction,
                                confidence: outlook.confidence,
                                rationale: outlook.rationale,
                                counterSignals: outlook.counterSignals
                            )
                        }
                        ForEach(report.sectors) { sector in
                            demoClaimRow(
                                name: sector.name,
                                direction: sector.direction,
                                confidence: sector.confidence,
                                rationale: sector.rationale,
                                counterSignals: sector.counterSignals
                            )
                        }
                    }

                    sectionTitle("值得关注的投资方向", icon: "scope")
                    ForEach(report.opportunities) { opportunity in
                        demoClaimRow(
                            name: opportunity.name,
                            direction: opportunity.direction,
                            confidence: opportunity.confidence,
                            rationale: opportunity.rationale,
                            counterSignals: opportunity.counterSignals
                        )
                    }

                    sectionTitle("行动候选", icon: "checklist")
                    ForEach(report.actions) { action in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(action.title)
                                    .font(AppPalette.appFont(.body, weight: .bold))
                                    .foregroundStyle(AppPalette.ink)
                                TintedCapsuleBadge(
                                    text: action.kind.displayText,
                                    tint: AppPalette.info,
                                    font: AppPalette.appFont(.caption, weight: .bold),
                                    horizontalPadding: 6,
                                    verticalPadding: 2
                                )
                                Spacer(minLength: 4)
                            }
                            Text(action.detail)
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .staticSurface(
                            tint: AppPalette.info,
                            fill: AppPalette.cardStrong,
                            strokeOpacity: 0.18,
                            activeStrokeOpacity: 0.40
                        )
                    }

                    Text(report.disclaimer)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(AppPalette.spaceL)
            }
        }
        .frame(width: 620, height: 620)
    }

    private var headerBar: some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: "eye")
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("示例研判 · 先看看能得到什么")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("这是一份静态演示数据;配置模型后,你的研判会基于真实持仓与行情生成。")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: AppPalette.spaceM)
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(AppPalette.spaceL)
    }

    private var sampleBanner: some View {
        Label(
            "示例数据,非真实研判——数字与结论均为演示用途",
            systemImage: "sparkles"
        )
        .font(AppPalette.appFont(.footnote, weight: .semibold))
        .foregroundStyle(AppPalette.brand)
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
            Text(title)
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
        }
    }

    private func demoClaimRow(
        name: String,
        direction: TrendDirection,
        confidence: TrendConfidence,
        rationale: String,
        counterSignals: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(direction.tint)
                Text(name)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
            }
            VerdictCard(
                direction: direction,
                confidence: confidence,
                rationale: rationale,
                counterSignals: counterSignals
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: direction.tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.40
        )
    }
}
