// Renders the app icon (gradient squircle + chart symbol) into an .iconset folder –
// or, with `--ios <file.png>`, the iPhone icon: one 1024 px square without transparency (iOS rounds the corners).
import AppKit

let ios = CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--ios"
let out = CommandLine.arguments[ios ? 2 : 1]
if !ios { try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }

func render(_ px: Int, fullBleed: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = fullBleed ? 0 : s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = fullBleed ? 0 : rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(red: 0.22, green: 0.52, blue: 1.0, alpha: 1),
                        NSColor(red: 0.50, green: 0.28, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -45)
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if ios {
    try! render(1024, fullBleed: true).write(to: URL(fileURLWithPath: out))
    exit(0)
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
