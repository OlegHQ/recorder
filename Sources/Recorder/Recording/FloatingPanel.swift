import AppKit

/// Borderless, non-activating, above document windows, on all Spaces, HUD material, radius 16.
/// Every recording-flow window uses this. SPEC §3 "floating panels", §4 window/panel rule.
final class FloatingPanel: NSPanel {
    private let content: NSView

    init(content: NSView, draggable: Bool) {
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

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // `.hudWindow` blends with whatever is behind the window; over a bright desktop/app that reads as
        // washed-out mid-grey instead of the near-black HUD the spec calls for. Force a dark appearance so
        // the blur itself renders dark, and lay a `Theme.bgPanel` tint on top so the result is near-black
        // regardless of what's behind the window.
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        // `layer.cornerRadius` + `masksToBounds` does not clip an NSVisualEffectView's behind-window blur
        // (it leaks square corners past the rounded shape). Use a resizable rounded-rect mask image instead;
        // keep `cornerRadius` (without `masksToBounds`) only so the CALayer border below follows the same
        // rounded shape.
        effect.maskImage = NSImage.roundedRectMask(radius: Theme.Radius.panel)
        effect.layer?.cornerRadius = Theme.Radius.panel
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = Theme.stroke.cgColor

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = Theme.bgPanel.withAlphaComponent(0.7).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        // The window's shadow is computed from the content's alpha channel; force it to recompute now that
        // the mask image has replaced the (unclipped) rectangular layer as the visible shape.
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

private extension NSImage {
    /// A resizable rounded-rect mask (opaque fill, transparent outside) for `NSVisualEffectView.maskImage`,
    /// the only way to clip its behind-window blur to rounded corners.
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
