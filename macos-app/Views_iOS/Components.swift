#if os(iOS)
import SwiftUI

// MARK: - iOS Shared UI Components
//
// 精简的 iOS 基础组件,风格与 macOS 版(SectionCard 等)保持视觉一致,但
// 独立实现以遵守「完全两套 Views」策略。复用共享的 AppPalette 设计 token
// (颜色/字体/间距/圆角)及其纯 SwiftUI modifier(panelStroke/sectionShadow 等)。

/// 卡片容器:图标 + 标题 + 副标题 + 尾部内容 + 主体内容。
/// 等价 macOS 版 SectionCard,iPhone 用更紧凑的间距。
struct IOSSectionCard<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        subtitle: String = "",
        icon: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.hairline.opacity(0.34), lineWidth: 1)
        )
    }
}

/// 空状态占位。
struct IOSEmptyState: View {
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.brand)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppPalette.cardHover, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

/// 统计数字小卡片(标题 + 数值 + 可选涨跌色)。
struct IOSStatTile: View {
    let title: String
    let value: String
    var tone: StatTone = .neutral

    enum StatTone {
        case neutral, positive, negative
        var color: Color {
            switch self {
            case .neutral: return AppPalette.ink
            case .positive: return AppPalette.marketGain
            case .negative: return AppPalette.marketLoss
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

/// 彩色小标签(状态/风险等级用)。
struct IOSTintedBadge: View {
    let text: String
    var tone: IOSStatTile.StatTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.12), in: Capsule())
            .foregroundStyle(tone.color)
    }
}

/// 涨跌色辅助:正数红涨、负数绿跌(中国股市惯例)。
func marketTone(for value: Double?) -> IOSStatTile.StatTone {
    guard let value else { return .neutral }
    if value > 0 { return .positive }
    if value < 0 { return .negative }
    return .neutral
}
#endif
