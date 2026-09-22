import AppKit

/// Borderless, non-activating, above document windows, on all Spaces, flat Signal surface.
/// Every recording-flow window uses this. SPEC §3 "floating panels", §4 window/panel rule.
final class FloatingPanel: NSPanel {
    private let content: NSView
    var onOrderOut: (() -> Void)?

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        if place == .out { onOrderOut?() }
    }

    init(content: NSView, draggable: Bool, bordered: Bool = true) {
        self.content = content
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Stay above document windows, but below modal dialogs, menus and system UI.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = draggable

        let surface = NSView()
        TechAppKit.styleSurface(surface)
        surface.layer?.cornerRadius = bordered ? Theme.Radius.panel : 0
        surface.layer?.borderWidth = bordered ? 1 : 0
        surface.layer?.borderColor = Theme.stroke.cgColor
        surface.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        contentView = surface
        invalidateShadow()

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
        // All registered windows belong to recording flow; disable AppKit's implicit panel fade.
        window.animationBehavior = .none
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
