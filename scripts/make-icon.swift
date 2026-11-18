// Draws the AIStats app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output-dir>
// Bars = system stats, speech bubble with dots = the agent conversation.
import AppKit

let canvas: CGFloat = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: 824 pt body centred on a 1024 canvas, continuous-corner radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x0E1A2B)); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [color(0x1B2D4F), color(0x0B1220)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Subtle grid lines, like a monitor.
    ctx.setStrokeColor(color(0xFFFFFF, 0.06)); ctx.setLineWidth(4)
    for y in stride(from: 260.0, through: 760.0, by: 125.0) {
        ctx.move(to: CGPoint(x: 160, y: y)); ctx.addLine(to: CGPoint(x: 864, y: y))
    }
    ctx.strokePath()

    // Stats bars.
    let bars: [(x: CGFloat, h: CGFloat)] = [(200, 200), (330, 330), (460, 250), (590, 430)]
    let barGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [color(0x3DDC97), color(0x22A6F2)] as CFArray, locations: [0, 1])!
    for bar in bars {
        let rect = CGRect(x: bar.x, y: 200, width: 96, height: bar.h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(barGradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.minY + 430), options: [])
        ctx.restoreGState()
    }

    // Speech bubble (top right) with a tail pointing down-left toward the bars.
    let bubble = CGRect(x: 520, y: 560, width: 320, height: 230)
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubble, cornerWidth: 100, cornerHeight: 100)
    bubblePath.move(to: CGPoint(x: 600, y: 580))
    bubblePath.addLine(to: CGPoint(x: 560, y: 500))
    bubblePath.addLine(to: CGPoint(x: 680, y: 566))
    bubblePath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(bubblePath); ctx.setFillColor(color(0xF7FAFF)); ctx.fillPath()
    ctx.restoreGState()

    // Three dots: the agent is talking.
    for (i, c) in [0x22A6F2, 0x2FC3C6, 0x3DDC97].enumerated() {
        let cx = bubble.midX + CGFloat(i - 1) * 82
        ctx.setFillColor(color(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: cx - 30, y: bubble.midY - 30, width: 60, height: 60))
    }

    // Top highlight.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.interpolationQuality = .high
    cg.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: outDir.appendingPathComponent("AppIcon.png"))
print(iconset.path)
