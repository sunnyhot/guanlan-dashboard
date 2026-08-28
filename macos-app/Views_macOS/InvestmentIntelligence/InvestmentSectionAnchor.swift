import SwiftUI

/// 区段锚点滚动与高亮的协调器。
/// 由 `EnhancementCenterView` 持有并经 environment 注入。
final class InvestmentSectionAnchorModel: ObservableObject {
    @Published var scrollTo: InvestmentTodayResearchRow.Kind?
    @Published var highlighted: InvestmentTodayResearchRow.Kind?
}

private struct InvestmentSectionAnchorsKey: EnvironmentKey {
    static let defaultValue: InvestmentSectionAnchorModel? = nil
}

extension EnvironmentValues {
    var investmentSectionAnchors: InvestmentSectionAnchorModel? {
        get { self[InvestmentSectionAnchorsKey.self] }
        set { self[InvestmentSectionAnchorsKey.self] = newValue }
    }
}

/// 区段锚点:滚动 id + 命中高亮描边(1 秒后由协调器清除)。
private struct InvestmentSectionAnchorModifier: ViewModifier {
    let kind: InvestmentTodayResearchRow.Kind
    @Environment(\.investmentSectionAnchors) private var anchors

    func body(content: Content) -> some View {
        content
            .id(kind.rawValue)
            .overlay {
                if anchors?.highlighted == kind {
                    RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                        .strokeBorder(AppPalette.brand.opacity(0.55), lineWidth: 1.5)
                        .padding(-AppPalette.spaceXS)
                        .allowsHitTesting(false)
                }
            }
            .animation(AppPalette.motionStandard, value: anchors?.highlighted)
    }
}

extension View {
    func investmentSectionAnchor(_ kind: InvestmentTodayResearchRow.Kind) -> some View {
        modifier(InvestmentSectionAnchorModifier(kind: kind))
    }
}

// 说明：「今日研判」摘要卡已移除（产品决定），锚点滚动/高亮基础设施
// 由本文件继续承载——区段仍可用锚点定位（滚动 id + 命中高亮）。
