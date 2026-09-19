import AppKit
import Observation
import QuartzCore
import RecorderCore
import SwiftUI

/// Which timed-block track a point/x-coordinate belongs to. Top-to-bottom draw/hit-test order
/// matches this declaration order (SPEC §7.1): clip, zoom, layout (only if `source.hasCamera`),
/// mask.
enum Lane: CaseIterable, Sendable {
    case clip, zoom, layout, mask
}

/// What a point in `TimelineView` is over (SPEC §7.2 hit-testing table). `hitTest(at:)` checks in
/// exactly the table's order: playhead cap, block edge, block body, ✂ bubble, empty lane, ruler.
enum TimelineHit: Equatable {
    case playhead
    case clipEdge(Int, RecorderCore.Edge)
    case clipBody(Int)
    case cutBubble(afterClip: Int)
    case blockEdge(UUID, RecorderCore.Edge)
    case blockBody(UUID)
    case emptyLane(Lane, source: Double)
    case ruler
    case none
}

/// The single custom-drawn timeline: ruler + clip/zoom/layout/mask lanes + playhead (SPEC §7.1).
/// Renders from `EditorModel.project`; it never owns project data. A flipped, layer-backed
/// `NSView` that manages its own virtual horizontal scroll/zoom via `geometry` (no `NSScrollView`).
/// Navigation (T-405) and hit-testing/selection (T-406) are added on top of this file.
final class TimelineView: NSView {
    weak var model: EditorModel? {
        didSet {
            lastClips = model?.project.clips ?? [] // no ripple from the very first assignment
            observeModel()
            maybeFitOnFirstLayout()
            loadWaveformIfNeeded()
        }
    }

    var geometry = TimelineGeometry(pxPerSecond: 60, scrollX: 0, width: 0)

    static let gutter: CGFloat = 16
    static let rulerHeight: CGFloat = 22
    static let clipHeight: CGFloat = 44
    static let zoomHeight: CGFloat = 32
    static let layoutHeight: CGFloat = 28
    static let maskHeight: CGFloat = 28
    static let blockRadius: CGFloat = 10
    /// SPEC §7.2 "Navigation": zoom range is whole project ↔ 1 frame = 8 pt, at 60 fps.
    static let maxPxPerSecond: Double = 8 * 60

    // MARK: - Navigation state (T-405)

    private var autoScrollEnabled = true
    private var wasPlaying = false
    /// SPEC §7.2 "Navigation": the timeline opens fitted — see `maybeFitOnFirstLayout`.
    private var didFitOnFirstLayout = false
    private var userDidZoom = false
    private var dragKind: DragKind?
    /// A clip trim's fixed references, captured once at `beginGesture` (SPEC §7.2 "Trim"): the
    /// clip's pre-drag `sourceStart`/`speed` and the output-time position of its (unaffected)
    /// leading edge — everything a drag needs to turn "mouse x" into a target source time for
    /// *either* edge, since a clip's own leading edge is always at that fixed output position
    /// regardless of how it's trimmed (only clips *before* it determine that).
    private enum DragKind {
        case scrub
        case createBlock(id: UUID, lane: Lane, anchor: Double)
        case trimClip(index: Int, edge: RecorderCore.Edge, priorOutput: Double, beginSourceStart: Double, beginSourceEnd: Double, speed: Double)
        // Zoom/layout/mask blocks are all stored in *source* time and `clips` never changes under
        // these two (unlike a clip trim), so `model.timeMap` — stable for the whole gesture — does
        // the output→source conversion directly; no "begin" snapshot of the block itself is
        // needed. `lane` picks which `Project` op (`moveZoom`/`moveLayout`/`moveMask`, same for
        // resize) `updateMoveBlock`/`updateResizeBlock` calls — one generic drag, not copied per lane.
        case moveBlock(id: UUID, lane: Lane, grabOffset: Double) // grabOffset = (source under the mouse) − block.start, at mouseDown
        case resizeBlock(id: UUID, lane: Lane, edge: RecorderCore.Edge)
    }
    private var hoverX: CGFloat?
    private var hoverY: CGFloat?
    private var trackingArea: NSTrackingArea?

    // MARK: - Waveform (T-416)

    /// Loaded off the main thread once per open (`Waveform.peaks(for:)` itself also caches by
    /// URL, but this avoids re-dispatching the load / racing a second `model` assignment).
    private var waveformPeaks: [Float]?
    private var waveformLoadedForPackage: URL?
    /// For selftests: whether the async load (`loadWaveformIfNeeded`) has landed.
    var hasWaveform: Bool { waveformPeaks != nil }

    // MARK: - Trim (T-408)

    /// `(x, text)` for the "new duration (Δ ±0:01.20)" chip drawn next to the dragged edge.
    private var trimChip: (x: CGFloat, text: String)?

    // MARK: - Ripple animation (T-408)

    /// The clips as of the last draw — compared each time `model.project` changes to detect an
    /// edit that isn't this view's own live drag (SPEC §7.2 "Feel": "nothing animates while the
    /// user is dragging that block").
    private var lastClips: [Clip] = []
    /// The pre-change clips being animated *from*, while a ripple is in flight.
    private var rippleFromClips: [Clip]?
    private var rippleStart: CFTimeInterval?
    private static let rippleDuration: CFTimeInterval = 0.18

    // MARK: - Split mode (T-407)

    /// `S` / the ✂ toolbar button = sticky, until `Esc`. `⌥` held = momentary. Either makes
    /// `isSplitMode` true (SPEC §7.2 "Split").
    private var splitModeSticky = false
    private var splitOptionHeld = false
    private var isSplitMode: Bool { splitModeSticky || splitOptionHeld }

    /// AC-TL-7: while in split mode, the preview shows the blade's (hover) frame instead of the
    /// playhead. `PreviewView`/`EditorModel` aren't merged into this lane yet — a coordinator wires
    /// this callback once they are, per the plan's integration note. `nil` = show the playhead again.
    var onHoverTime: ((Double?) -> Void)?

    /// Set by `snappedOutput` whenever the last computed value snapped, for the 1 px accent guide
    /// line (SPEC §7.2 "Snapping"). Cleared by whoever isn't currently snapping.
    private var snapGuideX: CGFloat?

    // MARK: - Lightweight animations (split flash/shake now; T-408 adds ripple) — one shared
    // `CADisplayLink`, started on demand and stopped once nothing is left animating.

    private static let cutFlashDuration: CFTimeInterval = 0.25
    private static let bladeShakeDuration: CFTimeInterval = 0.3
    private var cutFlash: (x: CGFloat, start: CFTimeInterval)?
    private var bladeShakeStart: CFTimeInterval?
    private var animationLink: CADisplayLink?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - T-610 state snapshot accessors (`isSplitMode`/`dragKind` stay private otherwise)

    var debugSplitMode: Bool { isSplitMode }
    var debugDragKind: String? {
        switch dragKind {
        case .none: return nil
        case .scrub: return "scrub"
        case .createBlock: return "createBlock"
        case .trimClip: return "trimClip"
        case .moveBlock: return "moveBlock"
        case .resizeBlock: return "resizeBlock"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgPanel.cgColor
        toolTip = "Drag across an empty lane to choose a zoom, mask, or layout range. Escape cancels."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometry.width = max(0, newSize.width - Self.gutter)
        maybeFitOnFirstLayout()
        needsDisplay = true
    }

    // MARK: - Animation driver

    private func ensureAnimating() {
        guard animationLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(animationTick(_:)))
        link.add(to: .main, forMode: .common)
        animationLink = link
        needsDisplay = true
    }

