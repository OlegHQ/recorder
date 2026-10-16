import AppKit
import AVFoundation
import Observation
import QuartzCore
import RecorderCore
import SwiftUI

/// Which timed-block track a point/x-coordinate belongs to. Top-to-bottom draw/hit-test order
/// matches this declaration order (SPEC §7.1): clip, zoom, layout (only if `source.hasCamera`),
/// mask.
enum Lane: CaseIterable, Hashable, Sendable {
    case clip, camera, zoom, keys, layout, mask, text, window
    case audio(Int)

    static let allCases: [Lane] = [.clip, .camera, .zoom, .keys, .layout, .mask, .text, .window]
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

/// The custom-drawn video, effect and audio timeline (SPEC §7.1).
/// Renders from `EditorModel.project`; it never owns project data. A flipped, layer-backed
/// `NSView` with virtual horizontal navigation and native enclosing vertical scrolling.
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

    var geometry = TimelineGeometry(pxPerSecond: 60, scrollX: 0, width: 0) {
        didSet { onNavigationChange?() }
    }
    var onNavigationChange: (() -> Void)?
    private(set) var snappingEnabled = true
    private var overviewDrag: (x: CGFloat, scroll: Double, original: Double)?
    private var dragOrigin: CGRect?
    private var selectionStart: CFTimeInterval?
    private var selectionKey = ""
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func toggleSnapping() {
        snappingEnabled.toggle()
        snapGuideX = nil
        onNavigationChange?()
        needsDisplay = true
    }

    var linkedVideoEdits: Bool { model?.project.linkVideoEdits == true }
    func toggleLinkedVideoEdits() {
        model?.edit("Link video edits") { $0.linkVideoEdits.toggle() }
        onNavigationChange?()
        needsDisplay = true
    }

    var rippleDeleteEnabled: Bool { model?.project.rippleDelete == true }
    func toggleRippleDelete() {
        model?.edit("Ripple Delete") { $0.rippleDelete.toggle() }
        onNavigationChange?()
        needsDisplay = true
    }

    // ponytail: keep media references in-process and paste only into the source project;
    // cross-project paste needs an asset import path before those references can travel safely.
    private static var clipboard: (token: String, package: URL, content: Project, lane: Lane?)?
    private static let clipboardType = NSPasteboard.PasteboardType("app.recorder.timeline-selection")
    var clipboardPasteboard: NSPasteboard = .general

    var canCopySelection: Bool {
        guard let model else { return false }
        return model.project.copySelection(clips: model.selectedClips, blocks: model.selection) != nil
    }
    var canPasteSelection: Bool {
        guard let clipboard = Self.clipboard, let model else { return false }
        return clipboard.package == model.packageURL.standardizedFileURL
            && clipboardPasteboard.string(forType: Self.clipboardType) == clipboard.token
    }

    @discardableResult private func copySelectionToClipboard() -> Bool {
        guard let model, let content = model.project.copySelection(clips: model.selectedClips, blocks: model.selection) else { return false }
        let token = UUID().uuidString
        clipboardPasteboard.clearContents()
        guard clipboardPasteboard.setString(token, forType: Self.clipboardType) else { return false }
        let preferredLane = model.selectedClips.isEmpty ? model.selection.first.flatMap { lane(ofBlock: $0) } : nil
        Self.clipboard = (token, model.packageURL.standardizedFileURL, content, preferredLane)
        return true
    }

    @objc func copy(_ sender: Any?) { if !copySelectionToClipboard() { NSSound.beep() } }

    @objc func cut(_ sender: Any?) {
        guard let model, copySelectionToClipboard() else { NSSound.beep(); return }
        let clips = model.selectedClips, blocks = model.selection
        model.edit("Cut") { project in
            project.deleteClips(clips)
            for id in blocks { project.removeBlock(id) }
        }
        deselect()
        model.playhead = min(model.playhead, timelineDuration)
    }

    @objc func paste(_ sender: Any?) {
        guard canPasteSelection, let clipboard = Self.clipboard, let model else { NSSound.beep(); return }
        var trial = model.project
        guard let selection = trial.pasteSelection(clipboard.content, atOutput: model.playhead) else { NSSound.beep(); return }
        model.edit("Paste") { $0 = trial }
        model.selectedClips = selection.clips
        model.selection = selection.clips.isEmpty ? selection.blocks : []
        var preferredLane = clipboard.lane
        if case .audio(let track)? = preferredLane,
           let current = model.project.audioTracks.firstIndex(where: { $0.id == clipboard.content.audioTracks[track].id }) {
            preferredLane = .audio(current)
        }
        if let preferredLane {
            model.selectedClips = []
            model.selection = selection.blocks.filter { lane(ofBlock: $0) == preferredLane }
        }
        needsDisplay = true
    }

    func selectTool() { exitSplitMode() }

    static let gutter: CGFloat = 132
    private(set) var compactTrackHeaders = false
    var gutterWidth: CGFloat { compactTrackHeaders ? 16 : Self.gutter }
    var lanes: [Lane] {
        Lane.allCases + (model.map { model in
            model.project.audioTracks.indices.filter { track in
                model.project.audioClips.contains { $0.track == track } ||
                    (dragKind != nil && dragProject?.audioClips.contains { $0.track == track } == true)
            }.map(Lane.audio)
        } ?? [])
    }
    private var timelineDuration: Double { model.map { max($0.timeMap.outputDuration, $0.project.exportDuration) } ?? 0 }

    func toggleCompactTrackHeaders() {
        compactTrackHeaders.toggle()
        geometry.width = max(0, bounds.width - gutterWidth)
        geometry.scrollX = clampScrollX(geometry.scrollX)
        needsLayout = true
        needsDisplay = true
    }
    static let rulerHeight: CGFloat = 22
    static let clipHeight: CGFloat = 32
    static let zoomHeight: CGFloat = 24
    static let layoutHeight: CGFloat = 24
    static let maskHeight: CGFloat = 24
    static let blockRadius: CGFloat = 0
    /// SPEC §7.2 "Navigation": zoom range is whole project ↔ 1 frame = 8 pt, at 60 fps.
    static let maxPxPerSecond: Double = 8 * 60

    // MARK: - Navigation state (T-405)

    private var autoScrollEnabled = true
    private var wasPlaying = false
    /// SPEC §7.2 "Navigation": the timeline opens fitted — see `maybeFitOnFirstLayout`.
    private var didFitOnFirstLayout = false
    private var userDidZoom = false
    private var dragClips: [Clip] = []
    private var dragProject: Project?
    private var dragSelection: Set<Int> = []
    private var marqueeStart: CGPoint?
    private var marqueeRect: CGRect?
    private var marqueeSelection: Set<Int> = []
    private var marqueeOriginalSelection: (clips: Set<Int>, blocks: Set<UUID>) = ([], [])
    private var dragKind: DragKind?
    /// A clip trim's fixed references, captured once at `beginGesture` (SPEC §7.2 "Trim"): the
    /// clip's pre-drag `sourceStart`/`speed` and the output-time position of its (unaffected)
    /// leading edge — everything a drag needs to turn "mouse x" into a target source time for
    /// *either* edge, since a clip's own leading edge is always at that fixed output position
    /// regardless of how it's trimmed (only clips *before* it determine that).
    private enum DragKind {
        case scrub
        case moveClip(index: Int, anchor: Double)
        case createBlock(id: UUID, lane: Lane, anchor: Double)
        case trimClip(index: Int, edge: RecorderCore.Edge, priorOutput: Double, beginSourceStart: Double, beginSourceEnd: Double, speed: Double)
        // Zoom/layout/mask blocks are all stored in *source* time and `clips` never changes under
        // these two (unlike a clip trim), so `model.timeMap` — stable for the whole gesture — does
        // the output→source conversion directly; no "begin" snapshot of the block itself is
        // needed. `lane` picks which `Project` op (`moveZoom`/`moveLayout`/`moveMask`, same for
        // resize) `updateMoveBlock`/`updateResizeBlock` calls — one generic drag, not copied per lane.
        case moveBlock(id: UUID, lane: Lane, grabOffset: Double) // grabOffset = (source under the mouse) − block.start, at mouseDown
        case resizeBlock(id: UUID, lane: Lane, edge: RecorderCore.Edge)
        case audio(id: UUID, edge: RecorderCore.Edge?, grabOffset: Double)
        case audioFade(id: UUID, edge: RecorderCore.Edge)
    }
    private var dragIgnoresLinks = false
    private var audioHeaderButtons: [Int: (volume: NSButton, mute: NSButton, record: NSButton)] = [:]
    private var volumePopover: NSPopover?
    private var hoverX: CGFloat?
    private var hoverY: CGFloat?
    private var trackingArea: NSTrackingArea?

    // MARK: - Waveform (T-416)

    /// Loaded off the main thread once per open (`Waveform.peaks(for:)` itself also caches by
    /// URL, but this avoids re-dispatching the load / racing a second `model` assignment).
    private var waveformPeaks: [String: [Float]] = [:]
    private var waveformFiles: Set<String> = []
    private var mediaDurations: [String: Double] = [:]
    private var waveformLoadedForPackage: URL?
    /// For selftests: whether the async load (`loadWaveformIfNeeded`) has landed.
    var hasWaveform: Bool { !waveformFiles.isEmpty && waveformFiles.allSatisfy { waveformPeaks[$0] != nil } }
    /// Silent mic spans (source time), hatched in the clip lane; same function Split at Pauses uses.
    private var silentSpans: [String: [TimeRange]] = [:]

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
    private var isSplitMode: Bool {
        splitModeSticky || (splitOptionHeld && !lanes.contains { lane in
            if case .audio = lane, let hoverY { return laneRow(lane).contains(CGPoint(x: gutterWidth + 1, y: hoverY)) }
            return false
        })
    }

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
    private var cutLane: Lane = .clip
    private var bladeShakeStart: CFTimeInterval?
    private var animationLink: CADisplayLink?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - T-610 state snapshot accessors (`isSplitMode`/`dragKind` stay private otherwise)

