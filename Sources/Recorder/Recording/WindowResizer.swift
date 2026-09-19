import ApplicationServices
import AppKit
import CoreGraphics

/// Resizes a real window via the Accessibility API (SPEC §4.4). `kAXSizeAttribute` resizes from the
/// window's top-left, so the origin stays put. Requires `Permissions.accessibility`; no-ops (rather than
/// crashing) when the process isn't trusted, since the toolbar already gates the whole recording flow on
/// `Permissions.allGranted`, so this is a defensive fallback, not the primary gate.
enum WindowResizer {
    static func focus(pid: pid_t, windowTitle: String?, frame: CGRect) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        // Geometry disambiguates documents with the same title. Never raise an unrelated fallback.
        let matchingTitle = windows.filter { windowTitle != nil && title(of: $0) == windowTitle }
        let target = windows.first { window in
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
            return abs(origin.x - frame.minX) < 2 && abs(origin.y - frame.minY) < 2
                && abs(dimensions.width - frame.width) < 2 && abs(dimensions.height - frame.height) < 2
        } ?? (matchingTitle.count == 1 ? matchingTitle[0] : nil)
        guard let target else { return }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    static func resize(pid: pid_t, windowTitle: String?, to size: CGSize) {
        guard Permissions.accessibility else { return }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return }

        // ponytail: matched by title only — the normative signature has no frame param — falling back to
        // the front-most AX window when the title is nil/unmatched. Upgrade path: thread a frame hint
        // through if ambiguous same-title multi-window cases turn out to matter.
        let target = windowTitle.flatMap { t in windows.first { title(of: $0) == t } } ?? windows[0]

        var mutableSize = size
        guard let axSize = AXValueCreate(.cgSize, &mutableSize) else { return }
        AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, axSize)
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
