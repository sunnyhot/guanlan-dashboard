import SwiftUI

struct NextHourGuidanceProgressView: View {
    let stage: NextHourGuidanceProgressStage
    @State private var startedAt: Date?

    private let steps = [
        "持仓",
        "行情",
        "快照",
        "三方分析",
        "汇总校验"
    ]

    /// 2026-09-02:前置阶段网络半开会长时间停在某个阶段——已耗时让用户能分辨
    /// 「在跑」还是「死了」（超时保护兜底,但健康慢路径也应可见进度）。
    private func elapsedText(now: Date) -> String? {
        guard let startedAt else { return nil }
        let interval = max(0, now.timeIntervalSince(startedAt))
        return String(format: "已进行 %d:%02d", Int(interval) / 60, Int(interval) % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                HStack(spacing: AppPalette.spaceS) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("盘中研判正在进行")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppPalette.spaceXS) {
                            Text(stage.title)
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                            if let elapsed = elapsedText(now: timeline.date) {
                                Text(elapsed)
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                                    .monospacedDigit()
                            }
                        }
                        Text("完成后会给出优先动作、触发条件、失效条件和三方判断依据。")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                HStack(spacing: AppPalette.spaceXS) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                        VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                            Capsule()
                                .fill(stepTint(at: index))
                                .frame(height: 4)
                            Text(title)
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(index <= stage.completedStepCount ? AppPalette.ink : AppPalette.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("盘中研判进度")
                .accessibilityValue("已完成 \(stage.completedStepCount) / \(steps.count) 个阶段，当前\(stage.title)")
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.info.opacity(AppPalette.accentSubtle), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                    .stroke(AppPalette.info.opacity(AppPalette.strokeSubtle), lineWidth: 1)
            )
            .onAppear {
                if startedAt == nil {
                    startedAt = Date()
                }
            }
        }
    }

    private func stepTint(at index: Int) -> Color {
        if index < stage.completedStepCount {
            return AppPalette.positive
        }
        if index == stage.completedStepCount {
            return AppPalette.info
        }
        return AppPalette.hairline
    }
}