    var debugSplitMode: Bool { isSplitMode }
    var debugIsAnimating: Bool { animationLink != nil }
    var debugDragKind: String? {
        switch dragKind {
        case .none: return nil
        case .scrub: return "scrub"
        case .moveClip: return "moveClip"
        case .createBlock: return "createBlock"
        case .trimClip: return "trimClip"
        case .moveBlock: return "moveBlock"
        case .resizeBlock: return "resizeBlock"
        case .audio: return "audio"
        case .audioFade: return "audioFade"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        geometry.width = max(0, frameRect.width - gutterWidth)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgPanel.cgColor
        for (button, name) in [(fullZoomButton, "Zoom"), (fullKeysButton, "Keys")] {
            button.isBordered = false
            button.font = Theme.labelFont
            button.contentTintColor = Theme.textPrimary
            button.target = self
            button.action = #selector(addFullLengthLayer(_:))
            button.toolTip = "Add full-length \(name) layer"
            button.setAccessibilityLabel("Add full-length \(name) layer")
            addSubview(button)
        }
    }

    private let fullZoomButton = NSButton(title: "+", target: nil, action: nil)
    private let fullKeysButton = NSButton(title: "+", target: nil, action: nil)

    override func layout() {
        super.layout()
        layoutAudioHeaders()
        for (button, lane) in [(fullZoomButton, Lane.zoom), (fullKeysButton, Lane.keys)] {
            let row = laneRow(lane)
            button.frame = CGRect(x: 78, y: row.minY, width: 24, height: row.height)
            let empty = lane == .zoom ? model?.project.zooms.isEmpty == true : model?.project.keystrokeClips.isEmpty == true
            button.isHidden = compactTrackHeaders || !empty || model?.project.clips.isEmpty != false
            button.isEnabled = (model?.project.clips.last?.sourceEnd ?? 0) - (model?.project.clips.first?.sourceStart ?? 0) >= 0.5
        }
    }

    @objc private func addFullLengthLayer(_ sender: NSButton) {
        guard let model, let first = model.project.clips.first, let last = model.project.clips.last else { return }
        let lane: Lane = sender === fullZoomButton ? .zoom : .keys
        guard lane == .zoom ? model.project.zooms.isEmpty : model.project.keystrokeClips.isEmpty else { return }
        guard last.sourceEnd - first.sourceStart >= 0.5 else { return }
        addBlock(lane: lane, atSource: first.sourceStart, length: last.sourceEnd - first.sourceStart)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size, dragKind != nil { cancelActiveDrag(); dragOrigin = nil }
        super.setFrameSize(newSize)
        geometry.width = max(0, newSize.width - gutterWidth)
        maybeFitOnFirstLayout()
        geometry.scrollX = clampScrollX(geometry.scrollX)
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
        if let start = selectionStart {
            if now - start < Theme.Motion.contextReveal { active = true } else { selectionStart = nil }
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
        needsLayout = true
        guard let model else { return }
        let previousContentHeight = contentHeight
        withObservationTracking {
            _ = model.project
            _ = model.playhead
            _ = model.isPlaying
            _ = model.selection
            _ = model.selectedClip
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
                let key = "\(model.selectedClips.sorted().map(String.init).joined(separator: ","))/\(model.selection.map(\.uuidString).sorted().joined())"
                if key != self.selectionKey {
                    self.selectionKey = key
                    if !self.reduceMotion { self.selectionStart = CACurrentMediaTime(); self.ensureAnimating() }
                }
                self.onNavigationChange?()
                if self.contentHeight != previousContentHeight { self.superview?.superview?.needsLayout = true }
                self.lastClips = model.project.clips
                self.loadWaveformIfNeeded()
                self.enclosingScrollView?.superview?.needsLayout = true
                if self.contentHeight != previousContentHeight { self.enclosingScrollView?.superview?.superview?.needsLayout = true }
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

    private var hasLayoutLane: Bool { model?.project.layouts.isEmpty == false }

    private func baseLaneHeight(_ lane: Lane) -> CGFloat {
        switch lane {
        case .clip: return Self.clipHeight
        case .camera: return model?.project.source.hasCamera == true ? 24 : 0
        case .zoom: return Self.zoomHeight
        case .keys: return Self.layoutHeight
        case .layout: return hasLayoutLane ? Self.layoutHeight : 0
        case .mask, .text: return Self.maskHeight
        case .window: return model?.project.windowCount ?? 1 > 1 ? Self.maskHeight : 0
        case .audio: return 36
        }
    }

    private func laneHeight(_ lane: Lane) -> CGFloat { baseLaneHeight(lane) }
    func laneMidY(_ lane: Lane) -> CGFloat { laneRow(lane).midY }

    /// Full-width row (spans the icon gutter too), in view-local (flipped) coordinates.
    private func laneRow(_ lane: Lane) -> CGRect {
        var y = Self.rulerHeight
        for l in lanes {
            let h = laneHeight(l)
            if l == lane { return CGRect(x: 0, y: y, width: bounds.width, height: h) }
            y += h
        }
        return .zero
    }

    private var rulerRow: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight) }

    /// Total content height (ruler + every visible lane).
    var contentHeight: CGFloat { lanes.reduce(Self.rulerHeight) { $0 + laneHeight($1) } }

    /// View-local x for output time `t`, past the icon gutter.
    private func x(forOutput t: Double) -> CGFloat { gutterWidth + CGFloat(geometry.x(forOutput: t)) }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        Theme.bgPanel.setFill()
        bounds.fill()

        guard let model else { return }
        let project = model.project
        let timeMap = model.timeMap

        NSGraphicsContext.saveGraphicsState()
        CGRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: contentHeight + 2).clip()
        drawTrackBeds()
        if project.clips.isEmpty {
            ("No video clips" as NSString).draw(
                at: CGPoint(x: gutterWidth + 12, y: laneRow(.clip).midY - 7),
                withAttributes: [.font: Theme.labelFont, .foregroundColor: Theme.textSecondary])
        }
        drawRuler()
        drawClipLane(project, timeMap)
        drawCameraLane(project, timeMap)
        drawZoomLane(project, timeMap)
        drawClickTicks(project, timeMap)
        drawEmptyLaneGhost()
        drawKeysLane(project, timeMap)
        if hasLayoutLane { drawLayoutLane(project, timeMap) }
        drawMaskLane(project, timeMap)
        drawTextLane(project, timeMap)
        drawWindowLane(project, timeMap)
        drawAudioLanes(project)
        drawLinkedPartners(project)
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
        drawDragOrigin()
        if let marqueeRect {
            Theme.textPrimary.withAlphaComponent(0.1).setFill(); marqueeRect.fill()
            Theme.textPrimary.setStroke(); NSBezierPath(rect: marqueeRect).stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawLaneLabels()
        drawFooter()
    }

    private func drawTrimChip() {
        guard let trimChip else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary]
        let label = trimChip.text as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: trimChip.x - size.width / 2 - 4, y: Self.rulerHeight + 4, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.setFill()
        chip.fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    private func drawLaneDividers() {
        Theme.stroke.setStroke()
        var y = Self.rulerHeight
        for lane in lanes {
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
        gutterLine.move(to: CGPoint(x: gutterWidth, y: 0))
        gutterLine.line(to: CGPoint(x: gutterWidth, y: contentHeight))
        gutterLine.lineWidth = 1
        gutterLine.stroke()
    }

    private func drawLaneLabels() {
        Theme.bgPanel.setFill()
        CGRect(x: 0, y: 0, width: gutterWidth, height: contentHeight).fill()
        let labels: [Lane: String] = [.clip: "Video", .camera: "Camera", .zoom: "Zoom", .layout: "Layout", .keys: "Keys", .mask: "Mask", .text: "Text", .window: "Window"]
        let colors: [Lane: NSColor] = [.clip: Theme.clip, .camera: Theme.layout, .keys: Theme.layout, .zoom: Theme.zoom, .layout: Theme.layout, .mask: Theme.mask, .text: Theme.text, .window: Theme.clip]
        // Lane.allCases order. Typed per element: one long `?? 0` array literal times out CI's type checker.
        let counts: [Int] = model.map { m -> [Int] in
            let p = m.project
            let clipCount: Int = p.clips.filter { !$0.isEmpty }.count
            return [clipCount, p.cameraClips.count, p.zooms.count, p.keystrokeClips.count, p.layouts.count, p.masks.count, p.texts.count, p.windowShots.count]
        } ?? [Int](repeating: 0, count: Lane.allCases.count)
        for (i, lane) in lanes.enumerated() {
            let row = laneRow(lane)
            guard row.height > 0 else { continue }
            if case .audio(let track) = lane { drawAudioHeader(track, row: row); continue }
            colors[lane]?.setFill()
            CGRect(x: compactTrackHeaders ? 6 : 10, y: row.midY - 5, width: 3, height: 10).fill()
            if compactTrackHeaders { continue }
            (labels[lane]! as NSString).draw(at: CGPoint(x: 22, y: row.midY - 7),
                withAttributes: [.font: Theme.labelFont, .foregroundColor: Theme.textPrimary])
            if !((lane == .zoom || lane == .keys) && counts[i] == 0) {
                ("\(counts[i])" as NSString).draw(at: CGPoint(x: 84, y: row.midY - 6),
                    withAttributes: [.font: Theme.captionFont, .foregroundColor: Theme.textTertiary])
            }
        }
        ((compactTrackHeaders ? "" : "Tracks") as NSString).draw(at: CGPoint(x: 10, y: 4),
            withAttributes: [.font: Theme.captionFont, .foregroundColor: Theme.textTertiary])
        drawLaneDividers()
        if window?.firstResponder === self {
            Theme.textPrimary.setFill()
            CGRect(x: 0, y: 0, width: 2, height: contentHeight).fill()
        }
    }

    private func drawTrackBeds() {
        for lane in lanes {
            let row = laneRow(lane)
            guard row.height > 0 else { continue }
            Theme.bgControl.setFill()
            CGRect(x: gutterWidth, y: row.minY + 3, width: max(0, bounds.width - gutterWidth), height: row.height - 6).fill()
        }
        let interval = geometry.tickInterval()
        var t = max(0, floor(geometry.output(forX: 0) / interval) * interval)
        while x(forOutput: t) < bounds.width {
            Theme.grid.setFill()
            CGRect(x: x(forOutput: t), y: Self.rulerHeight, width: 1, height: contentHeight - Self.rulerHeight).fill()
            t += interval
        }
    }

    // A stable feedback rail, with a whole-project overview on its right.
    var overviewRect: CGRect {
        CGRect(x: max(gutterWidth, bounds.width * 0.67), y: bounds.height - 25,
               width: max(0, bounds.width - max(gutterWidth, bounds.width * 0.67) - 12), height: 20)
    }

    private var selectedOutputRange: ClosedRange<Double>? {
        guard let model else { return nil }
        let selected = model.selectedClips.filter { model.project.clips.indices.contains($0) }
        if let first = selected.min(), let last = selected.max() {
            let start = model.project.clips.prefix(first).reduce(0) { $0 + $1.outputDuration }
            let end = model.project.clips.prefix(last + 1).reduce(0) { $0 + $1.outputDuration }
            return start...end
        }
        let blocks = model.project.zooms.map { ($0.id, $0.start, $0.end) }
            + model.project.keystrokeClips.map { ($0.id, $0.start, $0.end) }
            + model.project.cameraClips.map { ($0.id, $0.start, $0.end) }
            + model.project.layouts.map { ($0.id, $0.start, $0.end) }
            + model.project.masks.map { ($0.id, $0.start, $0.end) }
            + model.project.texts.map { ($0.id, $0.start, $0.end) }
            + model.project.windowShots.map { ($0.id, $0.start, $0.end) }
        var segments = blocks.filter { UUID(uuidString: $0.0).map(model.selection.contains) ?? false }
            .flatMap { visibleSegments(start: $0.1, end: $0.2, project: model.project, timeMap: model.timeMap) }
        for audio in model.project.audioClips where UUID(uuidString: audio.id).map(model.selection.contains) ?? false {
            segments += model.project.audioSegments(audio).map { (outStart: $0.output.start, outEnd: $0.output.end, tornLeft: false, tornRight: false) }
        }
        guard let start = segments.map(\.outStart).min(), let end = segments.map(\.outEnd).max() else { return nil }
        return start...end
    }

    var canFocusSelection: Bool { selectedOutputRange != nil }

    private func drawFooter() {
        guard bounds.height >= contentHeight + 26, let model else { return }
        var status = model.project.clips.isEmpty ? "No media" : (model.project.rippleDelete ? "Drag to select · Shift-click to add · Delete closes gap" : "Drag to select · Shift-click to add · Delete leaves gap")
        if isSplitMode { status = "Blade · click to split · Esc to select" }
        if let range = selectedOutputRange {
            status = "\(playheadLabel(range.lowerBound)) → \(playheadLabel(range.upperBound))  /  \(playheadLabel(range.upperBound - range.lowerBound))"
        }
        if dragKind != nil { status += snapGuideX == nil ? "  · ⌘ free" : "  · Snapped" }
        if let trimChip { status = trimChip.text }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let reveal = reduceMotion || dragKind != nil ? 1 : min(1, selectionStart.map { (CACurrentMediaTime() - $0) / Theme.Motion.contextReveal } ?? 1)
        (status as NSString).draw(in: CGRect(x: 12, y: bounds.height - 21, width: overviewRect.minX - 24, height: 16),
            withAttributes: [.font: Theme.captionFont, .foregroundColor: Theme.textSecondary.withAlphaComponent(0.5 + 0.5 * reveal), .paragraphStyle: paragraph])
        let rect = overviewRect
        Theme.bgControl.setFill(); rect.fill()
        let duration = timelineDuration
        guard duration > 0, rect.width > 0 else { return }
        var start = 0.0
        for clip in model.project.clips {
            (clip.isEmpty ? Theme.bgControl : Theme.clip.withAlphaComponent(0.4)).setFill()
            CGRect(x: rect.minX + start / duration * rect.width, y: rect.minY + 7,
                   width: max(1, clip.outputDuration / duration * rect.width - 1), height: 6).fill()
            start += clip.outputDuration
        }
        let left = max(0, geometry.output(forX: 0)) / duration
        let right = min(duration, geometry.output(forX: geometry.width)) / duration
        let viewport = CGRect(x: rect.minX + left * rect.width, y: rect.minY + 1,
                              width: max(2, (right - left) * rect.width), height: rect.height - 2)
        Theme.textPrimary.withAlphaComponent(0.1).setFill(); viewport.fill()
        Theme.textPrimary.setStroke(); NSBezierPath(rect: viewport).stroke()
        Theme.textPrimary.setFill()
        CGRect(x: rect.minX + model.playhead / duration * rect.width, y: rect.minY + 2, width: 2, height: rect.height - 4).fill()
    }

    private func drawDragOrigin() {
        guard let dragOrigin else { return }
        let path = NSBezierPath(rect: dragOrigin.insetBy(dx: 1, dy: 1))
        path.setLineDash([3, 3], count: 2, phase: 0)
        Theme.textPrimary.withAlphaComponent(0.65).setStroke()
        path.stroke()
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
            guard rect.width > 0.5, !clip.isEmpty else { continue }
            let label = "Clip \(i + 1)  ·  \(formatSpeed(clip.speed))×"
            drawBlock(rect, fill: Theme.clip, tornLeft: false, tornRight: false, label: label, selected: model?.selectedClips.contains(i) == true)
        }
    }

    private func loadWaveformIfNeeded() {
        guard let model else { return }
        let package = model.packageURL
        if waveformLoadedForPackage != package {
            waveformLoadedForPackage = package
            waveformPeaks = [:]; silentSpans = [:]; mediaDurations = [:]; waveformFiles = []
        }
        for file in Set(model.project.audioClips.map(\.file)).subtracting(waveformFiles) {
            waveformFiles.insert(file)
            guard let url = Waveform.audioURL(in: package, file: file) else { continue }
            Task.detached { [weak self] in
                let peaks = try? await Waveform.peaks(for: url)
                let silent = file == "mic.m4a" ? await Waveform.silent(in: url) : []
                let duration = try? await AVURLAsset(url: url).load(.duration).seconds
                await MainActor.run { [weak self] in
                    guard let self, self.waveformLoadedForPackage == package else { return }
                    self.waveformPeaks[file] = peaks
                    self.silentSpans[file] = silent
                    self.mediaDurations[file] = duration
                    self.needsDisplay = true
                }
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
        guard !oldClips.isEmpty, !reduceMotion else { return }
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

    private func drawCameraLane(_ project: Project, _ timeMap: TimeMap) {
        guard project.source.hasCamera else { return }
        let row = laneRow(.camera)
        for clip in project.cameraClips {
            for segment in visibleSegments(start: clip.start, end: clip.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                  width: x(forOutput: segment.outEnd) - x(forOutput: segment.outStart), height: row.height - 4)
                drawBlock(rect, fill: Theme.layout, tornLeft: false, tornRight: false, label: "Camera",
                          selected: UUID(uuidString: clip.id).map { model?.selection.contains($0) == true } ?? false)
            }
        }
    }

    private func drawZoomLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.zoom)
        let selection = model?.selection ?? []
        for zoom in project.zooms {
            let label = "\(String(format: "%.1f", zoom.scale))\u{00D7} \(zoom.mode == .auto ? "A" : "M")"
            let selected = UUID(uuidString: zoom.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: zoom.start, end: zoom.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.zoom, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    private func drawKeysLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.keys)
        let selection = model?.selection ?? []
        for layout in project.keystrokeClips {
            let label = "Keystrokes"
            let selected = UUID(uuidString: layout.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: layout.start, end: layout.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.layout, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    private func drawLayoutLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.layout)
        let selection = model?.selection ?? []
        for layout in project.layouts {
            let label = layout.kind == .settings ? "Keystrokes" : layout.kind == .cameraFull ? "Camera full" : layout.kind == .hidden ? "Camera hidden" : "Camera · size / position"
            let selected = UUID(uuidString: layout.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: layout.start, end: layout.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.layout, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: label, selected: selected)
            }
        }
    }

    /// SPEC §7.1 mask lane. The mask RECT itself is edited in
    /// the preview (`MaskRectOverlay`), not here — this lane only shows the block's time range.
    private func drawMaskLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.mask)
        let selection = model?.selection ?? []
        for mask in project.masks {
            let kindLabel = mask.kind == .highlight ? "Highlight" : (mask.kind == .blur ? "Blur" : "Mask")
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

    private func drawTextLane(_ project: Project, _ timeMap: TimeMap) {
        let row = laneRow(.text)
        let selection = model?.selection ?? []
        for text in project.texts {
            let selected = UUID(uuidString: text.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: text.start, end: text.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.text, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: text.text, selected: selected)
            }
        }
    }

    /// "Windows as layers": one block per shot, labelled with the window shown (hard cut at its edges).
    private func drawWindowLane(_ project: Project, _ timeMap: TimeMap) {
        guard laneHeight(.window) > 0 else { return }
        let row = laneRow(.window)
        let selection = model?.selection ?? []
        for shot in project.windowShots {
            let selected = UUID(uuidString: shot.id).map(selection.contains) ?? false
            for segment in visibleSegments(start: shot.start, end: shot.end, project: project, timeMap: timeMap) {
                let rect = CGRect(x: x(forOutput: segment.outStart), y: row.minY + 2,
                                   width: max(0, x(forOutput: segment.outEnd) - x(forOutput: segment.outStart)), height: row.height - 4)
                guard rect.width > 0.5 else { continue }
                drawBlock(rect, fill: Theme.clip, tornLeft: segment.tornLeft, tornRight: segment.tornRight, label: "Window \(shot.window + 1)", selected: selected)
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
            if let last = segments.last, abs(last.1 - outLo) < 1e-8 {
                segments[segments.count - 1] = (last.0, outHi, last.2, hi < end)
            } else {
                segments.append((outLo, outHi, lo > start, hi < end))
            }
        }
        return segments
    }

    // MARK: - Solid blocks, dark labels and a white selection outline

    private func drawBlock(_ rect: CGRect, fill: NSColor, tornLeft: Bool, tornRight: Bool, label: String?, selected: Bool = false) {
        let radius: CGFloat = 0
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let hovered = hoverX.map { x in hoverY.map { rect.contains(CGPoint(x: x, y: $0)) } ?? false } ?? false
        (hovered && dragKind == nil ? fill.blended(withFraction: 0.09, of: Theme.bgWindow) ?? fill : fill).setFill()
        path.fill()

        // A separated outline stays visible against pale blocks without a glow.
        if selected {
            NSGraphicsContext.saveGraphicsState()
            let progress = reduceMotion ? 1 : min(1, selectionStart.map { (CACurrentMediaTime() - $0) / Theme.Motion.contextReveal } ?? 1)
            let outset = 1 + 1.5 * (1 - pow(1 - progress, 3))
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -outset, dy: -outset), xRadius: radius, yRadius: radius)
            outline.lineWidth = 2
            Theme.textPrimary.setStroke()
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        if (selected || hovered), rect.width > 28 {
            Theme.bgWindow.withAlphaComponent(0.65).setFill()
            for px in [rect.minX + 3, rect.maxX - 5] {
                CGRect(x: px, y: rect.midY - 5, width: 2, height: 10).fill()
            }
        }
        // Torn edge marker (SPEC §7.1: "torn edge ⌇ when partially hidden" — U+2307 WAVY LINE).
        let tornAttrs: [NSAttributedString.Key: Any] = [.font: Theme.bodyFont, .foregroundColor: Theme.bgWindow]
        if tornLeft { ("\u{2307}" as NSString).draw(at: CGPoint(x: rect.minX + 1, y: rect.midY - 7), withAttributes: tornAttrs) }
        if tornRight { ("\u{2307}" as NSString).draw(at: CGPoint(x: rect.maxX - 9, y: rect.midY - 7), withAttributes: tornAttrs) }

        guard let label, rect.width > 24 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.captionFont, .foregroundColor: Theme.bgWindow,
                                                  .paragraphStyle: paragraph]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        let textRect = CGRect(x: max(rect.minX + 10, gutterWidth + 10), y: rect.minY + (rect.height > 35 ? 4 : (rect.height - size.height) / 2), width: max(0, rect.maxX - max(rect.minX + 10, gutterWidth + 10) - 10), height: size.height)
        text.draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Playhead

    private func drawPlayhead(_ t: Double) {
        let px = x(forOutput: t)
        guard px >= gutterWidth, px <= bounds.width else { return }
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
        let chip = CGRect(x: min(px + 6, bounds.width - size.width - 12), y: 2, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.setFill()
        chip.fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    /// 1 px white @ 30% line following the mouse, with a timecode tooltip (SPEC §7.1 "hover line").
    private func drawHover() {
        guard let hoverX, hoverX > gutterWidth, (hoverY ?? 0) < contentHeight, dragKind == nil else { return }
        let line = NSBezierPath()
        line.move(to: CGPoint(x: hoverX, y: 0))
        line.line(to: CGPoint(x: hoverX, y: contentHeight))
        line.lineWidth = 1
        Theme.textPrimary.withAlphaComponent(0.3).setStroke()
        line.stroke()

        let t = min(timelineDuration, max(0, geometry.output(forX: Double(hoverX) - Double(gutterWidth))))
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(10), .foregroundColor: Theme.textSecondary]
        let label = playheadLabel(t) as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: min(hoverX + 4, bounds.width - size.width - 12), y: 2, width: size.width + 8, height: size.height + 4)
        Theme.bgControl.withAlphaComponent(0.9).setFill()
        chip.fill()
        label.draw(at: CGPoint(x: chip.minX + 4, y: chip.minY + 2), withAttributes: attrs)
    }

    // MARK: - Split mode (SPEC §7.2 "Split" — the headline interaction)

    /// Full-height dashed accent blade at the snapped mouse x, with a timecode chip. `nil` when the
    /// mouse hasn't hovered the view yet.
    private func drawSplitBlade() {
        guard let t = bladeOutputTime() else { return }
        let px = x(forOutput: t) + bladeShakeOffset()
        let row = laneRow(lanes.first { laneRow($0).contains(CGPoint(x: gutterWidth + 1, y: hoverY ?? 0)) } ?? .clip)

        let line = NSBezierPath()
        line.move(to: CGPoint(x: px, y: row.minY))
        line.line(to: CGPoint(x: px, y: row.maxY))
        line.lineWidth = 1.5
        line.setLineDash([4, 3], count: 2, phase: 0)
        Theme.accent.setStroke()
        line.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.timecodeFont(11), .foregroundColor: Theme.textPrimary]
        let label = playheadLabel(t) as NSString
        let size = label.size(withAttributes: attrs)
        let chip = CGRect(x: px + 6, y: Self.rulerHeight + 4, width: size.width + 8, height: size.height + 4)
        Theme.accent.setFill()
        chip.fill()
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
        guard !reduceMotion, let bladeShakeStart else { return 0 }
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
        line.move(to: CGPoint(x: cutFlash.x, y: laneRow(cutLane).minY))
        line.line(to: CGPoint(x: cutFlash.x, y: laneRow(cutLane).maxY))
        line.lineWidth = 2
        Theme.textPrimary.withAlphaComponent(alpha).setStroke()
        line.stroke()
    }

