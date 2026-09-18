import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import Observation
import QuartzCore
import SwiftUI
import RecorderCore

/// Direct-manipulation video preview (SPEC §6.1, §6.2 "Preview"). Drives an `AVPlayer` over the
/// clip composition (`makeComposition`, T-305) and renders every displayed frame through the same
/// `Compositor` the exporter will use (`makeFrameState`, AC-ED-2). `draw` pulls the current pixel
/// buffer via `AVPlayerItemVideoOutput`, builds a `FrameState` and calls `Compositor.render`.
final class PreviewView: MTKView {
    let model: EditorModel

    private let compositor: Compositor
    private let textureCache: TextureCache
    private let commandQueue: MTLCommandQueue

    private var player: AVPlayer?
    private var screenOutput: AVPlayerItemVideoOutput?
    private var lastScreenPixelBuffer: CVPixelBuffer?
    private var statusObservation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?

    // T-502: camera.mov decode. `AVPlayerItemVideoOutput` has no per-track selection, so the camera
    // gets its own player over an `isolateTrack`-built single-track composition, kept in lockstep
    // with `player` (every seek/rate change mirrored) — see `FrameSource.isolateTrack`.
    private var cameraPlayer: AVPlayer?
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var lastCameraPixelBuffer: CVPixelBuffer?

    private var isSeeking = false
    private var pendingSeekTime: Double?
    private var lastClips: [Clip]

    /// Bounds the "no frame yet" redraw retry below (SPEC §6.2: "paused always shows a frame").
    private var pendingFrameRetries = 0
    private static let maxFrameRetries = 30
    // T-502: drag-to-reposition the camera bubble — `nil` unless the drag started inside it.
    // `Camera.corner` is the only stored position (four discrete corners, SPEC §6.6), so there's no
    // continuous position to follow live; the bubble snaps to the nearest corner on mouse-up.
    private var cameraDragActive = false

    // T-415: manual-zoom-target overlay — a `SelectionRectView` subview covering the whole preview,
    // shown only while a `.manual` zoom is selected (SPEC §6.6 "with a manual zoom selected, a
    // rectangle overlay shows the zoom target and can be dragged"). `PreviewView` overrides `hitTest`
    // (below) to keep routing every mouse event through its own `mouseDown`/`mouseDragged`/`mouseUp`
    // (same pattern as the camera-bubble drag) and forwards to `zoomTargetView` by calling its
    // handlers directly — that gives a `mouseUp`-time drag-end signal (`isDragging` just before the
    // forwarded call) without adding a second mouse-handling mechanism or subclassing
    // `SelectionRectView` (`final`).
    private let zoomTargetView = SelectionRectView(frame: .zero)
    private var zoomTargetContentRect: CGRect = .zero
    private var zoomTargetGestureActive = false

    init(model: EditorModel) {
        self.model = model
        self.lastClips = model.project.clips
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("no Metal device")
        }
        compositor = try! Compositor(device: device, package: model.packageURL)
        textureCache = TextureCache(device: device)
        commandQueue = queue
        super.init(frame: .zero, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm

        zoomTargetView.allowsResize = false
        zoomTargetView.minSize = CGSize(width: 1, height: 1)
        zoomTargetView.isHidden = true
        zoomTargetView.autoresizingMask = [.width, .height]
        zoomTargetView.onChange = { [weak self] r in self?.zoomTargetRectChanged(r) }
        addSubview(zoomTargetView)

        rebuildComposition()
        observeProject()
        observeSelection()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { displayLink?.invalidate() }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        updateZoomTargetOverlay()
    }

    // MARK: - Transport (SPEC §7.3; `TransportBar` below calls these)

    /// AC-TL-7 (split-mode hover): OUTPUT seconds. Non-nil + paused ⇒ the preview shows that frame
    /// (a coalesced, zero-tolerance seek — same mechanism `seek(toOutput:)` uses) WITHOUT moving
    /// `model.playhead`; `nil` seeks back to the playhead frame. Ignored while playing (`draw`'s
    /// `displayTime` falls back to `model.playhead` then) — a live playhead already drives the
    /// player, and split mode only hovers a paused timeline. One-line coordinator hook:
    /// `timeline.onHoverTime = { [weak preview] in preview?.hoverTime = $0 }`.
    var hoverTime: Double? {
        didSet {
            guard hoverTime != oldValue else { return }
            needsDisplay = true
            guard !model.isPlaying else { return }
            performSeek(to: hoverTime ?? model.playhead)
        }
    }

