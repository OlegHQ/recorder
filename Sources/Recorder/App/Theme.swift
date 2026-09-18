import AppKit
import SwiftUI

// Design tokens, SPEC §3. Dark-only UI — never hard-code a colour outside this file.
enum Theme {
    static let bgWindow = NSColor(hex: "#0A0B0F")
    static let bgPanel = NSColor(hex: "#15161C")
    static let bgControl = NSColor(hex: "#1F2027")
    static let bgHover = NSColor(hex: "#2A2B33")
    static let stroke = NSColor(hex: "#FFFFFF1A") // white @ 10%
    static let textPrimary = NSColor(hex: "#FFFFFF")
    static let textSecondary = NSColor(hex: "#FFFFFF8C") // white @ 55%
    static let accent = NSColor(hex: "#5B3DF5")
    static let accentText = NSColor(hex: "#A08CFF")
    static let clip = NSColor(hex: "#E8B93C")
    static let layout = NSColor(hex: "#3CB371")
    static let mask = NSColor(hex: "#E0567A")
    static let danger = NSColor(hex: "#FF5A5F")

    static var bgWindowColor: Color { Color(nsColor: bgWindow) }
    static var bgPanelColor: Color { Color(nsColor: bgPanel) }
    static var bgControlColor: Color { Color(nsColor: bgControl) }
    static var bgHoverColor: Color { Color(nsColor: bgHover) }
    static var strokeColor: Color { Color(nsColor: stroke) }
    static var textPrimaryColor: Color { Color(nsColor: textPrimary) }
    static var textSecondaryColor: Color { Color(nsColor: textSecondary) }
    static var accentColor: Color { Color(nsColor: accent) }
    static var accentTextColor: Color { Color(nsColor: accentText) }
    static var clipColor: Color { Color(nsColor: clip) }
    static var layoutColor: Color { Color(nsColor: layout) }
    static var maskColor: Color { Color(nsColor: mask) }
    static var dangerColor: Color { Color(nsColor: danger) }

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let panel: CGFloat = 16
    }

    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let titleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static func timecodeFont(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
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
}
