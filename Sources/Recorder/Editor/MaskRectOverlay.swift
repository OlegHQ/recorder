import AppKit
import Observation
import RecorderCore

/// Edits the selected mask's `rect` in the preview with `SelectionRectView` (T-108/T-310's shared
/// rectangle editor — SPEC §4.5/§6.7). Two pure mappings, both reused rather than duplicated: the
/// content rect the overlay is positioned against is `ZoomTargetMapping.contentRect` — the exact
/// same "letterboxed viewport, then the frame's `padding` inset inside it" math T-415's manual-zoom-
/// target overlay uses (mask rects, like zoom targets, are defined against the UN-zoomed screen
/// content — `PreviewView.draw`'s `isMaskSelected()` override shows that frame while a mask is
/// selected, same as it already does for a selected manual zoom); the `NormRect` <-> view-rect
/// conversion *within* that content rect is `CropSheet.swift`'s `CropMapping`, unchanged.
///
/// `PreviewView` owns the mount point (`maskOverlayView`/`onResize`) — this file owns only the
/// piece that's genuinely mine: the overlay view + its model wiring. Mounting it over the live
/// preview is `EditorWindowController`'s job (its init):
///
///   1. Create one `MaskRectOverlay(model:)`, set `preview.maskOverlayView = overlay.view` (a
///      subview covering the preview's *entire* image area — the same bounds the `MTKView`
///      occupies — `PreviewView` forwards mouse events to it the same way it does its own
///      zoom-target overlay, so the two never fight over the mouse).
///   2. Call `layout(in:)` once now and again every time that area resizes (`preview.onResize`).
///
/// Everything else — showing only while a mask is selected, syncing `rect` both ways, one undo
/// step per drag — is internal; the coordinator never touches `EditorModel` through this type.
@MainActor
final class MaskRectOverlay {
    /// The subview to mount over the preview's image area (SPEC §6.7's own pattern: dim outside,
    /// rule-of-thirds guides, 8 handles — this is literally `CropSheet`'s `SelectionRectView`).
    let view: NSView

    private let model: EditorModel
    private let selectionView = SelectionRectView(frame: .zero)
    private var imageRect: CGRect = .zero
    private var mountedSize: CGSize = .zero
    private var gestureOpen = false

    init(model: EditorModel) {
        self.model = model
        let container = HitForwardingView(frame: .zero)
        container.forward = selectionView
        selectionView.frame = container.bounds
        selectionView.autoresizingMask = [.width, .height]
        container.addSubview(selectionView)
        view = container

        selectionView.allowsCreation = false
        selectionView.onCancelDrag = { [weak self] in
            guard let self, self.gestureOpen else { return }
            self.gestureOpen = false
            self.model.cancelGesture()
            self.updateContentRect()
        }
        selectionView.onChange = { [weak self] r in self?.rectChanged(r) }
        selectionView.onKeyboardEditingChanged = { [weak self] editing in
            if editing { self?.gestureBegan() } else { self?.gestureEnded() }
        }
        container.onMouseDown = { [weak self] in self?.gestureBegan() }
        container.onMouseUp = { [weak self] in self?.gestureEnded() }
        observeSelection()
    }

    /// Call once after mounting `view`, and again whenever the mounted area's size changes.
    /// `size` is that area's own bounds size — the canvas letterbox/padding math (`updateContentRect`)
    /// is computed internally from `model.project`, so the coordinator doesn't need to know the
    /// source's pixel size, the crop, or the frame padding.
    func layout(in size: CGSize) {
        mountedSize = size
        view.frame = CGRect(origin: .zero, size: size)
        updateContentRect()
    }

