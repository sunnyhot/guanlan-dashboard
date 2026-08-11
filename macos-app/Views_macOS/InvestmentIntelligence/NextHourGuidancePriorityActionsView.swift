import SwiftUI

struct NextHourGuidancePriorityActionsView: View {
    let actions: [NextHourGuidanceAction]
    let onSelect: (NextHourGuidanceAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Label("下一小时优先动作", systemImage: "list.number")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: AppPalette.spaceS)
                if actions.count > priorityActionCount {
                    Text("其余 \(actions.count - priorityActionCount) 项维持观察")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if priorityActions.isEmpty {
                ContentUnavailableView(
                    "暂无可执行动作",
                    systemImage: "pause.circle",
                    description: Text("当前数据不足，等待下一轮盘中研判。")
                )
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(Array(priorityActions.enumerated()), id: \.element.id) { index, action in
                        NextHourGuidancePriorityActionRow(
                            position: index + 1,
                            action: action,
                            onSelect: { onSelect(action) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityActions: [NextHourGuidanceAction] {
        Array(actions.sorted { $0.confidence > $1.confidence }.prefix(priorityActionCount))
    }

    private var priorityActionCount: Int {
        min(3, actions.count)
    }
}
