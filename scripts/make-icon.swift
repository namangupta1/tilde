// Renders the Tilde app icon into an .iconset directory: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!.draw(in: path, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    path.lineWidth = s * 0.006
    path.stroke()
    // Prompt chevron + tilde
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.42, weight: .bold)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: para,
        .foregroundColor: NSColor(srgbRed: 0.90, green: 0.75, blue: 0.48, alpha: 1)]
    let str = NSAttributedString(string: "~", attributes: attrs)
    let h = str.size().height
    str.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2 + s * 0.02, width: rect.width, height: h))
    let cursor = NSRect(x: rect.midX + s * 0.17, y: rect.midY - s * 0.13, width: s * 0.07, height: s * 0.025)
    NSColor(srgbRed: 0.6, green: 0.78, blue: 0.47, alpha: 1).setFill()
    NSBezierPath(rect: cursor).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
