#if os(iOS)
import SwiftUI

// MARK: - iOS Design Tokens（编辑杂志型方向，见 Design/brand-spec.md）
//
// iOS 专属设计 token，覆盖共享 AppPalette 里偏通用/默认蓝的部分。不改
// 共享 AppPalette（避免影响 macOS）。哲学：暖砖红单重点 + serif 标题 +
// 大留白 + 等宽数字，反 AI-slop。
enum IOSDesign {
    // 颜色：全部明暗自适应（用 UIColor dynamic provider）。暖色调贯穿。
    // 暖砖红品牌色：浅色沉稳砖红，深色稍亮保证可见度
    static let accent = adaptive(light: Color(hex: "C44A3A")!, dark: Color(hex: "E06A55")!)
    // 暖白/暖黑底色：浅色暖白纸，深色暖黑炭（不是冷 zinc，保持杂志暖调）
    static let paper = adaptive(light: Color(hex: "FAF8F4")!, dark: Color(hex: "14110E")!)
    // 卡片底：略浅于 paper（dark 下略亮于背景）
    static let card = adaptive(light: Color(hex: "FFFFFF")!, dark: Color(hex: "1F1B16")!)
    // 文字：暖墨黑 / 暖白
    static let ink = adaptive(light: Color(hex: "1A1A1A")!, dark: Color(hex: "F2F0EC")!)
    // 次文字：暖灰
    static let muted = adaptive(light: Color(hex: "6B6358")!, dark: Color(hex: "9A9388")!)

    // 间距：严格 8pt 网格
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 24
    static let spaceXL: CGFloat = 32

    // 圆角（杂志型偏方正，不用大圆角）
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12

    // 字体 helper
    static func serifHeading(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func sansBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// 等宽数字（金额/百分比，专业对齐感）
    static func monoNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// iOS 明暗自适应颜色（UIColor dynamic provider，随 colorScheme 切换）。
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - iOS Shared UI Components

/// 卡片容器：杂志型——衬线标题、暖白卡片底、细线分隔，不用圆角图标块。
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
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: IOSDesign.spaceS) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSDesign.accent)
                // 杂志型：衬线标题，不用图标色块
                Text(title)
                    .font(IOSDesign.serifHeading(20))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(2)
                Spacer()
                trailing
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 细线分隔 header 与 content（杂志感）
            Divider().opacity(0.4)
            content
        }
        .padding(IOSDesign.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
        .overlay(
            RoundedRectangle(cornerRadius: IOSDesign.radiusM)
                .stroke(IOSDesign.ink.opacity(0.1), lineWidth: 1)
        )
    }
}

/// 空状态占位。杂志型：serif 标题，细线边框卡片。
struct IOSEmptyState: View {
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text(title)
                .font(IOSDesign.serifHeading(17, weight: .semibold))
                .foregroundStyle(IOSDesign.ink)
            Text(subtitle)
                .font(IOSDesign.sansBody(14))
                .foregroundStyle(IOSDesign.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(IOSDesign.accent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IOSDesign.spaceM)
        .background(IOSDesign.card.opacity(0.6), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }
}

/// 统计数字小卡片：serif 小标题 + 等宽数字（杂志型，对齐专业感）。
struct IOSStatTile: View {
    let title: String
    let value: String
    var tone: StatTone = .neutral

    enum StatTone {
        case neutral, positive, negative
        var color: Color {
            switch self {
            case .neutral: return IOSDesign.ink
            case .positive: return AppPalette.marketGain
            case .negative: return AppPalette.marketLoss
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceXS) {
            Text(title)
                .font(IOSDesign.sansBody(12))
                .foregroundStyle(IOSDesign.muted)
            Text(value)
                .font(IOSDesign.monoNumber(16))
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IOSDesign.spaceS + 4)
        .background(IOSDesign.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }
}

/// 彩色小标签（状态/风险等级用）。杂志型：细边框胶囊而非纯填色。
struct IOSTintedBadge: View {
    let text: String
    var tone: IOSStatTile.StatTone = .neutral

    var body: some View {
        Text(text)
            .font(IOSDesign.sansBody(12, weight: .medium))
            .padding(.horizontal, IOSDesign.spaceS)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(tone.color.opacity(0.3), lineWidth: 1))
            .foregroundStyle(tone.color)
    }
}

/// 涨跌色辅助：正数红涨、负数绿跌（中国股市惯例）。
func marketTone(for value: Double?) -> IOSStatTile.StatTone {
    guard let value else { return .neutral }
    if value > 0 { return .positive }
    if value < 0 { return .negative }
    return .neutral
}
#endif