    /// The blade's current (snapped) output time, from the last hover position. `nil` before the
    /// mouse has ever entered the view.
    private func bladeOutputTime() -> Double? {
        guard let hoverX, hoverX > gutterWidth, model != nil else { return nil }
        let raw = geometry.output(forX: geometryX(NSPoint(x: hoverX, y: 0)))
        let (value, snapped) = snappedOutput(raw, disabled: NSEvent.modifierFlags.contains(.command))
        snapGuideX = snapped ? x(forOutput: value) : nil
        return min(max(0, value), timelineDuration)
    }

    /// `Esc` exits split mode; the ✂ toolbar button and `S` toggle the sticky half of it.
    func toggleSplitModeSticky() {
        if splitModeSticky { exitSplitMode() } else { splitModeSticky = true; needsDisplay = true; updateHoverCallback() }
        onNavigationChange?()
    }

    private func exitSplitMode() {
        guard isSplitMode else { return }
        splitModeSticky = false
        splitOptionHeld = false
        onNavigationChange?()
        snapGuideX = nil
        onHoverTime?(nil)
        needsDisplay = true
    }

    /// `C` (immediate, at the playhead) and a split-mode click (at the blade) both land here.
    /// Refused (SPEC: within 2 frames of an edge, or a piece would be too short) → shake, no undo
    /// step. Success → exactly one `model.edit` (one undo step) + the cut flash.
    private func performSplit(atOutput t: Double, target: TimelineHit? = nil, clipOnly: Bool = false) {
        guard let model else { return }
        var trial = model.project
        let block: UUID?
        switch target {
        case .blockBody(let id), .blockEdge(let id, _): block = id
        case .clipBody, .clipEdge: block = nil
        case nil: block = clipOnly ? nil : model.selection.first
        default: return
        }
        let changed: Bool
        if let block, trial.audioClips.contains(where: { $0.id == block.uuidString }) { changed = trial.splitAudio(block, atOutput: t) }
        else if let block { changed = trial.splitBlock(block, atSource: model.timeMap.sourceTime(atOutput: t)) }
        else {
            if !clipOnly, target == nil, let selected = model.selectedClip, trial.clipIndex(atOutput: t) != selected { return }
            changed = trial.split(atOutput: t)
        }
        guard changed else {
            bladeShakeStart = CACurrentMediaTime()
            ensureAnimating()
            return
        }
        let px = x(forOutput: t)
        let splitIndex = model.project.clipIndex(atOutput: t)
        model.edit("Split") { $0 = trial }
        if clipOnly { model.selection = []; model.selectedClip = splitIndex }
        cutLane = block.flatMap { lane(ofBlock: $0) } ?? .clip
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
            project.keystrokeClips.map { ($0.id, $0.start, $0.end) },
            project.cameraClips.map { ($0.id, $0.start, $0.end) },
            project.layouts.map { ($0.id, $0.start, $0.end) },
            project.masks.map { ($0.id, $0.start, $0.end) },
            project.texts.map { ($0.id, $0.start, $0.end) },
            project.windowShots.map { ($0.id, $0.start, $0.end) },
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
        for audio in project.audioClips where UUID(uuidString: audio.id) != excludingBlock {
            for segment in project.audioSegments(audio) { candidates += [segment.output.start, segment.output.end] }
        }
        for layer in project.layers {
            if let start = timeMap.outputTime(atSource: layer.start) { candidates += [start, start + layer.end - layer.start] }
        }
        return candidates
    }