    func togglePlayPause() {
        model.isPlaying ? pause() : setRate(1)
    }

    func stepFrame(_ deltaSeconds: Double) {
        pause()
        seek(toOutput: model.playhead + deltaSeconds)
    }

    /// Coalesced: never queues more than one pending seek (SPEC §6.2 "Scrub").
    func seek(toOutput t: Double) {
        let clamped = min(max(t, 0), max(model.timeMap.outputDuration, 0))
        model.playhead = clamped
        performSeek(to: clamped)
    }

    private func performSeek(to t: Double) {
        let clamped = min(max(t, 0), max(model.timeMap.outputDuration, 0))
        pendingSeekTime = clamped
        needsDisplay = true
        if !isSeeking { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let t = pendingSeekTime, let player else { pendingSeekTime = nil; return }
        pendingSeekTime = nil
        isSeeking = true
        let time = CMTime(seconds: t, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false
            self.needsDisplay = true
            if self.pendingSeekTime != nil { self.performPendingSeek() }
        }
        // Best-effort: the camera bubble only needs to be roughly in sync, not gate the main seek's
        // completion callback (AC-ED-2 parity is graded on the screen path; export reads camera
        // frame-accurately off its own reader, T-505).
        cameraPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func setRate(_ rate: Float) {
        guard rate != 0, let player else { pause(); return }
        // A lingering hover seek must not hijack where playback resumes from (AC-TL-7 is a paused-
        // only feature; leaving the player wherever the last hover looked would desync it from
        // `model.playhead`).
        if hoverTime != nil { performSeek(to: model.playhead) }
        model.isPlaying = true
        player.rate = rate
        cameraPlayer?.rate = rate
        startDisplayLink()
    }

    private func pause() {
        player?.pause()
        cameraPlayer?.pause()
        model.isPlaying = false
        stopDisplayLink()
        needsDisplay = true
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let player, let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        model.playhead = t
        if item.duration.isValid, t >= item.duration.seconds - 1.0 / 60 {
            pause()
            return
        }
        needsDisplay = true
    }

    // MARK: - Keys (SPEC §7.3): Space, ←/→, ⇧←/⇧→, Home/End, J/K/L

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlayPause()                              // Space
        case 123: stepFrame(shift ? -1.0 : -1.0 / 60)            // ←
        case 124: stepFrame(shift ? 1.0 : 1.0 / 60)              // →
        case 115: pause(); seek(toOutput: 0)                     // Home
        case 119: pause(); seek(toOutput: model.timeMap.outputDuration) // End
        case 38: setRate(-1)                                     // J
        case 40: setRate(0)                                      // K
        case 37: setRate(1)                                      // L
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Composition (SPEC §6.2: rebuild on clip edits, keep playhead)

    private func observeProject() {
        withObservationTracking {
            _ = model.project
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateZoomTargetOverlay()
                let clips = self.model.project.clips
                if clips != self.lastClips {
                    self.lastClips = clips
                    self.rebuildComposition()
                } else {
                    self.needsDisplay = true
                }
                self.observeProject()
            }
        }
    }

    // T-415: `model.selection` lives outside `project` (it's UI state, not saved), so it needs its
    // own `withObservationTracking` — same one-more-registration-per-fire pattern as `observeProject`.
    private func observeSelection() {
        withObservationTracking {
            _ = model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateZoomTargetOverlay()
                self.observeSelection()
            }
        }
    }

    private func rebuildComposition() {
        let project = model.project
        let packageURL = model.packageURL
        let resumeSeconds = player?.currentTime().seconds ?? model.playhead
        Task { [weak self] in
            guard let self else { return }
            do {
                let (composition, audioMix) = try await makeComposition(package: packageURL, project: project)
                await MainActor.run { self.attach(composition: composition, audioMix: audioMix, resumeSeconds: resumeSeconds) }
            } catch {
                // ponytail: a package whose screen.mov is missing/too short just shows an empty
                // preview; recording/onboarding never hands the editor a project without one.
            }
        }
    }

