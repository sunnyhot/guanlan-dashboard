#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

enum AppPalette {
    // MARK: - Radii

    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let badgeRadius: CGFloat = 6
    static let iconBoxRadius: CGFloat = 6
    /// 色块 / 图例点 / 状态条等微型圆角（≤ 8x8 的纯色块）。
    static let swatchRadius: CGFloat = 2

    // MARK: - Spacing Tokens

    /// Micro spacing: icon-to-text, tight gaps (4pt)
    static let spaceXS: CGFloat = 4
    /// Small spacing: within component rows (6-8pt)
    static let spaceS: CGFloat = 8
    /// Medium spacing: between elements inside a card (10-12pt)
    static let spaceM: CGFloat = 12
    /// Large spacing: between cards/sections (14-16pt)
    static let spaceL: CGFloat = 16
    /// Extra-large spacing: hero/panel padding (18-20pt)
    static let spaceXL: CGFloat = 20

    /// Content area horizontal padding (used by section ScrollView containers)
    static let contentPadding: CGFloat = 16
    /// Toolbar horizontal padding
    static let toolbarPaddingH: CGFloat = 16
    /// Toolbar top padding
    static let toolbarPaddingTop: CGFloat = 16
    /// Toolbar bottom padding
    static let toolbarPaddingBottom: CGFloat = 14

    // MARK: - Motion / Interaction Tokens

    static let motionFastDuration: Double = 0.12
    static let motionStandardDuration: Double = 0.18
    static let motionSectionDuration: Double = 0.20
    static let motionSlowDuration: Double = 0.25

    static var motionFast: Animation {
        .easeOut(duration: motionFastDuration)
    }

    static var motionStandard: Animation {
        .easeOut(duration: motionStandardDuration)
    }

    static var motionSection: Animation {
        .easeInOut(duration: motionSectionDuration)
    }

    static var motionSlow: Animation {
        .easeInOut(duration: motionSlowDuration)
    }

