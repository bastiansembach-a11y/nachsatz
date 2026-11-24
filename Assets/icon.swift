import AppKit
// Zeichnet das App-Symbol: getippter Text, Schreibmarke, grauer Nachsatz. Aufruf: swift icon.swift <Ordner.iconset>
let dir = CommandLine.arguments[1]
func c(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a) }
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scale(by: CGFloat(px) / 1024); t.concat()
    let body = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = c(0x000000, 0.3); sh.shadowBlurRadius = 26; sh.shadowOffset = CGSize(width: 0, height: -12); sh.set()
    c(0xF3E8D5).setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [c(0xFCF8EF), c(0xF4E9D6), c(0xE7D6BB)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: CGRect(x: 100, y: 100, width: 824, height: 824), angle: -70)
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: NSColor) { col.setFill(); NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill() }
    bar(232, 628, 560, 76, c(0x3A2A1E))
    bar(232, 474, 236, 76, c(0x3A2A1E))
    bar(590, 474, 202, 76, c(0x3A2A1E, 0.26))
    bar(232, 320, 360, 76, c(0x3A2A1E, 0.26))
    c(0xB04A24).setFill(); NSBezierPath(roundedRect: CGRect(x: 512, y: 428, width: 34, height: 168), xRadius: 17, yRadius: 17).fill()
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSBezierPath(roundedRect: CGRect(x: 103, y: 103, width: 818, height: 818), xRadius: 187, yRadius: 187)
    rim.lineWidth = 6; c(0x8A6A45, 0.28).setStroke(); rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for s in [16, 32, 128, 256, 512] {
    try! draw(s).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s).png"))
    try! draw(s * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s)@2x.png"))
}
