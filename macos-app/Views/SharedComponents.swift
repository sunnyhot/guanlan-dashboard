import SwiftUI

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: maxWidth != .infinity ? maxWidth : nil, height: nil))
            sizes.append(size)

            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        let totalWidth = positions.enumerated().map { $0.element.x + sizes[$0.offset].width }.max() ?? 0
        let totalSize = CGSize(width: totalWidth, height: y + rowHeight)
        return (positions, sizes, totalSize)
    }
}

struct SnapshotMiniBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text.isEmpty ? "未标注" : text)
            .font(AppPalette.appFont(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, AppPalette.spaceS)
            .padding(.vertical, AppPalette.spaceXS)
            .background(tint.opacity(AppPalette.accentFill), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1)
            )
    }
}

struct ModuleTabBar<Item: Identifiable & Hashable, TrailingContent: View>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    let systemImage: (Item) -> String
    private let trailingContent: () -> TrailingContent

    init(
        items: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        systemImage: @escaping (Item) -> String,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.items = items
        self._selection = selection
        self.title = title
        self.systemImage = systemImage
        self.trailingContent = trailingContent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppPalette.spaceS) {
                ForEach(items) { item in
                    moduleTabButton(item)
                }

                Spacer(minLength: AppPalette.spaceS)
                trailingContent()
            }
            .padding(.horizontal, AppPalette.contentPadding)
            .padding(.vertical, 10)
            .background(AppPalette.card.opacity(0.45))

            Divider()
        }
    }

    private func moduleTabButton(_ item: Item) -> some View {
        let isSelected = selection == item

        return Button {
            guard !isSelected else { return }
            withAnimation(AppPalette.motionSection) {
                selection = item
            }
        } label: {
            Label(title(item), systemImage: systemImage(item))
                .font(AppPalette.appFont(.body, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AppPalette.onBrand : AppPalette.muted)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .interactiveSurface(
                    isSelected: isSelected,
                    tint: AppPalette.brand,
                    radius: AppPalette.controlRadius,
                    fill: AppPalette.cardStrong,
                    hoverFill: AppPalette.cardHover,
                    selectedFill: AppPalette.brand,
                    strokeOpacity: 0.45,
                    activeStrokeOpacity: AppPalette.selectionStrokeOpacity,
                    lift: 0
                )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .accessibilityLabel(title(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension ModuleTabBar where TrailingContent == EmptyView {
    init(
        items: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String,
        systemImage: @escaping (Item) -> String
    ) {
        self.init(
            items: items,
            selection: selection,
            title: title,
            systemImage: systemImage,
            trailingContent: { EmptyView() }
        )
    }
}

// MARK: - Shared Components

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let accent: Color
    let valueTint: Color

    init(title: String, value: String, subtitle: String, icon: String, accent: Color, valueTint: Color = AppPalette.ink) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.accent = accent
        self.valueTint = valueTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceXS + 2) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(accent)
                    .accentIconStyle(tint: accent, size: 26)

                Text(title)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(AppPalette.appFont(.title2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .foregroundStyle(valueTint)
                Text(subtitle)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 76, alignment: .leading)
        .padding(AppPalette.spaceM)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke()
    }
}

struct PressResponsiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressResponsiveButtonLabel(configuration: configuration)
    }
}

enum AppActionButtonKind: Equatable {
    case primary
    case secondary
    case text
    case danger
    case icon
    case menuItem
}

struct AppActionButtonStyle: ButtonStyle {
    let kind: AppActionButtonKind

    func makeBody(configuration: Configuration) -> some View {
        AppActionButtonLabel(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == AppActionButtonStyle {
    static var appPrimary: AppActionButtonStyle {
        AppActionButtonStyle(kind: .primary)
    }

    static var appSecondary: AppActionButtonStyle {
        AppActionButtonStyle(kind: .secondary)
    }

    static var appText: AppActionButtonStyle {
        AppActionButtonStyle(kind: .text)
    }

    static var appDanger: AppActionButtonStyle {
        AppActionButtonStyle(kind: .danger)
    }

    static var appIcon: AppActionButtonStyle {
        AppActionButtonStyle(kind: .icon)
    }

    static var appMenuItem: AppActionButtonStyle {
        AppActionButtonStyle(kind: .menuItem)
    }
}

private struct AppActionButtonLabel: View {
    let configuration: AppActionButtonStyle.Configuration
    let kind: AppActionButtonKind

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isInteractive: Bool {
        isEnabled && isHovering
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return AppPalette.onBrand
        case .danger:
            return AppPalette.danger
        case .secondary, .menuItem:
            return isInteractive ? AppPalette.ink : AppPalette.ink.opacity(0.90)
        case .text, .icon:
            return isInteractive ? AppPalette.brand : AppPalette.muted
        }
    }

    private var fill: Color {
        switch kind {
        case .primary:
            return AppPalette.brand.opacity(isInteractive ? 1 : 0.88)
        case .secondary:
            return isInteractive ? AppPalette.brandSoft : AppPalette.cardStrong
        case .danger:
            return AppPalette.danger.opacity(isInteractive ? 0.16 : 0.09)
        case .text, .icon:
            return isInteractive ? AppPalette.brand.opacity(0.10) : Color.clear
        case .menuItem:
            return isInteractive ? AppPalette.brand.opacity(0.12) : Color.clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary:
            return AppPalette.brand.opacity(isInteractive ? 0.96 : 0.72)
        case .secondary:
            return isInteractive ? AppPalette.brand.opacity(0.52) : AppPalette.line.opacity(0.50)
        case .danger:
            return AppPalette.danger.opacity(isInteractive ? 0.52 : 0.28)
        case .text, .icon, .menuItem:
            return Color.clear
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary, .secondary, .danger:
            return 12
        case .text:
            return 7
        case .icon:
            return 0
        case .menuItem:
            return 10
        }
    }

    private var verticalPadding: CGFloat {
        switch kind {
        case .primary, .secondary, .danger:
            return 8
        case .text:
            return 6
        case .icon:
            return 0
        case .menuItem:
            return 9
        }
    }

    private var minimumHeight: CGFloat {
        switch kind {
        case .icon:
            return 28
        case .menuItem:
            return 42
        default:
            return 30
        }
    }

    var body: some View {
        configuration.label
            .font(AppPalette.appFont(kind == .menuItem ? .subheadline : .footnote, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(
                minWidth: kind == .icon ? 28 : nil,
                minHeight: minimumHeight,
                alignment: kind == .menuItem ? .leading : .center
            )
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .background(fill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(stroke, lineWidth: 1)
            )
            .shadow(
                color: kind == .primary && isInteractive ? AppPalette.brand.opacity(0.18) : .clear,
                radius: 8,
                y: 3
            )
            .scaleEffect(
                accessibilityReduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.97 : 1)
            )
            .offset(y: accessibilityReduceMotion || !isInteractive ? 0 : -0.5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.46)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionFast, value: configuration.isPressed)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionStandard, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if accessibilityReduceMotion {
                    configuration.isExpanded.toggle()
                } else {
                    withAnimation(AppPalette.motionStandard) {
                        configuration.isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 10)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))

                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            .accessibilityHint("展开或收起内容")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct InlineDisclosureButton: View {
    let title: String
    let countText: String
    let icon: String
    let isExpanded: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            if accessibilityReduceMotion {
                action()
            } else {
                withAnimation(AppPalette.motionSection) {
                    action()
                }
            }
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: icon)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)

                Text(countText)
                    .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppPalette.card, in: Capsule())

                Spacer()

                Text(isExpanded ? "收起" : "展开")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)

                Image(systemName: "chevron.down")
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle(AppPalette.muted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            AppPalette.cardStrong.opacity(isHovering ? 0.64 : 0.42),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay(
            AppPalette.borderOverlay(
                radius: AppPalette.controlRadius,
                opacity: isHovering ? AppPalette.borderMedium : AppPalette.borderFaint
            )
        )
        .animation(accessibilityReduceMotion ? nil : AppPalette.motionFast, value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel(title)
        .accessibilityValue("\(countText)，\(isExpanded ? "已展开" : "已收起")")
        .accessibilityHint("展开或收起明细")
    }
}

private struct PressResponsiveButtonLabel: View {
    let configuration: PressResponsiveButtonStyle.Configuration
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .scaleEffect(accessibilityReduceMotion ? 1 : (configuration.isPressed ? 0.965 : 1))
            .brightness(isHovering ? 0.025 : 0)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionFast, value: configuration.isPressed)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionStandard, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct InteractiveSurfaceModifier: ViewModifier {
    var isSelected = false
    var tint: Color = AppPalette.brand
    var radius: CGFloat = AppPalette.cardRadius
    var fill: Color = AppPalette.card
    var hoverFill: Color = AppPalette.cardHover
    var selectedFill: Color?
    var strokeOpacity: Double = 0.34
    var activeStrokeOpacity: Double = 0.58
    var lift: CGFloat = 1
    var allowsHoverFeedback = true

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    private var isActive: Bool {
        isSelected || (allowsHoverFeedback && isHovering)
    }

    private var effectiveLift: CGFloat {
        allowsHoverFeedback && isHovering && !accessibilityReduceMotion ? lift : 0
    }

    private var surfaceFill: Color {
        if isSelected {
            return selectedFill ?? AppPalette.selectionFill.opacity(0.72)
        }
        if allowsHoverFeedback && isHovering {
            return hoverFill
        }
        return fill
    }

    private var surfaceStroke: Color {
        if isSelected {
            return tint.opacity(AppPalette.selectionStrokeOpacity)
        }
        if allowsHoverFeedback && isHovering {
            return tint.opacity(activeStrokeOpacity)
        }
        return AppPalette.line.opacity(strokeOpacity)
    }

    private var glowOpacity: Double {
        if isSelected {
            return AppPalette.selectionGlowOpacity
        }
        if allowsHoverFeedback && isHovering {
            return AppPalette.selectionGlowOpacity * 0.58
        }
        return 0
    }

    func body(content: Content) -> some View {
        content
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(surfaceStroke, lineWidth: isActive ? 1.15 : 1)
            )
            .shadow(
                color: tint.opacity(glowOpacity),
                radius: isActive ? AppPalette.selectionGlowRadius : 0,
                x: 0,
                y: isActive ? 4 : 0
            )
            .offset(y: -effectiveLift)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionStandard, value: isHovering)
            .animation(accessibilityReduceMotion ? nil : AppPalette.motionStandard, value: isSelected)
            .onChange(of: allowsHoverFeedback) { _, allowsHoverFeedback in
                if !allowsHoverFeedback {
                    isHovering = false
                }
            }
            .onHover { hovering in
                isHovering = allowsHoverFeedback && hovering
            }
    }
}