    static var motionSpring: Animation {
        .interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08)
    }

    static let hoverLift: CGFloat = 1.2
    static let selectionStrokeOpacity: Double = 0.76
    static let selectionGlowOpacity: Double = 0.16
    static let selectionGlowRadius: CGFloat = 12
    static let selectionRailWidth: CGFloat = 3
    static let sidebarRowRadius: CGFloat = 9

    // MARK: - Typography Tokens

    /// 语义字号阶梯，对应全仓 .font(.system(size:)) 的实际分布（89% 集中在 8-13pt）。
    enum AppFontSize: CGFloat {
        case caption2 = 8
        case caption = 9
        case footnote = 10
        case subheadline = 11
        case body = 12
        case headline = 13
        case title3 = 14
        case title2 = 16
        case title = 18
        case largeTitle = 22
    }

    /// 统一字体构造入口，替代散落的 .font(.system(size: N, weight: W))。
    /// 支持自动响应 Bold Text 辅助功能设置（legibilityWeight）。
    static func appFont(
        _ size: AppFontSize,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        legibilityWeight: Font.Weight? = nil
    ) -> Font {
        let resolvedWeight = legibilityWeight == .bold ? .bold : weight
        return .system(size: size.rawValue, weight: resolvedWeight, design: design)
    }

    // MARK: - Border / Stroke Opacity Presets

    static let borderLight: Double = 0.32
    static let borderMedium: Double = 0.42
    static let borderStrong: Double = 0.50
    static let borderHeavy: Double = 0.65
    static let borderFaint: Double = 0.22
    static let borderSubtle: Double = 0.35

    // MARK: - Surfaces (semantic)

    /// Elevated panel background (settings panels, filter panels).
    static let panelBackground = card

    // MARK: - Brand & Base Surfaces

    /// Electric blue brand accent
    static let brand = adaptive(light: rgb(0.16, 0.40, 0.88), dark: rgb(0.31, 0.55, 1.00))
    static let brandSoft = adaptive(light: rgb(0.88, 0.93, 1.00), dark: rgb(0.10, 0.15, 0.28))
    static let selectionFill = brandSoft
    static let selectionStroke = brand
    static let selectionGlow = brand
    /// Deep navy background
    static let surface = adaptive(light: rgb(0.94, 0.96, 0.99), dark: rgb(0.04, 0.05, 0.09))
    static let surfaceVariant = adaptive(light: rgb(0.87, 0.91, 0.96), dark: rgb(0.05, 0.07, 0.12))
    /// Card background — semi-transparent deep navy
    static let card = adaptive(light: rgb(1.00, 1.00, 1.00), dark: rgb(0.10, 0.12, 0.18))
    /// Card strong / elevated
    static let cardStrong = adaptive(light: rgb(0.95, 0.97, 1.00), dark: rgb(0.13, 0.15, 0.22))
    /// Card hover state
    static let cardHover = adaptive(light: rgb(0.90, 0.94, 0.99), dark: rgb(0.16, 0.18, 0.26))

    // MARK: - Text

    /// Primary text
    static let ink = adaptive(light: rgb(0.04, 0.06, 0.11), dark: rgb(0.92, 0.94, 0.98))
    /// Secondary / muted text
    static let muted = adaptive(light: rgb(0.28, 0.33, 0.43), dark: rgb(0.55, 0.58, 0.68))
    /// Text on brand-colored surfaces
    static let onBrand = adaptive(light: rgb(0.99, 0.99, 1.00), dark: rgb(0.99, 0.99, 1.00))

    // MARK: - Borders / Lines

    /// Standard hairline border for cards, panels, chips.
    static let hairline = adaptive(light: rgb(0.70, 0.76, 0.86), dark: rgb(0.18, 0.20, 0.28))
    /// Legacy alias — maps to `hairline`.
    static let line = hairline

    // MARK: - Control Fill

    /// Default input/control fill (text fields, segmented chips).
    static let controlFill = cardStrong

    // MARK: - Legacy Aliases (backward compat)

    static let paper = surface

    // MARK: - Semantic Colors

    static let positive = adaptive(light: rgb(0.02, 0.48, 0.28), dark: rgb(0.20, 0.78, 0.44))
    static let warning = adaptive(light: rgb(0.66, 0.40, 0.04), dark: rgb(0.96, 0.66, 0.24))
    static let danger = adaptive(light: rgb(0.70, 0.12, 0.12), dark: rgb(0.96, 0.36, 0.32))
    static let info = adaptive(light: rgb(0.10, 0.35, 0.70), dark: rgb(0.38, 0.62, 0.96))
    static let accentWarm = adaptive(light: rgb(0.62, 0.34, 0.08), dark: rgb(0.90, 0.62, 0.28))

    // MARK: - Chinese Market Convention (red=up, green=down)

    static let marketGain = adaptive(light: rgb(0.70, 0.12, 0.12), dark: rgb(0.96, 0.36, 0.32))
    static let marketLoss = adaptive(light: rgb(0.02, 0.48, 0.28), dark: rgb(0.20, 0.78, 0.44))

    static func marketTint(for value: Double?) -> Color {
        guard let value else { return muted }
        if value > 0 { return marketGain }
        if value < 0 { return marketLoss }
        return muted
    }

    // MARK: - Chart Palette

    /// 全仓环形图/饼图统一调色板。替换原 4 处逐字重复的 7 色数组。
    static let chartPalette: [Color] = [
        brand,
        info,
        accentWarm,
        positive,
        warning,
        danger,
        muted,
    ]

    /// 按 index 在 chartPalette 中循环取色,等价于原 `[index % 7]`,
    /// 但调色板长度变化时自动收敛,避免硬编码 7。防御负 index。
    static func chartColor(index: Int) -> Color {
        guard !chartPalette.isEmpty else { return muted }
        let count = chartPalette.count
        return chartPalette[(index % count + count) % count]
    }

    // MARK: - Gradients

    static var canvasGradient: LinearGradient {
        LinearGradient(
            colors: [
                surface,
                adaptive(light: rgb(0.90, 0.93, 0.98), dark: rgb(0.03, 0.05, 0.10)).opacity(0.92),
                brandSoft.opacity(0.62),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Unified Stroke Opacities

    /// Default border stroke opacity for cards & panels.
    static let strokeDefault: Double = 0.50
    /// Subtle / lighter border for inline elements (chips, badges).
    static let strokeSubtle: Double = 0.35
    /// Strong / emphasis border (selected states, settings).
    static let strokeStrong: Double = 0.70

    // MARK: - Unified Background Opacities

    /// Opacity used for toolbar background overlay.
    static let bgToolbar: Double = 0.96
    /// Opacity for default row fill.
    static let bgDefault: Double = 0.76

    // MARK: - Accent Tint Opacities (for icon backgrounds)

    /// Opacity for accent-tinted icon backgrounds.
    static let accentFill: Double = 0.14
    /// Opacity for accent-tinted icon border.
    static let accentBorder: Double = 0.22
    /// Opacity for subtle accent background (e.g. pill, status).
    static let accentSubtle: Double = 0.10
    /// Opacity for text on accent fill.
    static let accentOnFill: Double = 0.09

    // MARK: - Shadow Presets

    /// Shadow for section-level cards (SectionCard).
    static let sectionShadowColor: Color = .black.opacity(0.18)
    static let sectionShadowRadius: CGFloat = 12
    static let sectionShadowY: CGFloat = 4

    /// Shadow for panel-level containers (SettingsPanel).
    static let panelShadowColor: Color = .black.opacity(0.05)
    static let panelShadowRadius: CGFloat = 8
    static let panelShadowY: CGFloat = 2

    /// Shadow for floating sidebar.
    static let sidebarShadowColor: Color = .black.opacity(0.08)
    static let sidebarShadowRadius: CGFloat = 4
    static let sidebarShadowX: CGFloat = 1

    // MARK: - Reusable Stroke Overlay

    /// Standard card/panel border stroke overlay using the line color.
    static func borderOverlay(radius: CGFloat, opacity: Double = borderStrong) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .stroke(AppPalette.line.opacity(opacity), lineWidth: 1)
    }

    // MARK: - Helpers

    private static func adaptive(light: Color, dark: Color) -> Color {
        // Dynamic light/dark color that resolves against the current color scheme.
        // Uses the AppKit/UIKit dynamic color providers under the hood; on the
        // opposite platform the corresponding branch returns the matching Color.
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua: return NSColor(dark)
            default: return NSColor(light)
            }
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        return light
        #endif
    }

    /// Cross-platform sRGB color builder. Returns SwiftUI Color so adaptive() and
    /// direct color tokens share one type on both macOS and iOS.
    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - Color Hex Initializer (cross-platform)

extension Color {
    /// Initializes a Color from a 6-digit hex string (e.g. "#FF8800" or "FF8800").
    /// Returns nil for invalid input. Cross-platform (AppKit + UIKit).
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

// MARK: - View Extension: Unified Stroke & Card Style

extension View {
    /// Applies a standard card stroke border.
    func cardStroke(_ radius: CGFloat = AppPalette.cardRadius, opacity: Double = AppPalette.strokeDefault) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(AppPalette.hairline.opacity(opacity), lineWidth: 1)
        )
    }

    /// Applies a standard panel stroke border.
    func panelStroke(opacity: Double = AppPalette.strokeDefault) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.hairline.opacity(opacity), lineWidth: 1)
        )
    }

    /// Applies section-level shadow.
    func sectionShadow() -> some View {
        shadow(color: AppPalette.sectionShadowColor, radius: AppPalette.sectionShadowRadius, y: AppPalette.sectionShadowY)
    }

    /// Applies the standard input field style (background + border).
    func inputFieldStyle() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(AppPalette.hairline.opacity(AppPalette.strokeStrong), lineWidth: 1)
            )
    }

    /// Applies an accent-tinted icon container style.
    func accentIconStyle(tint: Color, size: CGFloat = 26) -> some View {
        self
            .frame(width: size, height: size)
            .background(tint.opacity(AppPalette.accentFill), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1)
            )
    }
}