    /// T-601 fix: was `CropMapping.imageRect(imageSize: sourceSize, in: size)` — the source's
    /// letterbox inside the view only, ignoring `PreviewView`'s own letterboxed viewport AND the
    /// frame's `padding` inset inside it (both insets `ZoomTargetMapping.contentRect` already
    /// accounts for, for the T-415 manual-zoom-target overlay). A mask dragged against the
    /// un-padded rect landed at the wrong spot on screen whenever `padding` was non-zero (the
    /// default is 0.08) or the view wasn't exactly the crop's own aspect. Root-caused by reusing
    /// that one pure `contentRect` function instead of duplicating letterbox math here — `syncFromModel`
    /// / `rectChanged` below still convert through it with the unchanged `CropMapping` pair.
    private func updateContentRect() {
        // Don't fight the mouse mid-drag (same guard `syncFromModel` uses below): reassigning
        // `selectionView.limit` re-clamps its CURRENT `rect` against `minSize` right away (`limit`'s
        // own `didSet`), which stomped a live drag's in-progress rect on every project-change tick
        // the drag's own edits triggered (`rectChanged` -> `model.update` -> this observer, via
        // `observeSelection`'s now-broader `model.project` tracking).
        guard !selectionView.isDragging else { return }
        imageRect = ZoomTargetMapping.contentRect(viewBounds: mountedSize, project: model.project)
        // One pixel of the cropped source, independent of preview scale and handle hit size.
        selectionView.minSize = CGSize(
            width: imageRect.width / max(1, Double(model.project.source.pixelWidth) * model.project.crop.w),
            height: imageRect.height / max(1, Double(model.project.source.pixelHeight) * model.project.crop.h))
        selectionView.limit = imageRect
        syncFromModel()
    }

    // MARK: - Model <-> view sync

    /// The selected mask's id, or `nil` while no mask (or something else) is selected.
    private var selectedMaskID: UUID? {
        guard !model.inspectorShowsProject, !model.previewShowsResult, model.selectedClip == nil, model.selection.count == 1, let id = model.selection.first,
              model.project.masks.contains(where: { $0.id == id.uuidString }) else { return nil }
        return id
    }

    /// SPEC §7: "Observe `model` with `withObservationTracking`" — the same pattern
    /// `TimelineView.observeModel()` uses, so the rect stays in sync with selection changes, undo/
    /// redo, and any other edit, not just this overlay's own drags. Tracks the whole `model.project`
    /// (not just `.masks`): `updateContentRect()`'s `ZoomTargetMapping.contentRect` also depends on
    /// `project.crop`/`project.frame.padding`, which can change independently of the mask list.
    private func observeSelection() {
        withObservationTracking {
            _ = model.inspectorShowsProject
            _ = model.previewShowsResult
            _ = model.selection
            _ = model.selectedClip
            _ = model.project
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateContentRect()
                self.observeSelection()
            }
        }
    }

    private func syncFromModel() {
        guard let id = selectedMaskID, let mask = model.project.masks.first(where: { $0.id == id.uuidString }) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        guard !selectionView.isDragging else { return } // an external change can't fight the mouse mid-drag
        let local = CropMapping.viewRect(from: mask.rect, imageRect: imageRect)
        if selectionView.rect != local { selectionView.rect = local }
    }

    /// `gestureOpen` (not just `let id = selectedMaskID`): `selectionView.onChange` also fires from a
    /// purely PROGRAMMATIC `rect`/`limit` assignment (`SelectionRectView.limit`'s own `didSet`
    /// unconditionally re-touches `rect`, so reassigning `.limit` to an unchanged value — which
    /// `updateContentRect` now does on every project/selection change, not only at mount — still
    /// fires `onChange`). Without this gate that stray call landed here mid-selection-change, before
    /// `syncFromModel` had set the real rect, and clobbered the mask's `rect` with whatever
    /// `selectionView.rect` happened to be at that instant (SPEC §7's own "one undo step per gesture"
    /// pattern — `zoomTargetRectChanged` in `PreviewView` gates the same way, on `zoomTargetGestureActive`).
    private func rectChanged(_ r: CGRect) {
        guard gestureOpen, let id = selectedMaskID else { return }
        let n = CropMapping.normRect(fromView: r, imageRect: imageRect)
        model.update { project in
            guard let i = project.masks.firstIndex(where: { $0.id == id.uuidString }) else { return }
            project.masks[i].rect = n
        }
    }

    // MARK: - One undo step per drag (AC-TL-6-style: every gesture = one undo step)

    private func gestureBegan() {
        guard selectedMaskID != nil, !gestureOpen else { return }
        gestureOpen = true
        model.beginGesture()
    }

    private func gestureEnded() {
        guard gestureOpen else { return }
        gestureOpen = false
        model.commitGesture("Mask rect")
    }
}