private struct ReducedMotionRespectingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if accessibilityReduceMotion {
                transaction.animation = nil
            }
        }
    }
}

struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let trailing: Trailing
    let content: Content

    init(title: String, subtitle: String, icon: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM - 2) {
            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .accentIconStyle(tint: AppPalette.brand, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            content
        }
        .padding(14)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke()
        .sectionShadow()
    }
}

struct EmptySectionState: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM - 2) {
            Text(title)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(subtitle)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppPalette.cardHover, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: AppPalette.strokeSubtle)
    }
}

struct StatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, AppPalette.spaceS)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.40)
    }
}

struct ToolbarBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(AppPalette.appFont(.footnote, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, AppPalette.spaceS)
            .padding(.vertical, AppPalette.spaceXS)
            .background(tint.opacity(AppPalette.accentFill), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                    .stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1)
            )
    }
}

struct ToastBar: View {
    let text: String
    let tint: Color
    let actionTitle: String?
    let action: (() -> Void)?
    let onDismiss: (() -> Void)?

    init(
        text: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.text = text
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: AppPalette.spaceS) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3, height: 14)
            Text(text)
                .font(AppPalette.appFont(.subheadline))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(AppPalette.ink)
                .textSelection(.enabled)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(AppPalette.appFont(.caption, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.muted)
                .accessibilityLabel("关闭提示")
                .help("关闭")
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
        .background(tint.opacity(AppPalette.accentSubtle), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            AppPalette.borderOverlay(radius: AppPalette.cardRadius, opacity: 0.28)
        )
    }
}


