// Run from the repository root: swift scripts/render-brand-assets.swift
import AppKit
import CoreText

CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/Fonts/BarlowSemiCondensed-Light.ttf") as CFURL, .process, nil)

func render(_ source: String, pixels: Int, to path: String, points: Int? = nil) throws {
    let image = NSImage(contentsOfFile: source)!
    let height = Int(CGFloat(pixels) * image.size.height / image.size.width)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: height))
    if source.hasSuffix("DMGBackground.svg") {
        // AppKit's SVG rasterizer substitutes process-registered fonts. Draw the
        // same heading with CoreText so the shipped PNG uses our bundled face.
        let context = NSGraphicsContext.current!.cgContext
        let scale = CGFloat(pixels) / 660
        context.scaleBy(x: scale, y: scale)
        NSColor(srgbRed: 8.0 / 255, green: 8.0 / 255, blue: 8.0 / 255, alpha: 1).setFill()
        NSRect(x: 32, y: 344, width: 270, height: 64).fill()
        context.textPosition = CGPoint(x: 36, y: 353)
        let heading = NSAttributedString(string: "Recorder", attributes: [
            .font: NSFont(name: "BarlowSemiCondensed-Light", size: 42)!,
            .foregroundColor: NSColor(srgbRed: 244.0 / 255, green: 243.0 / 255, blue: 238.0 / 255, alpha: 1)])
        CTLineDraw(CTLineCreateWithAttributedString(heading), context)
    }
    NSGraphicsContext.restoreGraphicsState()
    if let points { bitmap.size = NSSize(width: points, height: points * height / pixels) }
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render("Resources/AppIcon.svg", pixels: size * scale, to: iconset.appendingPathComponent(name).path)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "iconutil failed")
try render("Resources/DMGBackground.svg", pixels: 1320, to: "Resources/DMGBackground.png", points: 660)
try FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
try render("Resources/AppIcon.svg", pixels: 512, to: "build/app-icon.png")
