import AppKit
import Observation
import RecorderCore

/// Which timed-block track a point/x-coordinate belongs to. Top-to-bottom draw/hit-test order
/// matches this declaration order (SPEC §7.1): clip, zoom, layout (only if `source.hasCamera`),
/// mask (hidden until T-601).
enum Lane: CaseIterable, Sendable {
    case clip, zoom, layout, mask
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

    override var isFlipped: Bool { true }

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

    // MARK: - Observation (SPEC §7: "Observe model with withObservationTracking")

    private func observeModel() {
        guard let model else { return }
        withObservationTracking {
            _ = model.project
            _ = model.playhead
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.needsDisplay = true
                self?.observeModel()
            }
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
        for clip in project.clips {
            let outEnd = outStart + clip.outputDuration
            defer { outStart = outEnd }
            // A 1.5 pt gap on each side keeps neighbouring clips visually separate (their seam is
            // where a cut/trim can later be restored, T-408) even though they're the same colour.
            let rect = CGRect(x: x(forOutput: outStart) + 1.5, y: row.minY + 2,
                               width: max(0, x(forOutput: outEnd) - x(forOutput: outStart) - 3), height: row.height - 4)
            guard rect.width > 0.5 else { continue }
            let label = clip.speed != 1 ? "\(formatSpeed(clip.speed))\u{00D7} \u{23E9}" : nil
            drawBlock(rect, fill: Theme.clip, tornLeft: false, tornRight: false, label: label)
        }
    }

    // MARK: - Zoom / layout lanes (source-time blocks mapped through TimeMap; SPEC §7.1)

    private func drawZoomLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.zoom)
        for zoom in project.zooms {
            let label = "\u{1F50D} \(String(format: "%.1f", zoom.scale))\u{00D7} \(zoom.mode == .auto ? "A" : "M")"
            for segment in visibleSegments(start: zoom.start, end: zoom.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.accent, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label)
            }
        }
    }

    private func drawLayoutLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.layout)
        for layout in project.layouts {
            guard layout.kind == .cameraFull else { continue }
            let label = "\u{25C9} Camera full"
            for segment in visibleSegments(start: layout.start, end: layout.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.layout, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label)
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

    private func drawBlock(_ rect: CGRect, fill: NSColor, tornLeft: Bool, tornRight: Bool, label: String?) {
        let radius = min(Self.blockRadius, rect.height / 2, rect.width / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()

        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        highlight.lineWidth = 1
        Theme.textPrimary.withAlphaComponent(0.15).setStroke()
        highlight.stroke()

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
}