struct LabeledValue: View {
    let title: String
    let value: String
    let tint: Color
    let titleSize: AppPalette.AppFontSize
    let titleWeight: Font.Weight
    let titleLineLimit: Int?
    let valueSize: AppPalette.AppFontSize
    let valueWeight: Font.Weight
    let valueDesign: Font.Design
    let spacing: CGFloat
    let minimumScaleFactor: CGFloat
    let lineLimit: Int?
    let alignment: HorizontalAlignment

    init(
        title: String,
        value: String,
        tint: Color = AppPalette.ink,
        titleSize: AppPalette.AppFontSize = .footnote,
        titleWeight: Font.Weight = .regular,
        titleLineLimit: Int? = nil,
        valueSize: AppPalette.AppFontSize = .body,
        valueWeight: Font.Weight = .semibold,
        valueDesign: Font.Design = .monospaced,
        spacing: CGFloat = 2,
        minimumScaleFactor: CGFloat = 0.8,
        lineLimit: Int? = 1,
        alignment: HorizontalAlignment = .leading
    ) {
        self.title = title
        self.value = value
        self.tint = tint
        self.titleSize = titleSize
        self.titleWeight = titleWeight
        self.titleLineLimit = titleLineLimit
        self.valueSize = valueSize
        self.valueWeight = valueWeight
        self.valueDesign = valueDesign
        self.spacing = spacing
        self.minimumScaleFactor = minimumScaleFactor
        self.lineLimit = lineLimit
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            Text(title)
                .font(AppPalette.appFont(titleSize, weight: titleWeight))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(titleLineLimit)
            Text(value)
                .font(AppPalette.appFont(valueSize, weight: valueWeight, design: valueDesign))
                .foregroundStyle(tint)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScaleFactor)
        }
    }
}

