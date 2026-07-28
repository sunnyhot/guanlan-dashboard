import SwiftUI

extension EnhancementCenterView {
    /// 跟踪清单：只展示用户从今日研判主动加入的跟踪项（数据源 trendTrackingItems，不再用 tradeSignalSummary）
    var trackingContent: some View {
        Group {
            if model.trendTrackingItems.isEmpty {
                trendEmptyState("暂无跟踪项", detail: "从「今日研判」的行动候选点「加入跟踪」，这里会列出你主动跟踪的条件与状态。")
            } else {
                VStack(spacing: AppPalette.spaceM) {
                    ForEach(model.trendTrackingItems) { item in
                        trackingItemCard(item)
                    }
                }
            }
        }
    }

    private func trackingItemCard(_ item: TrendTrackingItem) -> some View {
        let tint = trackingStatusTint(item.status)
        let isSelected = model.selectedTrendTrackingItemID == item.id
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.assetName)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                if let code = item.assetCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                    Text(code)
                        .font(AppPalette.appFont(.footnote, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: 4)
                Text(item.action.displayText)
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle(tint)
                Text(item.status.displayText)
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(AppPalette.accentFill), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1))
            }

            Text("\(item.action.displayText)：\(item.reason)")
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            trendConfidenceMeter(item.confidence)

            trackingConditionLine("触发", item.triggerConditions, tint: AppPalette.info)
            trackingConditionLine("失效", item.invalidatingConditions, tint: AppPalette.warning)

            if let until = item.snoozeUntil?.trimmingCharacters(in: .whitespacesAndNewlines), !until.isEmpty {
                Text("暂缓至 \(until)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("来源报告：\(item.sourceGeneratedAt)")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trackingItemMenu(item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: isSelected ? 0.60 : 0.40
        )
    }

    private func trackingItemMenu(_ item: TrendTrackingItem) -> some View {
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
            Label("操作", systemImage: "ellipsis.circle")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func trackingConditionLine(_ title: String, _ items: [String], tint: Color) -> some View {
        let trimmed = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(tint)
                ForEach(trimmed, id: \.self) { value in
                    Text("· \(value)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trackingStatusTint(_ status: TrendTrackingStatus) -> Color {
        switch status {
        case .observing, .approaching:
            return AppPalette.info
        case .triggered:
            return AppPalette.positive
        case .invalidated:
            return AppPalette.warning
        case .staleData, .processed, .ended:
            return AppPalette.muted
        }
    }
}
