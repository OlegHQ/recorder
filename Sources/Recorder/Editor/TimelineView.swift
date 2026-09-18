import AppKit
import Observation
import QuartzCore
import RecorderCore

/// Which timed-block track a point/x-coordinate belongs to. Top-to-bottom draw/hit-test order
/// matches this declaration order (SPEC §7.1): clip, zoom, layout (only if `source.hasCamera`),
/// mask (hidden until T-601).
enum Lane: CaseIterable, Sendable {
    case clip, zoom, layout, mask
}

/// What a point in `TimelineView` is over (SPEC §7.2 hit-testing table). `hitTest(at:)` checks in
/// exactly the table's order: playhead cap, block edge, block body, ✂ bubble, empty lane, ruler.
enum TimelineHit: Equatable {
    case playhead
    case clipEdge(Int, Edge)
    case clipBody(Int)
    case cutBubble(afterClip: Int)
    case blockEdge(UUID, Edge)
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
        didSet { observeModel() }
    }

    var geometry = TimelineGeometry(pxPerSecond: 60, scrollX: 0, width: 0)

    static let gutter: CGFloat = 16
    static let rulerHeight: CGFloat = 22
    static let clipHeight: CGFloat = 44
    static let zoomHeight: CGFloat = 32
    static let layoutHeight: CGFloat = 28
    static let blockRadius: CGFloat = 10
    /// SPEC §7.2 "Navigation": zoom range is whole project ↔ 1 frame = 8 pt, at 60 fps.
    static let maxPxPerSecond: Double = 8 * 60

    // MARK: - Navigation state (T-405)

    private var autoScrollEnabled = true
    private var wasPlaying = false
    private var dragKind: DragKind?
    private enum DragKind { case scrub }
    private var hoverX: CGFloat?
    private var trackingArea: NSTrackingArea?

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgPanel.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometry.width = max(0, newSize.width - Self.gutter)
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

    private var hasLayoutLane: Bool { model?.project.source.hasCamera ?? false }

    private func laneHeight(_ lane: Lane) -> CGFloat {
        switch lane {
        case .clip: return Self.clipHeight
        case .zoom: return Self.zoomHeight
        case .layout: return hasLayoutLane ? Self.layoutHeight : 0
        case .mask: return 0 // ponytail: mask lane hidden until T-601, which turns this on.
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
        drawClipLane(project)
        drawZoomLane(project, timeMap)
        if hasLayoutLane { drawLayoutLane(project, timeMap) }
        drawLaneDividers()
        drawPlayhead(model.playhead)
        drawHover()
        if isSplitMode { drawSplitBlade() }
        drawCutFlash()
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
        let icons: [Lane: String] = [.clip: "rectangle.stack", .zoom: "magnifyingglass", .layout: "person.crop.square"]
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

    private func drawClipLane(_ project: Project) {
        let row = laneRow(.clip)
        var outStart = 0.0
        for (i, clip) in project.clips.enumerated() {
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            // A 1.5 pt gap on each side keeps neighbouring clips visually separate (their seam is
            // where a cut/trim can later be restored, T-408) even though they're the same colour.
            let rect = CGRect(x: x(forOutput: outStart) + 1.5, y: row.minY + 2,
                               width: max(0, x(forOutput: outEnd) - x(forOutput: outStart) - 3), height: row.height - 4)
            guard rect.width > 0.5 else { continue }
            let label = clip.speed != 1 ? "\(formatSpeed(clip.speed))\u{00D7} \u{23E9}" : nil
            drawBlock(rect, fill: Theme.clip, tornLeft: false, tornRight: false, label: label, selected: model?.selectedClip == i)
        }
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
            guard layout.kind == .cameraFull else { continue }
            let label = "\u{25C9} Camera full"
            let selected = UUID(uuidString: layout.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: layout.start, end: layout.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.layout, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
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

    /// A small hit box at every seam with a cut/trim to restore (drawn as the ✂ bubble by T-408,
    /// straddling the ruler/clip-lane divider so it never competes with a clip edge's hit zone):
    /// between two clips whose source ranges don't meet, and at the head/tail when trimmed.
    private func hitCutBubble(_ p: CGPoint, _ model: EditorModel) -> TimelineHit? {
        let row = laneRow(.clip)
        let bandTop = row.minY - 8
        guard p.y >= bandTop, p.y <= row.minY else { return nil }
        let clips = model.project.clips
        guard !clips.isEmpty else { return nil }
        let eps = 1e-6

        func box(at seamX: CGFloat) -> CGRect { CGRect(x: seamX - 6, y: bandTop, width: 12, height: 8) }

        if clips[0].sourceStart > eps, box(at: x(forOutput: 0)).contains(p) { return .cutBubble(afterClip: -1) }

        var outEnd = 0.0
        for i in clips.indices {
            outEnd += clips[i].outputDuration
            if i < clips.count - 1, clips[i + 1].sourceStart - clips[i].sourceEnd > eps, box(at: x(forOutput: outEnd)).contains(p) {
                return .cutBubble(afterClip: i)
            }
        }
        if model.project.source.duration - clips[clips.count - 1].sourceEnd > eps, box(at: x(forOutput: outEnd)).contains(p) {
            return .cutBubble(afterClip: clips.count - 1)
        }
        return nil
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
        geometry.zoom(by: factor, anchorX: anchorX, minPxPerSecond: minPxPerSecond(), maxPxPerSecond: Self.maxPxPerSecond)
        geometry.scrollX = clampScrollX(geometry.scrollX)
        needsDisplay = true
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
        case .clipBody(let i), .clipEdge(let i, _):
            // T-406 is hit-testing + selection only; the edge drag itself (trim) is T-408's job.
            selectClip(i)
        case .blockBody(let id), .blockEdge(let id, _):
            // The body/edge drag itself (move/resize) is T-409's job.
            selectBlock(id, addToSelection: event.modifierFlags.contains(.shift))
        case .cutBubble, .emptyLane:
            // Restoring a cut (T-408) and adding a block (T-409) aren't wired yet; a click here
            // still counts as "empty space" for deselection purposes.
            deselect()
        case .none:
            deselect()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragKind == .scrub else { return }
        scrub(toViewX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragKind = nil }

    /// SPEC §7.3: "Esc: cancel drag → exit split mode → deselect", checked in that order.
    override func cancelOperation(_ sender: Any?) {
        if isSplitMode { exitSplitMode(); return }
        deselect()
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
        (isSplitMode ? NSCursor.crosshair : cursor(for: hitTest(at: p))).set()
        updateHoverCallback()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        NSCursor.arrow.set()
        onHoverTime?(nil)
        needsDisplay = true
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