    private func attach(composition: AVMutableComposition, audioMix: AVAudioMix, resumeSeconds: Double) {
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        screenOutput = output
        lastScreenPixelBuffer = nil
        pendingFrameRetries = 0

        attachCamera(from: composition)

        // A freshly attached item has no decoded frame yet — `copyPixelBuffer` returns nil until
        // one exists, so drawing right away (or on a bare `readyToPlay`, which doesn't guarantee the
        // output has a buffer for the resume time) shows only the background, with the screen pass
        // skipped entirely (T-306 fix: "paused at open" showed no screen quad). Only a *completed*
        // zero-tolerance seek guarantees the output has a frame ready to redraw with.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.seekToShowCurrentFrame(resumeSeconds: resumeSeconds) }
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
        }
        needsDisplay = true
    }

    private func seekToShowCurrentFrame(resumeSeconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.needsDisplay = true
        }
        cameraPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// T-502: `composition`'s video track[1] (camera), isolated into its own single-track
    /// composition/player since `AVPlayerItemVideoOutput` can't select a track out of a shared item
    /// (`FrameSource.isolateTrack`). No-op when the project has no second video track.
    private func attachCamera(from composition: AVMutableComposition) {
        let videoTracks = composition.tracks(withMediaType: .video)
        guard videoTracks.count > 1 else {
            cameraPlayer = nil; cameraOutput = nil; lastCameraPixelBuffer = nil
            return
        }
        let cameraComposition = isolateTrack(videoTracks[1], duration: composition.duration)
        let item = AVPlayerItem(asset: cameraComposition)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        cameraOutput = output
        lastCameraPixelBuffer = nil
        if let cameraPlayer {
            cameraPlayer.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            newPlayer.volume = 0
            cameraPlayer = newPlayer
        }
    }

    // MARK: - Draw (SPEC §6.2 "Preview")

    override func draw(_ dirtyRect: NSRect) {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let project = model.project
        let unit = compositor.outputSize(for: project, longEdge: 1000)   // aspect only
        let aspect = unit.width / unit.height
        let viewportRect = screenRect(output: drawableSize, cropAspect: aspect, padding: 0)

        let pixelBuffer = currentScreenPixelBuffer()
        if pixelBuffer != nil {
            pendingFrameRetries = 0
        } else if !model.isPlaying {
            // `copyPixelBuffer(forItemTime:)` can still be nil for a beat right after a seek
            // completes — the item's decode pipeline hasn't caught up yet even though the seek
            // itself is done (T-306: "paused always shows a frame"). Nothing else re-triggers a
            // draw once we're paused and idle, so without this the screen quad stays missing
            // forever instead of just for the one dropped frame. Bounded so a package that really
            // has no screen video (see `rebuildComposition`'s catch) doesn't retry forever.
            scheduleFrameRetryIfNeeded()
        }
        let screenTexture = pixelBuffer.flatMap { textureCache.texture(from: $0) }
        let cameraTexture = currentCameraPixelBuffer().flatMap { textureCache.texture(from: $0) }
        // AC-TL-7: while paused, a non-nil `hoverTime` overrides what's DISPLAYED (`FrameState` is
        // still a pure function of this one output time — `model.playhead` itself is untouched).
        let displayTime = (!model.isPlaying ? hoverTime : nil) ?? model.playhead
        var state = makeFrameState(model: model, outputTime: displayTime, screen: screenTexture, camera: cameraTexture, size: viewportRect.size)

        // T-415: a `.manual` zoom selected ⇒ show the UN-zoomed frame (SPEC §6.6) so the target
        // overlay (`zoomTargetView`) is drawn against the same un-zoomed content it's positioned
        // over. Preview-only override — `makeFrameState`/export are untouched.
        if selectedManualZoom() != nil {
            state.view = .identity
            state.prevView = .identity
        }

        compositor.render(state, to: drawable.texture, commandBuffer: commandBuffer, viewport: viewportRect)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func scheduleFrameRetryIfNeeded() {
        guard screenOutput != nil, pendingFrameRetries < Self.maxFrameRetries else { return }
        pendingFrameRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.needsDisplay = true
        }
    }

    /// `copyPixelBuffer(forItemTime:)`, keeping the last buffer when a new one isn't ready (SPEC
    /// §6.2: "holds last frame for VFR gaps").
    private func currentScreenPixelBuffer() -> CVPixelBuffer? {
        guard let output = screenOutput else { return lastScreenPixelBuffer }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastScreenPixelBuffer = buffer
        }
        return lastScreenPixelBuffer
    }

    private func currentCameraPixelBuffer() -> CVPixelBuffer? {
        guard let output = cameraOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastCameraPixelBuffer = buffer
        }
        return lastCameraPixelBuffer
    }

    // MARK: - Manual zoom target (SPEC §6.6, T-415)

    /// The selected zoom, if it's the only selected block and its mode is `.manual` — the one state
    /// that shows the target overlay (SPEC §6.6: "with a manual zoom selected…").
    private func selectedManualZoom() -> Zoom? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        guard let zoom = model.project.zooms.first(where: { $0.id == id.uuidString }) else { return nil }
        return zoom.mode == .manual ? zoom : nil
    }

    private func updateZoomTargetOverlay() {
        guard let zoom = selectedManualZoom() else {
            zoomTargetView.isHidden = true
            return
        }
        zoomTargetView.isHidden = false
        zoomTargetView.frame = bounds
        let content = ZoomTargetMapping.contentRect(viewBounds: bounds.size, project: model.project)
        zoomTargetContentRect = content
        zoomTargetView.limit = content
        zoomTargetView.aspect = content.height > 0 ? content.width / content.height : nil
        // Don't fight the mouse mid-drag (same guard `CropSheet`/`AreaSelectionOverlay` use for their
        // own field-commit races) — `zoomTargetRectChanged` is already updating `zoom.center` live.
        if !zoomTargetView.isDragging {
            zoomTargetView.rect = ZoomTargetMapping.rect(center: zoom.center, scale: zoom.scale, in: content)
        }
        needsDisplay = true
    }

    /// `zoomTargetView.onChange`: fires on every rect mutation, including `updateZoomTargetOverlay`'s
    /// own programmatic assignment above — only a real drag (bracketed by `beginGesture`/
    /// `commitGesture` in `zoomTargetDragEnded`) turns a change into a `Project` edit.
    private func zoomTargetRectChanged(_ r: CGRect) {
        guard let zoom = selectedManualZoom() else { return }
        if zoomTargetView.isDragging, !zoomTargetGestureActive {
            model.beginGesture()
            zoomTargetGestureActive = true
        }
        guard zoomTargetGestureActive else { return }
        let center = ZoomTargetMapping.center(fromRect: r, in: zoomTargetContentRect)
        let zoomID = zoom.id
        model.update { project in
            guard let idx = project.zooms.firstIndex(where: { $0.id == zoomID }) else { return }
            project.zooms[idx].center = center
        }
        needsDisplay = true
    }

    private func zoomTargetDragEnded() {
        guard zoomTargetGestureActive else { return }
        zoomTargetGestureActive = false
        model.commitGesture("Move Zoom Target")
    }

    // MARK: - Camera drag (SPEC §6.6 Camera tab, T-502)

    /// This view isn't flipped (AppKit default, bottom-left origin/y-up) — mouse points are
    /// converted straight from the event, and the camera-bubble geometry below is expressed in that
    /// same convention (unlike `Compositor`'s own top-left/y-down canvas space).
    private func viewportRectInBounds() -> CGRect {
        let unit = compositor.outputSize(for: model.project, longEdge: 1000)   // aspect only
        let aspect = unit.width / unit.height
        return screenRect(output: bounds.size, cropAspect: aspect, padding: 0)
    }

    /// `Compositor.cameraBubbleRect` is top-left/y-down (canvas pixel space); flip it into this
    /// view's bottom-left/y-up bounds space instead of duplicating the margin/size formula.
    /// Ignores `shrinkWhenZoomed` (uses `viewScale: 1`) — a reasonable hit-test simplification, the
    /// bubble only shrinks a little and dragging mid-zoom is a rare edge case.
    private func cameraBubbleRectInBounds() -> CGRect {
        let viewport = viewportRectInBounds()
        let local = Compositor.cameraBubbleRect(project: model.project, outputSize: viewport.size)
        return CGRect(x: viewport.minX + local.minX, y: viewport.minY + (viewport.height - local.maxY),
                       width: local.width, height: local.height)
    }

    // T-415: never let AppKit's default hit-testing hand events straight to `zoomTargetView` (it
    // would bypass everything below) — `self` stays the one dispatch point, same as the camera
    // bubble, which has no subview of its own at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard zoomTargetView.isHidden else {
            zoomTargetView.mouseDown(with: event)
            window?.makeFirstResponder(self)   // keep Space/←/→ (SPEC §7.3) on the preview itself
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if model.project.source.hasCamera, cameraBubbleRectInBounds().contains(p) {
            cameraDragActive = true
        } else {
            cameraDragActive = false
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoomTargetView.isHidden else { zoomTargetView.mouseDragged(with: event); return }
        guard cameraDragActive else { super.mouseDragged(with: event); return }
        // No live follow: `Camera.corner` is the only stored position (four discrete corners) — the
        // bubble snaps to whichever corner the mouse is released over, like the recording-time
        // bubble (`CameraBubblePanel.snap()`).
    }

    override func mouseUp(with event: NSEvent) {
        guard zoomTargetView.isHidden else {
            let wasDragging = zoomTargetView.isDragging
            zoomTargetView.mouseUp(with: event)
            if wasDragging { zoomTargetDragEnded() }
            return
        }
        guard cameraDragActive else { super.mouseUp(with: event); return }
        cameraDragActive = false
        let p = convert(event.locationInWindow, from: nil)
        let viewport = viewportRectInBounds()
        let corner: Camera.Corner
        switch (p.x < viewport.midX, p.y < viewport.midY) {
        case (true, true): corner = .bottomLeft
        case (true, false): corner = .topLeft
        case (false, true): corner = .bottomRight
        case (false, false): corner = .topRight
        }
        if corner != model.project.camera.corner {
            model.edit("Camera position") { $0.camera.corner = corner }
        }
    }
}

