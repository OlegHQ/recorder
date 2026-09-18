import AppKit

/// Borderless, non-activating, above everything, on all Spaces, HUD material, radius 16.
/// Every recording-flow window uses this. SPEC §3 "floating panels", §4 window/panel rule.
final class FloatingPanel: NSPanel {
    private let content: NSView

    init(content: NSView, draggable: Bool) {
        self.content = content
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // SPEC §4 window/panel rule: `.screenSaver`-1 (above normal windows). `CGShieldingWindowLevel()` is the
        // level of the system's screen-lock/transition shield surface, not a normal interactive HUD level; a
        // window that high sits above menu bar/Dock/system UI where WindowServer doesn't treat it as an
        // ordinary interactive window (broken vibrancy rendering, no mouse/key event routing).
        level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 1)
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

    // `initialFirstResponder` only applies if set before the window's first `makeKey`, and NSWindow only
    // auto-assigns it from the contentView passed to the designated initializer (ours is replaced after
    // `super.init`) — so it never took effect here and first responder stayed the panel itself, which means
    // `content` never received key events (e.g. `cancelOperation(_:)` / Esc, AC-TB-4, never fired). Forcing it
    // on every `makeKeyAndOrderFront` is the reliable fix and covers reshow too.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(content)
    }

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
