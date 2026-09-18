import AppKit

/// A resizable, movable selection rectangle: 45% dim outside, dashed rule-of-thirds grid inside, 8 round
/// handles. Shared by area selection (T-108) and the crop sheet (T-310) — build it once. SPEC §4.5, §6.7.
final class SelectionRectView: NSView {
    var rect: CGRect = .zero {
        didSet {
            let clamped = SelectionRectView.clamp(rect, to: limit, minSize: minSize)
            if clamped != rect { rect = clamped; return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onChange?(rect)
        }
    }
    var limit: CGRect = .zero { didSet { rect = SelectionRectView.clamp(rect, to: limit, minSize: minSize) } }
    var minSize = CGSize(width: 100, height: 100)
    var aspect: CGFloat? // locked aspect (crop presets); ⇧ locks current
    var onChange: ((CGRect) -> Void)?

    // 8 resize handles. xEdge/yEdge: which edge of that axis tracks the mouse (true = max, false = min,
    // nil = axis unaffected). One routine (`resized(from:mouse:...)`) drives every handle plus rect creation.
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var xEdge: Bool? {
            switch self {
            case .topLeft, .bottomLeft, .left: return false
            case .topRight, .bottomRight, .right: return true
            case .top, .bottom: return nil
            }
        }
        var yEdge: Bool? {
            switch self {
            case .topLeft, .topRight, .top: return true
            case .bottomLeft, .bottomRight, .bottom: return false
            case .left, .right: return nil
            }
        }
    }

    private enum DragMode { case create, move(CGPoint), resize(Handle) }
    private var dragMode: DragMode?
    private var dragStart = CGRect.zero    // rect (or anchor, for .create) at mouseDown
    private var dragAspect: CGFloat = 1    // rect's own aspect at mouseDown, used when ⇧ is held

    private static let handleSize: CGFloat = 8

    // MARK: - Geometry

    private static func clamp(_ r: CGRect, to limit: CGRect, minSize: CGSize) -> CGRect {
        guard !limit.isEmpty else { return r }
        var size = CGSize(width: min(max(r.width, minSize.width), limit.width),
                           height: min(max(r.height, minSize.height), limit.height))
        size = CGSize(width: max(size.width, 0), height: max(size.height, 0))
        let x = min(max(r.minX, limit.minX), limit.maxX - size.width)
        let y = min(max(r.minY, limit.minY), limit.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Resizes `start` by dragging `handle`'s tracked edges to `mouse`. `option` mirrors the opposite edge
    /// around `start`'s centre (resize from centre); `aspect`, if set, is enforced by deriving the
    /// non-driving axis. Reused for rect creation by treating the click as a `.bottomRight` drag from a
    /// zero-size rect anchored at the mouse-down point.
    private func resized(from start: CGRect, handle: Handle, mouse p: CGPoint, option: Bool, aspect: CGFloat?) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if let e = handle.xEdge { if e { maxX = p.x } else { minX = p.x } }
        if let e = handle.yEdge { if e { maxY = p.y } else { minY = p.y } }

        if option {
            if let e = handle.xEdge { let d = e ? maxX - start.maxX : minX - start.minX
                if e { minX = start.minX - d } else { maxX = start.maxX - d } }
            if let e = handle.yEdge { let d = e ? maxY - start.maxY : minY - start.minY
                if e { minY = start.minY - d } else { maxY = start.maxY - d } }
        }

        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if let ratio = aspect, ratio > 0 {
            if handle.yEdge == nil {
                r.size.height = r.width / ratio
                r.origin.y = start.midY - r.height / 2
            } else if handle.xEdge == nil {
                r.size.width = r.height * ratio
                r.origin.x = start.midX - r.width / 2
            } else {
                let h = r.width / ratio
                r.origin.y = option ? start.midY - h / 2 : (handle.yEdge! ? minY : maxY - h)
                r.size.height = h
            }
        }
        return r
    }

    private func handlePoint(_ h: Handle) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleRect(_ h: Handle) -> CGRect {
        let c = handlePoint(h)
        return CGRect(x: c.x - Self.handleSize / 2, y: c.y - Self.handleSize / 2,
                       width: Self.handleSize, height: Self.handleSize)
    }

    private func hitHandle(_ p: CGPoint) -> Handle? {
        guard !rect.isEmpty else { return nil }
        return Handle.allCases.first { handleRect($0).insetBy(dx: -4, dy: -4).contains(p) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !rect.isEmpty else { return }

        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect).reversed)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        let grid = NSBezierPath()
        let xs = [rect.minX, rect.minX + rect.width / 3, rect.minX + 2 * rect.width / 3, rect.maxX]
        let ys = [rect.minY, rect.minY + rect.height / 3, rect.minY + 2 * rect.height / 3, rect.maxY]
        for x in xs { grid.move(to: CGPoint(x: x, y: rect.minY)); grid.line(to: CGPoint(x: x, y: rect.maxY)) }
        for y in ys { grid.move(to: CGPoint(x: rect.minX, y: y)); grid.line(to: CGPoint(x: rect.maxX, y: y)) }
        grid.lineWidth = 1
        grid.setLineDash([4, 3], count: 2, phase: 0)
        Theme.textPrimary.withAlphaComponent(0.8).setStroke()
        grid.stroke()

        Theme.textPrimary.setFill()
        for h in Handle.allCases { NSBezierPath(ovalIn: handleRect(h)).fill() }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let h = hitHandle(p) {
            dragMode = .resize(h)
            dragStart = rect
        } else if !rect.isEmpty, rect.contains(p) {
            dragMode = .move(CGPoint(x: p.x - rect.minX, y: p.y - rect.minY))
            dragStart = rect
        } else {
            dragMode = .create
            dragStart = CGRect(origin: p, size: .zero)
        }
        dragAspect = dragStart.height > 0 ? dragStart.width / dragStart.height : 1
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        let option = event.modifierFlags.contains(.option)
        let lockedAspect = aspect ?? (event.modifierFlags.contains(.shift) ? dragAspect : nil)

        switch mode {
        case .move(let offset):
            rect = CGRect(origin: CGPoint(x: p.x - offset.x, y: p.y - offset.y), size: dragStart.size)
        case .resize(let h):
            rect = resized(from: dragStart, handle: h, mouse: p, option: option, aspect: lockedAspect)
        case .create:
            rect = resized(from: dragStart, handle: .bottomRight, mouse: p, option: option, aspect: lockedAspect)
        }
    }

    override func mouseUp(with event: NSEvent) { dragMode = nil }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: rect.origin.x -= step // left
        case 124: rect.origin.x += step // right
        case 125: rect.origin.y -= step // down
        case 126: rect.origin.y += step // up
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        guard !rect.isEmpty else { addCursorRect(bounds, cursor: .crosshair); return }
        addCursorRect(rect, cursor: .openHand)
        for h in Handle.allCases { addCursorRect(handleRect(h).insetBy(dx: -4, dy: -4), cursor: cursor(for: h)) }
    }

    private func cursor(for h: Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch h {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return .frameResize(position: position, directions: .all)
    }
}