// MARK: - Selftest `hover-preview <package>` (AC-TL-7)

extension PreviewView {
    /// Drives the real `AVPlayer` seek path (not a mock) over a package with real media: `hoverTime`
    /// shows a different frame than `model.playhead` without moving it, and `nil` seeks back.
    @MainActor
    static func runHoverPreviewSelfTest(_ args: [String]) async throws {
        struct Fail: Error, CustomStringConvertible { let description: String }
        guard let packagePath = args.first else { throw Fail(description: "usage: hover-preview <package>") }
        let packageURL = URL(fileURLWithPath: packagePath)
        let model = try loadEditorModel(package: packageURL)
        let playheadTime = min(0.4, model.timeMap.outputDuration / 2)
        model.playhead = playheadTime

        let view = PreviewView(model: model)
        view.setFrameSize(NSSize(width: 640, height: 360))

        func waitUntil(_ timeout: Double = 5, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() {
                guard Date() < deadline else { throw Fail(description: "timed out waiting") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func playerSeconds() -> Double { view.player?.currentTime().seconds ?? -1 }

        // Let the initial attach + seek-to-playhead settle.
        try await waitUntil { view.player?.currentItem?.status == .readyToPlay }
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - playheadTime) < 0.05 }

        let hoverTarget = min(1.0, model.timeMap.outputDuration - 0.1)
        guard hoverTarget > playheadTime + 0.05 else { throw Fail(description: "fixture too short for a distinct hover target") }

        view.hoverTime = hoverTarget
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - hoverTarget) < 0.05 }
        guard model.playhead == playheadTime else {
            throw Fail(description: "hoverTime moved model.playhead: \(model.playhead) != \(playheadTime)")
        }
        print("hover-preview: playhead=\(playheadTime) hoverTarget=\(hoverTarget) player=\(playerSeconds())")