/// `SelectionRectView` is `final` (can't be subclassed to add drag-start/drag-end hooks), so this
/// small container owns hit-testing for the whole overlay area and forwards every mouse event to
/// `forward` directly — `hitTest` always resolves to `self`, not `forward`, only so `onMouseDown`/
/// `onMouseUp` can bracket one undo step per drag; `forward` still does all the actual rect
/// editing (its own `mouseDown` still calls `window?.makeFirstResponder(self)`, so keyboard
/// nudges/cursors keep working normally once it's first responder).
private final class HitForwardingView: NSView {
    weak var forward: NSView?
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        forward?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) { forward?.mouseDragged(with: event) }

    override func mouseUp(with event: NSEvent) {
        forward?.mouseUp(with: event)
        onMouseUp?()
    }
}

extension MaskRectOverlay {
    @MainActor static func runManipulationSelfTest() throws {
        _ = NSApplication.shared
        struct Fail: Error, CustomStringConvertible { let description: String }
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw Fail(description: message) } }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, window: Int = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: window, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("highlight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var project = Project(source: Source(pixelWidth: 1000, pixelHeight: 1000, duration: 3),
                              clips: [Clip(sourceStart: 0, sourceEnd: 3)])
        project.masks = [Mask(start: 0, end: 3, kind: .highlight, rect: NormRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2))]
        let model = EditorModel(packageURL: scratch, project: project, events: EventLog())
        defer { model.saveNow() }
        model.selection = [UUID(uuidString: project.masks[0].id)!]
        let overlay = MaskRectOverlay(model: model)
        let rectangle = overlay.selectionView
        func drag(_ from: CGPoint, _ to: CGPoint) {
            overlay.view.mouseDown(with: event(.leftMouseDown, from))
            overlay.view.mouseDragged(with: event(.leftMouseDragged, to))
            overlay.view.mouseUp(with: event(.leftMouseUp, to))
        }
        for size in [CGSize(width: 1000, height: 1000), CGSize(width: 500, height: 700)] {
            model.edit("Reset") { $0.masks = project.masks }
            overlay.layout(in: size)
            let start = rectangle.rect
            let center = CGPoint(x: start.midX, y: start.midY)
            let before = model.undoStepCount
            drag(center, CGPoint(x: center.x + overlay.imageRect.width * 0.1, y: center.y))
            try check(abs(model.project.masks[0].rect.x - 0.5) < 1e-9, "scale-dependent body drift")
            try check(model.undoStepCount == before + 1, "move not one undo step")
            model.undo(); model.selection = [UUID(uuidString: project.masks[0].id)!]; overlay.layout(in: size)
            try check(model.project.masks == project.masks, "undo")
            model.redo(); model.selection = [UUID(uuidString: project.masks[0].id)!]; overlay.layout(in: size)
            try check(abs(model.project.masks[0].rect.x - 0.5) < 1e-9, "redo")
            // Each intended edge/corner is reachable and uses pointer deltas, including off-center grabs.
            for (x, y) in [(0.0, 0.0), (0, 0.5), (0, 1), (0.5, 0), (0.5, 1), (1, 0), (1, 0.5), (1, 1)] {
                model.edit("Reset") { $0.masks = project.masks }
                overlay.layout(in: size)
                let r = rectangle.rect
                let grab = CGPoint(x: r.minX + x * r.width + 2, y: r.minY + y * r.height + 2)
                overlay.view.mouseDown(with: event(.leftMouseDown, grab))
                overlay.view.mouseDragged(with: event(.leftMouseDragged, grab))
                try check(rectangle.rect == r, "resize jumped at pointer-down")
                let dx = x == 0.5 ? 0.0 : (x == 0 ? -10.0 : 10.0)
                let dy = y == 0.5 ? 0.0 : (y == 0 ? -10.0 : 10.0)
                overlay.view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: grab.x + dx, y: grab.y + dy)))
                overlay.view.mouseUp(with: event(.leftMouseUp, grab))
                try check(abs(rectangle.rect.width - r.width - abs(dx)) < 1e-8 &&
                          abs(rectangle.rect.height - r.height - abs(dy)) < 1e-8, "wrong resize edge")
            }
            // Shrink beyond the opposite corner: clamp at one source pixel, never flip the anchor.
            let r = rectangle.rect
            drag(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX - 100, y: r.minY - 100))
            try check(abs(model.project.masks[0].rect.w - 0.001) < 1e-9 &&
                      abs(model.project.masks[0].rect.h - 0.001) < 1e-9, "minimum not one source pixel: \(model.project.masks[0].rect)")
            let tiny = rectangle.rect
            drag(CGPoint(x: tiny.midX, y: tiny.midY), CGPoint(x: tiny.midX + 10, y: tiny.midY + 10))
            try check(abs(rectangle.rect.minX - tiny.minX - 10) < 1e-8 && rectangle.rect.size == tiny.size,
                      "tiny body intercepted by resize handle")
            let small = rectangle.rect
            let handle = CGPoint(x: small.midX + 16, y: small.midY + 16)
            drag(handle, CGPoint(x: handle.x + 5, y: handle.y + 5))
            try check(abs(rectangle.rect.width - small.width - 5) < 1e-8, "tiny handle unusable")
            let beforeCancel = model.project, undoCount = model.undoStepCount
            let c = CGPoint(x: rectangle.rect.midX, y: rectangle.rect.midY)
            overlay.view.mouseDown(with: event(.leftMouseDown, c))
            overlay.view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: c.x + 20, y: c.y)))
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            rectangle.keyDown(with: escape)
            overlay.view.mouseUp(with: event(.leftMouseUp, c))
            try check(model.project == beforeCancel && model.undoStepCount == undoCount && !rectangle.isDragging, "Escape did not roll back")
            drag(CGPoint(x: rectangle.rect.midX, y: rectangle.rect.midY), CGPoint(x: -1000, y: -1000))
            try check(rectangle.rect.minX == overlay.imageRect.minX && rectangle.rect.minY == overlay.imageRect.minY, "bounds")
            try check(abs(model.project.masks[0].rect.x) < 1e-9 &&
                      abs(model.project.masks[0].rect.y + model.project.masks[0].rect.h - 1) < 1e-9,
                      "clamped view did not update persisted bounds")
            let saved = model.project.masks[0].rect
            drag(CGPoint(x: size.width - 5, y: size.height - 5), CGPoint(x: size.width / 2, y: size.height / 2))
            try check(model.project.masks[0].rect == saved, "outside drag recreated mask")
        }
        // Actual preview dispatch must leave keyboard focus on the rectangle, not steal it back.
        model.edit("Small highlight") { $0.masks[0].rect = NormRect(x: 0.5, y: 0.5, w: 0.001, h: 0.001) }
        let preview = PreviewView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = preview
        preview.maskOverlayView = overlay.view
        overlay.layout(in: preview.bounds.size)
        let center = CGPoint(x: rectangle.rect.midX, y: rectangle.rect.midY)
        preview.mouseDown(with: event(.leftMouseDown, center, window: window.windowNumber))
        try check(window.firstResponder === rectangle, "preview stole rectangle keyboard focus")
        rectangle.cancelOperation(nil)
        preview.mouseUp(with: event(.leftMouseUp, center, window: window.windowNumber))
        guard let bitmap = rectangle.bitmapImageRepForCachingDisplay(in: rectangle.bounds) else { throw Fail(description: "no bitmap") }
        rectangle.cacheDisplay(in: rectangle.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Fail(description: "no PNG") }
        try png.write(to: URL(fileURLWithPath: "/tmp/recorder-small-highlight.png"))
        print("Small highlight PNG: /tmp/recorder-small-highlight.png")
    }
}