struct TintedCapsuleBadge: View {
    enum FillStyle {
        case soft
        case solid
        case neutral
    }

    let text: String
    let tint: Color
    let style: FillStyle
    let font: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let softFillOpacity: Double
    let softStrokeOpacity: Double?

    init(
        text: String,
        tint: Color,
        style: FillStyle = .soft,
        font: Font = AppPalette.appFont(.footnote, weight: .semibold),
        horizontalPadding: CGFloat = AppPalette.spaceS,
        verticalPadding: CGFloat = AppPalette.spaceXS,
        softFillOpacity: Double = AppPalette.accentFill,
        softStrokeOpacity: Double? = AppPalette.accentBorder
    ) {
        self.text = text
        self.tint = tint
        self.style = style
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.softFillOpacity = softFillOpacity
        self.softStrokeOpacity = softStrokeOpacity
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background, in: Capsule())
            .overlay(overlay)
    }

    private var foreground: Color {
        switch style {
        case .soft:    return tint
        case .solid:   return .white
        case .neutral: return AppPalette.muted
        }
    }

    private var background: Color {
        switch style {
        case .soft:    return tint.opacity(softFillOpacity)
        case .solid:   return tint
        case .neutral: return AppPalette.cardStrong
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch style {
        case .soft:
            if let softStrokeOpacity {
                Capsule().stroke(tint.opacity(softStrokeOpacity), lineWidth: 1)
            }
        case .solid, .neutral:
            EmptyView()
        }
    }
}

// MARK: - Reusable Material Components

#if canImport(AppKit)
/// A translucent material panel suitable for sidebar, toolbar, or section backgrounds.
/// Uses NSVisualEffectView for consistent vibrancy across macOS 13+.
struct MaterialPanel: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = emphasized
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = emphasized
        nsView.state = .active
    }
}

