import AppKit
import Observation
import RecorderCore

/// Edits the selected mask's `rect` in the preview with `SelectionRectView` (T-108/T-310's shared
/// rectangle editor — SPEC §4.5/§6.7), mapped to/from `NormRect` with the exact same pure pair
/// `CropSheet.swift`'s `CropMapping` already uses (reused here, not duplicated).
///
/// `PreviewView` belongs to another lane right now, so this file owns only the small piece that's
/// genuinely mine: the overlay view + its model wiring. Mounting it over the live preview is ONE
/// hook for whoever owns `PreviewView`/`EditorWindowController`:
///
///   1. Create one `MaskRectOverlay(model:)` and add its `view` as a subview covering the
///      preview's *entire* image area (the same bounds the `MTKView` occupies).
///   2. Call `layout(in:)` once now and again every time that area resizes.
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
        container.onMouseDown = { [weak self] in self?.gestureBegan() }
        container.onMouseUp = { [weak self] in self?.gestureEnded() }
        observeSelection()
    }

    /// Call once after mounting `view`, and again whenever the mounted area's size changes.
    /// `size` is that area's own bounds size (source-pixel letterboxing is computed internally
    /// from `model.project.source`, via `CropMapping.imageRect` — the coordinator doesn't need to
    /// know the source's pixel size).
    func layout(in size: CGSize) {
        view.frame = CGRect(origin: .zero, size: size)
        let sourceSize = CGSize(width: model.project.source.pixelWidth, height: model.project.source.pixelHeight)
        imageRect = CropMapping.imageRect(imageSize: sourceSize, in: size)
        selectionView.limit = imageRect
        syncFromModel()
    }

    // MARK: - Model <-> view sync

    /// The selected mask's id, or `nil` while no mask (or something else) is selected.
    private var selectedMaskID: UUID? {
        guard model.selectedClip == nil, model.selection.count == 1, let id = model.selection.first,
              model.project.masks.contains(where: { $0.id == id.uuidString }) else { return nil }
        return id
    }

    /// SPEC §7: "Observe `model` with `withObservationTracking`" — the same pattern
    /// `TimelineView.observeModel()` uses, so the rect stays in sync with selection changes, undo/
    /// redo, and any other edit, not just this overlay's own drags.
    private func observeSelection() {
        withObservationTracking {
            _ = model.selection
            _ = model.selectedClip
            _ = model.project.masks
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncFromModel()
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

    private func rectChanged(_ r: CGRect) {
        guard let id = selectedMaskID else { return }
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
