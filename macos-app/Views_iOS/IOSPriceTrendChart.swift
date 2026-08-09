#if os(iOS)
import SwiftUI

// MARK: - iOS 价格/净值走势图（纯 SwiftUI Path 自绘，布局分区）
//
// 不用绝对定位的 ZStack，而是 HStack 分区：左 Y 轴列 | 绘图区（含底部 X 轴行）。
// 折线只在绘图区内画，坐标轴标签物理隔离，绝不重叠。

struct IOSPriceTrendChart: View {
    let points: [PersonalWatchlistDailyPoint]
    let costPrice: Double?

    @State private var visibleStart: Int = 0
    @State private var visibleEnd: Int = 0
    @State private var hasInitialized = false
    @State private var selectedIndex: Int?
    @State private var panLastX: CGFloat?
    @State private var zoomBaseStart: Int = 0
    @State private var zoomBaseEnd: Int = 0

    private var totalCount: Int { points.count }
    private var isZoomed: Bool { (visibleEnd - visibleStart) < max(1, totalCount - 1) }

    private var visiblePoints: [PersonalWatchlistDailyPoint] {
        guard totalCount > 0 else { return [] }
        let start = max(0, min(visibleStart, totalCount - 1))
        let end = max(start, min(visibleEnd, totalCount - 1))
        guard start <= end else { return [] }
        return Array(points[start...end])
    }

    private var yDomain: (min: Double, max: Double) {
        var prices = points.map(\.price)
        if let costPrice, costPrice > 0 { prices.append(costPrice) }
        guard let lo = prices.min(), let hi = prices.max(), hi > lo else { return (0, 1) }
        let spread = max(hi - lo, abs(hi) * 0.01, 0.0001)
        return (lo - spread * 0.12, hi + spread * 0.16)
    }

    var body: some View {
        GeometryReader { geo in
            let domain = yDomain
            let visible = visiblePoints
            let count = visible.count
            // 分区：左 Y 轴宽 42，右留 6，底 X 轴高 16，上留 8
            let axisW: CGFloat = 42
            let plotW = max(0, geo.size.width - axisW - 6)
            let plotH = max(0, geo.size.height - 8 - 16)

            HStack(alignment: .top, spacing: 0) {
                // 左 Y 轴列
                yAxisColumn(domain: domain, height: plotH, topPad: 8)
                    .frame(width: axisW)

                // 绘图区 + 底部 X 轴
                VStack(alignment: .leading, spacing: 0) {
                    plotArea(visible: visible, count: count, domain: domain,
                             plotW: plotW, plotH: plotH)
                        .frame(width: plotW, height: plotH)
                    xAxisRow(visible: visible, count: count, plotW: plotW)
                        .frame(width: plotW, height: 16)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear { initRangeIfNeeded() }
    }

    // MARK: Y 轴列（4 档标签 + 网格线不画这里，留给绘图区）

    private func yAxisColumn(domain: (min: Double, max: Double), height: CGFloat, topPad: CGFloat) -> some View {
        let values = (0..<4).map { i -> (Double, CGFloat) in
            let ratio = Double(i) / 3.0
            let value = domain.max - (domain.max - domain.min) * ratio
            let y = topPad + CGFloat(ratio) * height
            return (value, y)
        }
        return ZStack(alignment: .trailing) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                Text(formatPrice(item.0))
                    .font(.system(size: 9))
                    .foregroundStyle(IOSDesign.muted)
                    .frame(width: 38, height: 12)
                    .position(x: 21, y: item.1)
            }
        }
    }

    // MARK: 绘图区（网格线 + 面积 + 折线 + 成本线 + 选中 + 交互）

    private func plotArea(
        visible: [PersonalWatchlistDailyPoint],
        count: Int,
        domain: (min: Double, max: Double),
        plotW: CGFloat,
        plotH: CGFloat
    ) -> some View {
        let pointAt: (Int) -> CGPoint = { i in
            let x = count <= 1 ? plotW / 2 : CGFloat(i) / CGFloat(count - 1) * plotW
            let ratio = domain.max > domain.min ? (visible[i].price - domain.min) / (domain.max - domain.min) : 0.5
            let y = plotH - CGFloat(ratio) * plotH
            return CGPoint(x: x, y: y)
        }

        return ZStack(alignment: .topLeading) {
            // 网格线（横向 4 条，在绘图区内）
            ForEach(0..<4, id: \.self) { i in
                let ratio = Double(i) / 3.0
                let y = CGFloat(ratio) * plotH
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: plotW, y: y))
                }
                .stroke(IOSDesign.ink.opacity(0.06), lineWidth: 1)
            }

            // 渐变面积
            if count >= 2 {
                Path { p in
                    let first = pointAt(0)
                    p.move(to: CGPoint(x: first.x, y: plotH))
                    p.addLine(to: first)
                    for i in 1..<count { p.addLine(to: pointAt(i)) }
                    let last = pointAt(count - 1)
                    p.addLine(to: CGPoint(x: last.x, y: plotH))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IOSDesign.accent.opacity(0.22), IOSDesign.accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            }

            // 成本价虚线
            if let costPrice, costPrice > 0, domain.max > domain.min {
                let ratio = (costPrice - domain.min) / (domain.max - domain.min)
                let y = plotH - CGFloat(ratio) * plotH
                if y > 0 && y < plotH {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: plotW, y: y))
                    }
                    .stroke(IOSDesign.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }

            // 折线
            if count >= 2 {
                Path { p in
                    p.move(to: pointAt(0))
                    for i in 1..<count { p.addLine(to: pointAt(i)) }
                }
                .stroke(IOSDesign.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

            // 选中点
            if let selectedIndex, points.indices.contains(selectedIndex) {
                let visIdx = selectedIndex - visibleStartClamped
                if visIdx >= 0 && visIdx < count {
                    let pt = pointAt(visIdx)
                    // 竖线
                    Path { p in
                        p.move(to: CGPoint(x: pt.x, y: 0))
                        p.addLine(to: CGPoint(x: pt.x, y: plotH))
                    }
                    .stroke(IOSDesign.ink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    // 圆点
                    Circle().fill(IOSDesign.accent).frame(width: 9, height: 9).position(pt)
                    // 气泡（夹在绘图区内）
                    priceBubble(points[selectedIndex])
                        .fixedSize()
                        .position(x: min(max(pt.x, 45), plotW - 45), y: max(pt.y - 24, 16))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if isZoomed {
                        panByDrag(localX: value.location.x, plotW: plotW)
                    } else {
                        selectByX(localX: value.location.x, plotW: plotW, count: count)
                    }
                }
                .onEnded { _ in panLastX = nil }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let centerRatio = max(0, min(1, value.startLocation.x / max(plotW, 1)))
                    if abs(value.magnification - 1) < 0.02 {
                        zoomBaseStart = visibleStart
                        zoomBaseEnd = visibleEnd
                    }
                    applyZoom(centerRatio: centerRatio, scale: value.magnification)
                }
        )
        .onTapGesture(count: 2) { resetZoom() }
        .onTapGesture(count: 1) { if isZoomed { selectedIndex = nil } }
    }

    // MARK: X 轴行（3 个均匀日期标签）

    private func xAxisRow(visible: [PersonalWatchlistDailyPoint], count: Int, plotW: CGFloat) -> some View {
        let positions: [Int] = count >= 3 ? [0, (count - 1) / 2, count - 1] : Array(0..<max(count, 0))
        return ZStack(alignment: .topLeading) {
            ForEach(positions, id: \.self) { idx in
                guard idx < visible.count else { return AnyView(EmptyView()) }
                let x = count <= 1 ? plotW / 2 : CGFloat(idx) / CGFloat(count - 1) * plotW
                return AnyView(
                    Text(shortDate(visible[idx].date))
                        .font(.system(size: 9))
                        .foregroundStyle(IOSDesign.muted)
                        .fixedSize()
                        .position(x: x, y: 8)
                )
            }
        }
    }

    private var visibleStartClamped: Int {
        max(0, min(visibleStart, max(0, totalCount - 1)))
    }

    // MARK: 手势处理

    private func selectByX(localX: CGFloat, plotW: CGFloat, count: Int) {
        guard count > 0, plotW > 0 else { selectedIndex = nil; return }
        let ratio = max(0, min(1, localX / plotW))
        let idx = count == 1 ? 0 : Int((ratio * CGFloat(count - 1)).rounded())
        selectedIndex = visibleStartClamped + min(max(idx, 0), count - 1)
    }

    private func panByDrag(localX: CGFloat, plotW: CGFloat) {
        let width = visibleEnd - visibleStartClamped
        guard width > 0, plotW > 0 else { return }
        if let lastX = panLastX {
            let shift = Int(((localX - lastX) / plotW * CGFloat(width)).rounded())
            panWindow(by: -shift)
        }
        panLastX = localX
    }

    private func panWindow(by delta: Int) {
        guard delta != 0 else { return }
        let width = visibleEnd - visibleStartClamped
        var s = visibleStartClamped + delta
        var e = visibleEnd + delta
        if s < 0 { s = 0; e = width }
        if e > totalCount - 1 { e = totalCount - 1; s = max(0, e - width) }
        visibleStart = s
        visibleEnd = e
        if let i = selectedIndex, !(s...e).contains(i) { selectedIndex = nil }
    }

    private func applyZoom(centerRatio: CGFloat, scale: CGFloat) {
        let baseWidth = zoomBaseEnd - zoomBaseStart
        guard baseWidth > 0 else { return }
        let newWidth = max(30, min(max(1, totalCount - 1), Int((Double(baseWidth) / Double(scale)).rounded())))
        let center = zoomBaseStart + Int(Double(baseWidth) * Double(centerRatio))
        var s = center - Int(Double(newWidth) * Double(centerRatio))
        var e = s + newWidth
        if s < 0 { s = 0; e = min(totalCount - 1, newWidth) }
        if e > totalCount - 1 { e = totalCount - 1; s = max(0, e - newWidth) }
        visibleStart = s
        visibleEnd = e
    }

    private func resetZoom() {
        visibleStart = 0
        visibleEnd = max(0, totalCount - 1)
        selectedIndex = nil
    }

    private func initRangeIfNeeded() {
        guard !hasInitialized, totalCount > 0 else { return }
        visibleStart = 0
        visibleEnd = totalCount - 1
        hasInitialized = true
    }

    // MARK: 气泡

    private func priceBubble(_ point: PersonalWatchlistDailyPoint) -> some View {
        VStack(spacing: 1) {
            Text(formatPrice(point.price))
                .font(IOSDesign.monoNumber(13, weight: .bold))
                .foregroundStyle(Color.white)
            Text(fullDate(point.date))
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }

    // MARK: 辅助

    private func formatPrice(_ v: Double) -> String { String(format: "%.4f", v) }

    private func shortDate(_ raw: String) -> String {
        guard raw.count >= 10 else { return raw }
        let parts = raw.prefix(10).split(separator: "-")
        return parts.count == 3 ? "\(parts[1])-\(parts[2])" : String(raw.prefix(10))
    }

    private func fullDate(_ raw: String) -> String {
        raw.count >= 10 ? String(raw.prefix(10)) : raw
    }
}
#endif