        view.hoverTime = nil
        try await waitUntil { !view.isSeeking && abs(playerSeconds() - playheadTime) < 0.05 }
        guard model.playhead == playheadTime else {
            throw Fail(description: "nil hoverTime changed model.playhead: \(model.playhead) != \(playheadTime)")
        }
        print("hover-preview OK: hover moved the player without touching model.playhead; nil restored the playhead frame")
    }
}

// MARK: - Transport bar (SwiftUI, under the preview — SPEC §6.1 mockup)

/// `⏮ ◀❙ ▶ ❙▶ ⏭   00:12.40 / 01:33.00` — triggers `PreviewView`'s transport methods and mirrors
/// `model`'s playhead/duration (`EditorModel` is `@Observable`; reading its properties here is
/// enough for SwiftUI to re-render on change).
struct TransportBar: View {
    let model: EditorModel
    let preview: PreviewView

    var body: some View {
        HStack(spacing: 20) {
            transportButton("backward.end.fill") { preview.seek(toOutput: 0) }
            transportButton("backward.frame.fill") { preview.stepFrame(-1.0 / 60) }
            transportButton(model.isPlaying ? "pause.fill" : "play.fill") { preview.togglePlayPause() }
            transportButton("forward.frame.fill") { preview.stepFrame(1.0 / 60) }
            transportButton("forward.end.fill") { preview.seek(toOutput: model.timeMap.outputDuration) }
            Text("\(Self.timecode(model.playhead)) / \(Self.timecode(model.timeMap.outputDuration))")
                .font(Font(Theme.timecodeFont(13)))
                .foregroundStyle(Theme.textPrimaryColor)
        }
        .padding(.vertical, 10)
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.textPrimaryColor)
        }
        .buttonStyle(.plain)
    }

    static func timecode(_ t: Double) -> String {
        let clamped = max(0, t)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        let hundredths = Int(((clamped - clamped.rounded(.down)) * 100).rounded())
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}