    /// `raw` (an output time under the mouse) snapped to the nearest candidate within 6 pt,
    /// converted to seconds at the current zoom. `disabled` (⌘ held) skips snapping entirely.
    private func snappedOutput(_ raw: Double, excludingBlock: UUID? = nil, disabled: Bool) -> (value: Double, snapped: Bool) {
        guard snappingEnabled, !disabled else { return (raw, false) }
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
        guard let model, p.x >= gutterWidth, p.y >= 0, p.y <= contentHeight else { return .none }

        let playheadX = x(forOutput: model.playhead)
        if p.y <= Self.rulerHeight, abs(p.x - playheadX) <= 6 { return .playhead }

        if let hit = hitClipLane(p, model) { return hit }
        if model.project.source.hasCamera, let hit = hitBlockLane(p, model, lane: .camera, blocks: model.project.cameraClips.map { ($0.id, $0.start, $0.end) }) { return hit }
        if let hit = hitBlockLane(p, model, lane: .zoom, blocks: model.project.zooms.map { ($0.id, $0.start, $0.end) }) { return hit }
        if let hit = hitBlockLane(p, model, lane: .keys, blocks: model.project.keystrokeClips.map { ($0.id, $0.start, $0.end) }) { return hit }
        if hasLayoutLane, let hit = hitBlockLane(p, model, lane: .layout, blocks: model.project.layouts.map { ($0.id, $0.start, $0.end) }) {
            return hit
        }
        if let hit = hitBlockLane(p, model, lane: .mask, blocks: model.project.masks.map { ($0.id, $0.start, $0.end) }) { return hit }
        if let hit = hitBlockLane(p, model, lane: .text, blocks: model.project.texts.map { ($0.id, $0.start, $0.end) }) { return hit }
        if laneHeight(.window) > 0, let hit = hitBlockLane(p, model, lane: .window, blocks: model.project.windowShots.map { ($0.id, $0.start, $0.end) }) { return hit }
        for audio in model.project.audioClips {
            guard let id = UUID(uuidString: audio.id) else { continue }
            for segment in model.project.audioSegments(audio) {
                let rect = audioRect(audio, output: segment.output)
                guard p.x >= rect.minX, p.x <= rect.maxX, p.y >= rect.minY - 3, p.y <= rect.maxY + 3 else { continue }
                let zone = edgeZone(width: rect.width)
                if p.x <= rect.minX + zone { return .blockEdge(id, .leading) }
                if p.x >= rect.maxX - zone { return .blockEdge(id, .trailing) }
                return .blockBody(id)
            }
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
            guard !clip.isEmpty else { continue }
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
            rect.fill()
            glyph.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 1), withAttributes: attrs)
        }
    }

    private func hitEmptyLane(_ p: CGPoint, _ model: EditorModel) -> TimelineHit? {
        for lane: Lane in [.camera, .zoom, .keys, .layout, .mask, .text, .window] {
            guard laneHeight(lane) > 0 else { continue }
            let row = laneRow(lane)
            guard p.y >= row.minY, p.y <= row.maxY, p.x >= gutterWidth else { continue }
            let t = geometry.output(forX: geometryX(p))
            return .emptyLane(lane, source: model.timeMap.sourceTime(atOutput: t))
        }
        return nil
    }

    // MARK: - Cursors (SPEC §7.2 table)

    private func cursor(for hit: TimelineHit) -> NSCursor {
        switch hit {
        case .playhead, .clipEdge, .blockEdge: return .resizeLeftRight
        case .blockBody, .clipBody: return .openHand
        case .cutBubble: return .pointingHand
        case .emptyLane: return .crosshair
        case .ruler, .none: return .arrow
        }
    }

    // MARK: - Selection (SPEC §7.2 "Selection")

    private func lane(ofBlock id: UUID) -> Lane? {
        guard let model else { return nil }
        let key = id.uuidString
        if model.project.keystrokeClips.contains(where: { $0.id == key }) { return .keys }
        if model.project.cameraClips.contains(where: { $0.id == key }) { return .camera }
        if model.project.zooms.contains(where: { $0.id == key }) { return .zoom }
        if model.project.layouts.contains(where: { $0.id == key }) { return .layout }
        if model.project.masks.contains(where: { $0.id == key }) { return .mask }
        if model.project.texts.contains(where: { $0.id == key }) { return .text }
        if model.project.windowShots.contains(where: { $0.id == key }) { return .window }
        if let audio = model.project.audioClips.first(where: { $0.id == key }) { return .audio(audio.track) }
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
    func removeSelection(ignoringLinks: Bool = false) {
        guard let model else { return }
        if !model.selectedClips.isEmpty {
            let indices = model.selectedClips
            model.edit("Remove Clips") { $0.deleteClips(indices, propagate: !ignoringLinks) }
            model.selectedClip = nil
        } else if !model.selection.isEmpty {
            let ids = model.selection
            model.edit("Remove") { project in for id in ids { project.removeBlock(id, propagate: !ignoringLinks) } }
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
            if model?.project.audioClips.contains(where: { $0.id == id.uuidString }) == true { return audioContextMenu(id: id) }
            if lane(ofBlock: id) == .zoom { return zoomContextMenu(id: id) }
            selectBlock(id, addToSelection: false)
            let menu = NSMenu()
            if let mask = model?.project.masks.first(where: { $0.id == id.uuidString }) {
                for (kind, title) in [(Mask.Kind.mask, "Cover"), (.blur, "Blur"), (.highlight, "Highlight")] {
                    let item = actionItem(title, action: #selector(menuSetMaskKind(_:)), represented: MaskKindTarget(id: id, kind: kind))
                    item.state = mask.kind == kind ? .on : .off
                    menu.addItem(item)
                }
                menu.addItem(actionItem("Duplicate (\u{2318}D)", action: #selector(menuDuplicateBlock(_:)), represented: id))
                menu.addItem(.separator())
            }
            if lane(ofBlock: id) == .window, let count = model?.project.windowCount {
                for n in 0..<count { menu.addItem(actionItem("Show Window \(n + 1)", action: #selector(menuShowWindow(_:)), represented: [id, n])) }
                menu.addItem(.separator())
            }
            menu.addItem(actionItem("Split at Playhead (C)", action: #selector(menuSplitAtPlayhead)))
            menu.addItem(actionItem("Remove", action: #selector(menuRemoveBlock(_:)), represented: id))
            return menu
        case .ruler:
            return rulerContextMenu()
        default:
            // `hitTest`'s `.emptyLane` is only defined for the zoom/layout/mask lanes (SPEC §7.2
            // table); an empty spot in the clip lane itself (past the last clip) falls through to
            // `.none` there, so it's recognised here instead.
            return isInClipLane(p) ? emptyClipAreaMenu() : nil
        }
    }

    @objc private func menuShowWindow(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let id = pair[0] as? UUID, let n = pair[1] as? Int else { return }
        model?.edit("Show Window \(n + 1)") { $0.setWindowShot(id, window: n) }
    }

    private func actionItem(_ title: String, action: Selector?, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    /// SPEC §7.2 "Context menus": `Clip: Split at Playhead (C) · Speed ▸ · Mute Audio · Remove (⌫)`.
    private func clipContextMenu(index: Int) -> NSMenu {
        if model?.selectedClips.contains(index) != true { selectClip(index) }
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

    func splitClipAtPlayhead() {
        guard let model else { return }
        performSplit(atOutput: model.playhead, clipOnly: true)
    }

    @objc func menuSplitAtPlayhead() {
        guard let model else { return }
        performSplit(atOutput: model.playhead)
    }

    @objc private func menuRemoveClip(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        if model?.selectedClips.contains(i) != true { selectClip(i) }
        removeSelection()
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
        zoomToSelection.isEnabled = canFocusSelection
        menu.addItem(zoomToSelection)
        return menu
    }

    @objc private func menuFit() { fit() }

    @objc func menuZoomToSelection() {
        guard let range = selectedOutputRange, geometry.width > 0 else { return }
        let duration = max(1 / 60.0, range.upperBound - range.lowerBound)
        userDidZoom = true
        geometry.pxPerSecond = max(minPxPerSecond(), min(Self.maxPxPerSecond, geometry.width / (duration * 1.2)))
        geometry.scrollX = clampScrollX(range.lowerBound * geometry.pxPerSecond - geometry.width / 12)
        needsDisplay = true
    }

    // MARK: - Zoom range + fit (SPEC §7.2 "Navigation")

    /// The px/s that fits the whole project's output duration in the current view width — the
    /// low end of the zoom range ("whole project ↔ 1 frame = 8 pt").
    private func minPxPerSecond() -> Double {
        guard model != nil else { return 8 }
        let duration = timelineDuration
        return duration > 0 ? geometry.width / duration : 8
    }

    private func clampScrollX(_ x: Double) -> Double {
        let maxX = max(0, timelineDuration * geometry.pxPerSecond - geometry.width)
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
        guard !didFitOnFirstLayout, !userDidZoom, geometry.width > 0, model != nil, timelineDuration > 0 else { return }
        fit()
        didFitOnFirstLayout = true
    }

    /// 0...1 position for a "slider in the timeline toolbar" (linear over the zoom range).
    var zoomSliderValue: Double {
        let lo = minPxPerSecond(), hi = Self.maxPxPerSecond
        guard hi > lo else { return 0 }
        return (geometry.pxPerSecond - lo) / (hi - lo)
    }

    func stepZoom(by factor: Double) { zoom(by: factor, anchorX: geometry.x(forOutput: model?.playhead ?? 0)) }

    func setZoom(sliderValue: Double) {
        let lo = minPxPerSecond(), hi = Self.maxPxPerSecond
        let target = lo + (hi - lo) * min(max(sliderValue, 0), 1)
        zoom(by: target / geometry.pxPerSecond, anchorX: geometry.x(forOutput: model?.playhead ?? 0))
    }

    /// View-local x (past the gutter, as `geometry` expects) for a point already converted to
    /// this view's coordinate space.
    private func geometryX(_ p: NSPoint) -> Double { Double(p.x) - Double(gutterWidth) }

    // MARK: - Scroll / pinch (SPEC §7.2 "Navigation")

    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView, frame.height > scroll.contentSize.height,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            super.scrollWheel(with: event)
            return
        }
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
        if cmd, chars?.lowercased() == "a", let model {
            model.selectedClips = Set(model.project.clips.indices.filter { !model.project.clips[$0].isEmpty })
            model.selection = []
            return
        }
        if cmd, chars?.lowercased() == "x" { cut(nil); return }
        if cmd, chars?.lowercased() == "c" { copy(nil); return }
        if cmd, chars?.lowercased() == "v" { paste(nil); return }
        if cmd, chars?.lowercased() == "l" { toggleAudioLink(); return }
        if !cmd, chars?.lowercased() == "n" { toggleSnapping(); return }
        if !cmd, chars?.lowercased() == "f" { menuZoomToSelection(); return }
        if cmd, chars == "=" || chars == "+", let model {
            zoom(by: 1.4, anchorX: geometry.x(forOutput: model.playhead))
        } else if cmd, chars == "-", let model {
            zoom(by: 1 / 1.4, anchorX: geometry.x(forOutput: model.playhead))
        } else if shift, chars?.lowercased() == "z" {
            fit()
        } else if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete: ⌫ removes the selection
            removeSelection(ignoringLinks: event.modifierFlags.contains(.option))
        } else if !cmd, chars?.lowercased() == "c", let model { // `C` = split at the playhead, immediately
            performSplit(atOutput: model.playhead)
        } else if !cmd, chars?.lowercased() == "s" { // `S` = sticky split mode
            toggleSplitModeSticky()
        } else if !cmd, chars?.lowercased() == "v" { // `V` = back to the pointer (selection) tool
            exitSplitMode()
        } else if !cmd, !shift, chars?.lowercased() == "z" { // `Z` = add a zoom at the playhead
            addZoom(atOutput: model?.playhead ?? 0)
        } else if !cmd, !shift, chars?.lowercased() == "t", let model { // `T` = add text at the playhead
            model.addText(atSource: model.timeMap.sourceTime(atOutput: model.playhead))
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
            onNavigationChange?()
            needsDisplay = true
            updateHoverCallback()
        }
        super.flagsChanged(with: event)
    }

    // MARK: - Ruler scrub (click/drag on the ruler moves the playhead; SPEC §7.2 "Navigation")

    private func blockRect(at p: CGPoint) -> CGRect? {
        guard let model else { return nil }
        let tracks: [(Lane, [(Double, Double)])] = [
            (.zoom, model.project.zooms.map { ($0.start, $0.end) }),
            (.keys, model.project.keystrokeClips.map { ($0.start, $0.end) }),
            (.camera, model.project.cameraClips.map { ($0.start, $0.end) }),
            (.layout, model.project.layouts.map { ($0.start, $0.end) }),
            (.mask, model.project.masks.map { ($0.start, $0.end) }),
            (.text, model.project.texts.map { ($0.start, $0.end) }),
            (.window, model.project.windowShots.map { ($0.start, $0.end) })]
        for (lane, blocks) in tracks where laneRow(lane).contains(p) {
            for (start, end) in blocks {
                for segment in visibleSegments(start: start, end: end, project: model.project, timeMap: model.timeMap) {
                    let rect = CGRect(x: x(forOutput: segment.outStart), y: laneRow(lane).minY + 2,
                                      width: x(forOutput: segment.outEnd) - x(forOutput: segment.outStart), height: laneHeight(lane) - 4)
                    if p.x >= rect.minX, p.x <= rect.maxX { return rect }
                }
            }
        }
        return nil
    }

    private func panOverview(to x: CGFloat, centered: Bool) {
        guard model != nil, let drag = overviewDrag, overviewRect.width > 0 else { return }
        let scale = timelineDuration * geometry.pxPerSecond / overviewRect.width
        geometry.scrollX = clampScrollX(centered
            ? (x - overviewRect.minX) * scale - geometry.width / 2
            : drag.scroll + (x - drag.x) * scale)
        autoScrollEnabled = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragIgnoresLinks = event.modifierFlags.contains(.option)
        if bounds.height >= contentHeight + 26, overviewRect.contains(p) {
            let original = geometry.scrollX
            overviewDrag = (p.x, original, original)
            let duration = timelineDuration
            let time = (p.x - overviewRect.minX) / overviewRect.width * duration
            if time < geometry.output(forX: 0) || time > geometry.output(forX: geometry.width) {
                panOverview(to: p.x, centered: true)
            }
            overviewDrag = (p.x, geometry.scrollX, original)
            return
        }
        guard p.x >= gutterWidth, p.y <= bounds.height - 26 else { return }
        if beginAudioDrag(at: p, event: event) { return }
        if case .blockBody = hitTest(at: p) {
            dragOrigin = blockRect(at: p)
        } else if case .blockEdge = hitTest(at: p) {
            dragOrigin = blockRect(at: p)
        }
        // SPEC §7.2 hit-test table: "Anything, in Split mode | blade ✂ line | click = split" — this
        // overrides the normal per-lane hit-test dispatch below.
        if isSplitMode {
            dragOrigin = nil
            hoverX = p.x
            if let t = bladeOutputTime() { performSplit(atOutput: t, target: hitTest(at: p)) }
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
            guard let model else { return }
            if event.modifierFlags.contains(.shift) {
                if model.selectedClips.contains(i) { model.selectedClips.remove(i) }
                else { model.selectedClips.insert(i) }
                model.selection = []
                return
            }
            if !model.selectedClips.contains(i) { selectClip(i) }
            dragSelection = model.selectedClips
            dragClips = model.project.clips
            dragProject = model.project
            model.beginGesture()
            dragKind = .moveClip(index: i, anchor: model.timeMap.sourceTime(atOutput: geometry.output(forX: geometryX(p))))
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
            if !event.modifierFlags.contains(.shift), lane != .clip, let model {
                model.beginGesture()
                var id: UUID?
                model.update { project in
                    switch lane {
                    case .zoom: id = project.addZoom(atSource: source, mode: zoomMode(nearSource: source))
                    case .camera: id = project.addCamera(atSource: source)
                    case .keys: id = project.addKeys(atSource: source)
                    case .layout: id = project.addLayout(atSource: source, kind: .bubble)
                    case .mask: id = project.addMask(atSource: source, kind: .blur, opacity: 1)
                    case .text: id = project.addText(atSource: source)
                    case .window: id = project.addWindowShot(atSource: source, window: (project.windowIndex(atSource: source) + 1) % project.windowCount)
                    case .clip, .audio: break
                    }
                }
                guard let id else { model.cancelGesture(); return }
                selectBlock(id, addToSelection: false)
                dragKind = .createBlock(id: id, lane: lane, anchor: source)
                return
            }
            marqueeStart = p
            marqueeOriginalSelection = (model?.selectedClips ?? [], model?.selection ?? [])
            marqueeSelection = event.modifierFlags.contains(.shift) ? (model?.selectedClips ?? []) : []
        case .none:
            marqueeStart = p
            marqueeOriginalSelection = (model?.selectedClips ?? [], model?.selection ?? [])
            marqueeSelection = event.modifierFlags.contains(.shift) ? (model?.selectedClips ?? []) : []
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if overviewDrag != nil { panOverview(to: p.x, centered: false); return }
        if let start = marqueeStart, let model {
            guard marqueeRect != nil || hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: max(1, abs(p.x - start.x)), height: max(1, abs(p.y - start.y)))
            marqueeRect = rect
            let rects = clipRects(model.project.clips, row: laneRow(.clip))
            model.selectedClips = marqueeSelection.union(rects.indices.filter { !model.project.clips[$0].isEmpty && rects[$0].intersects(rect) })
            model.selection = []
            needsDisplay = true
            return
        }
        // The event in hand (not the live hardware state `NSEvent.modifierFlags` — that's for
        // idle/draw-time checks like the split blade, which has no event) is what "⌘ held disables
        // snapping" (SPEC §7.2 "Snapping") means during an actual drag.
        let snapDisabled = event.modifierFlags.contains(.command)
        switch dragKind {
        case .moveClip(_, let anchor):
            guard let model else { return }
            let raw = geometry.output(forX: geometryX(p))
            let (out, snapped) = snappedOutput(raw, disabled: snapDisabled)
            snapGuideX = snapped ? x(forOutput: out) : nil
            let anchorOutput = TimeMap(dragClips).outputTime(atSource: anchor) ?? 0
            var delta = out - anchorOutput
            // Snap the selected clips' leading edge to zero, not the pointer's grab position.
            if snappingEnabled, !snapDisabled, let first = dragSelection.min() {
                let leading = dragClips.prefix(first).reduce(0) { $0 + $1.outputDuration }
                if abs(leading + raw - anchorOutput) <= 6 / max(geometry.pxPerSecond, 1) {
                    delta = -leading
                    snapGuideX = x(forOutput: 0)
                }
            }
            model.update { project in
                if let dragProject { project = dragProject }
                model.selectedClips = project.moveClips(dragSelection, byOutput: delta, propagate: !dragIgnoresLinks)
            }
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
                case .text:
                    project.resizeText(id, edge: .leading, to: min(anchor, source))
                    project.resizeText(id, edge: .trailing, to: max(anchor, source))
                    project.resizeText(id, edge: .leading, to: min(anchor, source))
                case .window:
                    project.resizeWindowShot(id, edge: .leading, to: min(anchor, source))
                    project.resizeWindowShot(id, edge: .trailing, to: max(anchor, source))
                    project.resizeWindowShot(id, edge: .leading, to: min(anchor, source))
                case .keys:
                    project.resizeKeys(id, edge: .leading, to: min(anchor, source))
                    project.resizeKeys(id, edge: .trailing, to: max(anchor, source))
                    project.resizeKeys(id, edge: .leading, to: min(anchor, source))
                case .camera:
                    project.resizeCamera(id, edge: .leading, to: min(anchor, source))
                    project.resizeCamera(id, edge: .trailing, to: max(anchor, source))
                    project.resizeCamera(id, edge: .leading, to: min(anchor, source))
                case .layout:
                    project.resizeLayout(id, edge: .leading, to: min(anchor, source))
                    project.resizeLayout(id, edge: .trailing, to: max(anchor, source))
                    project.resizeLayout(id, edge: .leading, to: min(anchor, source))
                case .clip, .audio: break
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
        case .audio(let id, let edge, let offset):
            updateAudioDrag(id: id, edge: edge, grabOffset: offset, point: p, snapDisabled: snapDisabled)
        case .audioFade(let id, let edge):
            updateAudioFade(id: id, edge: edge, point: p)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeStart != nil {
            if marqueeRect == nil {
                model?.selectedClips = marqueeSelection
                model?.selection = []
            }
            marqueeStart = nil; marqueeRect = nil
            needsDisplay = true
            return
        }
        overviewDrag = nil
        dragOrigin = nil
        dragSelection = []
        needsDisplay = true
        switch dragKind {
        case .createBlock(_, let lane, _):
            model?.commitGesture("Add \(laneName(lane))")
        case .moveClip:
            model?.commitGesture("Move Video")
        case .trimClip:
            model?.commitGesture("Trim")
        case .moveBlock(_, let lane, _):
            model?.commitGesture("Move \(laneName(lane))")
        case .resizeBlock(_, let lane, _):
            model?.commitGesture("Resize \(laneName(lane))")
        case .audio(_, let edge, _):
            model?.commitGesture(edge == nil ? "Move Audio" : "Trim Audio")
        case .audioFade:
            model?.commitGesture("Audio Fade")
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
        if marqueeStart != nil {
            model?.selectedClips = marqueeOriginalSelection.clips
            model?.selection = marqueeOriginalSelection.blocks
            marqueeStart = nil; marqueeRect = nil
            needsDisplay = true
            return
        }
        dragOrigin = nil
        if let overviewDrag {
            geometry.scrollX = overviewDrag.original
            self.overviewDrag = nil
            needsDisplay = true
            return
        }
        if dragKind != nil { cancelActiveDrag(); return }
        if isSplitMode { exitSplitMode(); return }
        deselect()
    }

    private func cancelActiveDrag() {
        switch dragKind {
        case .moveClip: model?.selectedClips = dragSelection
        case .trimClip(let index, _, _, _, _, _): model?.selectedClip = index
        default: break
        }
        switch dragKind {
        case .moveClip, .trimClip, .moveBlock, .resizeBlock, .createBlock, .audio, .audioFade:
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
        dragSelection = []
        needsDisplay = true
    }

    // MARK: - Trim (SPEC §7.2 "Trim")

    private func beginTrim(index: Int, edge: RecorderCore.Edge) {
        guard let model, model.project.clips.indices.contains(index) else { return }
        dragClips = model.project.clips
        dragProject = model.project
        let clip = model.project.clips[index]
        var priorOutput = 0.0
        for c in model.project.clips[0..<index] { priorOutput += c.outputDuration }
        model.beginGesture()
        dragKind = .trimClip(index: index, edge: edge, priorOutput: priorOutput,
                              beginSourceStart: clip.sourceStart, beginSourceEnd: clip.sourceEnd, speed: clip.timeScale)
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
        model.update { project in
            if let dragProject { project = dragProject }
            model.selectedClip = project.placeClip(index, start: edge == .leading ? target : beginSourceStart,
                                                   end: edge == .trailing ? target : beginSourceEnd, propagate: !dragIgnoresLinks)
        }
        let index = model.selectedClip ?? index

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
        case .keys: return "Keystrokes"
        case .camera: return "Camera"
        case .layout: return "Layout"
        case .mask: return "Mask"
        case .text: return "Text"
        case .window: return "Window"
        case .audio(let track): return model?.project.audioTracks[track].name ?? "Audio"
        }
    }

    /// Empty-lane click / `Z` (zoom only): adds a block appropriate to that lane and selects it.
    /// One undo step.
    private func addBlock(lane: Lane, atSource s: Double, length: Double = 3) {
        guard let model else { return }
        var newID: UUID?
        switch lane {
        case .zoom: newID = model.addZoom(atSource: s, length: length)
        case .keys: model.edit("Add Keystrokes") { newID = $0.addKeys(atSource: s, length: length) }
        case .camera: model.edit("Add Camera") { newID = $0.addCamera(atSource: s) }
        case .layout: model.edit("Add Layout") { newID = $0.addLayout(atSource: s, kind: .bubble) }
        case .mask: model.edit("Add Mask") { newID = $0.addMask(atSource: s, kind: .mask) }
        case .text: newID = model.addText(atSource: s)
        case .window: model.edit("Add Window Shot") { newID = $0.addWindowShot(atSource: s, window: ($0.windowIndex(atSource: s) + 1) % $0.windowCount) }
        case .clip, .audio: break
        }
        if let newID { selectBlock(newID, addToSelection: false) }
    }

    /// `Z` adds a zoom at the playhead (SPEC §7.3).
    private func addZoom(atOutput t: Double) {
        guard let model else { return }
        addBlock(lane: .zoom, atSource: model.timeMap.sourceTime(atOutput: t))
    }

    /// `⌘D` duplicates every selected zoom/mask right after itself (SPEC §7.3).
    private func duplicateSelection() {
        guard let model, !model.selection.isEmpty else { return }
        var copies: [UUID] = []
        model.edit("Duplicate") { project in
            // Sorted so the result doesn't depend on Set order; each copy lands in the gap after its original.
            for id in model.selection.sorted(by: { $0.uuidString < $1.uuidString }) { if let copy = project.duplicateBlock(id) { copies.append(copy) } }
        }
        if !copies.isEmpty { model.selectedClip = nil; model.selection = Set(copies) }
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
        case .keys: return model.project.keystrokeClips.first { $0.id == id.uuidString }?.start
        case .camera: return model.project.cameraClips.first { $0.id == id.uuidString }?.start
        case .layout: return model.project.layouts.first { $0.id == id.uuidString }?.start
        case .mask: return model.project.masks.first { $0.id == id.uuidString }?.start
        case .text: return model.project.texts.first { $0.id == id.uuidString }?.start
        case .window: return model.project.windowShots.first { $0.id == id.uuidString }?.start
        case .audio: return model.project.audioClips.first { $0.id == id.uuidString }?.start
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
            case .keys: project.moveKeys(id, toStart: toStart)
            case .camera: project.moveCamera(id, toStart: toStart, propagate: !dragIgnoresLinks)
            case .layout: project.moveLayout(id, toStart: toStart)
            case .mask: project.moveMask(id, toStart: toStart)
            case .text: project.moveText(id, toStart: toStart)
            case .window: project.moveWindowShot(id, toStart: toStart)
            case .clip, .audio: break
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
            case .keys: project.resizeKeys(id, edge: edge, to: source)
            case .camera: project.resizeCamera(id, edge: edge, to: source, propagate: !dragIgnoresLinks)
            case .layout: project.resizeLayout(id, edge: edge, to: source)
            case .mask: project.resizeMask(id, edge: edge, to: source)
            case .text: project.resizeText(id, edge: edge, to: source)
            case .window: project.resizeWindowShot(id, edge: edge, to: source)
            case .clip, .audio: break
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
        case .keys:
            guard var trial = model?.project, let id = trial.addKeys(atSource: s),
                  let clip = trial.keystrokeClips.first(where: { $0.id == id.uuidString }) else { return nil }
            return (clip.start, clip.end)
        case .camera:
            guard var trial = model?.project, let id = trial.addCamera(atSource: s),
                  let clip = trial.cameraClips.first(where: { $0.id == id.uuidString }) else { return nil }
            return (clip.start, clip.end)
        case .layout: return model?.project.previewLayoutPlacement(atSource: s)
        case .mask: return model?.project.previewMaskPlacement(atSource: s)
        case .text:
            guard var trial = model?.project, let id = trial.addText(atSource: s),
                  let block = trial.texts.first(where: { $0.id == id.uuidString }) else { return nil }
            return (block.start, block.end)
        case .window: return model?.project.previewWindowShotPlacement(atSource: s)
        case .clip, .audio: return nil
        }
    }

    private func ghostFill(_ lane: Lane) -> NSColor {
        switch lane {
        case .clip: return Theme.clip
        case .zoom: return Theme.accent
        case .keys: return Theme.layout
        case .camera: return Theme.layout
        case .layout: return Theme.layout
        case .mask: return Theme.mask
        case .text: return Theme.text
        case .window: return Theme.clip
        case .audio: return Theme.audio
        }
    }

    /// Concise lane-specific labels for the add-preview block.
    private func ghostLabel(_ lane: Lane) -> String {
        switch lane {
        case .clip: return "+ add"
        case .zoom: return "+ Zoom"
        case .keys: return "+ Keys"
        case .camera: return "+ Camera"
        case .layout: return "+ Layout"
        case .mask: return "+ Mask"
        case .text: return "+ Text"
        case .window: return "+ Window"
        case .audio: return ""
        }
    }

    /// "Empty zoom/layout/mask lane: ghost block under pointer" (SPEC §7.1/§7.2).
    private func drawEmptyLaneGhost() {
        guard dragKind == nil, !isSplitMode, let model, let hoverX, let hoverY, hoverX > gutterWidth else { return }
        guard let lane = [Lane.camera, .zoom, .keys, .layout, .mask, .text, .window].first(where: { laneHeight($0) > 0 && hoverY >= laneRow($0).minY && hoverY <= laneRow($0).maxY }) else { return }
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

    private struct MaskKindTarget { let id: UUID; let kind: Mask.Kind }

    @objc private func menuSetMaskKind(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? MaskKindTarget else { return }
        model?.edit("Mask kind") { project in
            if let i = project.masks.firstIndex(where: { $0.id == t.id.uuidString }) { project.masks[i].kind = t.kind }
        }
    }

    @objc private func menuDuplicateBlock(_ sender: NSMenuItem) {
        guard sender.representedObject is UUID else { return }
        duplicateSelection() // the menu selected the block first
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
        model.playhead = min(max(0, t), timelineDuration)
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
        elements += axBlockElements(model.project.keystrokeClips, lane: .keys, model: model,
            id: { $0.id }, start: { $0.start }, end: { $0.end }, label: { _ in "Keystrokes" },
            nudge: { [weak self] id, frames in
                guard let model = self?.model, let clip = model.project.keystrokeClips.first(where: { $0.id == id.uuidString }) else { return }
                model.edit("Move Keystrokes") { $0.moveKeys(id, toStart: clip.start + Double(frames) / 60) }
            })
        elements += axBlockElements(model.project.cameraClips, lane: .camera, model: model,
            id: { $0.id }, start: { $0.start }, end: { $0.end }, label: { _ in "Camera" },
            nudge: { [weak self] id, frames in
                guard let self, let model = self.model,
                      let clip = model.project.cameraClips.first(where: { $0.id == id.uuidString }) else { return }
                model.edit("Move Camera") { $0.moveCamera(id, toStart: clip.start + Double(frames) / 60) }
            })
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
        if laneHeight(.text) > 0 {
            elements += axBlockElements(model.project.texts, lane: .text, model: model,
                                         id: { $0.id }, start: { $0.start }, end: { $0.end },
                                         label: { "Text, \($0.text)" },
                                         nudge: { [weak self] id, frames in
                                             guard let self, let model = self.model, let t = model.project.texts.first(where: { $0.id == id.uuidString }) else { return }
                                             model.edit("Move Text") { $0.moveText(id, toStart: t.start + Double(frames) * Self.axFrameSeconds) }
                                         })
        }
        if laneHeight(.window) > 0 {
            elements += axBlockElements(model.project.windowShots, lane: .window, model: model,
                                         id: { $0.id }, start: { $0.start }, end: { $0.end },
                                         label: { "Window \($0.window + 1)" },
                                         nudge: { [weak self] id, frames in self?.nudgeWindowShot(id, frames: frames) })
        }
        for audio in model.project.audioClips {
            let segments = model.project.audioSegments(audio)
            guard let first = segments.first, let last = segments.last, let id = UUID(uuidString: audio.id) else { continue }
            let link: String
            switch audio.link {
            case .screen: link = "linked to screen"
            case .camera: link = "linked to camera"
            case .layer: link = "linked to its video"
            case nil: link = "unlinked"
            }
            let label = "\(model.project.audioTracks[audio.track].name) audio, \(link), \(axTime(first.output.start)) to \(axTime(last.output.end)) seconds"
            elements.append(axElement(frame: audioRect(audio, output: TimeRange(start: first.output.start, end: last.output.end)), label: label) { [weak self] frames in
                guard let self, let model = self.model else { return }
                let source = model.timeMap.sourceTime(atOutput: first.output.start + Double(frames) / 60)
                model.edit("Move Audio") { $0.moveAudio(id, toStart: source) }
            })
        }
        if bounds.height >= contentHeight + 26 {
            let overview = axElement(frame: overviewRect, label: "Timeline overview", nudge: { [weak self] direction in
                guard let self else { return }
                self.geometry.scrollX = self.clampScrollX(self.geometry.scrollX + Double(direction) * self.geometry.width * 0.8)
                self.autoScrollEnabled = false
                self.needsDisplay = true
            })
            overview.setAccessibilityRole(.slider)
            overview.setAccessibilityValue("Visible \(playheadLabel(geometry.output(forX: 0))) to \(playheadLabel(min(timelineDuration, geometry.output(forX: geometry.width))))")
            elements.append(overview)
        }
        let audioControls = audioHeaderButtons.values.flatMap { [$0.volume, $0.mute, $0.record] }
        return elements + ([fullZoomButton, fullKeysButton] + audioControls).filter { !$0.isHidden }
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
            guard !clip.isEmpty else { continue }
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

    private func nudgeWindowShot(_ id: UUID, frames: Int) {
        guard let model, let shot = model.project.windowShots.first(where: { $0.id == id.uuidString }) else { return }
        model.edit("Move Window Shot") { $0.moveWindowShot(id, toStart: shot.start + Double(frames) * Self.axFrameSeconds) }
    }

    private func nudgeMask(_ id: UUID, frames: Int) {
        guard let model, let mask = model.project.masks.first(where: { $0.id == id.uuidString }) else { return }
        model.edit("Move Mask") { $0.moveMask(id, toStart: mask.start + Double(frames) * Self.axFrameSeconds) }
    }

    private func nudgeClip(_ i: Int, frames: Int) {
        guard let model, model.project.clips.indices.contains(i) else { return }
        let clip = model.project.clips[i]
        let delta = Double(frames) * Self.axFrameSeconds * clip.timeScale // OUTPUT-frame nudge -> SOURCE delta
        model.edit("Trim Clip") { model.selectedClip = $0.placeClip(i, start: clip.sourceStart, end: clip.sourceEnd + delta) }
    }
}

extension TimelineView {
    @MainActor static func runAudioUISelfTest() throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        func check(_ value: Bool, _ description: String) throws { if !value { throw Fail(description: description) } }
        _ = NSApplication.shared
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("audio-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        var project = Project(source: Source(duration: 12, hasCamera: true, hasMic: true), clips: [Clip(sourceStart: 0, sourceEnd: 12)])
        project.cameraClips = [CameraClip(start: 2, end: 6)]
        project.audioTracks = [AudioTrack(name: "Mic"), AudioTrack(name: "System"), AudioTrack(name: "Voiceover 1"), AudioTrack(name: "Audio 1")]
        project.audioClips = [AudioClip(start: 2, end: 6, mediaStart: 2, file: "mic.m4a", track: 0, link: .camera),
                              AudioClip(start: 0, end: 12, file: "system.m4a", track: 1, link: .screen),
                              AudioClip(start: 8, end: 10, file: "voice.m4a", track: 2),
                              AudioClip(start: 9, end: 11, file: "music.m4a", track: 3)]
        let model = EditorModel(packageURL: package, project: project, events: EventLog())
        defer { model.saveNow() }
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 1000, height: 400))
        view.model = model
        view.mediaDurations = ["mic.m4a": 12, "system.m4a": 12, "voice.m4a": 12, "music.m4a": 12]
        let toolbar = TimelineToolbar(frame: .zero)
        toolbar.timelineView = view
        let container = TimelineContainerView(toolbar: toolbar, timeline: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        view.geometry.pxPerSecond = 60
        let id = UUID(uuidString: project.audioClips[0].id)!
        func point(_ time: Double, track: Int = 0) -> CGPoint { CGPoint(x: view.x(forOutput: time), y: view.laneMidY(.audio(track)) + 5) }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                               timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ start: CGPoint, _ end: CGPoint, modifiers: NSEvent.ModifierFlags = [.command]) {
            view.mouseDown(with: event(.leftMouseDown, start, modifiers))
            view.mouseDragged(with: event(.leftMouseDragged, end, modifiers))
            view.mouseUp(with: event(.leftMouseUp, end, modifiers))
        }
        try check(view.lanes.suffix(4) == [.audio(0), .audio(1), .audio(2), .audio(3)], "Audio lane order")
        drag(point(3), point(4), modifiers: [.command, .option])
        let shifted = model.project.audioClips.first { $0.id == id.uuidString }!
        try check(model.project.cameraClips == project.cameraClips && shifted.start == 3, "Option drag moved camera or ignored audio")
        try check(model.undoStepCount == 1 && abs(model.project.syncOffset(shifted)! - 1) < 1e-8, "Option drag sync/undo")
        view.menuAudioSync()
        try check(abs(model.project.syncOffset(model.project.audioClips.first { $0.id == id.uuidString }!)!) < 1e-8, "Move into Sync left offset")
        model.undo(); model.undo()
        try check(model.project == project && model.undoStepCount == 0, "Sync/drag undo")
        model.selection = [id]
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!)
        let detached = model.project
        drag(point(3), point(4))
        try check(model.project.cameraClips == project.cameraClips && model.project.audioClips.first { $0.id == id.uuidString }?.start == 3, "Detached audio move")
        try check(model.undoStepCount == 2, "Detached move was not one undo step")
        model.undo(); try check(model.project == detached, "Detached move undo")
        model.undo(); try check(model.project == project, "Unlink undo")
        drag(point(3), point(4))
        try check(model.project.cameraClips[0].start == 3 && model.undoStepCount == 1, "Linked audio did not carry camera")
        model.undo()
        drag(point(6), point(5), modifiers: [.command, .option])
        try check(model.project.audioClips.first { $0.id == id.uuidString }?.end == 5 && model.project.cameraClips == project.cameraClips, "Option trim")
        model.undo()
        let targetY = view.laneMidY(.audio(2))
        view.mouseDown(with: event(.leftMouseDown, point(3), [.command, .option]))
        view.mouseDragged(with: event(.leftMouseDragged, point(3, track: 2), [.command, .option]))
        container.layoutSubtreeIfNeeded()
        try check(view.laneMidY(.audio(2)) == targetY && view.lanes.contains(.audio(0)) && view.debugDragKind == "audio", "Audio lane shifted during drag")
        view.mouseUp(with: event(.leftMouseUp, point(3, track: 2), [.command, .option]))
        try check(model.project.audioClips.first { $0.id == id.uuidString }?.track == 2 && model.undoStepCount == 1, "Vertical lane move")
        model.undo()
        drag(point(3), point(3, track: 1), modifiers: [.command, .option])
        try check(model.project == project && model.undoStepCount == 0, "Occupied audio lane accepted overlap")
        let handle = view.fadeHandle(project.audioClips[0], edge: .leading, project: project)!
        drag(CGPoint(x: handle.midX, y: handle.midY), CGPoint(x: view.x(forOutput: 2.76), y: handle.midY))
        try check(model.project.audioClips.first { $0.id == id.uuidString }?.fadeIn == 0.8 && model.undoStepCount == 1, "Fade handle quantization/undo")
        model.undo()
        view.mouseDown(with: event(.leftMouseDown, point(3), [.command, .option]))
        view.mouseDragged(with: event(.leftMouseDragged, point(4), [.command, .option]))
        view.cancelOperation(nil)
        try check(model.project == project && model.undoStepCount == 0, "Escape did not roll audio drag back")
        view.layoutSubtreeIfNeeded()
        guard let mute = view.audioHeaderButtons[0]?.mute else { throw Fail(description: "Missing mute header") }
        mute.performClick(nil)
        try check(model.project.audioTracks[0].muted && model.undoStepCount == 1, "Track mute")
        model.undo()
        model.beginGesture()
        for value in [0.4, 0.8, 1.5] { view.trackVolumeBinding(0).wrappedValue = value }
        model.commitGesture("Track Volume")
        try check(model.project.audioTracks[0].volume == 1.5 && model.undoStepCount == 1, "Track volume gesture")
        model.undo()
        model.selection = [id]
        let menu = view.audioContextMenu(id: id)
        try check(menu.items.contains { $0.title.hasPrefix("Unlink") } && menu.items.contains { $0.title == "Move into Sync" }, "Audio context menu")
        let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        try check(labels.contains("Mic audio, linked to camera, 2.0 to 6.0 seconds"), "Audio accessibility label")
        let panel = AudioPanel(model: model, audioID: id)
        model.beginGesture(); panel.gainBinding.wrappedValue = -6; model.commitGesture("Audio Gain")
        try check(abs(model.project.audioClips[0].gain - pow(10, -6 / 20.0)) < 1e-8 && model.undoStepCount == 1, "Audio inspector dB gain")
        model.undo()
        model.beginGesture(); panel.fadeBinding(incoming: false).wrappedValue = 0.44; model.commitGesture("Audio Fade")
        try check(model.project.audioClips[0].fadeOut == 0.4 && model.undoStepCount == 1, "Audio inspector fade")
        model.undo()
        let hosting = NSHostingView(rootView: InspectorView(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw Fail(description: "Audio panel bitmap") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/recorder-audio-inspector.png"))
        view.toggleCompactTrackHeaders(); view.layoutSubtreeIfNeeded()
        try check(view.gutterWidth == 16 && view.audioHeaderButtons.values.allSatisfy { $0.volume.isHidden && $0.mute.isHidden }, "Compact headers")
        view.toggleCompactTrackHeaders()
        container.setFrameSize(CGSize(width: 640, height: 220)); container.layoutSubtreeIfNeeded()
        try check(view.frame.height >= view.contentHeight + 26 && view.enclosingScrollView?.hasVerticalScroller == true, "Audio lanes clipped at minimum size")
        view.scrollToVisible(view.audioRect(project.audioClips[3], output: TimeRange(start: 9, end: 11)))
        try check(view.visibleRect.intersects(view.laneRow(.audio(3))), "Bottom audio lane not reachable")
        try check(model.project == project && model.project.checkInvariants() == nil, "Audio UI left invalid data")
    }

    private func beginAudioDrag(at point: CGPoint, event: NSEvent) -> Bool {
        guard let model else { return false }
        let id: UUID, edge: RecorderCore.Edge?
        switch hitTest(at: point) {
        case .blockBody(let block): id = block; edge = nil
        case .blockEdge(let block, let side): id = block; edge = side
        default: return false
        }
        guard let clip = model.project.audioClips.first(where: { $0.id == id.uuidString }),
              let first = model.project.audioSegments(clip).first else { return false }
        if splitModeSticky { return false }
        selectBlock(id, addToSelection: event.modifierFlags.contains(.shift))
        if event.modifierFlags.contains(.shift) { return true }
        dragProject = model.project
        dragOrigin = audioRect(clip, output: TimeRange(start: first.output.start, end: model.project.audioSegments(clip).last!.output.end))
        model.beginGesture()
        for side in [RecorderCore.Edge.leading, .trailing] {
            if fadeHandle(clip, edge: side, project: model.project)?.insetBy(dx: -3, dy: -4).contains(point) == true {
                dragKind = .audioFade(id: id, edge: side)
                return true
            }
        }
        dragKind = .audio(id: id, edge: edge, grabOffset: geometry.output(forX: geometryX(point)) - first.output.start)
        return true
    }

    private func updateAudioDrag(id: UUID, edge: RecorderCore.Edge?, grabOffset: Double, point: CGPoint, snapDisabled: Bool) {
        guard let model, let original = dragProject,
              let clip = original.audioClips.first(where: { $0.id == id.uuidString }) else { return }
        let raw = geometry.output(forX: geometryX(point)) - (edge == nil ? grabOffset : 0)
        let (output, snapped) = snappedOutput(raw, excludingBlock: id, disabled: snapDisabled)
        var changed = original
        if let edge {
            changed.resizeAudio(id, edge: edge, toOutput: output,
                                mediaDuration: mediaDurations[clip.file] ?? clip.mediaStart + original.audioSegments(clip).reduce(0) { $0 + $1.media.end - $1.media.start },
                                propagate: !dragIgnoresLinks)
        } else {
            if let lane = lanes.first(where: { laneRow($0).contains(CGPoint(x: gutterWidth + 1, y: point.y)) }),
               case .audio(let track) = lane, let index = changed.audioClips.firstIndex(where: { $0.id == clip.id }) {
                changed.audioClips[index].track = track
            }
            changed.moveAudio(id, toOutput: max(0, output), propagate: !dragIgnoresLinks)
        }
        if changed.checkInvariants(mediaDurations: mediaDurations) == nil { model.update { $0 = changed } }
        snapGuideX = snapped ? x(forOutput: output) : nil
        if let current = model.project.audioClips.first(where: { $0.id == id.uuidString }),
           let first = model.project.audioSegments(current).first, let last = model.project.audioSegments(current).last {
            trimChip = (x: point.x, text: String(format: "%.2f – %.2f s", first.output.start, last.output.end))
        }
        needsDisplay = true
    }

    private func updateAudioFade(id: UUID, edge: RecorderCore.Edge, point: CGPoint) {
        guard let model, let audio = model.project.audioClips.first(where: { $0.id == id.uuidString }) else { return }
        let segments = model.project.audioSegments(audio)
        guard let first = segments.first, let last = segments.last else { return }
        let time = geometry.output(forX: geometryX(point))
        let length = min(last.output.end - first.output.start, max(0, ((edge == .leading ? time - first.output.start : last.output.end - time) * 10).rounded() / 10))
        model.update { project in
            guard let index = project.audioClips.firstIndex(where: { $0.id == id.uuidString }) else { return }
            if edge == .leading { project.audioClips[index].fadeIn = length > 0 ? length : nil }
            else { project.audioClips[index].fadeOut = length > 0 ? length : nil }
        }
        trimChip = (x: point.x, text: String(format: "fade %.2f s", length))
        needsDisplay = true
    }

    @objc func toggleAudioLink() {
        guard let model, model.selection.count == 1, let id = model.selection.first,
              let clip = model.project.audioClips.first(where: { $0.id == id.uuidString }) else { return }
        let target: AudioClip.Link = model.project.layers.contains { $0.file == clip.file && $0.kind == .video } ? .layer :
            (clip.file == "mic.m4a" && model.project.source.hasCamera ? .camera : .screen)
        AudioPanel(model: model, audioID: id).changeLink(clip.link == nil ? target : nil)
    }

    private func audioContextMenu(id: UUID) -> NSMenu {
        selectBlock(id, addToSelection: false)
        let menu = NSMenu()
        guard let model, let clip = model.project.audioClips.first(where: { $0.id == id.uuidString }) else { return menu }
        menu.addItem(actionItem("Split at Playhead (C)", action: #selector(menuSplitAtPlayhead)))
        if clip.link != nil { menu.addItem(actionItem("Unlink (⌘L)", action: #selector(menuAudioLink(_:)), represented: "none")) }
        menu.addItem(actionItem("Link to Screen", action: #selector(menuAudioLink(_:)), represented: "screen"))
        if model.project.source.hasCamera { menu.addItem(actionItem("Link to Camera", action: #selector(menuAudioLink(_:)), represented: "camera")) }
        if model.project.layers.contains(where: { $0.file == clip.file && $0.kind == .video }) {
            menu.addItem(actionItem("Link to Its Video", action: #selector(menuAudioLink(_:)), represented: "layer"))
        }
        if model.project.syncOffset(clip) != nil { menu.addItem(actionItem("Move into Sync", action: #selector(menuAudioSync))) }
        menu.addItem(.separator())
        let mute = actionItem("Mute Clip", action: #selector(menuAudioMute))
        mute.state = clip.gain == 0 ? .on : .off; menu.addItem(mute)
        let record = actionItem("Re-record… (⇧R)", action: nil)
        record.isEnabled = false; menu.addItem(record)
        menu.addItem(actionItem("Remove (⌫)", action: #selector(menuRemoveBlock(_:)), represented: id))
        return menu
    }

    @objc private func menuAudioLink(_ sender: NSMenuItem) {
        guard let model, let id = model.selection.first, let target = sender.representedObject as? String else { return }
        AudioPanel(model: model, audioID: id).changeLink(AudioClip.Link(rawValue: target))
    }

    @objc func menuAudioSync() {
        guard let model, let id = model.selection.first else { return }
        AudioPanel(model: model, audioID: id).moveIntoSync()
    }

    @objc private func menuAudioMute() {
        guard let model, let id = model.selection.first else { return }
        model.edit("Mute Audio") { project in
            if let index = project.audioClips.firstIndex(where: { $0.id == id.uuidString }) { project.audioClips[index].gain = project.audioClips[index].gain == 0 ? 1 : 0 }
        }
    }

    private func audioRect(_ audio: AudioClip, output: TimeRange) -> CGRect {
        let row = laneRow(.audio(audio.track))
        return CGRect(x: x(forOutput: output.start), y: row.minY + 3,
                      width: max(0, x(forOutput: output.end) - x(forOutput: output.start)), height: row.height - 6)
    }

    private func drawAudioLanes(_ project: Project) {
        for audio in project.audioClips {
            let selected = UUID(uuidString: audio.id).map { model?.selection.contains($0) == true } ?? false
            let segments = project.audioSegments(audio)
            guard let first = segments.first, let last = segments.last else { continue }
            for segment in segments {
                let rect = audioRect(audio, output: segment.output)
                guard rect.maxX >= gutterWidth, rect.minX <= bounds.width else { continue }
                let voice = project.audioTracks[audio.track].name.hasPrefix("Voiceover")
                drawBlock(rect, fill: voice ? Theme.voiceover : Theme.audio,
                          tornLeft: false, tornRight: false, label: nil, selected: selected)
                let strip = CGRect(x: rect.minX + 3, y: rect.minY + 14, width: max(0, rect.width - 6), height: 14)
                drawAudioWaveform(audio, segment: segment, in: strip)
                if audio.gain == 0 { drawAudioHatch(rect) }
                let duration = last.output.end - first.output.start
                let ramp = NSBezierPath()
                ramp.move(to: CGPoint(x: x(forOutput: first.output.start), y: rect.maxY - 2))
                ramp.line(to: CGPoint(x: x(forOutput: first.output.start + min(audio.fadeIn ?? 0, duration)), y: rect.minY + 2))
                ramp.move(to: CGPoint(x: x(forOutput: last.output.end - min(audio.fadeOut ?? 0, duration)), y: rect.minY + 2))
                ramp.line(to: CGPoint(x: x(forOutput: last.output.end), y: rect.maxY - 2))
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                Theme.mediaMatte.withAlphaComponent(0.65).setStroke(); ramp.stroke()
                let badge: String
                switch audio.link {
                case .screen: badge = "⛓ Scr"
                case .camera: badge = "⛓ Cam"
                case .layer: badge = "⛓ Clip"
                case nil: badge = URL(fileURLWithPath: audio.file).lastPathComponent
                }
                let left = max(rect.minX + 12, gutterWidth + 4)
                (badge as NSString).draw(at: CGPoint(x: left, y: rect.minY + 1),
                    withAttributes: [.font: Theme.captionFont, .foregroundColor: Theme.mediaMatte])
                if let offset = project.syncOffset(audio), abs(offset) >= 1 / 60.0 {
                    let label = String(format: "%+.2f s", offset) as NSString
                    let size = label.size(withAttributes: [.font: Theme.captionFont])
                    let chip = CGRect(x: max(left + 48, rect.maxX - size.width - 7), y: rect.minY + 1, width: size.width + 4, height: 13)
                    Theme.danger.setFill(); chip.fill()
                    label.draw(at: CGPoint(x: chip.minX + 2, y: chip.minY), withAttributes: [.font: Theme.captionFont, .foregroundColor: Theme.mediaMatte])
                }
                if selected || hoverY.map({ laneRow(.audio(audio.track)).contains(CGPoint(x: gutterWidth + 1, y: $0)) }) == true {
                    Theme.mediaMatte.setFill()
                    for edge in [RecorderCore.Edge.leading, .trailing] { fadeHandle(audio, edge: edge, project: project)?.fill() }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawAudioWaveform(_ audio: AudioClip, segment: (media: TimeRange, output: TimeRange), in rect: CGRect) {
        guard let peaks = waveformPeaks[audio.file], !peaks.isEmpty, rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let duration = segment.media.end - segment.media.start
        for span in silentSpans[audio.file] ?? [] where span.end > segment.media.start && span.start < segment.media.end {
            let start = rect.minX + rect.width * CGFloat((max(span.start, segment.media.start) - segment.media.start) / duration)
            let end = rect.minX + rect.width * CGFloat((min(span.end, segment.media.end) - segment.media.start) / duration)
            drawAudioHatch(CGRect(x: start, y: rect.minY, width: end - start, height: rect.height))
        }
        Theme.mediaMatte.withAlphaComponent(0.5).setFill()
        var pixel = max(gutterWidth, rect.minX)
        while pixel < min(bounds.width, rect.maxX) {
            let index = Int((segment.media.start + Double((pixel - rect.minX) / rect.width) * duration) * Double(Waveform.peaksPerSecond))
            if peaks.indices.contains(index), audio.gain > 0 {
                let height = max(1, min(1, CGFloat(peaks[index]).squareRoot() * audio.gain) * rect.height)
                CGRect(x: pixel, y: rect.midY - height / 2, width: 2, height: height).fill()
            }
            pixel += 3
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAudioHatch(_ rect: CGRect) {
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let path = NSBezierPath()
        var pixel = max(gutterWidth, rect.minX) - rect.height
        while pixel < min(bounds.width, rect.maxX) {
            path.move(to: CGPoint(x: pixel, y: rect.maxY)); path.line(to: CGPoint(x: pixel + rect.height, y: rect.minY)); pixel += 6
        }
        Theme.mediaMatte.withAlphaComponent(0.3).setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fadeHandle(_ audio: AudioClip, edge: RecorderCore.Edge, project: Project) -> CGRect? {
        let segments = project.audioSegments(audio)
        guard let first = segments.first, let last = segments.last else { return nil }
        let start = x(forOutput: first.output.start), end = x(forOutput: last.output.end)
        guard end - start >= 28 else { return nil }
        return CGRect(x: edge == .leading ? start + 8 : end - 14, y: laneRow(.audio(audio.track)).minY + 5, width: 6, height: 6)
    }

    private func layoutAudioHeaders() {
        guard let model else { return }
        let visible = Set(lanes.compactMap { lane -> Int? in
            if case .audio(let track) = lane { return track }
            return nil
        })
        for track in Array(audioHeaderButtons.keys) where !visible.contains(track) {
            if let buttons = audioHeaderButtons.removeValue(forKey: track) { [buttons.volume, buttons.mute, buttons.record].forEach { $0.removeFromSuperview() } }
        }
        for track in visible {
            let settings = model.project.audioTracks[track]
            if audioHeaderButtons[track] == nil {
                let volume = NSButton(title: settings.name, target: self, action: #selector(showAudioVolume(_:)))
                let mute = NSButton(title: "M", target: self, action: #selector(toggleAudioTrackMute(_:)))
                let record = NSButton(title: "●", target: nil, action: nil)
                for button in [volume, mute, record] {
                    button.tag = track; button.isBordered = false; button.font = Theme.captionFont
                    button.contentTintColor = Theme.textPrimary; addSubview(button)
                }
                audioHeaderButtons[track] = (volume, mute, record)
            }
            guard let buttons = audioHeaderButtons[track] else { continue }
            let row = laneRow(.audio(track))
            buttons.volume.title = settings.name
            buttons.volume.alignment = .left
            buttons.volume.frame = CGRect(x: 20, y: row.minY + 2, width: 76, height: 28)
            buttons.volume.toolTip = "\(settings.name) volume"
            buttons.volume.setAccessibilityLabel("\(settings.name) volume")
            buttons.mute.frame = CGRect(x: 98, y: row.minY + 2, width: 26, height: 28)
            buttons.mute.contentTintColor = settings.muted ? Theme.danger : Theme.textSecondary
            buttons.mute.setAccessibilityLabel("Mute \(settings.name)")
            buttons.mute.setAccessibilityValue(settings.muted ? "On" : "Off")
            buttons.record.frame = CGRect(x: 2, y: row.minY + 2, width: 28, height: 28)
            buttons.record.isHidden = compactTrackHeaders || !settings.name.hasPrefix("Voiceover")
            buttons.record.isEnabled = false
            buttons.record.toolTip = "Voiceover recording"
            buttons.record.setAccessibilityLabel("Record \(settings.name)")
            if settings.name.hasPrefix("Voiceover") { buttons.volume.frame = CGRect(x: 30, y: row.minY + 2, width: 66, height: 28) }
            buttons.volume.isHidden = compactTrackHeaders
            buttons.mute.isHidden = compactTrackHeaders
        }
    }

    private func drawAudioHeader(_ track: Int, row: CGRect) {
        guard let model else { return }
        let settings = model.project.audioTracks[track]
        if compactTrackHeaders || !settings.name.hasPrefix("Voiceover") {
            (settings.name.hasPrefix("Voiceover") ? Theme.voiceover : Theme.audio).setFill()
            CGRect(x: compactTrackHeaders ? 5 : 9, y: row.midY - 5, width: 3, height: 10).fill()
        }
        guard !compactTrackHeaders else { return }
        Theme.bgHover.setFill()
        let meter = CGRect(x: 20, y: row.maxY - 5, width: 104, height: 3)
        meter.fill()
        guard model.isPlaying, !settings.muted else { return }
        var level = 0.0
        for audio in model.project.audioClips where audio.track == track {
            for segment in model.project.audioSegments(audio) where model.playhead >= segment.output.start && model.playhead < segment.output.end {
                let media = segment.media.start + (model.playhead - segment.output.start) / (segment.output.end - segment.output.start) * (segment.media.end - segment.media.start)
                let index = Int(media * Double(Waveform.peaksPerSecond))
                if let peaks = waveformPeaks[audio.file], peaks.indices.contains(index) {
                    let ramp = model.project.audioVolumeRamps(audio).first { model.playhead >= $0.range.start && model.playhead <= $0.range.end }
                    let gain = ramp.map { $0.start + ($0.end - $0.start) * (model.playhead - $0.range.start) / ($0.range.end - $0.range.start) } ?? audio.gain
                    level = max(level, Double(peaks[index]) * gain * settings.volume)
                }
            }
        }
        Theme.audio.setFill()
        CGRect(x: meter.minX, y: meter.minY, width: meter.width * min(1, sqrt(level)), height: 3).fill()
    }

    @objc private func toggleAudioTrackMute(_ sender: NSButton) {
        guard model?.project.audioTracks.indices.contains(sender.tag) == true else { return }
        model?.edit("Mute Track") { $0.audioTracks[sender.tag].muted.toggle() }
        needsLayout = true
    }

    @objc private func showAudioVolume(_ sender: NSButton) {
        guard let model, model.project.audioTracks.indices.contains(sender.tag) else { return }
        let track = sender.tag
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            LabeledSlider(title: model.project.audioTracks[track].name, value: trackVolumeBinding(track),
                          range: 0...2, defaultValue: 1, format: { String(format: "%.0f%%", $0 * 100) }, onEditingChanged: { editing in
                editing ? model.beginGesture() : model.commitGesture("Track Volume")
            }).padding(16).frame(width: 280).signalWindow())
        volumePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func trackVolumeBinding(_ track: Int) -> Binding<Double> {
        guard let model, model.project.audioTracks.indices.contains(track) else { return .constant(1) }
        let id = model.project.audioTracks[track].id
        return Binding(get: { model.project.audioTracks.first { $0.id == id }?.volume ?? 1 }, set: { value in
            guard value.isFinite else { return }
            model.update { project in
                if let index = project.audioTracks.firstIndex(where: { $0.id == id }) { project.audioTracks[index].volume = min(2, max(0, value)) }
            }
        })
    }

    private func drawLinkedPartners(_ project: Project) {
        let selectedAudio = project.audioClips.filter { audio in UUID(uuidString: audio.id).map { model?.selection.contains($0) == true } ?? false }
        func outline(_ rect: CGRect) {
            Theme.textPrimary.withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1)); path.lineWidth = 1; path.stroke()
        }
        var output = 0.0
        for (index, clip) in project.clips.enumerated() {
            defer { output += clip.outputDuration }
            if !clip.isEmpty, selectedAudio.contains(where: { $0.link == .screen && $0.start < clip.sourceEnd && $0.end > clip.sourceStart }) {
                outline(CGRect(x: x(forOutput: output), y: laneRow(.clip).minY + 3, width: CGFloat(clip.outputDuration * geometry.pxPerSecond), height: laneRow(.clip).height - 6))
            }
            if model?.selectedClips.contains(index) == true {
                for audio in project.audioClips where audio.link == .screen && audio.start < clip.sourceEnd && audio.end > clip.sourceStart {
                    project.audioSegments(audio).forEach { outline(audioRect(audio, output: $0.output)) }
                }
            }
        }
        for camera in project.cameraClips {
            let selected = UUID(uuidString: camera.id).map { model?.selection.contains($0) == true } ?? false
            let partners = project.audioClips.filter { $0.link == .camera && $0.start < camera.end && $0.end > camera.start }
            if selected { for audio in partners { project.audioSegments(audio).forEach { outline(audioRect(audio, output: $0.output)) } } }
            if partners.contains(where: { audio in selectedAudio.contains { $0.id == audio.id } }) {
                for segment in visibleSegments(start: camera.start, end: camera.end, project: project, timeMap: TimeMap(project.clips)) {
                    outline(CGRect(x: x(forOutput: segment.outStart), y: laneRow(.camera).minY + 3, width: CGFloat((segment.outEnd - segment.outStart) * geometry.pxPerSecond), height: laneRow(.camera).height - 6))
                }
            }
        }
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
        didSet {
            timelineView?.onNavigationChange = { [weak self] in self?.syncSlider() }
            syncSlider()
        }
    }

    private let pointerButton = NSButton(title: "", target: nil, action: nil)
    private let splitButton = ScissorsButton(title: "", target: nil, action: nil)
    private let rippleButton = NSButton(title: "", target: nil, action: nil)
    private let linkButton = NSButton(title: "", target: nil, action: nil)
    private let snapButton = NSButton(title: "", target: nil, action: nil)
    private let focusButton = NSButton(title: "", target: nil, action: nil)
    private let fitButton = NSButton(title: "", target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        TechAppKit.styleSurface(self)
        let buttons: [(NSButton, Selector, String)] = [
            (pointerButton, #selector(pointerTapped), "Select tool (V). Drag empty video space or below tracks to box-select video; Shift-click to add or remove clips."),
            (splitButton, #selector(splitTapped), "Blade tool (S). Command-click splits the clip at the playhead without changing tools. C splits the selection."),
            (snapButton, #selector(snapTapped), "Toggle snapping (N). Hold Command while dragging to bypass."),
            (linkButton, #selector(linkTapped), "Link layers to video. Video cuts, deletion, trims, moves and speed changes carry layers; layer edits stay independent."),
            (rippleButton, #selector(rippleTapped), "Ripple Delete. Close the space when deleting video clips; turn off to leave a gap."),
            (focusButton, #selector(focusTapped), "Focus selected clips or effects (F)"),
            (fitButton, #selector(fitTapped), "Fit whole project (Shift–Z)"),
            (zoomOutButton, #selector(zoomOutTapped), "Zoom out (Command–Minus)"),
            (zoomInButton, #selector(zoomInTapped), "Zoom in (Command–Plus)")]
        for (button, action, help) in buttons {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryChange)
            button.imageScaling = .scaleNone
            button.contentTintColor = Theme.textSecondary
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.target = self; button.action = action; button.toolTip = help
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.setAccessibilityLabel(help)
        }
        for (button, symbol) in [(pointerButton, "cursorarrow"), (splitButton, "scissors"),
                                  (snapButton, "align.horizontal.center"), (linkButton, "link"), (rippleButton, "arrow.left.to.line"), (focusButton, "viewfinder"), (fitButton, "arrow.left.and.right"),
                                  (zoomOutButton, "minus"), (zoomInButton, "plus")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            button.imagePosition = .imageOnly
            button.title = ""
        }
        let left = NSStackView(views: [pointerButton, splitButton, snapButton, linkButton, rippleButton])
        let right = NSStackView(views: [focusButton, fitButton, zoomOutButton, zoomInButton])
        for stack in [left, right] {
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func syncSlider() {
        guard let timelineView else { return }
        for (button, selected) in [(pointerButton, !timelineView.debugSplitMode),
                                   (splitButton, timelineView.debugSplitMode),
                                   (snapButton, timelineView.snappingEnabled),
                                   (linkButton, timelineView.linkedVideoEdits),
                                   (rippleButton, timelineView.rippleDeleteEnabled)] {
            button.contentTintColor = selected ? Theme.textPrimary : Theme.textTertiary
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "On" : "Off")
        }
        focusButton.isEnabled = timelineView.canFocusSelection
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.textPrimary.setFill()
        for button in [pointerButton, splitButton, snapButton, linkButton, rippleButton] where button.state == .on {
            let rect = convert(button.bounds, from: button)
            CGRect(x: rect.midX - 5, y: 1, width: 10, height: 1).fill()
        }
    }

    @objc private func pointerTapped() { timelineView?.selectTool(); syncSlider() }
    @objc private func rippleTapped() { timelineView?.toggleRippleDelete() }
    @objc private func linkTapped() { timelineView?.toggleLinkedVideoEdits() }
    @objc private func snapTapped() { timelineView?.toggleSnapping() }
    @objc private func focusTapped() { timelineView?.menuZoomToSelection() }
    @objc private func splitTapped() {
        if splitButton.commandClick { timelineView?.splitClipAtPlayhead() }
        else { timelineView?.toggleSplitModeSticky() }
        syncSlider()
        timelineView?.window?.makeFirstResponder(timelineView)
    }
    @objc private func fitTapped() { timelineView?.fit() }
    @objc private func zoomOutTapped() { timelineView?.stepZoom(by: 1 / 1.4) }
    @objc private func zoomInTapped() { timelineView?.stepZoom(by: 1.4) }
}

// Capture the modifier on mouse-down; NSButton still owns normal click tracking and release.
private final class ScissorsButton: NSButton {
    private(set) var commandClick = false
    override func mouseDown(with event: NSEvent) {
        commandClick = event.modifierFlags.contains(.command)
        defer { commandClick = false }
        super.mouseDown(with: event)
    }
}

extension TimelineToolbar {
    @MainActor static func runCommandSplitSelfTest() throws {
        _ = NSApplication.shared
        struct Fail: Error, CustomStringConvertible { let description: String }
        func check(_ value: Bool, _ message: String) throws { if !value { throw Fail(description: message) } }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("scissors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for sticky in [false, true] {
            var project = Project(source: Source(duration: 10), clips: [
                Clip(sourceStart: 0, sourceEnd: 4), Clip(sourceStart: 4, sourceEnd: 8),
                Clip(sourceStart: 8, sourceEnd: 10)])
            project.clips[2].isGap = true
            project.linkVideoEdits = false
            project.zooms = [Zoom(start: 0, end: 4, scale: 2)]
            let model = EditorModel(packageURL: scratch, project: project, events: EventLog())
            defer { model.saveNow() }
            let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: 250))
            timeline.model = model
            let toolbar = TimelineToolbar(frame: CGRect(x: 0, y: 250, width: 900, height: 40))
            toolbar.timelineView = timeline
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 290),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView?.addSubview(timeline)
            window.contentView?.addSubview(toolbar)
            window.contentView?.layoutSubtreeIfNeeded()
            func click(_ modifiers: NSEvent.ModifierFlags) {
                let point = toolbar.splitButton.convert(CGPoint(x: 14, y: 14), to: nil)
                func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                // Modifier released before mouse-up: the mouse-down intent must survive button tracking.
                NSApp.postEvent(event(.leftMouseUp, []), atStart: true)
                toolbar.splitButton.mouseDown(with: event(.leftMouseDown, modifiers))
            }
            if sticky { click([]) }
            try check(timeline.debugSplitMode == sticky, "ordinary click did not toggle blade")
            model.playhead = 2
            model.selectedClip = 1 // Selection does not span playhead: use the active screen clip.
            model.selection = [UUID(uuidString: project.zooms[0].id)!]
            click(.command)
            try check(model.project.clips.count == 4 && model.project.clips[0].sourceEnd == 2 &&
                      model.project.clips[1].sourceStart == 2 && model.project.zooms == project.zooms,
                      "Command-click did not split exactly the screen clip at playhead")
            try check(timeline.debugSplitMode == sticky && toolbar.splitButton.state == (sticky ? .on : .off),
                      "Command-click changed persistent tool state: mode=\(timeline.debugSplitMode), button=\(toolbar.splitButton.state.rawValue), expected=\(sticky)")
            try check(model.undoStepCount == 1 && model.selectedClip == 0 && model.selection.isEmpty,
                      "undo count or selection continuity")
            let split = model.project
            model.undo()
            try check(model.project == project, "undo did not restore geometry")
            model.redo()
            try check(model.project == split, "redo did not restore split")
            for time in [0.0, 2, 4, 9, 10] {
                model.playhead = time
                let before = model.project, count = model.undoStepCount
                click(.command)
                try check(model.project == before && model.undoStepCount == count && timeline.debugSplitMode == sticky,
                          "edge/gap click edited or changed tools")
            }
            model.playhead = 6
            model.selectedClip = 2 // Selected clip spans the playhead.
            click(.command)
            try check(model.project.clips[2].sourceEnd == 6 && model.selectedClip == 2,
                      "valid selected target was not retained")
            try check(model.project.checkInvariants() == nil, "invalid clip geometry")
            let beforeOrdinary = model.project
            click([])
            try check(timeline.debugSplitMode != sticky && model.project == beforeOrdinary,
                      "ordinary click split media or failed to toggle")
        }
    }
}


extension TimelineView {
    @MainActor static func checkClipZeroSnap(packageURL: URL) throws {
        struct Fail: Error { }
        for disabled in [false, true] {
            var gap = Clip(sourceStart: 0, sourceEnd: 1)
            gap.isGap = true
            var project = Project(source: Source(duration: 5), clips: [gap, Clip(sourceStart: 1, sourceEnd: 5)])
            project.linkVideoEdits = false
            let model = EditorModel(packageURL: packageURL, project: project, events: EventLog())
            let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: 250))
            view.model = model
            view.dragClips = project.clips
            view.dragProject = project
            view.dragSelection = [1]
            view.dragKind = .moveClip(index: 1, anchor: 2)
            model.beginGesture()
            let event = NSEvent.mouseEvent(with: .leftMouseDragged,
                location: CGPoint(x: view.x(forOutput: 1.00165), y: 60),
                modifierFlags: disabled ? [.command] : [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            view.mouseDragged(with: event)
            if disabled {
                guard model.project.clips[0].isEmpty,
                      abs(model.project.clips[0].outputDuration - 0.00165) < 1e-8 else { throw Fail() }
            } else {
                guard !model.project.clips[0].isEmpty, model.project.videoOpacity(atOutput: 0) == 1 else { throw Fail() }
            }
            model.cancelGesture()
            model.saveNow()
        }
    }
}
