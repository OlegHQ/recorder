import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Dev/QA tool: gives an agent shell "eyes and hands" on the real app via `--selftest`, driven
/// through `scripts/ui.sh` (which launches via `open` so Recorder's own TCC grants apply).
/// `screenshot` captures the real screen (including Recorder's own windows); `click`/`key`/`drag`
/// post synthetic HID events at global CGEvent (points, top-left origin) coordinates.
enum UIDriver {
    struct Fail: Error, CustomStringConvertible { let description: String }

    /// `screenshot <out.png> [displayIndex]` — full display at native pixel size, cursor shown,
    /// nothing excluded (so Recorder's own windows are captured too). Prints "WxH points=WxH".
    static func screenshot(_ args: [String]) async throws {
        guard let outPath = args.first else { throw Fail(description: "usage: screenshot <out.png> [displayIndex]") }
        let index = args.count > 1 ? (Int(args[1]) ?? 0) : 0
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard content.displays.indices.contains(index) else { throw Fail(description: "no display at index \(index)") }
        let display = content.displays[index]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = CGDisplayPixelsWide(display.displayID)
        config.height = CGDisplayPixelsHigh(display.displayID)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Fail(description: "no PNG destination at \(outPath)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Fail(description: "PNG finalize failed") }
        print("\(image.width)x\(image.height) points=\(Int(display.width))x\(Int(display.height))")
    }

    /// `click <x> <y> [right|double]` — global display coords in points, top-left origin (CGEvent space).
    static func click(_ args: [String]) async throws {
        guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
            throw Fail(description: "usage: click <x> <y> [right|double]")
        }
        guard Permissions.accessibility else { throw Fail(description: "Accessibility permission not granted to Recorder") }
        let point = CGPoint(x: x, y: y)
        let isRight = args.count > 2 && args[2] == "right"
        let isDouble = args.count > 2 && args[2] == "double"
        let button: CGMouseButton = isRight ? .right : .left
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let source = CGEventSource(stateID: .hidSystemState)

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 20_000_000)

        func post(_ type: CGEventType, clickState: Int64) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            event?.post(tap: .cghidEventTap)
        }
        post(downType, clickState: 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        post(upType, clickState: 1)
        if isDouble {
            try await Task.sleep(nanoseconds: 30_000_000)
            post(downType, clickState: 2)
            try await Task.sleep(nanoseconds: 30_000_000)
            post(upType, clickState: 2)
        }
    }

    /// `key <keyCode> [cmd,shift,opt,ctrl]` — key down/up with the given modifier flags.
    static func key(_ args: [String]) async throws {
        guard let first = args.first, let keyCode = CGKeyCode(first) else {
            throw Fail(description: "usage: key <keyCode> [cmd,shift,opt,ctrl]")
        }
        guard Permissions.accessibility else { throw Fail(description: "Accessibility permission not granted to Recorder") }
        var flags: CGEventFlags = []
        for name in args[safe: 1]?.split(separator: ",") ?? [] {
            switch name {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: throw Fail(description: "unknown modifier \(name)")
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 30_000_000)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    /// `drag <x1> <y1> <x2> <y2>` — mouse down, ~20 interpolated moves over ~0.4 s, up.
    static func drag(_ args: [String]) async throws {
        guard args.count >= 4, let x1 = Double(args[0]), let y1 = Double(args[1]),
              let x2 = Double(args[2]), let y2 = Double(args[3]) else {
            throw Fail(description: "usage: drag <x1> <y1> <x2> <y2>")
        }
        guard Permissions.accessibility else { throw Fail(description: "Accessibility permission not granted to Recorder") }
        let source = CGEventSource(stateID: .hidSystemState)
        let start = CGPoint(x: x1, y: y1)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x2, y: y2), mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
