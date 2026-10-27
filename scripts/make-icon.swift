// Draws the Pingski app icon (a bell with signal rings) at all required sizes into an .iconset folder.
// Usage: swift scripts/make-icon.swift path/to/AppIcon.iconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.16, green: 0.42, blue: 0.98, alpha: 1), CGColor(red: 0.42, green: 0.16, blue: 0.86, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Bell body
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
    let cx = s * 0.5, cy = s * 0.5
    let bell = CGMutablePath()
    let bw = s * 0.36, bh = s * 0.40
    bell.move(to: CGPoint(x: cx - bw / 2, y: cy - bh * 0.35))
    bell.addQuadCurve(to: CGPoint(x: cx - bw * 0.34, y: cy + bh * 0.25), control: CGPoint(x: cx - bw * 0.40, y: cy + bh * 0.05))
    bell.addArc(center: CGPoint(x: cx, y: cy + bh * 0.25), radius: bw * 0.34, startAngle: .pi, endAngle: 0, clockwise: false)
    bell.addQuadCurve(to: CGPoint(x: cx + bw / 2, y: cy - bh * 0.35), control: CGPoint(x: cx + bw * 0.40, y: cy + bh * 0.05))
    bell.addLine(to: CGPoint(x: cx + bw * 0.58, y: cy - bh * 0.48))
    bell.addLine(to: CGPoint(x: cx - bw * 0.58, y: cy - bh * 0.48))
    bell.closeSubpath()
    ctx.addPath(bell)
    ctx.fillPath()
    // Clapper
    ctx.addEllipse(in: CGRect(x: cx - s * 0.055, y: cy - bh * 0.48 - s * 0.085, width: s * 0.11, height: s * 0.11))
    ctx.fillPath()
    // Signal rings
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.035)
    for (i, r) in [s * 0.30, s * 0.38].enumerated() {
        let alpha: CGFloat = i == 0 ? 0.9 : 0.6
        ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        ctx.addArc(center: CGPoint(x: cx + bw * 0.5, y: cy + bh * 0.25), radius: r, startAngle: -.pi * 0.08, endAngle: .pi * 0.33, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: cx - bw * 0.5, y: cy + bh * 0.25), radius: r, startAngle: .pi * 0.67, endAngle: .pi * 1.08, clockwise: false)
        ctx.strokePath()
    }
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    write(draw(size: CGFloat(base)), pixels: base, name: "icon_\(base)x\(base).png")
    write(draw(size: CGFloat(base * 2)), pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset to \(outDir)")
