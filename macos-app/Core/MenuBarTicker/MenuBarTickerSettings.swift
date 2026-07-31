#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SwiftUI

enum MenuBarTickerTextColorMode: String, Codable, CaseIterable, Identifiable {
    case system
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .custom: return "自定义"
        }
    }
}

enum MenuBarTickerDimensionMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "自动"
        case .manual: return "手动"
        }
    }
}

enum MenuBarTickerLayoutMode: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "左右"
        case .vertical: return "上下"
        }
    }

    var icon: String {
        switch self {
        case .horizontal: return "arrow.left.and.right"
        case .vertical: return "arrow.up.and.down"
        }
    }
}

struct MenuBarTickerAppearance: Codable, Hashable {
    var textColorMode: MenuBarTickerTextColorMode
    var customTextColorHex: String
    var fontSize: Double
    var isBold: Bool
    var layoutMode: MenuBarTickerLayoutMode
    var spacingMode: MenuBarTickerDimensionMode
    var manualSpacing: Double
    var widthMode: MenuBarTickerDimensionMode
    var manualWidth: Double

    static let minFontSize: Double = 7
    static let maxFontSize: Double = 14
    static let minManualSpacing: Double = 0
    static let maxManualSpacing: Double = 28
    static let minManualWidth: Double = 72
    static let maxManualWidth: Double = 360

    static let `default` = MenuBarTickerAppearance(
        textColorMode: .system,
        customTextColorHex: "#1F292E",
        fontSize: 9,
        isBold: false,
        layoutMode: .vertical,
        spacingMode: .automatic,
        manualSpacing: 10,
        widthMode: .automatic,
        manualWidth: 180
    )

    private enum AppearanceCodingKeys: String, CodingKey {
        case textColorMode, customTextColorHex, fontSize, isBold
        case layoutMode, spacingMode, manualSpacing, widthMode, manualWidth
    }

