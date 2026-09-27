// 生成 AppIcon.icns（开发用：swift Resources/make-icon.swift Resources/AppIcon.icns）
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PinBox.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // 圆角底：蓝 → 靛渐变
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
    path.addClip()
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.99, alpha: 1),
                                   NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.85, alpha: 1)])!
    grad.draw(in: rect, angle: -90)

    // 右上角高光
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.45, y: size * 0.45, width: size * 0.8, height: size * 0.8)).fill()

    // 白色图钉
    if let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
        let conf = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .semibold)
        if let sym = pin.withSymbolConfiguration(conf) {
            let s = sym.size
            let r = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.01,
                           width: s.width, height: s.height)
            sym.isTemplate = true
            NSColor.white.set()
            sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            r.fill(using: .sourceAtop)
        }
    }
    img.unlockFocus()
    return img
}

func png(_ size: CGFloat, _ name: String) {
    let img = draw(size: size)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: iconset.appendingPathComponent(name))
}

png(16, "icon_16x16.png");        png(32, "icon_16x16@2x.png")
png(32, "icon_32x32.png");        png(64, "icon_32x32@2x.png")
png(128, "icon_128x128.png");     png(256, "icon_128x128@2x.png")
png(256, "icon_256x256.png");     png(512, "icon_256x256@2x.png")
png(512, "icon_512x512.png");     png(1024, "icon_512x512@2x.png")

// README 里用的图标
if let rep = NSBitmapImageRep(data: draw(size: 256).tiffRepresentation!),
   let data = rep.representation(using: .png, properties: [:]) {
    let out = URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("AppIcon.png")
    try? data.write(to: out)
    print("生成 \(out.path)")
}

let p = Process()
p.launchPath = "/usr/bin/iconutil"
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
print("生成 \(out)")
