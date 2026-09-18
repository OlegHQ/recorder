import AppKit

/// Borderless, non-activating, above everything, on all Spaces, HUD material, radius 16.
/// Every recording-flow window uses this. SPEC §3 "floating panels", §4 window/panel rule.
final class FloatingPanel: NSPanel {
    init(content: NSView, draggable: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(Int(CGShieldingWindowLevel()) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = draggable

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.Radius.panel
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.stroke.cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        FloatingPanel.register(self)
    }

    override var canBecomeKey: Bool { true }

    // Weak list of every live FloatingPanel/overlay window, so capture can exclude them all
    // (T-106). Overlay windows that aren't FloatingPanel instances (T-107) register themselves too.
    private static var trackedWindows: [Weak<NSWindow>] = []

    static func register(_ window: NSWindow) {
        trackedWindows.removeAll { $0.value == nil }
        trackedWindows.append(Weak(window))
    }

    static var allWindowIDs: [CGWindowID] {
        trackedWindows.compactMap { $0.value }.map { CGWindowID($0.windowNumber) }
    }
}

private struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
