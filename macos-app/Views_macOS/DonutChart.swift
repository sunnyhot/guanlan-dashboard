import SwiftUI
import Charts

// MARK: - DonutSlice

/// 环形图/饼图的单个扇区数据。颜色由调用方决定(自带 color)。
struct DonutSlice: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

// MARK: - DonutChart

/// 通用环形/饼图:只负责画环 + 渲染调用方传入的中心内容。
/// 不内置图例、不内置调色板;颜色由 `DonutSlice.color` 决定。
/// 调用方负责空数据态(不要传入空 slices,否则会画出空环)。
struct DonutChart<Center: View>: View {
    let slices: [DonutSlice]
    let innerRadius: CGFloat
    let angularInset: CGFloat
    let cornerRadius: CGFloat
    let size: CGFloat?
    let angleTitle: String
    let center: () -> Center

    init(
        slices: [DonutSlice],
        innerRadius: CGFloat = 0.64,
        angularInset: CGFloat = 1.5,
        cornerRadius: CGFloat = 3,
        size: CGFloat? = 142,
        angleTitle: String = "value",
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.slices = slices
        self.innerRadius = innerRadius
        self.angularInset = angularInset
        self.cornerRadius = cornerRadius
        self.size = size
        self.angleTitle = angleTitle
        self.center = center
    }

    var body: some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value(angleTitle, slice.value),
                    innerRadius: .ratio(innerRadius),
                    angularInset: angularInset
                )
                .foregroundStyle(slice.color)
                .cornerRadius(cornerRadius)
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .accessibilityHidden(true)

            center()
        }
        .modifier(OptionalSquareFrame(size: size))
    }
}

private struct OptionalSquareFrame: ViewModifier {
    let size: CGFloat?
    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size, height: size)
        } else {
            content
        }
    }
}

// MARK: - DonutLegend

enum DonutLegendSwatch {
    case circle
    case roundedRect
}

/// 环形图侧边图例。色块形状(Circle 7×7 / RoundedRectangle 8×8)、label、
/// 尾部内容均由调用方闭包决定。
struct DonutLegend<Item: Identifiable, Label: View, Trailing: View>: View {
    let items: [Item]
    let swatchShape: DonutLegendSwatch
    let swatchColor: (Item) -> Color
    let label: (Item) -> Label
    let trailing: (Item) -> Trailing
    let rowSpacing: CGFloat
    let verticalSpacing: CGFloat
    let spacerMinLength: CGFloat
    let accessibilityLabel: ((Item) -> String?)?

    init(
        items: [Item],
        swatchShape: DonutLegendSwatch,
        swatchColor: @escaping (Item) -> Color,
        @ViewBuilder label: @escaping (Item) -> Label,
        @ViewBuilder trailing: @escaping (Item) -> Trailing,
        rowSpacing: CGFloat = 6,
        verticalSpacing: CGFloat = 8,
        spacerMinLength: CGFloat = 4,
        accessibilityLabel: ((Item) -> String?)? = nil
    ) {
        self.items = items
        self.swatchShape = swatchShape
        self.swatchColor = swatchColor
        self.label = label
        self.trailing = trailing
        self.rowSpacing = rowSpacing
        self.verticalSpacing = verticalSpacing
        self.spacerMinLength = spacerMinLength
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            ForEach(items) { item in
                HStack(spacing: rowSpacing) {
                    swatchView(for: item).accessibilityHidden(true)
                    label(item)
                    Spacer(minLength: spacerMinLength)
                    trailing(item)
                }
                .accessibilityElement(children: .combine)
                .modifier(OptionalAccessibilityLabel(text: accessibilityLabel?(item)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func swatchView(for item: Item) -> some View {
        switch swatchShape {
        case .circle:
            Circle().fill(swatchColor(item)).frame(width: 7, height: 7)
        case .roundedRect:
            RoundedRectangle(cornerRadius: 2).fill(swatchColor(item)).frame(width: 8, height: 8)
        }
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text {
            content.accessibilityLabel(text)
        } else {
            content
        }
    }
}