    @objc private func animationTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var active = false
        if let start = cutFlash?.start {
            if now - start < Self.cutFlashDuration { active = true } else { cutFlash = nil }
        }
        if let start = bladeShakeStart {
            if now - start < Self.bladeShakeDuration { active = true } else { bladeShakeStart = nil }
        }
        if let start = rippleStart {
            if now - start < Self.rippleDuration { active = true } else { rippleStart = nil; rippleFromClips = nil }
        }
        needsDisplay = true
        if !active {
            link.invalidate()
            animationLink = nil
        }
    }

    // MARK: - Observation (SPEC §7: "Observe model with withObservationTracking")

    private func observeModel() {
        guard let model else { return }
        withObservationTracking {
            _ = model.project
            _ = model.playhead
            _ = model.isPlaying
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                // "manual scroll disables auto-scroll until playback restarts" (SPEC §7.2).
                if model.isPlaying, !self.wasPlaying { self.autoScrollEnabled = true }
                self.wasPlaying = model.isPlaying
                self.autoScrollIfNeeded()
                self.maybeFitOnFirstLayout() // the project's duration may only just have become known
                // T-408 "Ripple animation": clips changed from something other than a live drag
                // of this view's own doing (remove/restore/speed/undo/redo/an edit from elsewhere)
                // → animate from the old geometry. Nothing animates while a drag is active.
                if self.dragKind == nil, model.project.clips != self.lastClips {
                    self.beginRipple(from: self.lastClips)
                }
                self.lastClips = model.project.clips
                self.needsDisplay = true
                self.observeModel()
            }
        }
    }

    /// During playback, scroll a full page right once the playhead exits the right edge.
    private func autoScrollIfNeeded() {
        guard let model, model.isPlaying, autoScrollEnabled else { return }
        if geometry.x(forOutput: model.playhead) >= geometry.width {
            geometry.scrollX = clampScrollX(geometry.scrollX + geometry.width)
        }
    }

    // MARK: - Lane layout

    private var hasLayoutLane: Bool { model != nil }

    private func laneHeight(_ lane: Lane) -> CGFloat {
        switch lane {
        case .clip: return Self.clipHeight
        case .zoom: return Self.zoomHeight
        case .layout: return hasLayoutLane ? Self.layoutHeight : 0
        case .mask: return Self.maskHeight // SPEC §7.1: always shown, like the zoom lane (not gated on hasCamera)
        }
    }

    /// Full-width row (spans the icon gutter too), in view-local (flipped) coordinates.
    private func laneRow(_ lane: Lane) -> CGRect {
        var y = Self.rulerHeight
        for l in Lane.allCases {
            let h = laneHeight(l)
            if l == lane { return CGRect(x: 0, y: y, width: bounds.width, height: h) }
            y += h
        }
        return .zero
    }

    private var rulerRow: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight) }

    /// Total content height (ruler + every visible lane).
    private var contentHeight: CGFloat { Lane.allCases.reduce(Self.rulerHeight) { $0 + laneHeight($1) } }

    /// View-local x for output time `t`, past the icon gutter.
    private func x(forOutput t: Double) -> CGFloat { Self.gutter + CGFloat(geometry.x(forOutput: t)) }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        Theme.bgPanel.setFill()
        bounds.fill()

        guard let model else { return }
        let project = model.project
        let timeMap = model.timeMap

        drawGutterIcons()
        drawRuler()
        drawClipLane(project, timeMap)
        drawZoomLane(project, timeMap)
        drawClickTicks(project, timeMap)
        drawEmptyLaneGhost()
        if hasLayoutLane { drawLayoutLane(project, timeMap) }
        drawMaskLane(project, timeMap)
        drawLaneDividers()
        drawPlayhead(model.playhead)
        // Drawn after the playhead/its timecode chip so a cut near the playhead is never hidden
        // behind them — the ✂ bubble is an actionable affordance, the chip is informational.
        drawCutBubbles(project)
        drawHover()
        if isSplitMode { drawSplitBlade() }
        drawCutFlash()
        // SPEC §7.2 "Snapping": "a 1 px accent guide line spans all tracks while snapped" — applies
        // to every drag that sets `snapGuideX` (the split blade draws its own, mid-blade, above).
        if !isSplitMode, let snapGuideX { drawSnapGuide(at: snapGuideX) }
        drawTrimChip()
    }

    private func drawTrimChip() {
        guard let trimChip else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary]
        let label = trimChip.text as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: trimChip.x - size.width / 2 - 4, y: Self.rulerHeight + 4, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    private func drawLaneDividers() {
        Theme.stroke.setStroke()
        var y = Self.rulerHeight
        for lane in Lane.allCases {
            let h = laneHeight(lane)
            guard h > 0 else { continue }
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 0, y: y))
            line.line(to: CGPoint(x: bounds.width, y: y))
            line.lineWidth = 1
            line.stroke()
            y += h
        }
        let bottom = NSBezierPath()
        bottom.move(to: CGPoint(x: 0, y: y))
        bottom.line(to: CGPoint(x: bounds.width, y: y))
        bottom.lineWidth = 1
        bottom.stroke()

        let gutterLine = NSBezierPath()
        gutterLine.move(to: CGPoint(x: Self.gutter, y: 0))
        gutterLine.line(to: CGPoint(x: Self.gutter, y: contentHeight))
        gutterLine.lineWidth = 1
        gutterLine.stroke()
    }

    private func drawGutterIcons() {
        let icons: [Lane: String] = [.clip: "rectangle.stack", .zoom: "magnifyingglass", .layout: "person.crop.square", .mask: "rectangle.dashed"]
        for lane in Lane.allCases {
            guard laneHeight(lane) > 0, let symbol = icons[lane] else { continue }
            let row = laneRow(lane)
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { continue }
            let size = CGSize(width: 12, height: 12)
            let rect = CGRect(x: (Self.gutter - size.width) / 2, y: row.midY - size.height / 2, width: size.width, height: size.height)
            image.isTemplate = true
            NSGraphicsContext.saveGraphicsState()
            Theme.textSecondary.set()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Ruler

    private func drawRuler() {
        let interval = geometry.tickInterval()
        guard interval > 0 else { return }
        let firstTick = floor(geometry.output(forX: 0) / interval) * interval
        var t = max(0, firstTick)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textSecondary]
        while x(forOutput: t) <= bounds.width {
            let px = x(forOutput: t)
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: px, y: Self.rulerHeight - 6))
            tick.line(to: CGPoint(x: px, y: Self.rulerHeight))
            Theme.textSecondary.withAlphaComponent(0.5).setStroke()
            tick.lineWidth = 1
            tick.stroke()

            let label = rulerLabel(t, interval: interval) as NSString
            label.draw(at: CGPoint(x: px + 4, y: 3), withAttributes: attrs)
            t += interval
        }
    }

    // MARK: - Clip lane

    private func drawClipLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.clip)
        let clips = project.clips
        let targetRects = clipRects(clips, row: row)
        // T-408 "Ripple animation": ease from the pre-change geometry, keyed by index —
        // ponytail: animate by index; fine because ops change at most one seam.
        let eased = dragKind == nil ? rippleEasedProgress() : nil
        let fromRects = eased != nil ? clipRects(rippleFromClips ?? clips, row: row) : nil

        var outStart = 0.0
        for (i, clip) in clips.enumerated() {
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            var rect = targetRects[i]
            if let eased, let fromRects, i < fromRects.count { rect = lerp(fromRects[i], targetRects[i], eased) }
            guard rect.width > 0.5 else { continue }
            let label = clip.speed != 1 ? "\(formatSpeed(clip.speed))\u{00D7} \u{23E9}" : nil
            drawBlock(rect, fill: Theme.clip, tornLeft: false, tornRight: false, label: label, selected: model?.selectedClip == i)
            drawWaveform(in: rect, outStart: outStart, outEnd: outEnd, timeMap: timeMap)
        }
    }

    /// SPEC §7.1 clip lane: "waveform" peaks drawn inside each clip block, mapped through
    /// `TimeMap` — `px`'s fraction across `rect` maps to output time `[outStart, outEnd)`, so the
    /// waveform tracks the block exactly, including mid-ripple.
    private func drawWaveform(in rect: CGRect, outStart: Double, outEnd: Double, timeMap: TimeMap) {
        guard let waveformPeaks, !waveformPeaks.isEmpty, outEnd > outStart else { return }
        let inset = rect.insetBy(dx: 5, dy: 6)
        guard inset.width > 1 else { return }
        let midY = inset.midY
        Theme.textPrimary.withAlphaComponent(0.45).setFill()
        var px = inset.minX
        while px < inset.maxX {
            let fraction = (px - inset.minX) / inset.width
            let outputT = outStart + fraction * (outEnd - outStart)
            let sourceT = timeMap.sourceTime(atOutput: outputT)
            let index = Int(sourceT * Double(Waveform.peaksPerSecond))
            if waveformPeaks.indices.contains(index) {
                let amplitude = max(1, CGFloat(min(1, waveformPeaks[index])) * inset.height / 2)
                NSRect(x: px, y: midY - amplitude, width: 1, height: amplitude * 2).fill()
            }
            px += 1
        }
    }

    // MARK: - Waveform loading (T-416)

    /// `AVAssetReader`-backed, so off the main thread; `Waveform.peaks(for:)` also caches by URL
    /// (`// ponytail: computed on open, not cached on disk`, per `Waveform.swift`).
    private func loadWaveformIfNeeded() {
        guard let model, waveformLoadedForPackage != model.packageURL else { return }
        let packageURL = model.packageURL
        waveformLoadedForPackage = packageURL
        guard let audioURL = Waveform.audioURL(in: packageURL) else { return }
        Task.detached { [weak self] in
            let peaks = try? Waveform.peaks(for: audioURL)
            await MainActor.run {
                guard let self, self.waveformLoadedForPackage == packageURL else { return } // superseded by a later `model`
                self.waveformPeaks = peaks
                self.needsDisplay = true
            }
        }
    }

    /// Each clip's rect (SPEC §7.1 clip lane), for an arbitrary `clips` array — used both for the
    /// live geometry and (during a ripple) the pre-change geometry it's animating from.
    private func clipRects(_ clips: [Clip], row: CGRect) -> [CGRect] {
        var outStart = 0.0
        return clips.map { clip in
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            // A 1.5 pt gap on each side keeps neighbouring clips visually separate (their seam is
            // where a cut/trim can be restored) even though they're the same colour.
            return CGRect(x: x(forOutput: outStart) + 1.5, y: row.minY + 2,
                           width: max(0, x(forOutput: outEnd) - x(forOutput: outStart) - 3), height: row.height - 4)
        }
    }

    private func beginRipple(from oldClips: [Clip]) {
        guard !oldClips.isEmpty else { return }
        rippleFromClips = oldClips
        rippleStart = CACurrentMediaTime()
        ensureAnimating()
    }

    /// 0...1 ease-out progress, or `nil` once the 0.18 s ripple has finished.
    private func rippleEasedProgress() -> Double? {
        guard let rippleStart else { return nil }
        let elapsed = CACurrentMediaTime() - rippleStart
        guard elapsed < Self.rippleDuration else { return nil }
        let t = elapsed / Self.rippleDuration
        return 1 - pow(1 - t, 3) // ease-out cubic
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: b.minY,
               width: a.width + (b.width - a.width) * t, height: b.height)
    }

    // MARK: - Zoom / layout lanes (source-time blocks mapped through TimeMap; SPEC §7.1)

    private func drawZoomLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.zoom)
        let selection = model?.selection ?? []
        for zoom in project.zooms {
            let label = "\u{1F50D} \(String(format: "%.1f", zoom.scale))\u{00D7} \(zoom.mode == .auto ? "A" : "M")"
            let selected = UUID(uuidString: zoom.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: zoom.start, end: zoom.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.accent, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    private func drawLayoutLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.layout)
        let selection = model?.selection ?? []
        for layout in project.layouts {
            let label = layout.kind == .settings ? "Keystrokes" : layout.kind == .cameraFull ? "\u{25C9} Camera full" : layout.kind == .hidden ? "\u{25CB} Hidden" : "Camera · size / position"
            let selected = UUID(uuidString: layout.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: layout.start, end: layout.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.layout, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    /// SPEC §7.1 mask lane (T-601, "▦" mask / "◐" highlight). The mask RECT itself is edited in
    /// the preview (`MaskRectOverlay`), not here — this lane only shows the block's time range.
    private func drawMaskLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.mask)
        let selection = model?.selection ?? []
        for mask in project.masks {
            let kindLabel = mask.kind == .highlight ? "\u{25D0} Highlight" : (mask.kind == .blur ? "Blur" : "Mask")
            let label = "\(kindLabel) \(Int((mask.opacity * 100).rounded()))%"
            let selected = UUID(uuidString: mask.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: mask.start, end: mask.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.mask, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    /// The portions of source range `[start, end]` that survive the clip cuts, as output-time
    /// ranges — a zoom/layout block spanning a removed segment is drawn only for its visible
    /// part(s), each flagged for a torn `⌇` edge where the source range continues into a cut.
    private func visibleSegments(start: Double, end: Double, project: Project, timeMap: TimeMap)
        -> [(outStart: Double, outEnd: Double, tornLeft: Bool, tornRight: Bool)] {
        var segments: [(Double, Double, Bool, Bool)] = []
        for clip in project.clips {
            let lo = max(start, clip.sourceStart)
            let hi = min(end, clip.sourceEnd)
            guard lo < hi, let outLo = timeMap.outputTime(atSource: lo), let outHi = timeMap.outputTime(atSource: hi) else { continue }
            segments.append((outLo, outHi, lo > start, hi < end))
        }
        return segments
    }

    // MARK: - Block drawing (rounded rect radius 10, 1 px inner highlight, centred label)

    private func drawBlock(_ rect: CGRect, fill: NSColor, tornLeft: Bool, tornRight: Bool, label: String?, selected: Bool = false) {
        let radius = min(Self.blockRadius, rect.height / 2, rect.width / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()

        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        highlight.lineWidth = 1
        Theme.textPrimary.withAlphaComponent(0.15).setStroke()
        highlight.stroke()

        // Selection: 2 px white outline + glow (SPEC §7.2 "Selection").
        if selected {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = Theme.textPrimary.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = .zero
            shadow.set()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
            outline.lineWidth = 2
            Theme.textPrimary.setStroke()
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Torn edge marker (SPEC §7.1: "torn edge ⌇ when partially hidden" — U+2307 WAVY LINE).
        let tornAttrs: [NSAttributedString.Key: Any] = [.font: Theme.bodyFont, .foregroundColor: Theme.textPrimary.withAlphaComponent(0.6)]
        if tornLeft { ("\u{2307}" as NSString).draw(at: CGPoint(x: rect.minX + 1, y: rect.midY - 7), withAttributes: tornAttrs) }
        if tornRight { ("\u{2307}" as NSString).draw(at: CGPoint(x: rect.maxX - 9, y: rect.midY - 7), withAttributes: tornAttrs) }

        guard let label, rect.width > 24 else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.captionFont, .foregroundColor: Theme.textPrimary]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        let textRect = CGRect(x: rect.minX + 6, y: rect.minY + (rect.height - size.height) / 2, width: rect.width - 12, height: size.height)
        text.draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Playhead

    private func drawPlayhead(_ t: Double) {
        let px = x(forOutput: t)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: px, y: 0))
        line.line(to: CGPoint(x: px, y: contentHeight))
        line.lineWidth = 2
        Theme.textPrimary.setStroke()
        line.stroke()

        let capSize: CGFloat = 8
        let cap = NSBezierPath()
        cap.move(to: CGPoint(x: px - capSize / 2, y: 0))
        cap.line(to: CGPoint(x: px + capSize / 2, y: 0))
        cap.line(to: CGPoint(x: px, y: capSize))
        cap.close()
        Theme.textPrimary.setFill()
        cap.fill()

        // A small opaque chip behind the timecode (SPEC §7.1 second ruler line) so it reads over
        // the ruler's own ticks/labels regardless of overlap.
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary]
        let label = playheadLabel(t) as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: px + 6, y: 2, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    /// 1 px white @ 30% line following the mouse, with a timecode tooltip (SPEC §7.1 "hover line").
    private func drawHover() {
        guard let hoverX, hoverX > Self.gutter else { return }
        let line = NSBezierPath()
        line.move(to: CGPoint(x: hoverX, y: 0))
        line.line(to: CGPoint(x: hoverX, y: contentHeight))
        line.lineWidth = 1
        Theme.textPrimary.withAlphaComponent(0.3).setStroke()
        line.stroke()

        let t = geometry.output(forX: Double(hoverX) - Double(Self.gutter))
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(10), .foregroundColor: Theme.textSecondary]
        let label = playheadLabel(t) as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: hoverX + 4, y: contentHeight - size.height - 6, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    // MARK: - Split mode (SPEC §7.2 "Split" — the headline interaction)

    /// Full-height dashed accent blade at the snapped mouse x, with a timecode chip. `nil` when the
    /// mouse hasn't hovered the view yet.
    private func drawSplitBlade() {
        guard let t = bladeOutputTime() else { return }
        let px = x(forOutput: t) + bladeShakeOffset()

        let line = NSBezierPath()
        line.move(to: CGPoint(x: px, y: 0))
        line.line(to: CGPoint(x: px, y: contentHeight))
        line.lineWidth = 1.5
        line.setLineDash([4, 3], count: 2, phase: 0)
        Theme.accent.setStroke()
        line.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary]
        let label = playheadLabel(t) as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: px + 6, y: Self.rulerHeight + 4, width: size.width + 8, height: size.height + 4)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)

        if let snapGuideX { drawSnapGuide(at: snapGuideX) }
    }

    /// SPEC §7.2 "Snapping": "a 1 px accent guide line spans all tracks while snapped."
    private func drawSnapGuide(at px: CGFloat) {
        let line = NSBezierPath()
        line.move(to: CGPoint(x: px, y: 0))
        line.line(to: CGPoint(x: px, y: contentHeight))
        line.lineWidth = 1
        Theme.accent.withAlphaComponent(0.8).setStroke()
        line.stroke()
    }

    /// A refused split (SPEC §7.2): "3-cycle 4 px horizontal shake of the blade, no alert."
    private func bladeShakeOffset() -> CGFloat {
        guard let bladeShakeStart else { return 0 }
        let elapsed = CACurrentMediaTime() - bladeShakeStart
        guard elapsed < Self.bladeShakeDuration else { return 0 }
        let cycles = 3.0
        return CGFloat(sin(elapsed / Self.bladeShakeDuration * cycles * 2 * .pi)) * 4
    }

    /// A successful split (SPEC §7.2): "a 0.25 s 'cut flash' (white line fading) confirms it."
    private func drawCutFlash() {
        guard let cutFlash else { return }
        let elapsed = CACurrentMediaTime() - cutFlash.start
        guard elapsed < Self.cutFlashDuration else { return }
        let alpha = 1 - CGFloat(elapsed / Self.cutFlashDuration)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: cutFlash.x, y: 0))
        line.line(to: CGPoint(x: cutFlash.x, y: contentHeight))
        line.lineWidth = 2
        Theme.textPrimary.withAlphaComponent(alpha).setStroke()
        line.stroke()
    }

    /// The blade's current (snapped) output time, from the last hover position. `nil` before the
    /// mouse has ever entered the view.
    private func bladeOutputTime() -> Double? {
        guard let hoverX, hoverX > Self.gutter, let model else { return nil }
        let raw = geometry.output(forX: geometryX(NSPoint(x: hoverX, y: 0)))
        let (value, snapped) = snappedOutput(raw, disabled: NSEvent.modifierFlags.contains(.command))
        snapGuideX = snapped ? x(forOutput: value) : nil
        return min(max(0, value), model.timeMap.outputDuration)
    }

    /// `Esc` exits split mode; the ✂ toolbar button and `S` toggle the sticky half of it.
    func toggleSplitModeSticky() {
        if splitModeSticky { exitSplitMode() } else { splitModeSticky = true; needsDisplay = true; updateHoverCallback() }
    }

    private func exitSplitMode() {
        guard isSplitMode else { return }
        splitModeSticky = false
        splitOptionHeld = false
        snapGuideX = nil
        onHoverTime?(nil)
        needsDisplay = true
    }

    /// `C` (immediate, at the playhead) and a split-mode click (at the blade) both land here.
    /// Refused (SPEC: within 2 frames of an edge, or a piece would be too short) → shake, no undo
    /// step. Success → exactly one `model.edit` (one undo step) + the cut flash.
    private func performSplit(atOutput t: Double) {
        guard let model else { return }
        var trial = model.project
        guard trial.split(atOutput: t) else {
            bladeShakeStart = CACurrentMediaTime()
            ensureAnimating()
            return
        }
        let px = x(forOutput: t)
        model.edit("Split") { _ = $0.split(atOutput: t) }
        cutFlash = (x: px, start: CACurrentMediaTime())
        ensureAnimating()
    }

    private func updateHoverCallback() {
        guard isSplitMode, let t = bladeOutputTime() else { onHoverTime?(nil); return }
        onHoverTime?(t)
    }

    // MARK: - Snapping (SPEC §7.2 "Snapping" — shared by the split blade, trims (T-408) and

    // block move/resize (T-409): one routine, not three.

    /// Candidate output-time snap points: the playhead, every clip edge, every visible zoom/layout/
    /// mask block edge (excluding one being dragged), and click events from the event log.
    private func snapCandidates(excludingBlock: UUID? = nil) -> [Double] {
        guard let model else { return [] }
        var candidates: [Double] = [model.playhead]
        var outStart = 0.0
        for clip in model.project.clips {
            candidates.append(outStart)
            outStart += clip.outputDuration
            candidates.append(outStart)
        }
        let timeMap = model.timeMap
        let project = model.project
        let laneBlocks: [[(id: String, start: Double, end: Double)]] = [
            project.zooms.map { ($0.id, $0.start, $0.end) },
            project.layouts.map { ($0.id, $0.start, $0.end) },
            project.masks.map { ($0.id, $0.start, $0.end) },
        ]
        for blocks in laneBlocks {
            for b in blocks where UUID(uuidString: b.id) != excludingBlock {
                for segment in visibleSegments(start: b.start, end: b.end, project: project, timeMap: timeMap) {
                    candidates.append(segment.outStart)
                    candidates.append(segment.outEnd)
                }
            }
        }
        for click in model.events.clicks() {
            if let out = timeMap.outputTime(atSource: click.t) { candidates.append(out) }
        }
        return candidates
    }

    /// `raw` (an output time under the mouse) snapped to the nearest candidate within 6 pt,
    /// converted to seconds at the current zoom. `disabled` (⌘ held) skips snapping entirely.
    private func snappedOutput(_ raw: Double, excludingBlock: UUID? = nil, disabled: Bool) -> (value: Double, snapped: Bool) {
        guard !disabled else { return (raw, false) }
        let threshold = 6 / max(geometry.pxPerSecond, 1)
        return snap(raw, candidates: snapCandidates(excludingBlock: excludingBlock), threshold: threshold)
    }

    // MARK: - Timecode formatting

    private func rulerLabel(_ t: Double, interval: Double) -> String {
        let t = max(0, t)
        if interval < 1 {
            let frames = Int((t * 60).rounded())
            return String(format: "%d:%02d;%02d", frames / 3600, (frames / 60) % 60, frames % 60)
        }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func playheadLabel(_ t: Double) -> String {
        let centi = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centi / 6000, (centi / 100) % 60, centi % 100)
    }

    private func formatSpeed(_ speed: Double) -> String {
        speed.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", speed) : String(format: "%.1f", speed)
    }

    // MARK: - Hit-testing (SPEC §7.2 table; checked in exactly the table's order)

    /// 6 pt edge zone, shrinking to 3 pt when the block is narrower than 24 pt (SPEC §7.2).
    private func edgeZone(width: CGFloat) -> CGFloat { width < 24 ? 3 : 6 }

    func hitTest(at p: CGPoint) -> TimelineHit {
        guard let model else { return .none }

        let playheadX = x(forOutput: model.playhead)
        if p.y <= Self.rulerHeight, abs(p.x - playheadX) <= 6 { return .playhead }

        if let hit = hitClipLane(p, model) { return hit }
        if let hit = hitBlockLane(p, model, lane: .zoom, blocks: model.project.zooms.map { ($0.id, $0.start, $0.end) }) { return hit }
        if hasLayoutLane, let hit = hitBlockLane(p, model, lane: .layout, blocks: model.project.layouts.map { ($0.id, $0.start, $0.end) }) {
            return hit
        }
        if let hit = hitBlockLane(p, model, lane: .mask, blocks: model.project.masks.map { ($0.id, $0.start, $0.end) }) { return hit }
        if let hit = hitCutBubble(p, model) { return hit }
        if let hit = hitEmptyLane(p, model) { return hit }
        if p.y <= Self.rulerHeight { return .ruler }
        return .none
    }

    private func hitClipLane(_ p: CGPoint, _ model: EditorModel) -> TimelineHit? {
        let row = laneRow(.clip)
        guard p.y >= row.minY, p.y <= row.maxY else { return nil }
        var outStart = 0.0
        for (i, clip) in model.project.clips.enumerated() {
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            let x0 = x(forOutput: outStart), x1 = x(forOutput: outEnd)
            guard p.x >= x0, p.x <= x1 else { continue }
            let zone = edgeZone(width: x1 - x0)
            if p.x <= x0 + zone { return .clipEdge(i, .leading) }
            if p.x >= x1 - zone { return .clipEdge(i, .trailing) }
            return .clipBody(i)
        }
        return nil
    }

    /// Shared by the zoom/layout lanes: `blocks` visible span(s) come from the same
    /// `visibleSegments` the drawing code uses, so you can only grab what's actually on screen.
    private func hitBlockLane(_ p: CGPoint, _ model: EditorModel, lane: Lane, blocks: [(id: String, start: Double, end: Double)]) -> TimelineHit? {
        let row = laneRow(lane)
        guard p.y >= row.minY, p.y <= row.maxY else { return nil }
        let timeMap = model.timeMap
        for b in blocks {
            for segment in visibleSegments(start: b.start, end: b.end, project: model.project, timeMap: timeMap) {
                let x0 = x(forOutput: segment.outStart), x1 = x(forOutput: segment.outEnd)
                guard p.x >= x0, p.x <= x1, let uuid = UUID(uuidString: b.id) else { continue }
                let zone = edgeZone(width: x1 - x0)
                if p.x <= x0 + zone { return .blockEdge(uuid, .leading) }
                if p.x >= x1 - zone { return .blockEdge(uuid, .trailing) }
                return .blockBody(uuid)
            }
        }
        return nil
    }

    /// Every seam with a cut/trim to restore, as (which clip it follows, `-1` = the head, its
    /// output x): between two clips whose source ranges don't meet, and at the head/tail when
    /// trimmed. Shared by hit-testing and drawing the ✂ bubble (SPEC §7.2 "Restore").
    private func cutBubbleSeams(_ project: Project) -> [(afterClip: Int, outputX: CGFloat)] {
        let clips = project.clips
        guard !clips.isEmpty else { return [] }
        let eps = 1e-6
        var seams: [(Int, CGFloat)] = []
        if clips[0].sourceStart > eps { seams.append((-1, x(forOutput: 0))) }
        var outEnd = 0.0
        for i in clips.indices {
            outEnd += clips[i].outputDuration
            if i < clips.count - 1, clips[i + 1].sourceStart - clips[i].sourceEnd > eps {
                seams.append((i, x(forOutput: outEnd)))
            }
        }
        if project.source.duration - clips[clips.count - 1].sourceEnd > eps { seams.append((clips.count - 1, x(forOutput: outEnd))) }
        return seams
    }

    /// A small hit box at every seam with a cut/trim (straddling the ruler/clip-lane divider so it
    /// never competes with a clip edge's hit zone).
    private func hitCutBubble(_ p: CGPoint, _ model: EditorModel) -> TimelineHit? {
        let bandTop = laneRow(.clip).minY - 8
        guard p.y >= bandTop, p.y <= bandTop + 8 else { return nil }
        for seam in cutBubbleSeams(model.project) where CGRect(x: seam.outputX - 6, y: bandTop, width: 12, height: 8).contains(p) {
            return .cutBubble(afterClip: seam.afterClip)
        }
        return nil
    }

    /// Draws the ✂ bubble at every seam (SPEC §7.1: "✂ bubble = a cut/trim exists here; click it
    /// to restore").
    private func drawCutBubbles(_ project: Project) {
        let bandTop = laneRow(.clip).minY - 8
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.captionFont, .foregroundColor: Theme.textPrimary]
        let glyph = "\u{2702}" as NSString
        let size = glyph.size(withAttributes: attrs)
        for seam in cutBubbleSeams(project) {
            let rect = CGRect(x: seam.outputX - 6, y: bandTop, width: 12, height: 8)
            Theme.bgControl.setFill()
            NSBezierPath(ovalIn: rect).fill()
            glyph.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 1), withAttributes: attrs)
        }
    }

    private func hitEmptyLane(_ p: CGPoint, _ model: EditorModel) -> TimelineHit? {
        for lane: Lane in [.zoom, .layout, .mask] {
            guard laneHeight(lane) > 0 else { continue }
            let row = laneRow(lane)
            guard p.y >= row.minY, p.y <= row.maxY, p.x >= Self.gutter else { continue }
            let t = geometry.output(forX: geometryX(p))
            return .emptyLane(lane, source: model.timeMap.sourceTime(atOutput: t))
        }
        return nil
    }

    // MARK: - Cursors (SPEC §7.2 table)

    private func cursor(for hit: TimelineHit) -> NSCursor {
        switch hit {
        case .playhead, .clipEdge, .blockEdge: return .resizeLeftRight
        case .blockBody: return .openHand
        case .cutBubble: return .pointingHand
        case .emptyLane: return .crosshair
        case .clipBody, .ruler, .none: return .arrow
        }
    }

    // MARK: - Selection (SPEC §7.2 "Selection")

    private func lane(ofBlock id: UUID) -> Lane? {
        guard let model else { return nil }
        let key = id.uuidString
        if model.project.zooms.contains(where: { $0.id == key }) { return .zoom }
        if model.project.layouts.contains(where: { $0.id == key }) { return .layout }
        if model.project.masks.contains(where: { $0.id == key }) { return .mask }
        return nil
    }

    private func selectClip(_ i: Int) {
        model?.selectedClip = i
        model?.selection = []
    }

    private func selectBlock(_ id: UUID, addToSelection: Bool) {
        guard let model else { return }
        model.selectedClip = nil
        if addToSelection, let existing = model.selection.first, lane(ofBlock: existing) == lane(ofBlock: id) {
            model.selection.insert(id)
        } else {
            model.selection = [id]
        }
    }

    private func deselect() {
        model?.selectedClip = nil
        model?.selection = []
    }

    /// `⌫` removes the selection: the selected clip, or every selected zoom/layout/mask block.
    private func removeSelection() {
        guard let model else { return }
        if let i = model.selectedClip {
            model.edit("Remove Clip") { _ = $0.removeClip(i) }
            model.selectedClip = nil
        } else if !model.selection.isEmpty {
            let ids = model.selection
            model.edit("Remove") { project in for id in ids { project.removeBlock(id) } }
            model.selection = []
        }
    }

    // MARK: - Context menus (SPEC §7.2 "Context menus")

    private func isInClipLane(_ p: CGPoint) -> Bool {
        let row = laneRow(.clip)
        return p.y >= row.minY && p.y <= row.maxY
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        switch hitTest(at: p) {
        case .clipBody(let i), .clipEdge(let i, _):
            return clipContextMenu(index: i)
        case .blockBody(let id), .blockEdge(let id, _):
            return lane(ofBlock: id) == .zoom ? zoomContextMenu(id: id) : nil
        case .ruler:
            return rulerContextMenu()
        default:
            // `hitTest`'s `.emptyLane` is only defined for the zoom/layout/mask lanes (SPEC §7.2
            // table); an empty spot in the clip lane itself (past the last clip) falls through to
            // `.none` there, so it's recognised here instead.
            return isInClipLane(p) ? emptyClipAreaMenu() : nil
        }
    }

    private func actionItem(_ title: String, action: Selector?, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    /// SPEC §7.2 "Context menus": `Clip: Split at Playhead (C) · Speed ▸ · Mute Audio · Remove (⌫)`.
    private func clipContextMenu(index: Int) -> NSMenu {
        selectClip(index)
        let menu = NSMenu()
        menu.addItem(actionItem("Split at Playhead (C)", action: #selector(menuSplitAtPlayhead)))
        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedSubmenu(index: index)
        menu.addItem(speed)
        // ponytail: `Clip` has no per-clip mute field yet (adding one is a `Project.swift` change,
        // out of this lane's scope while other agents are editing it) — shown, but disabled.
        menu.addItem(actionItem("Mute Audio", action: nil))
        menu.items.last?.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(actionItem("Remove (\u{232B})", action: #selector(menuRemoveClip(_:)), represented: index))
        return menu
    }

    private struct SpeedTarget { let index: Int; let speed: Double }

    private func speedSubmenu(index: Int) -> NSMenu {
        let menu = NSMenu()
        let current = model?.project.clips[index].speed
        for preset in [0.5, 1, 1.5, 2, 4, 8] {
            let item = actionItem("\(formatSpeed(preset))\u{00D7}", action: #selector(menuSetSpeed(_:)),
                                   represented: SpeedTarget(index: index, speed: preset))
            item.state = current == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Custom\u{2026}", action: #selector(menuCustomSpeed(_:)), represented: SpeedTarget(index: index, speed: 0)))
        return menu
    }

    @objc private func menuSplitAtPlayhead() {
        guard let model else { return }
        performSplit(atOutput: model.playhead)
    }

    @objc private func menuRemoveClip(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        model?.edit("Remove Clip") { _ = $0.removeClip(i) }
    }

    @objc private func menuSetSpeed(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SpeedTarget else { return }
        model?.edit("Speed") { $0.setSpeed(target.index, target.speed) }
    }

    /// `Speed ▸ Custom…`: an `NSAlert` with a text field (0.25...16), mirroring the "Custom Size"
    /// pattern already used for the area-selection overlay.
    @objc private func menuCustomSpeed(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SpeedTarget, let model,
              model.project.clips.indices.contains(target.index) else { return }
        let field = NSTextField(string: String(format: "%.2f", model.project.clips[target.index].speed))
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        let alert = NSAlert()
        alert.messageText = "Custom Speed"
        alert.informativeText = "0.25\u{2013}16\u{00D7}"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let value = Double(field.stringValue) else { return }
        model.edit("Speed") { $0.setSpeed(target.index, value) }
    }

    /// SPEC §7.2 "Context menus": `Empty clip-track area: Restore All Cuts`.
    private func emptyClipAreaMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem("Restore All Cuts", action: #selector(menuRestoreAllCuts)))
        return menu
    }

    @objc private func menuRestoreAllCuts() {
        model?.edit("Restore All Cuts") { $0.restoreAllCuts() }
    }

    /// SPEC §7.2 "Context menus": `Ruler: Fit (⇧Z) · Zoom to Selection`.
    private func rulerContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem("Fit (\u{21E7}Z)", action: #selector(menuFit)))
        let zoomToSelection = actionItem("Zoom to Selection", action: #selector(menuZoomToSelection))
        zoomToSelection.isEnabled = model?.selectedClip != nil
        menu.addItem(zoomToSelection)
        return menu
    }

    @objc private func menuFit() { fit() }

    @objc private func menuZoomToSelection() {
        guard let model, let i = model.selectedClip, model.project.clips.indices.contains(i) else { return }
        var outStart = 0.0
        for c in model.project.clips[0..<i] { outStart += c.outputDuration }
        let outEnd = outStart + model.project.clips[i].outputDuration
        guard outEnd > outStart, geometry.width > 0 else { return }
        geometry.pxPerSecond = min(Self.maxPxPerSecond, geometry.width / (outEnd - outStart))
        geometry.scrollX = clampScrollX(outStart * geometry.pxPerSecond)
        needsDisplay = true
    }

    // MARK: - Zoom range + fit (SPEC §7.2 "Navigation")

    /// The px/s that fits the whole project's output duration in the current view width — the
    /// low end of the zoom range ("whole project ↔ 1 frame = 8 pt").
    private func minPxPerSecond() -> Double {
        guard let model else { return 8 }
        let duration = model.timeMap.outputDuration
        return duration > 0 ? geometry.width / duration : 8
    }

    private func clampScrollX(_ x: Double) -> Double {
        let maxX = max(0, (model?.timeMap.outputDuration ?? 0) * geometry.pxPerSecond - geometry.width)
        return min(max(0, x), maxX)
    }

    /// `⇧Z` / the Fit button: zooms out (or in) to show the whole project.
    func fit() {
        geometry.pxPerSecond = minPxPerSecond()
        geometry.scrollX = 0
        needsDisplay = true
    }

    private func zoom(by factor: Double, anchorX: Double) {
        userDidZoom = true // don't auto-fit again once the user has manually zoomed (T-405 fix)
        geometry.zoom(by: factor, anchorX: anchorX, minPxPerSecond: minPxPerSecond(), maxPxPerSecond: Self.maxPxPerSecond)
        geometry.scrollX = clampScrollX(geometry.scrollX)
        needsDisplay = true
    }

    /// SPEC §7.2 "Navigation": the timeline opens fitted. `setFrameSize`/`model`'s `didSet`/an
    /// observed project change all call this; it only ever fires once (on whichever of those
    /// happens last — first non-zero width *and* a known duration), and never once the user has
    /// manually zoomed.
    private func maybeFitOnFirstLayout() {
        guard !didFitOnFirstLayout, !userDidZoom, geometry.width > 0, let model, model.timeMap.outputDuration > 0 else { return }
        fit()
        didFitOnFirstLayout = true
    }

    /// 0...1 position for a "slider in the timeline toolbar" (linear over the zoom range).
    var zoomSliderValue: Double {
        let lo = minPxPerSecond(), hi = Self.maxPxPerSecond
        guard hi > lo else { return 0 }
        return (geometry.pxPerSecond - lo) / (hi - lo)
    }

    func setZoom(sliderValue: Double) {
        let lo = minPxPerSecond(), hi = Self.maxPxPerSecond
        let target = lo + (hi - lo) * min(max(sliderValue, 0), 1)
        zoom(by: target / geometry.pxPerSecond, anchorX: geometry.x(forOutput: model?.playhead ?? 0))
    }

    /// View-local x (past the gutter, as `geometry` expects) for a point already converted to
    /// this view's coordinate space.
    private func geometryX(_ p: NSPoint) -> Double { Double(p.x) - Double(Self.gutter) }

    // MARK: - Scroll / pinch (SPEC §7.2 "Navigation")

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(Double(event.scrollingDeltaY) * 0.01), anchorX: geometryX(p))
        } else {
            geometry.scrollX = clampScrollX(geometry.scrollX - Double(event.scrollingDeltaX))
            autoScrollEnabled = false
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + Double(event.magnification), anchorX: geometryX(p))
    }

    // MARK: - Keyboard (⌘=/⌘- anchored at the playhead, ⇧Z = fit, C/S = split — SPEC §7.3)

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers
        if cmd, chars == "=" || chars == "+", let model {
            zoom(by: 1.4, anchorX: geometry.x(forOutput: model.playhead))
        } else if cmd, chars == "-", let model {
            zoom(by: 1 / 1.4, anchorX: geometry.x(forOutput: model.playhead))
        } else if shift, chars?.lowercased() == "z" {
            fit()
        } else if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete: ⌫ removes the selection
            removeSelection()
        } else if !cmd, chars?.lowercased() == "c", let model { // `C` = split at the playhead, immediately
            performSplit(atOutput: model.playhead)
        } else if !cmd, chars?.lowercased() == "s" { // `S` = sticky split mode
            toggleSplitModeSticky()
        } else if !cmd, chars?.lowercased() == "v" { // `V` = back to the pointer (selection) tool
            exitSplitMode()
        } else if !cmd, !shift, chars?.lowercased() == "z" { // `Z` = add a zoom at the playhead
            addZoom(atOutput: model?.playhead ?? 0)
        } else if cmd, chars?.lowercased() == "d" { // `⌘D` = duplicate the selected zoom/mask after itself
            duplicateSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    /// `⌥` held = momentary split mode (SPEC §7.2 "Split").
    override func flagsChanged(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        if optionHeld != splitOptionHeld {
            splitOptionHeld = optionHeld
            needsDisplay = true
            updateHoverCallback()
        }
        super.flagsChanged(with: event)
    }

    // MARK: - Ruler scrub (click/drag on the ruler moves the playhead; SPEC §7.2 "Navigation")

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // SPEC §7.2 hit-test table: "Anything, in Split mode | blade ✂ line | click = split" — this
        // overrides the normal per-lane hit-test dispatch below.
        if isSplitMode {
            hoverX = p.x
            if let t = bladeOutputTime() { performSplit(atOutput: t) }
            return
        }
        let hit = hitTest(at: p)
        switch hit {
        case .playhead, .ruler:
            dragKind = .scrub
            scrub(toViewX: p.x)
        case .clipEdge(let i, let edge):
            beginTrim(index: i, edge: edge)
        case .clipBody(let i):
            selectClip(i)
        case .blockBody(let id):
            guard let lane = lane(ofBlock: id) else { break }
            // SPEC §7.2 "Zoom blocks": "Double-click = select + move playhead to its start" — a
            // zoom-only affordance; every lane's body-drag otherwise moves the block (§7.2's
            // hit-test table: "move (zoom/layout/mask only; clips don't reorder)").
            if event.clickCount >= 2, lane == .zoom {
                doubleClickZoom(id: id)
            } else {
                beginMoveBlock(id: id, lane: lane, atViewX: p.x)
            }
        case .blockEdge(let id, let edge):
            guard let lane = lane(ofBlock: id) else { break }
            beginResizeBlock(id: id, lane: lane, edge: edge)
        case .cutBubble(let afterClip):
            showRestorePopover(afterClip: afterClip, at: p)
        case .emptyLane(let lane, let source):
            guard let model, lane != .clip else { return }
            model.beginGesture()
            var id: UUID?
            model.update { project in
                switch lane {
                case .zoom: id = project.addZoom(atSource: source, length: 3, mode: zoomMode(nearSource: source))
                case .mask: id = project.addMask(atSource: source, length: 3, kind: .blur, opacity: 1)
                case .layout: id = project.addLayout(atSource: source, length: 3, kind: .bubble)
                case .clip: break
                }
            }
            guard let id else { model.cancelGesture(); return }
            selectBlock(id, addToSelection: false)
            dragKind = .createBlock(id: id, lane: lane, anchor: source)
        case .none:
            deselect()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The event in hand (not the live hardware state `NSEvent.modifierFlags` — that's for
        // idle/draw-time checks like the split blade, which has no event) is what "⌘ held disables
        // snapping" (SPEC §7.2 "Snapping") means during an actual drag.
        let snapDisabled = event.modifierFlags.contains(.command)
        switch dragKind {
        case .createBlock(let id, let lane, let anchor):
            guard let model else { return }
            let raw = geometry.output(forX: geometryX(p))
            let (snapped, didSnap) = snappedOutput(raw, excludingBlock: id, disabled: snapDisabled)
            snapGuideX = didSnap ? x(forOutput: snapped) : nil
            let source = model.timeMap.sourceTime(atOutput: snapped)
            model.update { project in
                // Contract first, then expand: works in either direction and clamps at neighbours.
                switch lane {
                case .zoom:
                    project.resizeZoom(id, edge: .leading, to: min(anchor, source))
                    project.resizeZoom(id, edge: .trailing, to: max(anchor, source))
                    project.resizeZoom(id, edge: .leading, to: min(anchor, source))
                case .mask:
                    project.resizeMask(id, edge: .leading, to: min(anchor, source))
                    project.resizeMask(id, edge: .trailing, to: max(anchor, source))
                    project.resizeMask(id, edge: .leading, to: min(anchor, source))
                case .layout:
                    project.resizeLayout(id, edge: .leading, to: min(anchor, source))
                    project.resizeLayout(id, edge: .trailing, to: max(anchor, source))
                    project.resizeLayout(id, edge: .leading, to: min(anchor, source))
                case .clip: break
                }
            }
            needsDisplay = true
        case .scrub:
            scrub(toViewX: p.x)
        case .trimClip(let index, let edge, let priorOutput, let beginStart, let beginEnd, let speed):
            updateTrim(index: index, edge: edge, priorOutput: priorOutput, beginSourceStart: beginStart,
                       beginSourceEnd: beginEnd, speed: speed, viewX: p.x, snapDisabled: snapDisabled)
        case .moveBlock(let id, let lane, let grabOffset):
            updateMoveBlock(id: id, lane: lane, grabOffset: grabOffset, viewX: p.x, snapDisabled: snapDisabled)
        case .resizeBlock(let id, let lane, let edge):
            updateResizeBlock(id: id, lane: lane, edge: edge, viewX: p.x, snapDisabled: snapDisabled)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragKind {
        case .createBlock(_, let lane, _):
            model?.commitGesture("Add \(laneName(lane))")
        case .trimClip:
            model?.commitGesture("Trim")
        case .moveBlock(_, let lane, _):
            model?.commitGesture("Move \(laneName(lane))")
        case .resizeBlock(_, let lane, _):
            model?.commitGesture("Resize \(laneName(lane))")
        case .scrub, nil:
            dragKind = nil
            return
        }
        trimChip = nil
        snapGuideX = nil
        onHoverTime?(nil)
        dragKind = nil
        needsDisplay = true
    }

    /// SPEC §7.3: "Esc: cancel drag → exit split mode → deselect", checked in that order.
    /// AC-TL-6: `Esc` mid-drag restores the pre-drag project.
    override func cancelOperation(_ sender: Any?) {
        if dragKind != nil { cancelActiveDrag(); return }
        if isSplitMode { exitSplitMode(); return }
        deselect()
    }

    private func cancelActiveDrag() {
        switch dragKind {
        case .trimClip, .moveBlock, .resizeBlock, .createBlock:
            model?.cancelGesture()
        case .scrub, nil:
            dragKind = nil
            needsDisplay = true
            return
        }
        trimChip = nil
        snapGuideX = nil
        onHoverTime?(nil)
        dragKind = nil
        needsDisplay = true
    }

    // MARK: - Trim (SPEC §7.2 "Trim")

    private func beginTrim(index: Int, edge: RecorderCore.Edge) {
        guard let model, model.project.clips.indices.contains(index) else { return }
        let clip = model.project.clips[index]
        var priorOutput = 0.0
        for c in model.project.clips[0..<index] { priorOutput += c.outputDuration }
        model.beginGesture()
        dragKind = .trimClip(index: index, edge: edge, priorOutput: priorOutput,
                              beginSourceStart: clip.sourceStart, beginSourceEnd: clip.sourceEnd, speed: clip.speed)
        selectClip(index)
    }

    /// Maps the mouse's output-time position to a target source time via the clip's *pre-drag*
    /// start/leading-edge/speed (fixed for the whole gesture — see `DragKind.trimClip`'s doc) and
    /// calls `trimClip`, which itself clamps against the neighbour, `[0, source.duration]` and the
    /// minimum length. One routine for either edge: `TimeMap`'s own per-clip formula, extrapolated.
    private func updateTrim(index: Int, edge: RecorderCore.Edge, priorOutput: Double, beginSourceStart: Double,
                             beginSourceEnd: Double, speed: Double, viewX: CGFloat, snapDisabled: Bool) {
        guard let model else { return }
        let raw = geometry.output(forX: geometryX(NSPoint(x: viewX, y: 0)))
        let (snapped, didSnap) = snappedOutput(raw, disabled: snapDisabled)
        snapGuideX = didSnap ? x(forOutput: snapped) : nil
        let target = beginSourceStart + (snapped - priorOutput) * speed
        model.update { $0.trimClip(index, edge: edge, toSource: target) }

        guard model.project.clips.indices.contains(index) else { return }
        let newDuration = model.project.clips[index].outputDuration
        let beginDuration = (beginSourceEnd - beginSourceStart) / speed
        let edgeOutput = edge == .leading ? priorOutput : priorOutput + newDuration
        trimChip = (x: x(forOutput: edgeOutput), text: trimChipText(duration: newDuration, delta: newDuration - beginDuration))
        onHoverTime?(edgeOutput) // "preview shows the frame at the edge" (SPEC §7.2 "Trim")
        needsDisplay = true
    }

    private func trimChipText(duration: Double, delta: Double) -> String {
        let sign = delta < 0 ? "\u{2212}" : "+"
        return "\(playheadLabel(duration)) (\u{0394} \(sign)\(playheadLabel(abs(delta))))"
    }

    // MARK: - Zoom/layout/mask blocks (SPEC §7.2 "Zoom blocks" + the hit-test table's "Empty zoom/
    // layout/mask lane" row) — one generic body-move/edge-resize/add-on-click/ghost per lane,
    // parametrised by `Lane` and dispatched to the matching `Project` op; nothing here is copied
    // per lane.

    /// `.auto` if a left-click event lies within ±1 s of `s`, else `.manual` (zoom-only: layout/
    /// mask blocks have no auto/manual distinction).
    private func zoomMode(nearSource s: Double) -> Zoom.Mode {
        (model?.events.clicks().contains { abs($0.t - s) <= 1 } ?? false) ? .auto : .manual
    }

    private func laneName(_ lane: Lane) -> String {
        switch lane {
        case .clip: return "Clip"
        case .zoom: return "Zoom"
        case .layout: return "Layout"
        case .mask: return "Mask"
        }
    }

    /// Empty-lane click / `Z` (zoom only): adds a block appropriate to that lane and selects it.
    /// One undo step.
    private func addBlock(lane: Lane, atSource s: Double) {
        guard let model else { return }
        var newID: UUID?
        switch lane {
        case .zoom: model.edit("Add Zoom") { newID = $0.addZoom(atSource: s, mode: zoomMode(nearSource: s)) }
        case .layout: model.edit("Add Layout") { newID = $0.addLayout(atSource: s, kind: .bubble) }
        case .mask: model.edit("Add Mask") { newID = $0.addMask(atSource: s, kind: .mask) }
        case .clip: break // clips are never added this way (SPEC's hit-test table only lists zoom/layout/mask)
        }
        if let newID { selectBlock(newID, addToSelection: false) }
    }

    /// `Z` adds a zoom at the playhead (SPEC §7.3).
    private func addZoom(atOutput t: Double) {
        guard let model else { return }
        addBlock(lane: .zoom, atSource: model.timeMap.sourceTime(atOutput: t))
    }

    /// `⌘D` duplicates the selected zoom/mask right after itself (SPEC §7.3).
    private func duplicateSelection() {
        guard let model, let id = model.selection.first else { return }
        var newID: UUID?
        model.edit("Duplicate") { newID = $0.duplicateBlock(id) }
        if let newID { selectBlock(newID, addToSelection: false) }
    }

    /// "Double-click = select + move playhead to its start" (SPEC §7.2 "Zoom blocks" — zoom-only).
    private func doubleClickZoom(id: UUID) {
        guard let model, let zoom = model.project.zooms.first(where: { $0.id == id.uuidString }),
              let out = model.timeMap.outputTime(atSource: zoom.start) else { return }
        selectBlock(id, addToSelection: false)
        model.playhead = out
    }

    /// The block's current start, whichever lane it's in.
    private func blockStart(id: UUID, lane: Lane) -> Double? {
        guard let model else { return nil }
        switch lane {
        case .zoom: return model.project.zooms.first { $0.id == id.uuidString }?.start
        case .layout: return model.project.layouts.first { $0.id == id.uuidString }?.start
        case .mask: return model.project.masks.first { $0.id == id.uuidString }?.start
        case .clip: return nil
        }
    }

    private func beginMoveBlock(id: UUID, lane: Lane, atViewX viewX: CGFloat) {
        guard let model, let start = blockStart(id: id, lane: lane) else { return }
        let mouseSource = model.timeMap.sourceTime(atOutput: geometry.output(forX: geometryX(NSPoint(x: viewX, y: 0))))
        model.beginGesture()
        dragKind = .moveBlock(id: id, lane: lane, grabOffset: mouseSource - start)
        selectBlock(id, addToSelection: false)
    }

    /// Blocks live in *source* time but `clips` never changes under this drag, so (unlike a clip
    /// trim) `model.timeMap` is stable for its whole duration and can convert output→source
    /// directly — no fixed-anchor extrapolation needed.
    private func updateMoveBlock(id: UUID, lane: Lane, grabOffset: Double, viewX: CGFloat, snapDisabled: Bool) {
        guard let model else { return }
        let raw = geometry.output(forX: geometryX(NSPoint(x: viewX, y: 0)))
        let (snapped, didSnap) = snappedOutput(raw, excludingBlock: id, disabled: snapDisabled)
        snapGuideX = didSnap ? x(forOutput: snapped) : nil
        let toStart = model.timeMap.sourceTime(atOutput: snapped) - grabOffset
        model.update { project in
            switch lane {
            case .zoom: project.moveZoom(id, toStart: toStart)
            case .layout: project.moveLayout(id, toStart: toStart)
            case .mask: project.moveMask(id, toStart: toStart)
            case .clip: break
            }
        }
        needsDisplay = true
    }

    private func beginResizeBlock(id: UUID, lane: Lane, edge: RecorderCore.Edge) {
        guard blockStart(id: id, lane: lane) != nil, let model else { return }
        model.beginGesture()
        dragKind = .resizeBlock(id: id, lane: lane, edge: edge)
        selectBlock(id, addToSelection: false)
    }

    private func updateResizeBlock(id: UUID, lane: Lane, edge: RecorderCore.Edge, viewX: CGFloat, snapDisabled: Bool) {
        guard let model else { return }
        let raw = geometry.output(forX: geometryX(NSPoint(x: viewX, y: 0)))
        let (snapped, didSnap) = snappedOutput(raw, excludingBlock: id, disabled: snapDisabled)
        snapGuideX = didSnap ? x(forOutput: snapped) : nil
        let source = model.timeMap.sourceTime(atOutput: snapped) // read before `update`'s exclusive `inout` access to `project`
        model.update { project in
            switch lane {
            case .zoom: project.resizeZoom(id, edge: edge, to: source)
            case .layout: project.resizeLayout(id, edge: edge, to: source)
            case .mask: project.resizeMask(id, edge: edge, to: source)
            case .clip: break
            }
        }
        needsDisplay = true
    }

    /// Non-mutating placement preview for the empty-lane "ghost" (SPEC §7.2), whichever lane the
    /// hover point is over — the exact placement `addBlock(lane:atSource:)` would use, so the two
    /// never disagree.
    private func previewPlacement(lane: Lane, atSource s: Double) -> (start: Double, end: Double)? {
        switch lane {
        case .zoom: return model?.project.previewZoomPlacement(atSource: s)
        case .layout: return model?.project.previewLayoutPlacement(atSource: s)
        case .mask: return model?.project.previewMaskPlacement(atSource: s)
        case .clip: return nil
        }
    }

    private func ghostFill(_ lane: Lane) -> NSColor {
        switch lane {
        case .clip: return Theme.clip
        case .zoom: return Theme.accent
        case .layout: return Theme.layout
        case .mask: return Theme.mask
        }
    }

    /// SPEC §7.1's "🔍 + add ← ghost on hover" glyph, per lane.
    private func ghostLabel(_ lane: Lane) -> String {
        switch lane {
        case .clip: return "+ add"
        case .zoom: return "\u{1F50D} + add"
        case .layout: return "\u{25C9} + add"
        case .mask: return "\u{25A6} + add"
        }
    }

    /// "Empty zoom/layout/mask lane: ghost block under pointer" (SPEC §7.1/§7.2).
    private func drawEmptyLaneGhost() {
        guard dragKind == nil, !isSplitMode, let model, let hoverX, let hoverY, hoverX > Self.gutter else { return }
        guard let lane = [Lane.zoom, .layout, .mask].first(where: { laneHeight($0) > 0 && hoverY >= laneRow($0).minY && hoverY <= laneRow($0).maxY }) else { return }
        let row = laneRow(lane)
        let s = model.timeMap.sourceTime(atOutput: geometry.output(forX: geometryX(NSPoint(x: hoverX, y: 0))))
        guard model.timeMap.outputTime(atSource: s) != nil else { return } // hovering a removed segment: no gap to add into
        guard let placement = previewPlacement(lane: lane, atSource: s),
              let outStart = model.timeMap.outputTime(atSource: placement.start),
              let outEnd = model.timeMap.outputTime(atSource: placement.end) else { return }
        let rect = CGRect(x: x(forOutput: outStart), y: row.minY + 2, width: max(0, x(forOutput: outEnd) - x(forOutput: outStart)), height: row.height - 4)
        guard rect.width > 0.5 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.blockRadius, yRadius: Self.blockRadius)
        ghostFill(lane).withAlphaComponent(0.4).setFill() // "hatched 40% opacity" (SPEC §7.1)
        path.fill()
        let dashed = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.blockRadius, yRadius: Self.blockRadius)
        dashed.setLineDash([3, 2], count: 2, phase: 0)
        ghostFill(lane).setStroke()
        dashed.stroke()

        guard rect.width > 24 else { return }
        let label = ghostLabel(lane) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.captionFont, .foregroundColor: Theme.textPrimary.withAlphaComponent(0.8)]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    /// "left-click times from `events` (draw them as 1×4 pt ticks in the zoom lane)" (SPEC §7.2 "Snapping").
    private func drawClickTicks(_ project: Project, _ timeMap: TimeMap) {
        guard let model else { return }
        let row = laneRow(.zoom)
        Theme.textPrimary.withAlphaComponent(0.4).setFill()
        for click in model.events.clicks() {
            guard let out = timeMap.outputTime(atSource: click.t) else { continue }
            let px = x(forOutput: out)
            NSRect(x: px - 0.5, y: row.maxY - 4, width: 1, height: 4).fill()
        }
    }

    // MARK: - Zoom context menu (SPEC §7.2 "Zoom blocks": "Right-click ▸ Disable/Enable · Instant · Remove")

    private func zoomContextMenu(id: UUID) -> NSMenu? {
        guard let model, let zoom = model.project.zooms.first(where: { $0.id == id.uuidString }) else { return nil }
        selectBlock(id, addToSelection: false)
        let menu = NSMenu()
        menu.addItem(actionItem(zoom.enabled ? "Disable" : "Enable", action: #selector(menuToggleZoomEnabled(_:)), represented: id))
        let instant = actionItem("Instant", action: #selector(menuToggleZoomInstant(_:)), represented: id)
        instant.state = zoom.instant ? .on : .off
        menu.addItem(instant)
        menu.addItem(.separator())
        menu.addItem(actionItem("Remove", action: #selector(menuRemoveBlock(_:)), represented: id))
        return menu
    }

    @objc private func menuToggleZoomEnabled(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model?.edit("Toggle Zoom") { project in
            if let i = project.zooms.firstIndex(where: { $0.id == id.uuidString }) { project.zooms[i].enabled.toggle() }
        }
    }

    @objc private func menuToggleZoomInstant(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model?.edit("Toggle Instant") { project in
            if let i = project.zooms.firstIndex(where: { $0.id == id.uuidString }) { project.zooms[i].instant.toggle() }
        }
    }

    @objc private func menuRemoveBlock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model?.edit("Remove") { $0.removeBlock(id) }
    }

    // MARK: - Restore (SPEC §7.2 "Restore")

    /// The removed source duration at seam `afterClip` (`-1` = the head), for the popover's text.
    private func removedDuration(afterClip i: Int, project: Project) -> Double {
        let clips = project.clips
        guard !clips.isEmpty else { return 0 }
        if i == -1 { return clips[0].sourceStart }
        if i == clips.count - 1 { return project.source.duration - clips[i].sourceEnd }
        guard clips.indices.contains(i), clips.indices.contains(i + 1) else { return 0 }
        return clips[i + 1].sourceStart - clips[i].sourceEnd
    }

    /// One undo step (SPEC §7.4 `restoreCut`, already clamped/merging there).
    func restoreCut(afterClip i: Int) {
        model?.edit("Restore") { $0.restoreCut(afterClip: i) }
    }

    /// `NSPopover` "Restore 00:05.80 removed here [Restore]" (SPEC §7.2).
    private func showRestorePopover(afterClip i: Int, at p: NSPoint) {
        guard let model else { return }
        let removed = removedDuration(afterClip: i, project: model.project)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RestorePopoverView(
            text: "Restore \(playheadLabel(removed)) removed here",
            action: { [weak self, weak popover] in
                self?.restoreCut(afterClip: i)
                popover?.performClose(nil)
            }))
        let seamX = cutBubbleSeams(model.project).first { $0.afterClip == i }?.outputX ?? p.x
        let bandTop = laneRow(.clip).minY - 8
        popover.show(relativeTo: CGRect(x: seamX - 6, y: bandTop, width: 12, height: 8), of: self, preferredEdge: .maxY)
    }

    private func scrub(toViewX viewX: CGFloat) {
        guard let model else { return }
        let t = geometry.output(forX: geometryX(NSPoint(x: viewX, y: 0)))
        model.playhead = min(max(0, t), model.timeMap.outputDuration)
    }

    // MARK: - Hover line + timecode tooltip (`NSTrackingArea`, `mouseMoved`)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x
        hoverY = p.y
        (isSplitMode ? NSCursor.crosshair : cursor(for: hitTest(at: p))).set()
        updateHoverCallback()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        hoverY = nil
        NSCursor.arrow.set()
        onHoverTime?(nil)
        needsDisplay = true
    }

    // MARK: - Accessibility (AC-TL-8: "each block is an accessibility element with role, label
    // and increment/decrement actions to move it by 1 frame")

    /// SPEC's own 60 fps assumption (matches `split(atOutput:fps:)`'s default and the zoom
    /// range's "1 frame = 8 pt") — the increment/decrement nudge size.
    private static let axFrameSeconds = 1.0 / 60

    /// One `NSAccessibilityElement` per block (clip/zoom/layout/mask), rebuilt fresh on every
    /// call (VoiceOver only asks when it needs them, and this keeps the elements' frames/labels
    /// always current with the live project — no separate cache to invalidate).
    override func accessibilityChildren() -> [Any]? {
        guard let model else { return [] }
        var elements = axClipElements(model)
        elements += axBlockElements(model.project.zooms, lane: .zoom, model: model,
                                     id: { $0.id }, start: { $0.start }, end: { $0.end },
                                     label: { "Zoom \(String(format: "%.1f", $0.scale))\u{00D7}" },
                                     nudge: { [weak self] id, frames in self?.nudgeZoom(id, frames: frames) })
        if hasLayoutLane {
            elements += axBlockElements(model.project.layouts, lane: .layout, model: model,
                                         id: { $0.id }, start: { $0.start }, end: { $0.end },
                                         label: { "Layout, \($0.kind == .cameraFull ? "Camera full" : $0.kind == .hidden ? "Hidden" : "Size / position")" },
                                         nudge: { [weak self] id, frames in self?.nudgeLayout(id, frames: frames) })
        }
        if laneHeight(.mask) > 0 {
            elements += axBlockElements(model.project.masks, lane: .mask, model: model,
                                         id: { $0.id }, start: { $0.start }, end: { $0.end },
                                         label: { "\($0.kind == .highlight ? "Highlight" : ($0.kind == .blur ? "Blur" : "Mask")), opacity \(Int(($0.opacity * 100).rounded()))%" },
                                         nudge: { [weak self] id, frames in self?.nudgeMask(id, frames: frames) })
        }
        return elements
    }

    /// Clip blocks: label per AC-TL-8's own shape, plus a speed suffix when sped up. A clip has no
    /// "move" drag (SPEC §7.2's hit-test table: body drag doesn't move a clip, only edge-drag/trim
    /// does), so its nudge extends/shrinks the trailing edge by one frame — `trimClip`, the exact
    /// `TimelineOps` call an edge-drag already makes.
    private func axClipElements(_ model: EditorModel) -> [TimelineBlockAXElement] {
        let row = laneRow(.clip)
        var out: [TimelineBlockAXElement] = []
        var outStart = 0.0
        for (i, clip) in model.project.clips.enumerated() {
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            let rect = CGRect(x: x(forOutput: outStart), y: row.minY,
                               width: max(0, x(forOutput: outEnd) - x(forOutput: outStart)), height: row.height)
            var label = "Clip, \(axTime(outStart)) to \(axTime(outEnd)) seconds"
            if clip.speed != 1 { label += ", \(formatSpeed(clip.speed))\u{00D7} speed" }
            out.append(axElement(frame: rect, label: label) { [weak self] frames in self?.nudgeClip(i, frames: frames) })
        }
        return out
    }

    /// Zoom/layout/mask blocks: identical shape, parametrised by lane (no copies) — `id`/`start`/
    /// `end` extract the block's own fields, `label` supplies the kind-specific prefix, and only
    /// the block's first visible segment (SPEC's torn-edge splitting, `visibleSegments`) becomes an
    /// element; a block fully hidden behind a cut has nothing on screen to expose.
    private func axBlockElements<T>(_ blocks: [T], lane: Lane, model: EditorModel,
                                     id: (T) -> String, start: (T) -> Double, end: (T) -> Double,
                                     label: (T) -> String, nudge: @escaping (UUID, Int) -> Void) -> [TimelineBlockAXElement] {
        let row = laneRow(lane)
        let timeMap = model.timeMap
        var out: [TimelineBlockAXElement] = []
        for b in blocks {
            guard let uuid = UUID(uuidString: id(b)) else { continue }
            guard let seg = visibleSegments(start: start(b), end: end(b), project: model.project, timeMap: timeMap).first else { continue }
            let rect = CGRect(x: x(forOutput: seg.outStart), y: row.minY,
                               width: max(0, x(forOutput: seg.outEnd) - x(forOutput: seg.outStart)), height: row.height)
            let text = "\(label(b)), \(axTime(seg.outStart)) to \(axTime(seg.outEnd)) seconds"
            out.append(axElement(frame: rect, label: text) { frames in nudge(uuid, frames) })
        }
        return out
    }

    private func axElement(frame viewRect: CGRect, label: String, nudge: ((Int) -> Void)?) -> TimelineBlockAXElement {
        let element = TimelineBlockAXElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(label)
        element.setAccessibilityFrame(screenFrame(forViewRect: viewRect))
        element.nudge = nudge
        return element
    }

    /// View-local (flipped) rect → screen coordinates: through the window (`convert(_:to: nil)`,
    /// the same direction `hitTest`'s callers use in reverse) and then `convertToScreen`.
    private func screenFrame(forViewRect r: CGRect) -> CGRect {
        let windowRect = convert(r, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    private func axTime(_ t: Double) -> String { String(format: "%.1f", max(0, t)) }

    private func nudgeZoom(_ id: UUID, frames: Int) {
        guard let model, let zoom = model.project.zooms.first(where: { $0.id == id.uuidString }) else { return }
        model.edit("Move Zoom") { $0.moveZoom(id, toStart: zoom.start + Double(frames) * Self.axFrameSeconds) }
    }

    private func nudgeLayout(_ id: UUID, frames: Int) {
        guard let model, let layout = model.project.layouts.first(where: { $0.id == id.uuidString }) else { return }
        model.edit("Move Layout") { $0.moveLayout(id, toStart: layout.start + Double(frames) * Self.axFrameSeconds) }
    }

    private func nudgeMask(_ id: UUID, frames: Int) {
        guard let model, let mask = model.project.masks.first(where: { $0.id == id.uuidString }) else { return }
        model.edit("Move Mask") { $0.moveMask(id, toStart: mask.start + Double(frames) * Self.axFrameSeconds) }
    }

    private func nudgeClip(_ i: Int, frames: Int) {
        guard let model, model.project.clips.indices.contains(i) else { return }
        let clip = model.project.clips[i]
        let delta = Double(frames) * Self.axFrameSeconds * clip.speed // OUTPUT-frame nudge -> SOURCE delta
        model.edit("Trim Clip") { $0.trimClip(i, edge: .trailing, toSource: clip.sourceEnd + delta) }
    }
}

/// One accessibility element per timeline block (AC-TL-8): role `.button`, a SPEC-shaped label,
/// frame in screen coordinates, and increment/decrement that nudge the block by one frame through
/// the exact `EditorModel`/`TimelineOps` call the matching drag would make — one undo step each.
private final class TimelineBlockAXElement: NSAccessibilityElement {
    var nudge: ((Int) -> Void)?

    override func accessibilityPerformIncrement() -> Bool {
        guard let nudge else { return false }
        nudge(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let nudge else { return false }
        nudge(-1)
        return true
    }
}

/// SPEC §7.2 "Restore": `Restore 00:05.80 removed here [Restore]`.
private struct RestorePopoverView: View {
    let text: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout)
            Button("Restore", action: action)
        }
        .padding(12)
    }
}

/// SPEC §7.1's 32 pt toolbar row above the ruler: the ✂ Split button (T-407), Fit button and zoom
/// slider (T-405) that drive `TimelineView`. The zoom/undo/redo buttons belong to whichever task
/// implements those actions (T-409, already-wired undo/redo menu items).
final class TimelineToolbar: NSView {
    weak var timelineView: TimelineView? {
        didSet { syncSlider() }
    }

    private let splitButton = NSButton(title: "\u{2702} Split", target: nil, action: nil)
    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        splitButton.bezelStyle = .rounded
        splitButton.target = self
        splitButton.action = #selector(splitTapped)
        fitButton.bezelStyle = .rounded
        fitButton.target = self
        fitButton.action = #selector(fitTapped)
        slider.target = self
        slider.action = #selector(sliderChanged)

        let stack = NSStackView(views: [splitButton, fitButton, slider])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func syncSlider() {
        guard let timelineView else { return }
        slider.doubleValue = timelineView.zoomSliderValue
    }

    @objc private func splitTapped() {
        timelineView?.toggleSplitModeSticky()
        timelineView?.window?.makeFirstResponder(timelineView)
    }

    @objc private func fitTapped() {
        timelineView?.fit()
        syncSlider()
    }

    @objc private func sliderChanged() {
        timelineView?.setZoom(sliderValue: slider.doubleValue)
    }
}
