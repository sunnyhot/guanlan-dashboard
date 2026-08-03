import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("usage: swift render_macos_icon.swift <master-image> <iconset-dir>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("无法读取图标主图: \(sourceURL.path)\n", stderr)
    exit(1)
}

let iconDefinitions: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "RenderIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建位图画布"])
    }

    bitmap.size = NSSize(width: size, height: size)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "RenderIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建绘图上下文"])
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext
    context.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(rect)

    // macOS icons sit on a transparent canvas and keep more breathing room than
    // their full-bleed iOS counterpart. This also preserves the silhouette in
    // the Dock and Finder at small sizes.
    let inset = CGFloat(size) * 0.075
    let panelRect = rect.insetBy(dx: inset, dy: inset)
    let radius = panelRect.width * 0.225
    let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: radius, yRadius: radius)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -CGFloat(size) * 0.018),
        blur: CGFloat(size) * 0.045,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    NSColor(calibratedRed: 0.015, green: 0.055, blue: 0.14, alpha: 1).setFill()
    panelPath.fill()
    context.restoreGState()

    context.saveGState()
    panelPath.addClip()
    sourceImage.draw(
        in: panelRect,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    context.restoreGState()

    NSColor.white.withAlphaComponent(0.16).setStroke()
    panelPath.lineWidth = max(1, CGFloat(size) * 0.006)
    panelPath.stroke()

    return bitmap
}

func writePNG(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RenderIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法生成 PNG"])
    }
    try pngData.write(to: url)
}

for (name, size) in iconDefinitions {
    let url = outputDirectory.appendingPathComponent(name)
    try writePNG(bitmap: drawIcon(size: size), to: url)
}