/// Convenience modifier that wraps content in a material background with optional border and corner radius.
struct MaterialBackgroundModifier: ViewModifier {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat
    var borderColor: Color?
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                MaterialPanel(material: material, blendingMode: blendingMode)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor ?? AppPalette.line.opacity(0.35), lineWidth: borderWidth)
            )
    }
}
#else
/// iOS fallback material panel backed by SwiftUI's native material system.
struct MaterialPanel: View {
    var material: Material = .regularMaterial
    var blendingMode: Material = .regularMaterial // ignored on iOS
    var emphasized: Bool = false

    var body: some View {
        Color.clear.background(material, ignoreSafeAreaEdges: .all)
    }
}

struct MaterialBackgroundModifier: ViewModifier {
    var material: Material = .regularMaterial
    var blendingMode: Material = .regularMaterial
    var cornerRadius: CGFloat
    var borderColor: Color?
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                Color.clear.background(material)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor ?? AppPalette.line.opacity(0.35), lineWidth: borderWidth)
            )
    }
}
#endif

extension View {
    func interactiveSurface(
        isSelected: Bool = false,
        tint: Color = AppPalette.brand,
        radius: CGFloat = AppPalette.cardRadius,
        fill: Color = AppPalette.card,
        hoverFill: Color = AppPalette.cardHover,
        selectedFill: Color? = nil,
        strokeOpacity: Double = 0.34,
        activeStrokeOpacity: Double = 0.58,
        lift: CGFloat = 1,
        allowsHoverFeedback: Bool = true
    ) -> some View {
        modifier(InteractiveSurfaceModifier(
            isSelected: isSelected,
            tint: tint,
            radius: radius,
            fill: fill,
            hoverFill: hoverFill,
            selectedFill: selectedFill,
            strokeOpacity: strokeOpacity,
            activeStrokeOpacity: activeStrokeOpacity,
            lift: lift,
            allowsHoverFeedback: allowsHoverFeedback
        ))
    }

    func staticSurface(
        isSelected: Bool = false,
        tint: Color = AppPalette.brand,
        radius: CGFloat = AppPalette.cardRadius,
        fill: Color = AppPalette.card,
        selectedFill: Color? = nil,
        strokeOpacity: Double = 0.34,
        activeStrokeOpacity: Double = 0.58
    ) -> some View {
        modifier(InteractiveSurfaceModifier(
            isSelected: isSelected,
            tint: tint,
            radius: radius,
            fill: fill,
            hoverFill: fill,
            selectedFill: selectedFill,
            strokeOpacity: strokeOpacity,
            activeStrokeOpacity: activeStrokeOpacity,
            lift: 0,
            allowsHoverFeedback: false
        ))
    }

    func respectsReducedMotion() -> some View {
        modifier(ReducedMotionRespectingModifier())
    }

    /// Apply a translucent material background with rounded corners and optional border.
    #if canImport(AppKit)
    func materialBackground(
        _ material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        cornerRadius: CGFloat = AppPalette.panelRadius,
        borderColor: Color? = nil,
        borderWidth: CGFloat = 1
    ) -> some View {
        modifier(MaterialBackgroundModifier(
            material: material,
            blendingMode: blendingMode,
            cornerRadius: cornerRadius,
            borderColor: borderColor,
            borderWidth: borderWidth
        ))
    }
    #else
    /// iOS material background using SwiftUI's native material system.
    func materialBackground(
        _ material: Material = .regularMaterial,
        blendingMode: Material = .regularMaterial,
        cornerRadius: CGFloat = AppPalette.panelRadius,
        borderColor: Color? = nil,
        borderWidth: CGFloat = 1
    ) -> some View {
        modifier(MaterialBackgroundModifier(
            material: material,
            blendingMode: blendingMode,
            cornerRadius: cornerRadius,
            borderColor: borderColor,
            borderWidth: borderWidth
        ))
    }
    #endif
}
