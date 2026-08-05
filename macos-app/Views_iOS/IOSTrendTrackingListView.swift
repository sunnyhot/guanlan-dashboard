#if os(iOS)
import SwiftUI

// MARK: - iOS AI 跟踪清单
//
// 复用 Core 的 `TrendTrackingItem` + AppModel 的增删改方法。
// 跟踪项由用户从「今日研判」行动候选主动加入；这里只做展示与状态管理。
// 注意：TrendActionKind.displayText / TrendTrackingStatus 色彩映射在 macOS 是
// Views_macOS 内的 extension，iOS target 编译不到，这里用 fileprivate 自建等价映射。

struct IOSTrendTrackingListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IOSSectionCard(title: "跟踪清单", subtitle: subtitle, icon: "checklist") {
            if model.trendTrackingItems.isEmpty {
                IOSEmptyState(
                    title: "暂无跟踪项",
                    subtitle: "从「今日研判」的行动候选点「加入跟踪」，这里会列出你主动跟踪的条件与状态。"
                )
            } else {
                VStack(spacing: IOSDesign.spaceS) {
                    ForEach(model.trendTrackingItems) { item in
                        trackingCard(item)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let count = model.trendTrackingItems.count
        return count == 0 ? "等待加入" : "共 \(count) 项"
    }

    // MARK: 跟踪项卡片

    private func trackingCard(_ item: TrendTrackingItem) -> some View {
        let tint = statusColor(item.status)
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: IOSDesign.spaceS) {
                Text(item.assetName)
                    .font(IOSDesign.sansBody(15, weight: .bold))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(1)
                if let code = item.assetCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                    Text(code)
                        .font(IOSDesign.monoNumber(11, weight: .regular))
                        .foregroundStyle(IOSDesign.muted)
                }
                Spacer(minLength: 4)
                Text(actionLabel(item.action))
                    .font(IOSDesign.sansBody(11, weight: .bold))
                    .foregroundStyle(tint)
                IOSTintedBadge(text: item.status.displayText, tone: statusTone(item.status))
            }

            Text("\(actionLabel(item.action))：\(item.reason)")
                .font(IOSDesign.sansBody(13))
                .foregroundStyle(IOSDesign.muted)
                .fixedSize(horizontal: false, vertical: true)

            confidenceBar(item.confidence)

            conditionLine("触发", item.triggerConditions, color: AppPalette.info)
            conditionLine("失效", item.invalidatingConditions, color: AppPalette.warning)

            if let until = item.snoozeUntil?.trimmingCharacters(in: .whitespacesAndNewlines), !until.isEmpty {
                Text("暂缓至 \(until)")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
            }

            HStack {
                Text("来源：\(item.sourceGeneratedAt)")
                    .font(IOSDesign.sansBody(10))
                    .foregroundStyle(IOSDesign.muted)
                    .lineLimit(1)
                Spacer()
                statusMenu(item)
            }
        }
        .padding(IOSDesign.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
        .overlay(
            RoundedRectangle(cornerRadius: IOSDesign.radiusS)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: 置信度条

    private func confidenceBar(_ confidence: TrendConfidence) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IOSDesign.spaceS) {
                Text("置信度")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
                Spacer()
                Text("\(confidence.score) · \(confidence.label)")
                    .font(IOSDesign.monoNumber(11, weight: .medium))
                    .foregroundStyle(IOSDesign.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSDesign.ink.opacity(0.08))
                    Capsule()
                        .fill(IOSDesign.accent)
                        .frame(width: geo.size.width * CGFloat(max(0, min(confidence.score, 100))) / 100)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: 条件列表

    @ViewBuilder
    private func conditionLine(_ title: String, _ items: [String], color: Color) -> some View {
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IOSDesign.sansBody(11, weight: .semibold))
                    .foregroundStyle(color)
                ForEach(trimmed, id: \.self) { value in
                    Text("· \(value)")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 状态操作菜单

    private func statusMenu(_ item: TrendTrackingItem) -> some View {
        Menu {
            Button("标记已触发") { model.markTrackingItem(item.id, status: .triggered, note: "手动标记已触发") }
            Button("标记已失效") { model.markTrackingItem(item.id, status: .invalidated, note: "手动标记已失效") }
            Button("标记已处理") { model.markTrackingItem(item.id, status: .processed, note: "手动标记已处理") }
            Divider()
            Button("暂缓一天") { model.snoozeTrackingItem(item.id, days: 1) }
            Button("暂缓一周") { model.snoozeTrackingItem(item.id, days: 7) }
            if item.status == .processed {
                Button("恢复跟踪") { model.resumeTrackingItem(item.id) }
            }
            Divider()
            Button("结束跟踪", role: .destructive) { model.endTrackingItem(item.id) }
            Button("取消跟踪（删除）", role: .destructive) { model.removeTrackingItem(item.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IOSDesign.ink)
        }
    }

    // MARK: 映射辅助

    private func actionLabel(_ action: TrendActionKind) -> String {
        switch action {
        case .watch:             return "观察"
        case .waitForConfirmation: return "等待确认"
        case .observeInBatches:  return "分批观察"
        case .pausePlan:         return "暂停计划"
        case .considerIncrease:  return "考虑增加"
        case .considerReduce:    return "考虑降低"
        case .rebalanceReview:   return "调仓复核"
        }
    }

    private func statusColor(_ status: TrendTrackingStatus) -> Color {
        switch status {
        case .observing, .approaching: return AppPalette.info
        case .triggered:               return AppPalette.positive
        case .invalidated:             return AppPalette.warning
        case .staleData, .processed, .ended: return AppPalette.muted
        }
    }

    private func statusTone(_ status: TrendTrackingStatus) -> IOSStatTile.StatTone {
        switch status {
        case .triggered:               return .positive
        case .invalidated:             return .negative
        case .observing, .approaching: return .neutral
        case .staleData, .processed, .ended: return .neutral
        }
    }
}
#endif
