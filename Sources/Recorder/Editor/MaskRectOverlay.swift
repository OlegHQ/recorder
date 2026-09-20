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