    init(
        textColorMode: MenuBarTickerTextColorMode = .system,
        customTextColorHex: String = "#1F292E",
        fontSize: Double = 9,
        isBold: Bool = false,
        layoutMode: MenuBarTickerLayoutMode = .vertical,
        spacingMode: MenuBarTickerDimensionMode = .automatic,
        manualSpacing: Double = 10,
        widthMode: MenuBarTickerDimensionMode = .automatic,
        manualWidth: Double = 180
    ) {
        self.textColorMode = textColorMode
        self.customTextColorHex = customTextColorHex
        self.fontSize = fontSize
        self.isBold = isBold
        self.layoutMode = layoutMode
        self.spacingMode = spacingMode
        self.manualSpacing = manualSpacing
        self.widthMode = widthMode
        self.manualWidth = manualWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AppearanceCodingKeys.self)
        textColorMode = try c.decodeIfPresent(MenuBarTickerTextColorMode.self, forKey: .textColorMode) ?? .system
        customTextColorHex = try c.decodeIfPresent(String.self, forKey: .customTextColorHex) ?? "#1F292E"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 9
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        layoutMode = try c.decodeIfPresent(MenuBarTickerLayoutMode.self, forKey: .layoutMode) ?? Self.default.layoutMode
        spacingMode = try c.decodeIfPresent(MenuBarTickerDimensionMode.self, forKey: .spacingMode) ?? .automatic
        manualSpacing = try c.decodeIfPresent(Double.self, forKey: .manualSpacing) ?? 10
        widthMode = try c.decodeIfPresent(MenuBarTickerDimensionMode.self, forKey: .widthMode) ?? .automatic
        manualWidth = try c.decodeIfPresent(Double.self, forKey: .manualWidth) ?? 180
    }

    func normalized() -> MenuBarTickerAppearance {
        var copy = self
        copy.fontSize = min(max(copy.fontSize, Self.minFontSize), Self.maxFontSize)
        copy.manualSpacing = min(max(copy.manualSpacing, Self.minManualSpacing), Self.maxManualSpacing)
        copy.manualWidth = min(max(copy.manualWidth, Self.minManualWidth), Self.maxManualWidth)
        if copy.layoutMode == .vertical,
           copy.widthMode == .manual,
           copy.manualWidth == Self.default.manualWidth {
            copy.widthMode = .automatic
        }
        // Hex validation stays cross-platform (no AppKit dependency).
        if !Self.isValidHex(copy.customTextColorHex) {
            copy.customTextColorHex = Self.default.customTextColorHex
        }
        return copy
    }

    /// Cross-platform hex validation. True when `hex` is a valid 6-digit RGB color string.
    static func isValidHex(_ hex: String) -> Bool {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, Int(raw, radix: 16) != nil else { return false }
        return true
    }

    var swiftUIColor: Color {
        switch textColorMode {
        case .system:
            return AppPalette.ink
        case .custom:
            return Color(hex: customTextColorHex) ?? AppPalette.ink
        }
    }

    #if canImport(AppKit)
    var fontWeight: NSFont.Weight {
        isBold ? .bold : .medium
    }

    var nsColor: NSColor? {
        switch textColorMode {
        case .system:
            return nil
        case .custom:
            return MenuBarTickerAppearance.nsColor(hex: customTextColorHex) ?? .labelColor
        }
    }

    static func normalizedHex(from color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func nsColor(hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    #endif
}

enum MenuBarTickerLayoutMetrics {
    static let previewHorizontalPadding: CGFloat = 6
    static let previewVerticalPadding: CGFloat = 5

    private static let horizontalStatusHorizontalPadding: CGFloat = 3
    private static let verticalStatusHorizontalPadding: CGFloat = 1

    static func statusHorizontalPadding(for appearance: MenuBarTickerAppearance) -> CGFloat {
        appearance.layoutMode == .vertical ? verticalStatusHorizontalPadding : horizontalStatusHorizontalPadding
    }

    static func automaticStatusSpacing(for appearance: MenuBarTickerAppearance) -> CGFloat {
        appearance.layoutMode == .horizontal ? max(8, CGFloat(appearance.fontSize) * 1.05) : 0
    }

    static func statusImageWidth(measurements: [CGFloat], appearance: MenuBarTickerAppearance) -> CGFloat {
        let padding = statusHorizontalPadding(for: appearance)
        let measuredWidth: CGFloat
        switch appearance.layoutMode {
        case .horizontal:
            let spacing = appearance.spacingMode == .manual
                ? CGFloat(appearance.manualSpacing)
                : automaticStatusSpacing(for: appearance)
            measuredWidth = measurements.reduce(0, +)
                + CGFloat(max(0, measurements.count - 1)) * spacing
                + padding * 2
        case .vertical:
            measuredWidth = (measurements.max() ?? 0) + padding * 2
        }
        return ceil(appearance.widthMode == .manual ? CGFloat(appearance.manualWidth) : measuredWidth)
    }
}

struct MenuBarTickerSettings: Codable, Hashable {
    var isEnabled: Bool
    var maxVisibleItems: Int
    var selections: [MenuBarTickerSelection]
    var appearance: MenuBarTickerAppearance
    var carouselIntervalSeconds: Double

    static let storageKey = "qieman.dashboard.menuBarTickerSettings.v1"
    static let verticalLayoutMigrationKey = "qieman.dashboard.menuBarTickerSettings.v1.verticalLayoutMigrated"
    static let maxVisibleItemsLimit = 2
    static let minCarouselInterval: Double = 2
    static let maxCarouselInterval: Double = 30

    static let `default` = MenuBarTickerSettings(
        isEnabled: true,
        maxVisibleItems: 2,
        selections: [.kind(.overallDailyPct), .kind(.overallProfitPct), .kind(.totalValue)],
        appearance: .default,
        carouselIntervalSeconds: 5
    )

    init(
        isEnabled: Bool,
        maxVisibleItems: Int,
        selections: [MenuBarTickerSelection],
        appearance: MenuBarTickerAppearance = .default,
        carouselIntervalSeconds: Double = 5
    ) {
        self.isEnabled = isEnabled
        self.maxVisibleItems = maxVisibleItems
        self.selections = selections
        self.appearance = appearance
        self.carouselIntervalSeconds = carouselIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case maxVisibleItems
        case selections
        case enabledKinds
        case holdingSelections
        case appearance
        case carouselIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? Self.default.isEnabled
        maxVisibleItems = try container.decodeIfPresent(Int.self, forKey: .maxVisibleItems) ?? Self.default.maxVisibleItems
        appearance = try container.decodeIfPresent(MenuBarTickerAppearance.self, forKey: .appearance) ?? Self.default.appearance
        carouselIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .carouselIntervalSeconds) ?? Self.default.carouselIntervalSeconds

        if let decoded = try? container.decodeIfPresent([MenuBarTickerSelection].self, forKey: .selections) {
            selections = decoded
        } else {
            let kinds = try container.decodeIfPresent([MenuBarTickerKind].self, forKey: .enabledKinds) ?? []
            let holdings = try container.decodeIfPresent([MenuBarHoldingMetricSelection].self, forKey: .holdingSelections) ?? []
            selections = kinds.map { .kind($0) } + holdings.map { .holding($0) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(maxVisibleItems, forKey: .maxVisibleItems)
        try container.encode(selections, forKey: .selections)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(carouselIntervalSeconds, forKey: .carouselIntervalSeconds)
    }

    static func load() -> MenuBarTickerSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MenuBarTickerSettings.self, from: data) else {
            return .default
        }
        var loaded = decoded.normalized()
        if !UserDefaults.standard.bool(forKey: verticalLayoutMigrationKey) {
            if loaded.appearance.layoutMode == .horizontal {
                loaded.appearance.layoutMode = .vertical
                if let data = try? JSONEncoder().encode(loaded.normalized()) {
                    UserDefaults.standard.set(data, forKey: Self.storageKey)
                }
            }
            UserDefaults.standard.set(true, forKey: verticalLayoutMigrationKey)
        }
        return loaded.normalized()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func normalized() -> MenuBarTickerSettings {
        var copy = self
        copy.maxVisibleItems = min(max(copy.maxVisibleItems, 1), Self.maxVisibleItemsLimit)
        copy.carouselIntervalSeconds = min(max(copy.carouselIntervalSeconds, Self.minCarouselInterval), Self.maxCarouselInterval)
        copy.appearance = copy.appearance.normalized()

        let validKinds = Set(MenuBarTickerKind.allCases)
        var seenIDs = Set<String>()
        copy.selections = copy.selections.filter { selection in
            guard seenIDs.insert(selection.id).inserted else { return false }
            switch selection {
            case .kind(let kind): return validKinds.contains(kind)
            case .holding: return true
            }
        }
        return copy
    }
}
