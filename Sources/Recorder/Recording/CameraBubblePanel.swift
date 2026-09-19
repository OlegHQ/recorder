import AppKit
import AVFoundation
import RecorderCore

/// The live camera preview bubble (SPEC §4.6): 200×200 pt squircle (radius 40), draggable, snaps to the
/// nearest screen corner (24 pt margin) on mouse-up. Built on `FloatingPanel`, so it's registered for
/// capture exclusion like every recording-flow panel (AC-CAM-1) — it is a preview only, the camera itself
/// is written to `camera.mov` by `CameraCapture`.
enum CameraBubblePanel {
    private static var panel: FloatingPanel?
    /// The bubble's last corner; stored into `project.camera.corner` when the recording finishes (SPEC §4.6).
    private(set) static var corner: Camera.Corner = .bottomRight

    static func show(previewLayer: AVCaptureVideoPreviewLayer) {
        hide()
        let view = BubbleView(previewLayer: previewLayer)
        view.onDragEnd = { snap() }
        let p = FloatingPanel(content: view, draggable: false)
        // The camera supplies its own rounded shape; the HUD backing would fill its corners.
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        p.contentView = view
        p.invalidateShadow()
        place(p, at: corner)
        p.orderFrontRegardless()
        panel = p
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func place(_ panel: NSWindow, at corner: Camera.Corner) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(origin(for: corner, on: screen))
    }

    private static func origin(for corner: Camera.Corner, on screen: NSScreen) -> NSPoint {
        let f = screen.visibleFrame
        switch corner {
        case .topLeft: return NSPoint(x: f.minX + bubbleMargin, y: f.maxY - bubbleMargin - bubbleSize)
        case .topRight: return NSPoint(x: f.maxX - bubbleMargin - bubbleSize, y: f.maxY - bubbleMargin - bubbleSize)
        case .bottomLeft: return NSPoint(x: f.minX + bubbleMargin, y: f.minY + bubbleMargin)
        case .bottomRight: return NSPoint(x: f.maxX - bubbleMargin - bubbleSize, y: f.minY + bubbleMargin)
        }
    }

    /// Snaps to whichever corner of its current screen the bubble's centre is nearest to.
    private static func snap() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let sf = screen.frame
        corner = (center.x < sf.midX)
            ? (center.y < sf.midY ? .bottomLeft : .topLeft)
            : (center.y < sf.midY ? .bottomRight : .topRight)
        panel.setFrameOrigin(origin(for: corner, on: screen))
    }
}

private let bubbleSize: CGFloat = 200
private let bubbleMargin: CGFloat = 24

/// Hosts the preview layer and tracks a manual drag (not `isMovableByWindowBackground`, which wouldn't
/// let us detect mouse-up to snap).
private final class BubbleView: NSView {
    var onDragEnd: (() -> Void)?
    private var dragStart: NSPoint?
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: NSRect(x: 0, y: 0, width: bubbleSize, height: bubbleSize))
        wantsLayer = true
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = 40
        previewLayer.cornerCurve = .continuous
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    override var fittingSize: NSSize { NSSize(width: bubbleSize, height: bubbleSize) }

    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let loc = event.locationInWindow
        var origin = window.frame.origin
        origin.x += loc.x - dragStart.x
        origin.y += loc.y - dragStart.y
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        onDragEnd?()
    }
}
