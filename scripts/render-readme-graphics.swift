// Native, reproducible README artwork. Run from the repository root.
import AppKit
import CoreText

let directory = URL(fileURLWithPath: "docs/images")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/Fonts/BarlowSemiCondensed-Light.ttf") as CFURL, .process, nil)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 480,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
func color(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value, green: value, blue: value, alpha: 1) }
color(8 / 255).setFill()
NSRect(x: 0, y: 0, width: 1600, height: 480).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, mono: Bool = false, ink: NSColor = color(0.96)) {
    let font = NSFont(name: mono ? "Andale Mono" : "BarlowSemiCondensed-Light", size: size)!
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: ink])
}
text("Recorder", x: 64, y: 265, size: 132)
text("Screen recording. With room to edit.", x: 72, y: 236, size: 26, mono: true, ink: color(0.72))
let icon = NSImage(contentsOfFile: "Resources/AppIcon.svg")!
icon.draw(in: NSRect(x: 1250, y: 210, width: 240, height: 240))
color(0.23).setFill()
NSRect(x: 72, y: 179, width: 1456, height: 1).fill()
for (index, item) in [("Capture", "Display · Window · Area"), ("Edit", "Cut · Zoom · Compose"), ("Export", "MP4 · GIF · Clipboard")].enumerated() {
    let x = CGFloat(72 + index * 500)
    color(0.96).setFill()
    NSRect(x: x, y: 112, width: 44, height: 32).fill()
    text("0\(index + 1)", x: x + 9, y: 117, size: 20, mono: true, ink: color(0.03))
    text(item.0, x: x + 62, y: 104, size: 40)
    text(item.1, x: x, y: 58, size: 21, mono: true, ink: color(0.72))
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("hero.png"))
print("wrote docs/images/hero.png")
