// Generates mac-app/Support/AppIcon.icns. Usage: swift mac-app/scripts/make-icon.swift <out-dir>
// Writes AppIcon.iconset/ and AppIcon.icns into <out-dir>; copy the .icns to mac-app/Support/.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: art occupies ~80% of the canvas, corner radius ~22.5% of that.
    let art = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = CGPath(roundedRect: art, cornerWidth: art.width * 0.225, cornerHeight: art.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(bg); ctx.setFillColor(CGColor(red: 0.29, green: 0.082, blue: 0.294, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 0.42, green: 0.17, blue: 0.43, alpha: 1), // top, lighter
        CGColor(red: 0.23, green: 0.05, blue: 0.24, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: art.maxY), end: CGPoint(x: 0, y: art.minY), options: [])
    ctx.restoreGState()

    // Speech bubble: rounded rect + tail at bottom-left.
    let b = CGRect(x: s * 0.255, y: s * 0.33, width: s * 0.49, height: s * 0.36)
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: b, cornerWidth: s * 0.09, cornerHeight: s * 0.09)
    bubble.move(to: CGPoint(x: b.minX + s * 0.07, y: b.minY + s * 0.01))
    bubble.addLine(to: CGPoint(x: b.minX + s * 0.05, y: b.minY - s * 0.085))
    bubble.addLine(to: CGPoint(x: b.minX + s * 0.17, y: b.minY + s * 0.01))
    bubble.closeSubpath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.addPath(bubble); ctx.fillPath()

    // Heart centered in the bubble.
    let c = CGPoint(x: b.midX, y: b.midY - s * 0.005), h = s * 0.075
    let heart = CGMutablePath()
    heart.move(to: CGPoint(x: c.x, y: c.y - h))
    heart.addCurve(to: CGPoint(x: c.x - h * 1.1, y: c.y + h * 0.15),
                   control1: CGPoint(x: c.x - h * 0.5, y: c.y - h * 0.65), control2: CGPoint(x: c.x - h * 1.1, y: c.y - h * 0.3))
    heart.addCurve(to: CGPoint(x: c.x, y: c.y + h * 0.35),
                   control1: CGPoint(x: c.x - h * 1.1, y: c.y + h * 0.75), control2: CGPoint(x: c.x - h * 0.35, y: c.y + h * 0.85))
    heart.addCurve(to: CGPoint(x: c.x + h * 1.1, y: c.y + h * 0.15),
                   control1: CGPoint(x: c.x + h * 0.35, y: c.y + h * 0.85), control2: CGPoint(x: c.x + h * 1.1, y: c.y + h * 0.75))
    heart.addCurve(to: CGPoint(x: c.x, y: c.y - h),
                   control1: CGPoint(x: c.x + h * 1.1, y: c.y - h * 0.3), control2: CGPoint(x: c.x + h * 0.5, y: c.y - h * 0.65))
    ctx.setFillColor(CGColor(red: 0.29, green: 0.082, blue: 0.294, alpha: 1)); ctx.addPath(heart); ctx.fillPath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
exit(p.terminationStatus)
