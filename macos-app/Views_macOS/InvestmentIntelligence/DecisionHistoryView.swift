import SwiftUI

/// 已结束事项列表。放在父级 `SectionCard` 内，自身只渲染标题 + 行，
/// 不再重复卡片外壳（避免卡中卡）。
struct DecisionHistoryView: View {
    let cases: [DecisionCase]
    let onSelect: (DecisionCase) -> Void

    var body: some View {
        if !cases.isEmpty {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack {
                    Text("已结束的事项")
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    Text("\(cases.count) 条")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }

                ForEach(Array(cases.prefix(12).enumerated()), id: \.element.id) { index, decisionCase in
                    Button { onSelect(decisionCase) } label: {
                        HStack(spacing: AppPalette.spaceM) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(decisionCase.title)
                                    .font(AppPalette.appFont(.body, weight: .medium))
                                    .foregroundStyle(AppPalette.ink)
                                Text("\(decisionCase.userDisposition.displayName) · \(String(decisionCase.resolvedAt ?? decisionCase.updatedAt).prefix(10))")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                            }
                            Spacer()
                            Text(decisionCase.metricLabel)
                                .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppPalette.muted)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppPalette.muted)
                        }
                        .padding(.vertical, AppPalette.spaceS)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < min(cases.count, 12) - 1 { Divider() }
                }
            }
        }
    }
}
