import AppKit
import SwiftUI
import CoreText

/// Signal UI: flat, dark recording software inspired by instrumentation rather than consumer video apps.
/// Keep every app colour, type role, radius and spacing value here so AppKit and SwiftUI stay identical.
enum Theme {
    // MARK: Surfaces
    static let bgWindow = NSColor(hex: "#080808")
    static let bgPanel = NSColor(hex: "#0B0B0B")
    static let bgControl = NSColor(hex: "#141414")
    static let bgHover = NSColor(hex: "#252525")
    static let bgSelected = NSColor(hex: "#292929")

    // MARK: Structure
    static let grid = NSColor(hex: "#202020")
    static let stroke = NSColor(hex: "#383838")
    static let strokeStrong = NSColor(hex: "#808080")

    // MARK: Content
    static let textPrimary = NSColor(hex: "#F4F3EE")
    static let textSecondary = NSColor(hex: "#B8B8B2")
    static let textTertiary = NSColor(hex: "#93938E")

    // MARK: Signals
    static let accent = NSColor(hex: "#F4F3EE")
    static let accentText = NSColor(hex: "#FFFFFF")
    static let accentDim = NSColor(hex: "#303030")
    static let clip = NSColor(hex: "#ECE6CE")
    static let zoom = NSColor(hex: "#D7EAF0")
    static let layout = NSColor(hex: "#DCE8D7")
    static let mask = NSColor(hex: "#E5DCEC")
    static let warning = NSColor(hex: "#D8C86A")
    static let danger = NSColor(hex: "#E38276")

    static var bgWindowColor: Color { Color(nsColor: bgWindow) }
    static var bgPanelColor: Color { Color(nsColor: bgPanel) }
    static var bgControlColor: Color { Color(nsColor: bgControl) }
    static var bgHoverColor: Color { Color(nsColor: bgHover) }
    static var bgSelectedColor: Color { Color(nsColor: bgSelected) }
    static var gridColor: Color { Color(nsColor: grid) }
    static var strokeColor: Color { Color(nsColor: stroke) }
    static var strokeStrongColor: Color { Color(nsColor: strokeStrong) }
    static var textPrimaryColor: Color { Color(nsColor: textPrimary) }
    static var textSecondaryColor: Color { Color(nsColor: textSecondary) }
    static var textTertiaryColor: Color { Color(nsColor: textTertiary) }
    static var accentColor: Color { Color(nsColor: accent) }
    static var accentTextColor: Color { Color(nsColor: accentText) }
    static var accentDimColor: Color { Color(nsColor: accentDim) }
    static var clipColor: Color { Color(nsColor: clip) }
    static var zoomColor: Color { Color(nsColor: zoom) }
    static var layoutColor: Color { Color(nsColor: layout) }
    static var maskColor: Color { Color(nsColor: mask) }
    static var warningColor: Color { Color(nsColor: warning) }
    static var dangerColor: Color { Color(nsColor: danger) }

    enum Radius {
        static let control: CGFloat = 0
        static let card: CGFloat = 0
        static let panel: CGFloat = 0
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 32
    }

    enum Motion {
        static let press = 0.08
        static let drag = 0.10
        static let hover = 0.16
        static let contextReveal = 0.24
        static let reducedFade = 0.12
        static let reveal = 0.42
        static let springResponse = 0.22
        static let springDamping = 0.85
    }

    static let bodyFont = monoFont(12)
    static let captionFont = monoFont(10)
    static let labelFont = monoFont(11)
    static let titleFont = headingFont(28)
    static let displayFont = headingFont(58)
    private static let registerHeadingFont: Void = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts/BarlowSemiCondensed-Light.ttf")
        let source = URL(fileURLWithPath: "Resources/Fonts/BarlowSemiCondensed-Light.ttf")
        let url = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func headingFont(_ size: CGFloat) -> NSFont {
        _ = registerHeadingFont
        return NSFont(name: "BarlowSemiCondensed-Light", size: size)
            ?? NSFont(name: "ArialNarrow", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .light)
    }
    static func timecodeFont(_ size: CGFloat) -> NSFont { monoFont(size) }

    private static func monoFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "AndaleMono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSColor {
    /// Parses `#RRGGBB` or `#RRGGBBAA` (leading `#` optional). The only hex colour parser in the repo.
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                       Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
